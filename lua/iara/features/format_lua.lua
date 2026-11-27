--- Guarded StyLua formatting for Lua buffers.
---
--- Explicit only (`:IaraFormat`, `<leader>fm`), never on save. The buffer
--- text goes to StyLua through stdin; the result replaces the buffer in
--- one undoable `nvim_buf_set_lines` call, or is discarded without any
--- edit when it failed, overflowed, timed out, or became stale. This
--- module also owns `formatexpr` in Lua buffers so `gq` never falls back
--- to LSP formatting. See contracts.md, section "Tooling and baseline".
---
--- Admission (ARCH, Performance envelope): one active and one pending
--- request per buffer, two active and two pending session-wide. A
--- cancelled job stays active until its process is cleaned up. Pending
--- requests hold only the buffer number; text is captured, in batches
--- that recheck the tick, only once a request becomes active. The active
--- cap is the memory cap: each active request may hold its input, 1 MiB
--- of output, 64 KiB of stderr, and decoded lines, within the 8 MiB
--- session reservation.
local config = require("iara.config")
local eligibility = require("iara.core.eligibility")
local proc = require("iara.core.proc")
local root = require("iara.core.root")

local M = {}

local api = vim.api

M.TAG = "iara.format_lua"
M.LIMITS = {
  timeout_ms = 5000,
  max_lines = 10000,
  max_output_bytes = 1048576,
  max_stderr_bytes = 65536,
  active = 2,
  pending = 2,
  capture_batch_lines = 1000,
}

local CONFIG_NAMES = { "stylua.toml", ".stylua.toml" }
-- Tool locations inside an explicitly trusted project root.
local PROJECT_TOOLS = { "node_modules/.bin/stylua", ".tools/bin/stylua" }
local LSP_FORMATEXPR = "v:lua.vim.lsp.formatexpr()"
-- Options captured with the text; a change discards the result.
local GUARDED_OPTIONS = {
  "fileformat",
  "endofline",
  "fixendofline",
  "filetype",
}
local MAPPING = "<leader>fm"

---@type table<integer, table> Current request per buffer. A result is
---applied only while its request is still the buffer's current one.
local requests = {}
---@type table<table, true> Requests that are capturing or own a live
---process, including cancelled ones whose cleanup has not finished.
local active = {}
---@type integer[] Buffers with a pending request, oldest first.
local pending = {}
local is_setup = false
local reported_settings = {}

local function failure(code, message)
  return { code = code, message = message }
end

local function report(err)
  vim.notify("Iara: format: " .. err.message, vim.log.levels.WARN)
end

---Read an optional absolute path from `languages.lua`; an invalid value
---is reported once and ignored.
local function path_setting(name)
  local value = config.get("languages.lua." .. name)
  if value == nil then
    return nil
  end
  if type(value) == "string" and vim.startswith(value, "/") then
    return value
  end
  if not reported_settings[name] then
    reported_settings[name] = true
    report(
      failure(
        "invalid",
        "languages.lua."
          .. name
          .. " must be an "
          .. "absolute path; ignoring it"
      )
    )
  end
  return nil
end

---True when the composed configuration makes StyLua the Lua formatter.
local function stylua_owns_lua()
  local formatters = config.get("formatters.lua")
  return config.enabled("languages.lua")
    and config.enabled("formatters.lua")
    and type(formatters) == "table"
    and formatters[1] == "stylua"
end

local function is_trusted(project)
  for _, dir in ipairs(config.get("trusted_projects") or {}) do
    if vim.uv.fs_realpath(vim.fn.fnamemodify(dir, ":p")) == project then
      return true
    end
  end
  return false
end

local function executable(path)
  return vim.fn.executable(path) == 1
end

---Personal absolute command, trusted project tool, Mason, then PATH.
local function resolve_command(project)
  local personal = path_setting("stylua")
  if personal then
    if executable(personal) then
      return personal
    end
    local message = "languages.lua.stylua is not executable: " .. personal
    return nil, failure("not_found", message)
  end
  local candidates = {}
  if is_trusted(project) then
    for _, relative in ipairs(PROJECT_TOOLS) do
      table.insert(candidates, project .. "/" .. relative)
    end
  end
  table.insert(candidates, vim.fn.stdpath("data") .. "/mason/bin/stylua")
  table.insert(candidates, vim.fn.exepath("stylua"))
  for _, candidate in ipairs(candidates) do
    if candidate ~= "" and executable(candidate) then
      return candidate
    end
  end
  return nil,
    failure(
      "not_found",
      "StyLua not found: install stylua on PATH or set languages.lua.stylua"
    )
