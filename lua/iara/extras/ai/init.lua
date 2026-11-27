--- Ask AI about a selection (task AI1), enabled by `extras.ai` (on by
--- default). In Visual mode, `Space ai` prefers Codex and `Space ac`
--- selects Claude. The popup streams the CLI's answer; follow-up
--- questions resend the excerpt and the earlier turns. The command
--- `:'<,'>IaraAsk [question]` uses the same default as `Space ai`.
---
--- This is an explicit request and response, separate from the agent
--- terminals: each question runs the CLI once, read-only and without
--- tools (see `iara.extras.ai.backend` for the exact argv), with the
--- question on stdin, and nothing is typed into any terminal or written
--- into any buffer. The excerpt is captured with the agent context rules
--- (A2): its caps refuse instead of truncating.
---
--- Settings (all optional):
---   extras = { ai = {
---     backend = "claude",      -- or "codex"; default: the first found
---     argv = { "claude" },     -- command before the one-shot arguments
---     timeout_ms = 180000,     -- deadline of one answer
---   } }
--- `argv` needs `backend` and is refused when it contains an argument
--- that bypasses or widens permissions, tools, or the sandbox.
--- See contracts.md, section `iara.extras.ai`.
local backend = require("iara.extras.ai.backend")

local M = {}

local DEFAULT_TIMEOUT_MS = 180000

local FIELDS = { backend = true, argv = true, timeout_ms = true }

---@type { backend: string?, argv: string[]?, timeout_ms: integer }
local options = { timeout_ms = DEFAULT_TIMEOUT_MS }

local configured = false

---@type IaraAiPopup|nil
local current = nil

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.ERROR)
end

local function is_argv(value)
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

local function argv_problem(settings)
  if not settings.backend then
    return "argv needs backend"
  end
  if not is_argv(settings.argv) then
    return "argv must be a list of non-empty strings"
  end
  local unsafe = backend.unsafe_argument(settings.argv)
  if unsafe then
    return "argv must not contain the unsafe argument " .. unsafe
  end
  return nil
end

local function field_problem(settings, key)
  local value = settings[key]
  if not FIELDS[key] then
    return "unknown field " .. tostring(key)
  elseif key == "backend" and not backend.BACKENDS[value] then
    return 'backend must be "claude" or "codex"'
  elseif key == "timeout_ms" and (type(value) ~= "number" or value < 1000) then
    return "timeout_ms must be a number >= 1000"
  elseif key == "argv" then
    return argv_problem(settings)
  end
  return nil
end

---Read `extras.ai`; each invalid field is reported and ignored.
local function read_options(settings)
  options = { timeout_ms = DEFAULT_TIMEOUT_MS }
  local valid = {}
  for key in pairs(settings) do
    local problem = field_problem(settings, key)
    if problem then
      notify(("extras.ai %s; ignored"):format(problem))
    else
      valid[key] = settings[key]
    end
  end
  options = vim.tbl_extend("force", options, vim.deepcopy(valid))
end

local function command_for(name)
  if name == options.backend and options.argv then
    return options.argv
  end
  return backend.BACKENDS[name].argv
end

---The explicitly requested or configured backend, else the first found.
---@param requested string?
---@return string|nil name
---@return string[]|nil command
---@return string|nil problem Why no backend can answer.
local function choose_backend(requested)
  local preferred = requested or options.backend
  if preferred then
    local command = command_for(preferred)
    if vim.fn.executable(command[1]) ~= 1 then
      local title = backend.BACKENDS[preferred].title
      local message = "%s is not installed: %q was not found on PATH"
      return preferred, command, message:format(title, command[1])
    end
    return preferred, command
  end
  for _, name in ipairs(backend.ORDER) do
    local command = backend.BACKENDS[name].argv
    if vim.fn.executable(command[1]) == 1 then
      return name, command
    end
  end
  return "codex",
    backend.BACKENDS.codex.argv,
    "no AI CLI found: install Codex (`codex`) or Claude Code (`claude`)"
end

---"file.lua:12-20" for the excerpt.
local function location(snapshot)
  local range = snapshot.range
  local first = range[1] + 1
  local last = range[3] + 1
  if range[4] == 0 and range[3] > range[1] then
    last = range[3]
  end
  local lines = first == last and tostring(first) or (first .. "-" .. last)
  return snapshot.buffer_label .. ":" .. lines
end

local function project_dir(bufnr)
  local ok, root = pcall(require, "iara.core.root")
  if ok then
    return root.resolve(bufnr).path
  end
  return vim.uv.cwd()
