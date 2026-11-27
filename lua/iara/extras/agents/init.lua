--- Agent terminals (A1): Claude Code and Codex in named project
--- terminals, enabled by `extras.agents` (on by default).
---
--- Each CLI runs with its native argv, configuration, authentication,
--- permissions, models, and session controls. Iara adds no flags and no
--- environment, stores no credentials, and refuses a configured argv that
--- bypasses the CLI's permission or sandbox checks. Sessions are role
--- "agent" records of the terminal registry (T2), shown in the terminal
--- agent panel (T3, T4, UX2) and labeled by project, agent, and
--- instance. The agent panel is separate from the shell panel and opens
--- at `extras.agents.position` ("right"), or at a per-agent
--- `extras.agents.<name>.position`; `:IaraAgentPosition` and `Space ap`
--- move it, `Space at` shows or hides it. Hiding the panel never cancels
--- an agent; interrupting and exiting stay native.
---
--- Context reaches an agent only by preview and manual paste: a mapping
--- captures the Visual selection or a disk reference of the current file
--- (A2), previews the exact payload (`y` copies it), and releases the
--- snapshot when the preview closes. Nothing is typed into an agent.
---
--- A session that exits with status 0 closes its panel and is disposed;
--- a nonzero exit keeps the transcript readable. `close_on_exit` changes
--- this: "success" (default), true (always close), false (always keep).
---
--- Optional settings, for wrappers or profile flags:
---   extras = { agents = { claude = { argv = { "claude", "--verbose" } } } }
---   extras = { agents = { close_on_exit = true } }
---   extras = { agents = { position = "float", codex = { position = "top" } } }
--- See contracts.md, section `iara.extras.agents`.
local panel = require("iara.features.terminal.panel")
local registry = require("iara.features.terminal.registry")
local root = require("iara.core.root")
local terminal = require("iara.features.terminal")
local title = require("iara.features.terminal.title")

local M = {}

---@class IaraAgentDefinition
---@field title string Display name.
---@field argv string[] Native argv; the first item is the executable.

---@type table<string, IaraAgentDefinition>
M.AGENTS = {
  claude = { title = "Claude Code", argv = { "claude" } },
  codex = { title = "Codex", argv = { "codex" } },
}

---Picker and completion order.
M.ORDER = { "claude", "codex" }

---Arguments that disable the CLIs' own approvals, permissions, or
---sandbox. Iara never launches an agent with any of them.
M.BYPASS_ARGUMENTS = {
  "--dangerously-skip-permissions",
  "--allow-dangerously-skip-permissions",
  "--dangerously-bypass-approvals-and-sandbox",
  "--yolo",
  "bypassPermissions",
  "danger-full-access",
}

local MAPPINGS = {
  { "n", "<leader>aa", "select", "Choose an agent session" },
  { "n", "<leader>at", "toggle", "Toggle agent panel" },
  { "n", "<leader>ap", "cycle_position", "Move agent panel (next position)" },
  { "n", "<leader>ac", "launch_claude", "Open Claude Code" },
  { "n", "<leader>ax", "launch_codex", "Open Codex" },
  { "x", "<leader>as", "preview_selection", "Preview selection for agent" },
  { "n", "<leader>af", "preview_file", "Preview file reference for agent" },
}

local configured = false

---Launch argv per agent, after the user's `argv` settings.
---@type table<string, string[]>
local launch_argv = {}

---When an exited session closes: "success" (status 0), true, or false.
---@type "success"|boolean
local close_policy = "success"

local CLOSE_POLICIES = { success = true, [true] = true, [false] = true }

---Panel position per agent, after `position` settings and commands.
---@type table<string, IaraPanelPosition>
local positions = {}

---Settings of `extras.agents` that are not agent names.
local GLOBAL_SETTINGS = { close_on_exit = true, position = true }

---Fields of `extras.agents.<name>`.
local AGENT_FIELDS = { argv = true, position = true }

---Increments on every action, so a late choice of an older picker is
---dropped.
local action_generation = 0

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.ERROR)
end

local function next_action()
  action_generation = action_generation + 1
  return action_generation
end

---@return IaraError
local function failure(code, message)
  return { code = code, message = message }
end

