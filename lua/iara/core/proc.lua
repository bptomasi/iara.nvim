--- Owned processes: direct argv spawning on libuv with bounded streams,
--- wall deadlines, and TERM/KILL/pipe-close escalation. See section 5 of
--- contracts.md for the public contract.
local M = {}

local uv = vim.uv

---Escalation steps, measured from the moment a job starts ending.
local ESCALATION = { kill_ms = 200, close_ms = 500, report_ms = 1000 }

---Pipes still open this long after a natural exit belong to descendants.
local NATURAL_CLOSE_MS = 500

local STREAM_DEFAULTS = {
  stdout = { mode = "collect", max_bytes = 1048576 },
  stderr = { mode = "collect", max_bytes = 65536 },
}
local DEFAULT_MAX_LINE_BYTES = 65536
local MODES = { lines = true, chunks = true, collect = true, discard = true }

local next_id = 0
---@type table<integer, table> Live jobs by id, until on_complete runs.
local live = {}
local augroup = nil

---Validate `argv` and copy it in the same pass: the full list for the
---handle and the operands for libuv. Strings are immutable, so a shallow
---copy keeps later caller mutations away from the job; one pass replaces
---the three list copies spawning used to make.
---@return string[] copy, string[] args
local function copy_argv(argv)
  if type(argv) ~= "table" or argv[1] == nil then
    error("iara.core.proc: argv must be a non-empty list", 3)
  end
  local copy, args = {}, {}
  for index, item in ipairs(argv) do
    if type(item) ~= "string" then
      error(("iara.core.proc: argv[%d] is not a string"):format(index), 3)
    end
    if item:find("\0", 1, true) then
      error(("iara.core.proc: argv[%d] contains NUL"):format(index), 3)
    end
    copy[index] = item
    if index > 1 then
      args[index - 1] = item
    end
  end
  return copy, args
end

local function validate_admission(admission, level)
  if admission == nil then
    return
  end
  local valid = type(admission) == "table"
    and type(admission.group) == "string"
    and type(admission.max) == "number"
    and admission.max >= 1
  if not valid then
    error("iara.core.proc: admission needs a group and a max >= 1", level)
  end
end

