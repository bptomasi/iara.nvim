--- Content lane: runs ripgrep over an explicit list of eligible files.
---
--- The query is one argv item after `-e`, and every file operand is
--- prefixed with `./` after `--`, so no query or file name can become an
--- option. `--encoding none` keeps byte offsets on disk bytes (a BOM
--- counts). Operands are split into batches by argv bytes; a batch that
--- fails to spawn with E2BIG is retried with half the budget. Two
--- batches run at once (ARCH allows two active grep batches), so a large
--- list is split in two even when one batch would fit.
---
--- Binary policy: explicit operands make ripgrep search binary files with
--- NUL conversion instead of skipping them, so each file's occurrences are
--- held until its JSON `end` frame. A non-null `binary_offset` discards
--- all of them, including matches before the NUL. A file without `end`
--- is incomplete and never published.
---
--- Exit 1 means no match. Exit 2 is an error even after published files;
--- other batches still run so their results and errors aggregate. A JSON
--- frame above 256 KiB or a deadline stops the run as "partial".
---
--- Held occurrences are decoded work: all batches together may hold at
--- most 2 MiB of them (ARCH, queued and decoded work), counted before
--- they are kept; above that the run stops as "partial" with an
--- "overflow" error. Processes start through `search.slots`, which caps
--- live search processes at four session-wide. Ripgrep keeps its
--- default thread count (see contracts.md, section 9.3).
local slots = require("iara.features.search.slots")

local M = {}

local LIMITS = {
  -- Operand bytes per batch, counting each argv pointer: about half of
  -- Linux's usual 2 MiB ARG_MAX, which also holds the environment.
  -- Fewer, larger batches save a ripgrep start each.
  batch_bytes = 1024 * 1024,
  -- Smaller lists are not worth splitting across the active batches.
  split_bytes = 64 * 1024,
  -- iara.core.proc passes argv through unpack(), which LuaJIT limits to
  -- fewer than 8,000 values.
  batch_operands = 7000,
  active_batches = 2,
  -- Frames are rejected before decoding (ARCH, framing paragraph).
  frame_bytes = 256 * 1024,
  stdout_bytes = 64 * 1024 * 1024,
  stderr_bytes = 64 * 1024,
  -- Held occurrences of one file, which arrive before its `end` frame.
  file_occurrences = 10000,
  -- Decoded occurrences held by all batches until their files end.
  held_bytes = 2 * 1024 * 1024,
  -- Accounted cost of one held occurrence table beyond its text.
  occurrence_bytes = 64,
  text_bytes = 256,
  message_bytes = 1024,
  -- Each grep or validation job (ARCH, Performance envelope).
  timeout_ms = 10000,
}

local CASE_FLAGS = {
  smart = "--smart-case",
  sensitive = "--case-sensitive",
  insensitive = "--ignore-case",
}

local JSON_OPTS = { luanil = { object = true, array = true } }

local function validate(spec, callbacks)
  if type(spec) ~= "table" or type(spec.root) ~= "string" then
    error("iara.features.search.grep: spec.root must be a string", 3)
  end
  if type(spec.files) ~= "table" then
    error("iara.features.search.grep: spec.files must be a list", 3)
  end
  local query = spec.query
  if type(query) ~= "string" or query == "" or query:find("\0", 1, true) then
    error("iara.features.search.grep: query must be non-empty, no NUL", 3)
  end
  if not CASE_FLAGS[spec.case] then
    error("iara.features.search.grep: invalid case mode", 3)
  end
  if type(spec.generation) ~= "number" then
    error("iara.features.search.grep: spec.generation is required", 3)
  end
  if type(callbacks) ~= "table" or type(callbacks.on_done) ~= "function" then
    error("iara.features.search.grep: callbacks.on_done is required", 3)
  end
  if type(callbacks.on_file) ~= "function" then
    error("iara.features.search.grep: callbacks.on_file is required", 3)
  end
end

local function base_argv(spec)
  local argv = { "rg", "--no-config", "--json", "--encoding", "none" }
  if not spec.regex then
    table.insert(argv, "--fixed-strings")
  end
  vim.list_extend(argv, { CASE_FLAGS[spec.case], "-e", spec.query, "--" })
  return argv
end

local function bounded_message(text)
  text = vim.trim(text or "")
  if #text > LIMITS.message_bytes then
    text = text:sub(1, LIMITS.message_bytes) .. "..."
  end
  return text
end

---Raw bytes of a JSON "arbitrary data" field: `text` or base64 `bytes`.
local function field_bytes(field)
  if field == nil then
    return ""
  end
  return field.text or vim.base64.decode(field.bytes)
end