end

---Nearest StyLua configuration between the file and the project root,
---else the personal `languages.lua.stylua_config`. StyLua never searches
---by itself, so no configuration outside these places applies.
local function resolve_config(source, project)
  local dir = vim.fs.dirname(source)
  if vim.startswith(dir .. "/", project .. "/") then
    local found = vim.fs.find(CONFIG_NAMES, {
      path = dir,
      upward = true,
      stop = vim.fs.dirname(project),
      limit = 1,
    })[1]
    if found then
      return found
    end
  end
  local personal = path_setting("stylua_config")
  if personal and vim.fn.filereadable(personal) == 1 then
    return personal
  end
  local message = "no stylua.toml or .stylua.toml between the file and "
    .. project
    .. "; set languages.lua.stylua_config"
  return nil, failure("not_found", message)
end

---Reason why `bufnr` cannot be formatted now, or nil.
local function admission_problem(bufnr)
  local bo = vim.bo[bufnr]
  if bo.filetype ~= "lua" then
    return "not a Lua buffer"
  end
  if bo.buftype ~= "" or api.nvim_buf_get_name(bufnr) == "" then
    return "the buffer is not a file; save it first"
  end
  if not bo.modifiable then
    return "the buffer is not modifiable"
  end
  local state = eligibility.check(bufnr)
  if state.state ~= "eligible" then
    return "conservative mode: " .. (state.message or state.reason or "")
  end
  if api.nvim_buf_line_count(bufnr) > M.LIMITS.max_lines then
    return ("more than %d lines"):format(M.LIMITS.max_lines)
  end
end

---Record what the result must still match when it arrives. The text is
---captured later, in batches.
local function describe(bufnr)
  local request = {
    bufnr = bufnr,
    tick = api.nvim_buf_get_changedtick(bufnr),
    source = vim.fs.normalize(api.nvim_buf_get_name(bufnr)),
    line_count = api.nvim_buf_line_count(bufnr),
    lines = {},
    options = {},
  }
  for _, name in ipairs(GUARDED_OPTIONS) do
    request.options[name] = vim.bo[bufnr][name]
  end
  return request
end

---Reason why the formatter's owner, trust, or root changed, or nil.
local function owner_change(request)
  if not stylua_owns_lua() then
    return "StyLua formatting was disabled"
  end
  if is_trusted(request.cwd) ~= request.trusted then
    return "the project trust changed"
  end
  if root.resolve(request.bufnr).path ~= request.cwd then
    return "the project root changed"
  end
  -- The tick guard covers the text; "unknown" only means a recheck of
  -- that same text is still running.
  if eligibility.check(request.bufnr).state == "conservative" then
    return "the buffer entered conservative mode"
  end
end

---Reason why the request no longer matches its buffer text, or nil.
local function text_change(request)
  local bufnr = request.bufnr
  if requests[bufnr] ~= request then
    return "a newer request replaced this one"
  end
  if not api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].modifiable then
    return "the buffer was unloaded or made read-only"
  end
  if api.nvim_buf_get_changedtick(bufnr) ~= request.tick then
    return "the buffer changed while formatting"
  end
  if vim.fs.normalize(api.nvim_buf_get_name(bufnr)) ~= request.source then
    return "the buffer was renamed while formatting"
  end
end

---Reason why the captured snapshot no longer matches the buffer, or nil.
local function stale_reason(request)
  local reason = text_change(request) or owner_change(request)
  if reason then
    return reason
  end
  for name, value in pairs(request.options) do
    if vim.bo[request.bufnr][name] ~= value then
      return "'" .. name .. "' changed while formatting"
    end
  end
  if api.nvim_get_mode().mode ~= "n" then
    return "not in Normal mode"
  end
end

local STATUS_CODES = {
  not_found = "not_found",
  overflow = "overflow",
  timeout = "timeout",
  spawn_failed = "stylua",
  refused = "busy",
}

local function stylua_failure(result)
  local detail = vim.trim(result.stderr or ""):sub(1, 500)
  if detail == "" then
    detail = ("exit code %d"):format(result.code)
  end
  return failure("stylua", "StyLua failed: " .. detail)
