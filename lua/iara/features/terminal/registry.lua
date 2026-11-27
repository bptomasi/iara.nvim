--- Terminal registry: records and processes, no window layout.
---
--- A record owns its project, role, instance, generation, launch profile
--- (argv, cwd, environment overrides), buffer, job, and status. Status is
--- independent of visibility: jobs start in hidden buffers and their exit
--- is observed through `on_exit`, never through window events. Restart
--- starts a new generation in a new buffer and keeps the previous
--- transcript until the record is disposed. See contracts.md, section
--- `iara.features.terminal.registry`.
local M = {}

local retention = require("iara.core.term_retention")

---Session limits from ARCH, Terminal and agent lifecycle.
M.LIMITS = { scrollback = 10000, running = 8, retained = 4 }

local EVENT = "IaraTerminalChanged"
local ROLES = { main = true, shell = true, agent = true }
local RUNNING = { starting = true, running = true, stopping = true }
local RETAINED = { exited = true, failed = true }

---@class IaraTerminalRecord
---@field id integer Unique per session.
---@field project string `worktree_id` of the owning root.
---@field root_path string
---@field role "main"|"shell"|"agent"
---@field name string? Agent name for role "agent".
---@field instance integer One-based per project, role, and name.
---@field generation integer Increments on restart.
---@field argv string[]
---@field cwd string Launch directory; immutable.
---@field env table<string, string> Explicit overrides only.
---@field bufnr integer?
---@field job integer?
---@field status "starting"|"running"|"stopping"|"exited"|"failed"
---@field exit_code integer?
---@field error IaraError?
---@field label string Display label, without secrets.

---@type table<integer, IaraTerminalRecord>
local records = {}

---Previous transcripts kept after restart, per record id.
---@type table<integer, integer[]>
local transcripts = {}

local last_id = 0

---@type integer|nil
local group = nil

---@return IaraError
local function failure(code, message)
  return { code = code, message = message }
end

local function fire(record, previous)
  vim.api.nvim_exec_autocmds("User", {
    pattern = EVENT,
    data = {
      id = record.id,
      status = record.status,
      previous = previous,
      generation = record.generation,
    },
    modeline = false,
  })
end

---Update the status first, then announce it (contracts.md, Events).
local function set_status(record, status)
  local previous = record.status
  record.status = status
  fire(record, previous)
end

local function is_string_list(value)
  if type(value) ~= "table" or #value == 0 then
    return false
  end
  for _, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      return false
    end
  end
  return true
end

local function is_string_map(value)
  if type(value) ~= "table" then
    return false
  end
  for key, item in pairs(value) do
    if type(key) ~= "string" or type(item) ~= "string" then
      return false
    end
  end
  return true
end

---Raise for malformed specs; these are caller bugs, not runtime failures.
local function validate_spec(spec)
  local function check(ok, message)
    if not ok then
      error("iara.features.terminal.registry: " .. message, 4)
    end
  end
  check(type(spec) == "table", "spec must be a table")
  local root = spec.root
  check(type(root) == "table", "spec.root must be an IaraRoot")
  check(type(root.path) == "string", "spec.root.path must be a string")
  check(type(root.worktree_id) == "string", "spec.root needs worktree_id")
  check(ROLES[spec.role] == true, "unknown role " .. tostring(spec.role))
  local named = type(spec.name) == "string" and spec.name ~= ""
  check(named == (spec.role == "agent"), "a name is required for agents")
  check(spec.argv == nil or is_string_list(spec.argv), "argv: strings")
  check(spec.cwd == nil or type(spec.cwd) == "string", "cwd: string")
  check(spec.env == nil or is_string_map(spec.env), "env: string map")
end

---Argv of the configured shell, split like `:terminal` does, so the
---native successful-exit handler recognizes it as the unadorned shell.
local function shell_argv()
  return vim.split(vim.o.shell, "%s+", { trimempty = true })
end

local function default_argv(spec)
  if spec.role == "agent" then
    return { spec.name }
  end
  return shell_argv()
end

---@return string|nil cwd Normalized launch directory.
---@return IaraError|nil
local function launch_directory(path)
  local cwd = vim.fs.normalize(path)
  if vim.fn.isabsolutepath(cwd) ~= 1 or vim.fn.isdirectory(cwd) ~= 1 then
    return nil, failure("no_directory", "not a directory: " .. path)
  end
  return cwd
end

---@return IaraError|nil
local function check_retention()
  local ok, reason = retention.available()
  if ok then
    return nil
  end
  return failure(
    "retention_unavailable",
    "terminals are disabled: " .. tostring(reason)
  )
end

local function count_running()
  local count = 0
  for _, record in pairs(records) do
    if RUNNING[record.status] then
      count = count + 1
    end
  end
  return count
end

---Exited or failed records plus transcripts kept after restarts.
local function count_retained()
  local count = 0
  for id, record in pairs(records) do
    if RETAINED[record.status] then
      count = count + 1
    end
    count = count + #(transcripts[id] or {})
  end
  return count
end