---Display text: no line terminator, at most `text_bytes` bytes cut at a
---character boundary, a tab shown as one space, unprintable bytes and
---invalid UTF-8 escaped. `exact` is true when nothing was escaped, so
---byte offsets of the line also index the text.
---@return string text
---@return boolean exact
local function display_text(line)
  line = line:gsub("\r?\n$", "")
  if #line > LIMITS.text_bytes then
    local cut = LIMITS.text_bytes + 1
    cut = cut + vim.str_utf_start(line, cut)
    line = line:sub(1, cut - 1)
  end
  -- One space per tab keeps every byte offset.
  line = line:gsub("\t", " ")
  -- A NUL byte turns a Lua string into a Blob in vim.fn and raises E976.
  -- Vim represents NUL as "\n" in text, which strtrans shows as "^@".
  local text = vim.fn.strtrans((line:gsub("%z", "\n")))
  return text, text == line
end

local function finish(run, result)
  if run.finished then
    return
  end
  run.finished = true
  result.generation = run.spec.generation
  result.binary_files = run.binary_files
  vim.schedule(function()
    run.callbacks.on_done(result)
  end)
end

local function final_result(run)
  if run.error then
    return { state = "error", error = run.error }
  end
  if run.truncation then
    return { state = "partial", error = run.truncation }
  end
  return { state = run.published and "complete" or "no_match" }
end

---Stop the active batches and every later one, keeping what was
---published.
local function stop(run, field, err)
  run[field] = run[field] or err
  for _, job in pairs(run.jobs) do
    job:cancel(err.code)
  end
  finish(run, final_result(run))
end

local function on_match(run, batch, data)
  local held = batch.pending[field_bytes(data.path)]
  if not held then
    return
  end
  if #held + #data.submatches > LIMITS.file_occurrences then
    return stop(run, "truncation", {
      code = "overflow",
      message = ("a file has more than %d occurrences"):format(
        LIMITS.file_occurrences
      ),
    })
  end
  local text, exact = display_text(field_bytes(data.lines))
  local cost = #text + #data.submatches * LIMITS.occurrence_bytes
  if run.held_bytes + cost > LIMITS.held_bytes then
    return stop(run, "truncation", {
      code = "overflow",
      message = ("held occurrences exceeded %d bytes"):format(
        LIMITS.held_bytes
      ),
    })
  end
  run.held_bytes = run.held_bytes + cost
  batch.held[held] = (batch.held[held] or 0) + cost
  for _, submatch in ipairs(data.submatches) do
    table.insert(held, {
      row = data.line_number - 1,
      byte_start = submatch.start,
      byte_end = submatch["end"],
      text = text,
      text_exact = exact,
    })
  end
end

---Stop accounting `held` once it is published or dropped.
local function release_held(run, batch, held)
  if held and batch.held[held] then
    run.held_bytes = run.held_bytes - batch.held[held]
    batch.held[held] = nil
  end
end

local function on_end(run, batch, data)
  local raw = field_bytes(data.path)
  local held = batch.pending[raw]
  batch.pending[raw] = nil
  release_held(run, batch, held)
  if data.binary_offset ~= nil then
    run.binary_files = run.binary_files + 1
    return
  end
  if not held or #held == 0 then
    return
  end
  local path = raw:gsub("^%./", "")
  for _, item in ipairs(held) do
    item.path = path
  end
  run.published = true
  run.callbacks.on_file(path, held)
end

local function on_frame(run, batch, frame)
  local ok, message = pcall(vim.json.decode, frame, JSON_OPTS)
  if not ok or type(message) ~= "table" or not message.data then
    return stop(run, "error", {
      code = "rg",
      message = "ripgrep produced an unreadable JSON frame",
    })
  end
  local kind, data = message.type, message.data
  if kind == "begin" then
    batch.pending[field_bytes(data.path)] = {}
  elseif kind == "match" then
    on_match(run, batch, data)
  elseif kind == "end" then
    on_end(run, batch, data)
  elseif kind == "summary" then
    batch.saw_summary = true
  end
end

---Classify exit 2. Ripgrep prints a summary frame once it has searched,
---so its absence means the pattern or the arguments were rejected.
local function exit_error(run, batch, result)
  local detail = bounded_message(result.stderr)
  if not batch.saw_summary and run.spec.regex then
    return { code = "regex", message = "invalid regex: " .. detail }, true
  end
  local message = detail ~= "" and detail or "ripgrep failed"
  return { code = "rg", message = message }, not batch.saw_summary
end

local function spawn_error(result)
  local err = result.error or {}
  return {
    code = result.status == "not_found" and "not_found" or "spawn",
    message = err.message or "cannot start ripgrep",
    uv_error = err.uv_error,
  }
end

local function stream_error(result)
  if result.status == "overflow" then
    return {
      code = "overflow",
      message = ("a ripgrep %s frame exceeded %d bytes"):format(
        result.overflow or "output",
        LIMITS.frame_bytes
      ),
    }
  end
  local err = result.error or {}
  return { code = "rg", message = err.message or "ripgrep timed out" }
end

local start_batches