end

---Turn a complete, successful StyLua run into buffer lines.
local function decode(result)
  if result.status ~= "exited" then
    local code = STATUS_CODES[result.status] or "stylua"
    local message = result.error and result.error.message or result.status
    return nil, failure(code, message)
  end
  if result.code ~= 0 then
    return nil, stylua_failure(result)
  end
  local out = result.stdout or ""
  local complete = result.eof.stdout and not result.pipes_forced
  if not complete or (out ~= "" and out:sub(-1) ~= "\n") then
    return nil, failure("stylua", "StyLua output was incomplete")
  end
  if out == "" then
    return { "" }
  end
  return vim.split(out:sub(1, -2), "\n", { plain = true })
end

---Replace the whole buffer at once, keeping each window's cursor row.
local function replace_lines(bufnr, lines)
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    cursors[win] = api.nvim_win_get_cursor(win)
  end
  local ok, problem = pcall(api.nvim_buf_set_lines, bufnr, 0, -1, true, lines)
  if not ok then
    return failure("stale", "could not apply the result: " .. problem)
  end
  for win, cursor in pairs(cursors) do
    local row = math.min(cursor[1], #lines)
    pcall(api.nvim_win_set_cursor, win, { row, cursor[2] })
  end
end

local function finish(request, result)
  if result.status == "cancelled" then
    return
  end
  local lines, err = decode(result)
  local stale = stale_reason(request)
  if requests[request.bufnr] == request then
    requests[request.bufnr] = nil
  end
  if stale and not err then
    err = failure("stale", "result discarded: " .. stale .. "; retry")
  end
  if not err and not vim.deep_equal(lines, request.lines) then
    err = replace_lines(request.bufnr, lines)
  end
  if err then
    report(err)
  end
end

local function remove_pending(bufnr)
  for index, queued in ipairs(pending) do
    if queued == bufnr then
      table.remove(pending, index)
      return true
    end
  end
  return false
end

local function cancel_request(bufnr, reason)
  remove_pending(bufnr)
  local request = requests[bufnr]
  requests[bufnr] = nil
  if request and request.handle then
    request.handle:cancel(reason)
  end
end

---Validate the buffer and resolve StyLua and its configuration.
local function prepare(bufnr)
  if not stylua_owns_lua() then
    return nil, failure("ineligible", "StyLua formatting is disabled")
  end
  local problem = admission_problem(bufnr)
  if problem then
    return nil, failure("ineligible", "cannot format: " .. problem)
  end
  local request = describe(bufnr)
  local project = root.resolve(bufnr).path
  local command, err = resolve_command(project)
  if not command then
    return nil, err
  end
  request.config_path, err = resolve_config(request.source, project)
  if not request.config_path then
    return nil, err
  end
  request.command, request.cwd = command, project
  request.trusted = is_trusted(project)
  return request
end

-- Defined after the admission queue, which it drives.
local retire

local function spawn(request)
  local argv = {
    request.command,
    "--config-path",
    request.config_path,
    "--no-editorconfig",
    -- Buffer lines carry no line endings; 'fileformat' decides them.
    "--line-endings",
    "Unix",
    "--stdin-filepath",
    request.source,
    "-",
  }
  local limits = M.LIMITS
  return proc.spawn(argv, {
    cwd = request.cwd,
    stdin = table.concat(request.lines, "\n") .. "\n",
    timeout_ms = limits.timeout_ms,
    tag = M.TAG,
    -- Backstop for the queue above; it also refuses after a failed
    -- cleanup, which keeps a handle live.
    admission = { group = M.TAG, max = limits.active },
    stdout = { mode = "collect", max_bytes = limits.max_output_bytes },
    stderr = { mode = "collect", max_bytes = limits.max_stderr_bytes },
    on_complete = function(result)
      finish(request, result)
      retire(request)
    end,
  })
end

local function active_count(bufnr)
  local count = 0
  for request in pairs(active) do
    if bufnr == nil or request.bufnr == bufnr then
      count = count + 1
    end
  end
  return count
end

---Copy one batch of lines per main-loop tick, so a large buffer never
---blocks input; any edit in between discards the request.
local function capture_batch(request)
  local stale = text_change(request)
  if stale then
    if requests[request.bufnr] == request then
      requests[request.bufnr] = nil
      report(failure("stale", "discarded: " .. stale .. "; retry"))
    end
    return retire(request)
  end
  local first = #request.lines
  local last =
    math.min(first + M.LIMITS.capture_batch_lines, request.line_count)
  local batch = api.nvim_buf_get_lines(request.bufnr, first, last, true)
  vim.list_extend(request.lines, batch)
  if last < request.line_count then
    return vim.schedule(function()
      capture_batch(request)
    end)
  end
  request.handle = spawn(request)
end

---Make `bufnr`'s request active now: resolve, then capture its text.
local function activate(bufnr)
  local request, err = prepare(bufnr)
  if not request then
    report(err)
    return false, err
  end
  requests[bufnr] = request
  active[request] = true
  capture_batch(request)
  return true
end

---Start pending requests while the caps allow, oldest first.
local function pump()
  local index = 1
  while index <= #pending and active_count() < M.LIMITS.active do
    local bufnr = pending[index]
    if active_count(bufnr) > 0 then
      index = index + 1
    else
      table.remove(pending, index)
      if api.nvim_buf_is_loaded(bufnr) then
        activate(bufnr)
      end
    end
  end
end

---Forget a finished or abandoned request, then admit pending ones.
---@param request table
function retire(request)
  if not active[request] then
    return
  end
  active[request] = nil
  pump()
end

---Queue `bufnr` as pending (metadata only), replacing its older pending
---request. Refused when two other buffers are already pending.
local function enqueue(bufnr)
  if remove_pending(bufnr) or #pending < M.LIMITS.pending then
    table.insert(pending, bufnr)
    return true
  end
  local err = failure("busy", "two formatting requests are already waiting")
  report(err)
  return false, err
end

---Format a Lua buffer once through StyLua. The result is applied later
---as one undoable edit, or discarded with a reported reason. A newer
---request on the same buffer cancels the active one and waits, as the
---buffer's one pending request, until that job has been cleaned up.
---@param bufnr integer? 0 or nil for the current buffer.
---@return boolean started True when active or pending.
---@return IaraError|nil err Error codes: "not_found", "ineligible",
---  "busy".
function M.format(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if type(bufnr) ~= "number" or not api.nvim_buf_is_valid(bufnr) then
    error("iara.features.format_lua: invalid buffer", 2)
  end
  cancel_request(bufnr, "superseded")
  if active_count(bufnr) > 0 or active_count() >= M.LIMITS.active then
    return enqueue(bufnr)
  end
  return activate(bufnr)
end

---@param bufnr integer? 0 or nil for the current buffer.
---@return "idle"|"pending"|"active" state "active" covers capture and
---  a running StyLua process of the buffer's current request.
function M.status(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  for _, queued in ipairs(pending) do
    if queued == bufnr then
      return "pending"
    end
  end
  return requests[bufnr] and "active" or "idle"
end

---Clear the LSP `formatexpr` default so `gq` keeps native formatting.
local function clear_lsp_formatexpr(bufnr)
  if vim.bo[bufnr].formatexpr == LSP_FORMATEXPR then
    vim.bo[bufnr].formatexpr = ""
  end
end

local function own_lua_buffer(bufnr)
  clear_lsp_formatexpr(bufnr)
  vim.keymap.set("n", MAPPING, function()
    M.format(bufnr)
  end, { buffer = bufnr, desc = "Format Lua with StyLua" })
end

local function create_autocmds(group)
  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "lua",
    callback = function(args)
      own_lua_buffer(args.buf)
    end,
  })
  -- LSP sets its formatexpr default just before LspAttach fires.
  api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "lua" then
        clear_lsp_formatexpr(args.buf)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(args)
      cancel_request(args.buf, "buffer unloaded")
    end,
  })
end

---Register `:IaraFormat`, the Lua buffer mapping, and `formatexpr`
---ownership. Does nothing unless StyLua is the Lua formatter.
---@param _ table? Composed configuration (read through iara.config).
function M.setup(_)
  if is_setup or not stylua_owns_lua() then
    return
  end
  is_setup = true
  path_setting("stylua")
  path_setting("stylua_config")
  local group = api.nvim_create_augroup("IaraFormatLua", { clear = true })
  create_autocmds(group)
  api.nvim_create_user_command("IaraFormat", function()
    M.format(0)
  end, { desc = "Format the current Lua buffer with StyLua" })
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "lua" then
      own_lua_buffer(bufnr)
    end
  end
end

return M