local function validate_stream(stream, name)
  if stream == nil then
    return
  end
  if type(stream) ~= "table" or not MODES[stream.mode or "collect"] then
    error(("iara.core.proc: invalid %s stream mode"):format(name), 4)
  end
  local delimiter = stream.delimiter
  if delimiter ~= nil and (type(delimiter) ~= "string" or #delimiter ~= 1) then
    error(("iara.core.proc: %s delimiter must be one byte"):format(name), 4)
  end
end

local function validate_opts(opts)
  if type(opts) ~= "table" then
    error("iara.core.proc: opts must be a table", 3)
  end
  if type(opts.on_complete) ~= "function" then
    error("iara.core.proc: opts.on_complete is required", 3)
  end
  if type(opts.cwd) ~= "string" or opts.cwd:sub(1, 1) ~= "/" then
    error("iara.core.proc: opts.cwd must be an absolute path", 3)
  end
  if opts.timeout_ms == nil and not opts.long_lived then
    error("iara.core.proc: opts.timeout_ms is required", 3)
  end
  validate_stream(opts.stdout, "stdout")
  validate_stream(opts.stderr, "stderr")
  validate_admission(opts.admission, 4)
end

local function new_stream(name, config)
  config = config or {}
  local defaults = STREAM_DEFAULTS[name]
  return {
    name = name,
    mode = config.mode or defaults.mode,
    max_bytes = config.max_bytes or defaults.max_bytes,
    max_line_bytes = config.max_line_bytes or DEFAULT_MAX_LINE_BYTES,
    delimiter = config.delimiter or "\n",
    on_data = config.on_data,
    pipe = uv.new_pipe(false),
    open = true,
    eof = false,
    bytes = 0,
    partial = "",
    collected = {},
  }
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function close_stream(stream)
  if not stream.open then
    return
  end
  stream.open = false
  stream.pipe:read_stop()
  close_handle(stream.pipe)
end

local function close_timers(job)
  for _, timer in ipairs(job.timers) do
    timer:stop()
    close_handle(timer)
  end
end

---Run `fn` on the main loop after `ms`, unless the job completed first.
local function after(job, ms, fn)
  local timer = uv.new_timer()
  table.insert(job.timers, timer)
  -- Timers count from the cached loop time, which can lag behind the
  -- spawn time; refresh it so a deadline never fires early.
  uv.update_time()
  timer:start(ms, 0, function()
    vim.schedule(function()
      if not job.completed then
        fn()
      end
    end)
  end)
  return timer
end

local function collected(stream)
  if stream.mode == "collect" then
    return table.concat(stream.collected)
  end
end

local function build_result(job)
  local out, err = job.streams.stdout, job.streams.stderr
  return {
    status = job.status or "exited",
    code = job.code,
    signal = job.signal,
    stdout = collected(out),
    stderr = collected(err),
    eof = { stdout = out.eof, stderr = err.eof },
    pipes_forced = job.pipes_forced,
    overflow = job.overflow,
    reason = job.reason,
    error = job.error,
    escalation = job.escalation,
    cleanup_failed = job.cleanup_failed == true,
    elapsed_ms = (uv.hrtime() - job.started) / 1e6,
  }
end

---Complete the job once the process is reaped and both pipes are closed.
local function try_finish(job)
  if job.completed or not job.reaped then
    return
  end
  if job.streams.stdout.open or job.streams.stderr.open then
    return
  end
  job.completed = true
  close_handle(job.stdin)
  close_timers(job)
  live[job.id] = nil
  job.opts.on_complete(build_result(job))
end

---Record that escalation `step` acted, in ms since the job began ending.
local function mark_step(job, step)
  if job.escalation then
    job.escalation[step] = (uv.hrtime() - job.ending_at) / 1e6
  end
end

local function force_close_pipes(job)
  local forced = false
  for _, stream in pairs(job.streams) do
    if stream.open then
      forced = true
      close_stream(stream)
    end
  end
  if forced then
    job.pipes_forced = true
    mark_step(job, "close")
  end
  try_finish(job)
end

---Signal the whole process group: the child leads its own group, so
---descendants sharing our pipes are reached too.
---@return boolean sent False when the process had already exited.
local function send_signal(job, signame)
  if job.exited or not job.pid then
    return false
  end
  if not uv.kill(-job.pid, signame) then
    pcall(uv.process_kill, job.process, signame)
  end
  return true
end

---Cleanup is still unfinished: keep ownership (the handle stays live and
---blocks its admission group) and tell the owner once.
local function report_cleanup_failure(job)
  if job.cleanup_failed then
    return
  end
  job.cleanup_failed = true
  mark_step(job, "report")
  if job.opts.on_cleanup_failure then
    job.opts.on_cleanup_failure(job.public)
  end
end

---Start ending the job: record the first cause, discard further data, and
---escalate from TERM to KILL, forced pipe closure, and failure report.
local function terminate(job, status, fields)
  if job.ending or job.completed then
    return
  end
  job.ending = true
  job.ending_at = uv.hrtime()
  job.escalation = {}
  job.status = job.status or status
  for key, value in pairs(fields or {}) do
    job[key] = value
  end
  if job.deadline then
    job.deadline:stop()
  end
  if send_signal(job, "sigterm") then
    mark_step(job, "term")
  end
  after(job, ESCALATION.kill_ms, function()
    if send_signal(job, "sigkill") then
      mark_step(job, "kill")
    end
  end)
  after(job, ESCALATION.close_ms, function()
    force_close_pipes(job)
  end)
  after(job, ESCALATION.report_ms, function()
    report_cleanup_failure(job)
  end)
end

---Signal before closing the pipe: a writer that hits EPIPE first could
---exit on its own and hide that the job was terminated.
local function overflow(job, stream, limit)
  terminate(job, "overflow", {
    overflow = stream.name,
    error = {
      code = "overflow",
      message = ("%s of %s exceeded %d bytes"):format(
        stream.name,
        job.command,
        limit
      ),
    },
  })
  close_stream(stream)
  try_finish(job)
end

local function emit(stream, items)
  if stream.on_data and #items > 0 then
    stream.on_data(items)
  end
end

local function frame_lines(job, stream, data)
  local text = stream.partial .. data
  local limit = stream.max_line_bytes
  local items, start = {}, 1
  while true do
    local stop = text:find(stream.delimiter, start, true)
    if not stop then
      break
    end
    if stop - start > limit then
      return overflow(job, stream, limit)
    end
    table.insert(items, text:sub(start, stop - 1))
    start = stop + 1
  end
  stream.partial = text:sub(start)
  if #stream.partial > limit then
    return overflow(job, stream, limit)
  end
  emit(stream, items)
end

local function on_chunk(job, stream, data)
  if job.ending or not stream.open then
    return
  end
  if stream.mode == "collect" then
    table.insert(stream.collected, data)
  elseif stream.mode == "chunks" then
    emit(stream, { data })
  else
    frame_lines(job, stream, data)
  end
end

local function on_stream_end(job, stream, err)
  if not stream.open then
    return
  end
  stream.eof = err == nil
  local tail = stream.partial
  stream.partial = ""
  if stream.mode == "lines" and tail ~= "" and not job.ending then
    emit(stream, { tail })
  end
  close_stream(stream)
  try_finish(job)
end

---Account bytes in the libuv callback so pending data stays bounded by
---`max_bytes`; everything else runs on the main loop in stream order.
local function start_reading(job, stream)
  stream.pipe:read_start(function(err, data)
    if err or not data then
      vim.schedule(function()
        on_stream_end(job, stream, err)
      end)
      return
    end
    if stream.mode == "discard" or stream.over then
      return
    end
    stream.bytes = stream.bytes + #data
    local over = stream.bytes > stream.max_bytes
    stream.over = over
    vim.schedule(function()
      if over then
        return overflow(job, stream, stream.max_bytes)
      end
      on_chunk(job, stream, data)
    end)
  end)
end

local function on_process_exit(job, code, signal)
  job.exited, job.reaped = true, true
  job.code, job.signal = code, signal
  job.status = job.status or "exited"
  close_handle(job.process)
  if job.deadline then
    job.deadline:stop()
  end
  if job.opts.on_exit then
    job.opts.on_exit(code, signal)
  end
  if not job.ending then
    after(job, NATURAL_CLOSE_MS, function()
      force_close_pipes(job)
    end)
  end
  try_finish(job)
end

local function build_env(opts)
  if opts.env == nil and not opts.clear_env then
    return nil
  end
  local merged = opts.clear_env and {} or vim.fn.environ()
  for key, value in pairs(opts.env or {}) do
    merged[key] = value
  end
  local list = {}
  for key, value in pairs(merged) do
    table.insert(list, key .. "=" .. value)
  end
  return list
end

local function fail_spawn(job, message, name)
  local cwd_exists = vim.fn.isdirectory(job.opts.cwd) == 1
  local missing = name == "ENOENT" and cwd_exists
  job.status = missing and "not_found" or "spawn_failed"
  if missing then
    message = ("executable not found: %s"):format(job.command)
  else
    message = ("cannot start %s: %s"):format(job.command, message)
  end
  job.error = { code = job.status, message = message, uv_error = name }
  job.reaped = true
  close_stream(job.streams.stdout)
  close_stream(job.streams.stderr)
  vim.schedule(function()
    try_finish(job)
  end)
end

local function write_stdin(job)
  local pipe, input = job.stdin, job.opts.stdin
  if input and input ~= "" then
    pipe:write(input)
  end
  -- Shutdown waits for pending writes; a child that never reads makes the
  -- write fail with EPIPE, which is not an error for the job.
  pipe:shutdown(function()
    close_handle(pipe)
  end)
end

local function start_process(job, args)
  local streams = job.streams
  local process, pid, err_name = uv.spawn(job.command, {
    args = args,
    stdio = { job.stdin, streams.stdout.pipe, streams.stderr.pipe },
    cwd = job.opts.cwd,
    env = build_env(job.opts),
    detached = true,
  }, function(code, signal)
    vim.schedule(function()
      on_process_exit(job, code, signal)
    end)
  end)
  if not process then
    return fail_spawn(job, pid, err_name)
  end
  job.process, job.pid, job.public.pid = process, pid, pid
  start_reading(job, streams.stdout)
  start_reading(job, streams.stderr)
  write_stdin(job)
  if job.opts.timeout_ms then
    job.deadline = after(job, job.opts.timeout_ms, function()
      terminate(job, "timeout", {
        error = {
          code = "timeout",
          message = ("%s exceeded its %d ms deadline"):format(
            job.command,
            job.opts.timeout_ms
          ),
        },
      })
    end)
  end
end

local function cancel(job, reason)
  if job.completed or job.ending then
    return
  end
  job.reason = reason
  terminate(job, "cancelled")
end

local function new_job(argv, opts)
  next_id = next_id + 1
  local job = {
    id = next_id,
    command = argv[1],
    opts = opts,
    started = uv.hrtime(),
    stdin = uv.new_pipe(false),
    streams = {
      stdout = new_stream("stdout", opts.stdout),
      stderr = new_stream("stderr", opts.stderr),
    },
    timers = {},
    pipes_forced = false,
  }
  job.public = {
    id = job.id,
    argv = argv,
    cancel = function(_, reason)
      cancel(job, reason)
    end,
    is_active = function()
      return not job.completed
    end,
  }
  return job
end

local function ensure_exit_autocmd()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("IaraProc", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.cancel_all()
    end,
  })