---The bypass argument found in `argv`, if any; `--flag=value` counts.
---@param argv string[]
---@return string|nil
local function bypass_argument(argv)
  for _, argument in ipairs(argv) do
    local flag, value = argument:match("^(%-%-[^=]+)=(.*)$")
    for _, bypass in ipairs(M.BYPASS_ARGUMENTS) do
      if argument == bypass or flag == bypass or value == bypass then
        return bypass
      end
    end
  end
  return nil
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

---Problem with one agent's settings, or nil when they are usable.
---@return string|nil
local function settings_problem(settings)
  if type(settings) ~= "table" then
    return "must be a table"
  end
  for key in pairs(settings) do
    if not AGENT_FIELDS[key] then
      return "unknown field " .. tostring(key)
    end
  end
  local position = settings.position
  if position ~= nil and not panel.POSITIONS[position] then
    return "position must be one of " .. table.concat(panel.ORDER, ", ")
  end
  if settings.argv == nil then
    return nil
  end
  if not is_argv(settings.argv) then
    return "argv must be a list of non-empty strings"
  end
  local bypass = bypass_argument(settings.argv)
  if bypass then
    return "argv must not contain the bypass argument " .. bypass
  end
  return nil
end

---Read `extras.agents`; an invalid entry is reported once and replaced
---by the native default.
local function read_close_policy(value)
  if value == nil or CLOSE_POLICIES[value] then
    return value == nil and "success" or value
  end
  notify(
    'extras.agents.close_on_exit must be "success", true, or false; '
      .. 'using "success"'
  )
  return "success"
end

---Default panel position of every agent; an invalid one is reported
---and replaced by "right".
local function read_position(value)
  if value == nil or terminal.check_position(value, "agent") then
    return value or "right"
  end
  return "right"
end

---Launch argv and panel position of one agent; invalid settings are
---reported and replaced by the native argv and the default position.
local function read_agent(name, settings, default_position)
  local agent = M.AGENTS[name]
  local problem = settings ~= nil and settings_problem(settings)
  if problem then
    notify(
      ("extras.agents.%s %s; using %q"):format(name, problem, agent.argv[1])
    )
  end
  local valid = not problem and settings or {}
  launch_argv[name] = vim.deepcopy(valid.argv or agent.argv)
  positions[name] = valid.position or default_position
end

local function read_options(options)
  close_policy = read_close_policy(options.close_on_exit)
  local default_position = read_position(options.position)
  panel.agent:set_position(default_position)
  launch_argv, positions = {}, {}
  for name in pairs(M.AGENTS) do
    read_agent(name, options[name], default_position)
  end
  for name in pairs(options) do
    if not M.AGENTS[name] and not GLOBAL_SETTINGS[name] then
      notify("extras.agents: unknown agent " .. tostring(name))
    end
  end
end

---Show a session in the agent panel at its agent's position.
local function show(record)
  return terminal.show(record.id, { position = positions[record.name] })
end

local function check_name(name)
  if not M.AGENTS[name] then
    error("iara.extras.agents: unknown agent " .. tostring(name), 3)
  end
end

local function is_live(record)
  return record.status == "running" or record.status == "starting"
end

---Newest session of `name` in a project, preferring live ones.
---@return IaraTerminalRecord|nil
local function latest_session(project, name)
  local found = nil
  local filter = { project = project, role = "agent" }
  for _, record in ipairs(registry.list(filter)) do
    local newer = not found or is_live(record) or not is_live(found)
    if record.name == name and newer then
      found = record
    end
  end
  return found
end

---Start a new session of `name` in the project root and show it. A
---missing CLI is reported and changes nothing.
---@param project_root IaraRoot
---@param name string
---@return IaraTerminalRecord|nil
---@return IaraError|nil
local function start(project_root, name)
  local argv = launch_argv[name] or M.AGENTS[name].argv
  if vim.fn.executable(argv[1]) ~= 1 then
    local err = failure(
      "not_found",
      ("%s is not installed: %q was not found on PATH"):format(
        M.AGENTS[name].title,
        argv[1]
      )
    )
    notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  local spec = { root = project_root, role = "agent", name = name }
  spec.argv = argv
  local record, err = registry.create(spec)
  if not record then
    notify(("cannot start %s: %s"):format(name, err and err.message))
    return nil, err
  end
  show(record)
  return record
end