---Advance after a batch, or return the reason the whole run ends.
local function after_batch(run, batch, result)
  local status = result.status
  if status == "spawn_failed" and result.error.uv_error == "E2BIG" then
    if batch.count > 1 then
      run.budget = math.min(run.budget, math.floor(batch.bytes / 2))
      table.insert(run.queue, 1, { first = batch.first, last = batch.last })
      return
    end
  end
  if status == "not_found" or status == "spawn_failed" then
    return "error", spawn_error(result)
  end
  if status == "refused" then
    return "error", { code = "refused", message = result.error.message }
  end
  if status ~= "exited" then
    return "truncation", stream_error(result)
  end
  if result.code >= 2 then
    local err, fatal = exit_error(run, batch, result)
    run.error = run.error or err
    return fatal and "error" or nil, err
  end
end

local function on_batch_complete(run, batch, result)
  run.jobs[batch], run.active = nil, run.active - 1
  -- Files without an `end` frame are never published.
  for held in pairs(batch.held) do
    release_held(run, batch, held)
  end
  if run.finished then
    return
  end
  local field, err = after_batch(run, batch, result)
  if field then
    return stop(run, field, err)
  end
  start_batches(run)
end

local function spawn(run, argv, batch, stdin)
  run.active = run.active + 1
  run.jobs[batch] = slots.spawn(argv, {
    cwd = run.spec.root,
    stdin = stdin,
    timeout_ms = LIMITS.timeout_ms,
    tag = "search.grep",
    stdout = {
      mode = "lines",
      max_bytes = LIMITS.stdout_bytes,
      max_line_bytes = LIMITS.frame_bytes,
      on_data = function(frames)
        for _, frame in ipairs(frames) do
          if run.finished then
            return
          end
          on_frame(run, batch, frame)
        end
      end,
    },
    stderr = { mode = "collect", max_bytes = LIMITS.stderr_bytes },
    on_complete = function(result)
      on_batch_complete(run, batch, result)
    end,
  })
end

---Argv bytes of one operand: `./`, the path, its NUL, and its pointer.
local function operand_bytes(file)
  return #file + 3 + 8
end

---Bytes per batch below the budget: a share of the whole list, so the
---active batches split it.
local function batch_target(files)
  local total = 0
  for _, file in ipairs(files) do
    total = total + operand_bytes(file)
  end
  local share = math.ceil(total / LIMITS.active_batches)
  return math.max(share, LIMITS.split_bytes)
end

---Whether one more operand of `bytes` would overfill `batch`.
local function is_full(batch, bytes, limit)
  if batch.count == 0 then
    return false
  end
  return batch.bytes + bytes > limit or batch.count == LIMITS.batch_operands
end

---Next operands from the queue until the byte limit; at least one file.
local function next_batch(run)
  local range = table.remove(run.queue, 1)
  local argv = base_argv(run.spec)
  local files = run.spec.files
  local limit = math.min(run.budget, run.target)
  local batch =
    { first = range.first, count = 0, bytes = 0, pending = {}, held = {} }
  for index = range.first, range.last do
    local bytes = operand_bytes(files[index])
    if is_full(batch, bytes, limit) then
      table.insert(run.queue, 1, { first = index, last = range.last })
      break
    end
    table.insert(argv, "./" .. files[index])
    batch.count, batch.bytes = batch.count + 1, batch.bytes + bytes
  end
  batch.last = batch.first + batch.count - 1
  return argv, batch
end

---Start queued batches up to the active limit; finish when all are done.
start_batches = function(run)
  while #run.queue > 0 and run.active < LIMITS.active_batches do
    local argv, batch = next_batch(run)
    spawn(run, argv, batch)
  end
  if #run.queue == 0 and run.active == 0 then
    finish(run, final_result(run))
  end
end

---Validate the pattern alone: search empty standard input, so an invalid
---regex is an error even when no file is eligible.
local function start_validation(run)
  local argv = base_argv(run.spec)
  table.insert(argv, "-")
  spawn(run, argv, { count = 0, bytes = 0, pending = {}, held = {} }, "")
end

---Run ripgrep with literal argv. `on_file` receives every occurrence of
---one completed, non-binary file at once, in file arrival order. With an
---empty `files` list, only validates the regex.
---@param spec IaraGrepSpec
---@param callbacks { on_file: fun(path: string, items: IaraOccurrence[]),
---  on_done: fun(result: IaraGrepResult) }
---@return { cancel: fun(self) } handle
function M.run(spec, callbacks)
  validate(spec, callbacks)
  local run = {
    spec = spec,
    callbacks = callbacks,
    queue = { { first = 1, last = #spec.files } },
    budget = LIMITS.batch_bytes,
    target = batch_target(spec.files),
    jobs = {},
    active = 0,
    binary_files = 0,
    held_bytes = 0,
  }
  if #spec.files > 0 then
    start_batches(run)
  elseif spec.regex then
    start_validation(run)
  else
    finish(run, { state = "no_match" })
  end
  return {
    cancel = function()
      for _, job in pairs(run.jobs) do
        job:cancel("cancelled")
      end
      finish(run, { state = "cancelled" })
    end,
  }
end

return M