---Refuse work that would exceed a cap; nothing is ever evicted.
---@param running_slot boolean The action adds a running job.
---@param retained_slot boolean The action adds a retained transcript.
---@return IaraError|nil
local function check_caps(running_slot, retained_slot)
  local limits = M.LIMITS
  if running_slot and count_running() >= limits.running then
    return failure(
      "cap",
      ("%d terminals are running; stop one first"):format(limits.running)
    )
  end
  if retained_slot and count_retained() >= limits.retained then
    return failure(
      "cap",
      ("%d exited terminals are kept; dispose one first"):format(
        limits.retained
      )
    )
  end
  return nil
end

---Lowest instance number not used by a live record of the same kind.
local function next_instance(project, role, name)
  local used = {}
  for _, record in pairs(records) do
    local same = record.project == project and record.role == role
    if same and record.name == name then
      used[record.instance] = true
    end
  end
  local instance = 1
  while used[instance] do
    instance = instance + 1
  end
  return instance
end

---Display label from identity only: argv and environment may hold
---secrets, so neither appears here.
local function make_label(record, root)
  local kind = record.role == "main" and "main"
    or ("%s %d"):format(record.name or record.role, record.instance)
  local label = ("%s %s"):format(root.label or root.path, kind)
  if record.cwd == record.root_path then
    return label
  end
  local relative = vim.fs.relpath(record.root_path, record.cwd)
  return ("%s in %s"):format(
    label,
    relative or vim.fn.fnamemodify(record.cwd, ":~")
  )
end

local function new_record(spec, cwd)
  last_id = last_id + 1
  local record = {
    id = last_id,
    project = spec.root.worktree_id,
    root_path = spec.root.path,
    role = spec.role,
    name = spec.name,
    instance = next_instance(spec.root.worktree_id, spec.role, spec.name),
    generation = 1,
    argv = vim.deepcopy(spec.argv or default_argv(spec)),
    cwd = cwd,
    env = vim.deepcopy(spec.env or {}),
    status = "starting",
  }
  record.label = make_label(record, spec.root)
  return record
end

---Exit handler bound to one generation, so a restarted record ignores
---its previous job. Runs while the buffer is hidden too.
local function exit_handler(id, generation)
  return function(_, code)
    local record = records[id]
    if not record or record.generation ~= generation then
      return
    end
    record.job = nil
    record.exit_code = code
    set_status(record, "exited")
  end
end

---Start the record's job in `bufnr`. jobstart() may raise, return 0
---(invalid arguments), or -1 (not executable).
---@return integer|nil job
---@return IaraError|nil
local function start_job(record, bufnr)
  local opts = {
    term = true,
    cwd = record.cwd,
    env = next(record.env) and record.env or nil,
    on_exit = exit_handler(record.id, record.generation),
  }
  local ok, job = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.jobstart(record.argv, opts)
  end)
  local program = record.argv[1]
  if not ok then
    return nil, failure("spawn", ("cannot start %s: %s"):format(program, job))
  end
  if job == -1 then
    return nil, failure("spawn", "not executable: " .. program)
  end
  if job <= 0 then
    return nil, failure("spawn", "invalid arguments for " .. program)
  end
  return job
end

local function remove_transcript(id, bufnr)
  local list = transcripts[id] or {}
  for index, transcript in ipairs(list) do
    if transcript == bufnr then
      table.remove(list, index)
      return
    end
  end
end

local function wipe_buffers(buffers)
  for _, bufnr in ipairs(buffers) do
    retention.disown(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---Forget a record and its transcripts, then announce "disposed".
local function forget(record)
  records[record.id] = nil
  local old = transcripts[record.id] or {}
  transcripts[record.id] = nil
  local previous = record.status
  record.status = "disposed"
  fire(record, previous)
  return old
end

---A buffer of the record went away outside dispose(): a transcript is
---just dropped; the live buffer takes its job and record with it.
local function on_unload(id, bufnr)
  local record = records[id]
  if not record then
    return
  end
  if record.bufnr ~= bufnr then
    remove_transcript(id, bufnr)
    return
  end
  if record.job then
    pcall(vim.fn.jobstop, record.job)
  end
  local old = forget(record)
  -- Deleting buffers inside an unload autocmd is not allowed.
  vim.schedule(function()
    wipe_buffers(old)
  end)
end

local function stop_all_jobs()
  for _, record in pairs(records) do
    if record.job and RUNNING[record.status] then
      pcall(vim.fn.jobstop, record.job)
    end
  end
end

local function ensure_group()
  if group then
    return group
  end
  group = vim.api.nvim_create_augroup("IaraTerminalRegistry", {
    clear = true,
  })
  -- VimLeavePre runs after quit is committed, unlike ExitPre: an aborted
  -- quit keeps every shell. Stopping never waits.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = stop_all_jobs,
  })
  return group
end

local function watch_buffer(id, bufnr)
  vim.api.nvim_create_autocmd("BufUnload", {
    group = ensure_group(),
    buffer = bufnr,
    once = true,
    callback = function()
      on_unload(id, bufnr)
    end,
  })
end