---Open (or focus) a named agent terminal for the invoking project. An
---existing session is shown as it is, even when it exited; a new one
---starts at the project root. `position` (UX2) is where this agent's
---panel opens from now on; an unknown one is reported and nothing opens.
---Error code: "not_found" when the CLI is missing; nothing else happens.
---@param name "claude"|"codex"
---@param position IaraPanelPosition?
---@return IaraTerminalRecord|nil record
---@return IaraError|nil err
function M.launch(name, position)
  check_name(name)
  next_action()
  if position ~= nil and not terminal.check_position(position, "agent") then
    return nil, failure("position", "unknown position " .. tostring(position))
  end
  positions[name] = position or positions[name] or "right"
  local project_root = root.resolve(0)
  local session = latest_session(project_root.worktree_id, name)
  if not session then
    return start(project_root, name)
  end
  show(session)
  return registry.get(session.id)
end

---Picker text: label, status when not running, and the project path.
local function describe(item)
  if item.new then
    return ("New %s session in %s"):format(item.title, item.root.label)
  end
  local record = item.record
  local text = record.label
  if record.status ~= "running" then
    local code = record.exit_code and (" " .. record.exit_code) or ""
    text = ("%s [%s%s]"):format(text, record.status, code)
  end
  return ("%s  %s"):format(text, vim.fn.fnamemodify(record.root_path, ":~"))
end

---Sessions of the invoking project first, then those of other projects,
---then one "new session" entry per agent.
local function picker_items(project_root)
  local own, others = {}, {}
  for _, record in ipairs(registry.list({ role = "agent" })) do
    local list = record.project == project_root.worktree_id and own or others
    table.insert(list, { record = record })
  end
  local items = vim.list_extend(own, others)
  for _, name in ipairs(M.ORDER) do
    local label = M.AGENTS[name].title
    table.insert(items, { new = name, title = label, root = project_root })
  end
  return items
end

local function choose(item, generation)
  if not item or generation ~= action_generation then
    return
  end
  if item.new then
    start(item.root, item.new)
    return
  end
  if not registry.get(item.record.id) then
    notify("the chosen agent session no longer exists", vim.log.levels.WARN)
    return
  end
  show(item.record)
end

---Choose an agent session of any project, or start a new one for the
---invoking project.
function M.select()
  local generation = next_action()
  local items = picker_items(root.resolve(0))
  local opts = { prompt = "Agent", format_item = describe }
  vim.ui.select(items, opts, function(item)
    -- Pickers may still own the window while calling back.
    vim.schedule(function()
      choose(item, generation)
    end)
  end)
end

---Newest session of the invoking project, preferring live ones.
---@return IaraTerminalRecord|nil
local function project_session(project)
  local found = nil
  for _, name in ipairs(M.ORDER) do
    local session = latest_session(project, name)
    local better = session
      and (not found or is_live(session) and not is_live(found))
    if better then
      found = session
    end
  end
  return found
end

---Space at: hide a visible agent panel, else show the invoking
---project's agent session; without one, choose or start a session.
function M.toggle()
  next_action()
  if panel.agent:hide() then
    return
  end
  local session = project_session(root.resolve(0).worktree_id)
  if not session then
    M.select()
    return
  end
  show(session)
end

---:IaraAgentPosition {side}: where the agent panel opens for every
---agent from now on (overriding per-agent settings); a visible panel
---moves there without restarting its session.
---@param side IaraPanelPosition
---@return boolean ok False for an unknown side, which is reported.
function M.set_position(side)
  if not terminal.check_position(side, "agent") then
    return false
  end
  for name in pairs(M.AGENTS) do
    positions[name] = side
  end
  panel.agent:set_position(side)
  return true
end

---Space ap, :IaraAgentPosition: move the agent panel to the next
---position; a hidden panel is shown there as `toggle` would.
function M.cycle_position()
  M.set_position(panel.next_position(panel.agent:position()))
  if not panel.agent:window() then
    M.toggle()
  end
end

---Preview a snapshot; release it once its preview is gone.
local function preview(context, snapshot)
  local source = vim.api.nvim_get_current_buf()
  local ok, err = context.preview(snapshot)
  local preview_buf = vim.api.nvim_get_current_buf()
  if not ok or preview_buf == source then
    context.release(snapshot.id)
    if err then
      notify("context not shown: " .. err.message, vim.log.levels.WARN)
    end
    return
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("IaraAgents", { clear = false }),
    buffer = preview_buf,
    once = true,
    callback = function()
      -- The preview owner still holds the buffer during this event.
      vim.schedule(function()
        context.release(snapshot.id)
      end)
    end,
  })