end

local function open_popup(context, snapshot, payload, requested)
  local name, command, unavailable = choose_backend(requested)
  local popup = require("iara.extras.ai.popup")
  local conversation = require("iara.extras.ai.conversation").new({
    payload = payload,
    cwd = project_dir(snapshot.bufnr),
    backend = name,
    command = command,
    timeout_ms = options.timeout_ms,
  })
  local opened
  opened = popup.open({
    conversation = conversation,
    title = backend.BACKENDS[name].title,
    location = location(snapshot),
    -- A linewise excerpt ends with a line break; show no empty line.
    excerpt = vim.split(snapshot.text:gsub("\n$", ""), "\n", { plain = true }),
    filetype = snapshot.filetype,
    unavailable = unavailable,
    on_close = function()
      context.release(snapshot.id)
      if current == opened then
        current = nil
      end
    end,
  })
  current = opened
  return opened
end

---Snapshot of the selection; nil and reported when it is refused.
local function capture(capture_opts)
  local context = require("iara.extras.agents.context")
  local snapshot, err = context.capture(capture_opts)
  if not snapshot then
    return nil, err
  end
  local payload
  payload, err = context.format(snapshot)
  if not payload then
    context.release(snapshot.id)
    return nil, err
  end
  return context, snapshot, payload
end

local function ask(opts, requested)
  opts = opts or {}
  local capture_opts = {}
  if opts.range then
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_mark(bufnr, "<", opts.range[1], 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", opts.range[2], 0, {})
    capture_opts.mode = "linewise"
  end
  local context, snapshot, payload = capture(capture_opts)
  if vim.fn.mode():find("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  if not context then
    notify(
      "cannot ask about this selection: " .. snapshot.message,
      vim.log.levels.WARN
    )
    return nil, snapshot
  end
  M.close()
  local popup = open_popup(context, snapshot, payload, requested)
  if opts.question and opts.question ~= "" then
    vim.api.nvim_buf_set_lines(popup.input_buf, 0, -1, false, {
      opts.question,
    })
    require("iara.extras.ai.popup").submit(popup)
  end
  return popup
end

---Open the Ask AI popup for the live or last Visual selection, or for
---`opts.range` (linewise). Submit `opts.question` when provided.
---Error codes: those of `iara.extras.agents.context.capture`.
---@param opts { range: integer[]?, question: string? }?
---@return IaraAiPopup|nil popup
---@return IaraError|nil err
function M.ask(opts)
  return ask(opts)
end

---The open popup, or nil.
---@return IaraAiPopup|nil
function M.current()
  return current
end

---Close the open popup (cancelling its request), if any.
function M.close()
  if current then
    require("iara.extras.ai.popup").close(current)
  end
end

---Range of `:IaraAsk`: the last Visual selection keeps its mode when
---the range is exactly its lines; any other range is linewise.
local function command_range(args)
  if args.range == 0 then
    return nil
  end
  local first = vim.fn.line("'<")
  local last = vim.fn.line("'>")
  if args.line1 == first and args.line2 == last then
    return nil
  end
  return { args.line1, args.line2 }
end

local function create_command()
  vim.api.nvim_create_user_command("IaraAsk", function(args)
    M.ask({ range = command_range(args), question = args.args })
  end, {
    range = true,
    nargs = "*",
    desc = "Ask AI about the selected lines (optional question)",
  })
end

local function map_selection(keymaps, lhs, desc, rhs)
  if keymaps["x " .. lhs] == nil then
    vim.keymap.set("x", lhs, rhs, { desc = desc })
  end
end

local function create_mappings(keymaps)
  map_selection(keymaps, "<leader>ai", "Ask AI about the selection", M.ask)
  map_selection(
    keymaps,
    "<leader>ac",
    "Ask Claude about the selection",
    function()
      ask(nil, "claude")
    end
  )
end

---Register `:IaraAsk` and the Visual Ask AI keys once, when `extras.ai` is
---enabled. Starts no process.
---@param config table Composed configuration.
function M.setup(config)
  local extras = type(config) == "table" and config.extras or {}
  local settings = type(extras) == "table" and extras.ai or nil
  if settings == true then
    settings = {}
  end
  if configured or type(settings) ~= "table" then
    return
  end
  configured = true
  read_options(settings)
  create_command()
  create_mappings(type(config.keymaps) == "table" and config.keymaps or {})
end

return M