end

---@return integer live, boolean cleanup_failed For one admission group.
local function group_usage(group)
  local count, failed = 0, false
  for _, job in pairs(live) do
    local admission = job.opts.admission
    if admission and admission.group == group then
      count = count + 1
      failed = failed or job.cleanup_failed == true
    end
  end
  return count, failed
end

---@param admission IaraProcAdmission
---@return IaraError|nil refusal
local function admission_refusal(admission)
  local count, failed = group_usage(admission.group)
  if failed then
    return {
      code = "cleanup_failed",
      message = ("%s: a process could not be cleaned up"):format(
        admission.group
      ),
    }
  end
  if count >= admission.max then
    return {
      code = "cap",
      message = ("%s: %d live processes (cap %d)"):format(
        admission.group,
        count,
        admission.max
      ),
    }
  end
end

---A handle for a refused spawn: nothing starts, and on_complete reports
---status "refused" on a later main-loop iteration, like spawn failures.
local function refuse(argv, opts, refusal)
  next_id = next_id + 1
  local handle = { id = next_id, argv = argv, refused = refusal.code }
  local completed = false
  handle.cancel = function() end
  handle.is_active = function()
    return not completed
  end
  vim.schedule(function()
    completed = true
    opts.on_complete({
      status = "refused",
      eof = { stdout = false, stderr = false },
      pipes_forced = false,
      refused = refusal.code,
      error = { code = "refused", message = refusal.message },
      elapsed_ms = 0,
    })
  end)
  return handle