end

---Capture with `opts` and preview the payload.
local function capture_and_preview(opts, leave_visual)
  local context = require("iara.extras.agents.context")
  local snapshot, err = context.capture(opts)
  if leave_visual then
    vim.cmd("normal! \27")
  end
  if not snapshot then
    notify("context not captured: " .. err.message, vim.log.levels.WARN)
    return
  end
  preview(context, snapshot)
end

---Visual mode: preview the live selection (A2 needs the live mode for
---`$` blocks), before focus changes.
local function preview_selection()
  next_action()
  capture_and_preview({}, true)
end

---Preview a disk reference to the current file, never its unsaved text.
local function preview_file()
  next_action()
  capture_and_preview({ mode = "reference" }, false)
end

local ACTIONS = {
  select = M.select,
  toggle = M.toggle,
  cycle_position = M.cycle_position,
  launch_claude = function()
    M.launch("claude")
  end,
  launch_codex = function()
    M.launch("codex")
  end,
  preview_selection = preview_selection,
  preview_file = preview_file,
}

local function create_mappings(user_keymaps)
  for _, mapping in ipairs(MAPPINGS) do
    local mode, lhs, action, desc = unpack(mapping)
    if user_keymaps[mode .. " " .. lhs] == nil then
      vim.keymap.set(mode, lhs, ACTIONS[action], { desc = desc })
    end
  end
end

local function agent_command(args)
  local name, position = unpack(args.fargs)
  if not name then
    M.select()
    return
  end
  if not M.AGENTS[name] or #args.fargs > 2 then
    notify("usage: :IaraAgent [claude|codex] [position]")
    return
  end
  M.launch(name, position)
end

---Agent names first, then positions after a name.
local function complete_agent(_, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  local typing_first = #words < 2 or (#words == 2 and not line:find("%s$"))
  if typing_first then
    return vim.deepcopy(M.ORDER)
  end
  return vim.deepcopy(panel.ORDER)
end

local function position_command(args)
  if args.args == "" then
    M.cycle_position()
    return
  end
  M.set_position(args.args)
end

local function create_commands()
  local command = vim.api.nvim_create_user_command
  command("IaraAgent", agent_command, {
    nargs = "*",
    complete = complete_agent,
    desc = "Open an agent (claude, codex) at a position, or choose one",
  })
  command("IaraAgentToggle", M.toggle, { desc = "Show or hide agents" })
  command("IaraAgentPosition", position_command, {
    nargs = "?",
    complete = function()
      return vim.deepcopy(panel.ORDER)
    end,
    desc = "Move the agent panel (no argument: next position)",
  })
  command("IaraAgentFile", preview_file, {
    desc = "Preview a disk reference to the current file for an agent",
  })
end

local function closes_on_exit(record)
  if close_policy == "success" then
    return record.exit_code == 0
  end
  return close_policy
end

---Report how an agent session ended, then close it or keep its
---transcript as `close_on_exit` says.
local function on_terminal_changed(args)
  local status = args.data.status
  if status ~= "exited" and status ~= "failed" then
    return
  end
  local record = registry.get(args.data.id)
  if not record or record.role ~= "agent" then
    return
  end
  local code = record.exit_code and (" with status " .. record.exit_code) or ""
  notify(("%s %s%s"):format(record.label, status, code), vim.log.levels.INFO)
  if status == "exited" and closes_on_exit(record) then
    -- After the exit event has reached every listener.
    vim.schedule(function()
      terminal.close(record.id, record.generation)
    end)
  end
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup("IaraAgents", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraTerminalChanged",
    callback = on_terminal_changed,
  })
end

---Register commands, mappings, and the exit listener once, when
---`extras.agents` is enabled. Starts no process.
---@param config table Composed configuration.
function M.setup(config)
  local extras = type(config) == "table" and config.extras or {}
  local options = type(extras) == "table" and extras.agents or nil
  if options == true then
    options = {}
  end
  if configured or type(options) ~= "table" then
    return
  end
  configured = true
  for name, agent in pairs(M.AGENTS) do
    title.name_agent(name, agent.title)
  end
  read_options(options)
  create_commands()
  create_autocmds()
  create_mappings(type(config.keymaps) == "table" and config.keymaps or {})
end

return M