---Start the record's job in a new hidden buffer. On failure, only the
---buffer created here is removed.
---@return boolean ok
---@return IaraError|nil
local function launch(record)
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.b[bufnr].iara_context_root = record.root_path
  -- Owned before spawning, so even an instant successful exit is kept.
  retention.own(bufnr)
  local job, err = start_job(record, bufnr)
  if not job then
    wipe_buffers({ bufnr })
    return false, err
  end
  vim.bo[bufnr].scrollback = M.LIMITS.scrollback
  record.bufnr = bufnr
  record.job = job
  watch_buffer(record.id, bufnr)
  return true
end

---@return IaraError|nil
local function preflight(path)
  local unavailable = check_retention()
  if unavailable then
    return nil, unavailable
  end
  return launch_directory(path)
end

local function check_id(id)
  if type(id) ~= "number" then
    error("iara.features.terminal.registry: id must be an integer", 3)
  end
end

local function not_found(id)
  return failure("not_found", ("no terminal with id %d"):format(id))
end

---Create a record and start its job in a new buffer without opening a
---window. Error codes: "cap" (8 running or 4 retained), "spawn",
---"retention_unavailable", "no_directory". Raises for a malformed spec or
---a second main terminal of one project.
---@param spec { root: IaraRoot, role: string, name: string?,
---  argv: string[]?, cwd: string?, env: table<string, string>? }
---@return IaraTerminalRecord|nil
---@return IaraError|nil
function M.create(spec)
  validate_spec(spec)
  if spec.role == "main" and M.main_for(spec.root) then
    error("iara.features.terminal.registry: main terminal exists", 2)
  end
  local cwd, err = preflight(spec.cwd or spec.root.path)
  -- Every new job ends as a retained record, so both caps apply.
  err = err or check_caps(true, true)
  if err then
    return nil, err
  end
  local record = new_record(spec, cwd)
  -- Registered while starting, so TermOpen listeners can find it.
  records[record.id] = record
  local ok, spawn_err = launch(record)
  if not ok then
    records[record.id] = nil
    return nil, spawn_err
  end
  set_status(record, "running")
  return M.get(record.id)
end

---@param id integer
---@return IaraTerminalRecord|nil record A copy; re-query after events.
function M.get(id)
  check_id(id)
  local record = records[id]
  return record and vim.deepcopy(record) or nil
end

---@param filter { project: string?, role: string?, status: string? }?
---@return IaraTerminalRecord[] records Copies sorted by id.
function M.list(filter)
  filter = filter or {}
  local result = {}
  for _, record in pairs(records) do
    local matches = (not filter.project or filter.project == record.project)
      and (not filter.role or filter.role == record.role)
      and (not filter.status or filter.status == record.status)
    if matches then
      table.insert(result, vim.deepcopy(record))
    end
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

---@param root IaraRoot
---@return IaraTerminalRecord|nil record The main terminal of the root.
function M.main_for(root)
  return M.list({ project = root.worktree_id, role = "main" })[1]
end

---Asynchronous stop; never waits. Exit arrives as status "exited".
---Unknown ids and records that are not running are ignored.
---@param id integer
function M.stop(id)
  check_id(id)
  local record = records[id]
  if not record or not record.job or not RUNNING[record.status] then
    return
  end
  vim.fn.jobstop(record.job)
  if record.status ~= "stopping" then
    set_status(record, "stopping")
  end
end

---Caps for a restart: a running record keeps its slot but adds a
---transcript; a finished one needs a slot and turns into a transcript.
local function restart_caps(record)
  if RUNNING[record.status] then
    return check_caps(false, true)
  end
  return check_caps(true, false)
end

---New generation and buffer; the old transcript stays until disposal.
---A running job is stopped first. Error codes: "not_found", "cap",
---"spawn", "retention_unavailable", "no_directory".
---@param id integer
---@return IaraTerminalRecord|nil
---@return IaraError|nil
function M.restart(id)
  check_id(id)
  local record = records[id]
  if not record then
    return nil, not_found(id)
  end
  local _, err = preflight(record.cwd)
  err = err or restart_caps(record)
  if err then
    return nil, err
  end
  local old_job, old_bufnr = record.job, record.bufnr
  -- The old job's exit belongs to the previous generation and is ignored.
  record.generation = record.generation + 1
  if old_job then
    pcall(vim.fn.jobstop, old_job)
  end
  record.job, record.exit_code, record.error = nil, nil, nil
  local ok, spawn_err = launch(record)
  if not ok then
    record.error = spawn_err
    set_status(record, "failed")
    return nil, spawn_err
  end
  transcripts[id] = transcripts[id] or {}
  table.insert(transcripts[id], old_bufnr)
  set_status(record, "running")
  return M.get(id)
end

---Remove an exited or failed record with its buffer and transcripts.
---Error codes: "running", "not_found".
---@param id integer
---@return boolean ok
---@return IaraError|nil
function M.dispose(id)
  check_id(id)
  local record = records[id]
  if not record then
    return false, not_found(id)
  end
  if RUNNING[record.status] then
    return false, failure("running", record.label .. " is still running")
  end
  local buffers = forget(record)
  table.insert(buffers, record.bufnr)
  wipe_buffers(buffers)
  return true
end

return M