end

---Spawn `argv` (argv[1] resolved through PATH). Always returns a handle;
---spawn failures and refusals arrive through on_complete. Raises for an
---empty argv, non-string items, NUL bytes, a missing `on_complete`/`cwd`,
---or a malformed `admission`.
---@param argv string[]
---@param opts IaraProcOpts
---@return IaraProcHandle
function M.spawn(argv, opts)
  local copy, args = copy_argv(argv)
  validate_opts(opts)
  local refusal = opts.admission and admission_refusal(opts.admission)
  if refusal then
    return refuse(copy, opts, refusal)
  end
  ensure_exit_autocmd()
  local job = new_job(copy, opts)
  live[job.id] = job
  start_process(job, args)
  return job.public
end

---Whether a spawn with `admission` would start now. Retiring handles
---count toward the cap; a live handle whose cleanup failed (1 s after
---it began ending) blocks its whole group until it is finally reaped.
---@param admission IaraProcAdmission
---@return boolean admitted
---@return IaraError|nil refusal Codes "cap" and "cleanup_failed".
function M.admits(admission)
  if admission == nil then
    error("iara.core.proc: admission is required", 2)
  end
  validate_admission(admission, 3)
  local refusal = admission_refusal(admission)
  return refusal == nil, refusal
end

---Live handles (not yet completed), optionally for one tag. Callers use
---it to enforce their own concurrency caps; retiring handles count.
---@param tag string?
---@return integer
function M.active_count(tag)
  local count = 0
  for _, job in pairs(live) do
    if tag == nil or job.opts.tag == tag then
      count = count + 1
    end
  end
  return count
end

---@param tag string? Cancel every live handle, or those with `tag`.
function M.cancel_all(tag)
  for _, job in pairs(vim.tbl_values(live)) do
    if tag == nil or job.opts.tag == tag then
      cancel(job)
    end
  end
end

return M
