--- Terminal actions: the main terminal per project, extra shells, the
--- terminal list, and leaving terminal input.
---
--- Every action resolves the project of the invoking buffer when it
--- starts. Records and processes belong to the registry (T2); windows
--- belong to `panel`: shells show in the shell panel, agent sessions in
--- the agent panel, each at its own position (UX2). Hiding never
--- stops a job, and no action restarts one silently. Explicit show and
--- focus, including directional shortcuts, enter terminal input.
--- Ordinary buffer entry leaves the user in control of the mode.
---
--- A shell (role main or shell) that exits for any reason closes its
--- panel and is disposed at once, unless `features.terminal`
--- `close_on_exit = false` keeps the transcript (T4, by user decision;
--- this supersedes ARCH's successful-exit retention for shells). Agent
--- sessions follow `extras.agents.close_on_exit`. See contracts.md,
--- section `iara.features.terminal`.
local keymaps = require("iara.features.terminal.keymaps")
local panel = require("iara.features.terminal.panel")
local registry = require("iara.features.terminal.registry")
local root = require("iara.core.root")
local title = require("iara.features.terminal.title")

local shell_panel = panel.shell

local M = {}

local configured = false

---Close and dispose shells when they exit (`features.terminal`).
local close_on_exit = true

---Increments on every action, so a deferred choice from an older action
---never takes focus.
local action_generation = 0

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.ERROR)
end

local function next_action()
  action_generation = action_generation + 1
  return action_generation
end

---@return IaraTerminalRecord|nil
local function record_for_buffer(bufnr)
  for _, record in ipairs(registry.list()) do
    if record.bufnr == bufnr then
      return record
    end
  end
  return nil
end

---Enter terminal input once the current action has finished, unless a
---newer action started or the panel lost focus meanwhile.
local function enter_input(win)
  local generation = action_generation
  vim.schedule(function()
    local current = generation == action_generation
      and vim.api.nvim_get_current_win() == win
    if current then
      vim.cmd.startinsert()
    end
  end)
end

---Directional navigation focused an open panel. Resume its running job.
function M.resume_panel_input()
  local win = vim.api.nvim_get_current_win()
  if win ~= shell_panel:window() and win ~= panel.agent:window() then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local record = record_for_buffer(bufnr)
  if record and record.status == "running" then
    -- Switch modes before the next queued key goes to Terminal-Normal.
    vim.cmd.startinsert()
  end
end

---Show a record in the panel of its role and focus it; a live job gets
---input. `position`, when given, is where that panel opens from now on.
---@return boolean shown
local function present(record, position)
  local target = panel.for_role(record.role)
  local ok, win = pcall(function()
    if position then
      target:set_position(position)
    end
    return target:show(record.bufnr)
  end)
  if not ok then
    notify("cannot open the terminal panel: " .. tostring(win))
    return false
  end
  -- With 'noshowmode', entering terminal input never redraws the command
  -- line, so a message from an earlier action (such as "no terminals
  -- yet") would stay under the terminal that now exists.
  vim.api.nvim_echo({ { "" } }, false, {})
  if record.status == "running" then
    enter_input(win)
  end
  return true
end

---@return IaraTerminalRecord|nil
local function create(spec)
  local record, err = registry.create(spec)
  if not record then
    notify(err and err.message or "cannot create the terminal")
  end
  return record
end

local function main_terminal(project_root)
  return registry.main_for(project_root)
    or create({ root = project_root, role = "main" })
end

---Toggle hides a visible panel unless it shows a live terminal of
---another project and was invoked from outside it: then the invoking
---project's main terminal takes the panel instead.
local function should_hide(win, project)
  if vim.api.nvim_get_current_win() == win then
    return true
  end
  local shown = record_for_buffer(vim.api.nvim_win_get_buf(win))
  return shown == nil or shown.project == project
end

---F7 / Space tt: main terminal of the invoking buffer's project. In a
---focused agent panel, F7 hides that panel instead.
function M.toggle_main()
  next_action()
  if panel.agent:window() == vim.api.nvim_get_current_win() then
    panel.agent:hide()
    return
  end
  local project_root = root.resolve(0)
  local win = shell_panel:window()
  if win and should_hide(win, project_root.worktree_id) then
    shell_panel:hide()
    return
  end
  local record = main_terminal(project_root)
  if record then
    present(record)
  end
end

---Idempotent focus without toggling visibility.
function M.focus_main()
  next_action()
  local record = main_terminal(root.resolve(0))
  if record then
    present(record)
  end
end

---Space tn: another shell at the project root.
function M.new()
  next_action()
  local record = create({ root = root.resolve(0), role = "shell" })
  if record then
    present(record)
  end
end

---Directory of a named local file buffer, which may be modified.
---@return string|nil dir
---@return string|nil reason
local function file_directory(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or name == "" then
    return nil, "the current buffer is not a file"
  end
  if name:find("^%a[%w+.-]*://") then
    return nil, "the current file is not local"
  end
  local dir = vim.fs.dirname(vim.fs.normalize(name))
  if vim.fn.isdirectory(dir) ~= 1 then
    return nil, "the directory of the current file does not exist"
  end
  return dir
end

---Space t.: a shell in the current file's directory.
function M.new_here()
  next_action()
  local dir, reason = file_directory(vim.api.nvim_get_current_buf())
  if not dir then
    notify(
      reason .. "; Space tn opens one at the project root",
      vim.log.levels.WARN
    )
    return
  end
  local spec = { root = root.resolve(0), role = "shell", cwd = dir }
  local record = create(spec)
  if record then
    present(record)
  end
end

---Picker text: label, status when not running, and the project path,
---which tells apart projects whose directories share a name.
local function describe(record)
  local text = record.label
  if record.status ~= "running" then
    local code = record.exit_code and (" " .. record.exit_code) or ""
    text = ("%s [%s%s]"):format(text, record.status, code)
  end
  return ("%s  %s"):format(text, vim.fn.fnamemodify(record.root_path, ":~"))
end

local function show_choice(choice, generation)
  if not choice or generation ~= action_generation then
    return
  end
  local record = registry.get(choice.id)
  if not record or not record.bufnr then
    notify("the chosen terminal no longer exists", vim.log.levels.WARN)
    return
  end
  present(record)
end

---Space tl: choose among the terminals of every project.
function M.select()
  local generation = next_action()
  local records = registry.list()
  if #records == 0 then
    notify(
      "no terminals yet; F7 opens the project's main terminal",
      vim.log.levels.INFO
    )
    return
  end
  local opts = { prompt = "Terminal", format_item = describe }
  vim.ui.select(records, opts, function(choice)
    -- Pickers may still own the window while calling back.
    vim.schedule(function()
      show_choice(choice, generation)
    end)
  end)
end

---:IaraTermExit, leave terminal input mode.
function M.exit_input()
  if vim.api.nvim_get_mode().mode == "t" then
    vim.cmd.stopinsert()
  end
end

---Show and focus a registry record in the panel of its role (used by
---agents, A1). `opts.position` moves that panel there first (UX2).
---@param id integer
---@param opts { position: IaraPanelPosition? }?
---@return boolean shown
function M.show(id, opts)
  next_action()
  local record = registry.get(id)
  if not record or not record.bufnr then
    return false
  end
  return present(record, opts and opts.position)
end

---Close the panel showing an exited record, in any tab, and dispose the
---record with its buffer. Focus returns to the previous editing window
---when the panel had it. Running records are left alone.
---@param id integer
---@param generation integer? Close only this generation of the record.
---@return boolean closed
function M.close(id, generation)
  local record = registry.get(id)
  local finished = record
    and (record.status == "exited" or record.status == "failed")
  if not finished or (generation and record.generation ~= generation) then
    return false
  end
  if record.bufnr then
    panel.for_role(record.role):close_buffer(record.bufnr)
  end
  return (registry.dispose(id))
end

---Whether `side` is a panel position; an unknown one is reported.
---@param side any
---@param what string "terminal" or "agent", for the message.
---@return boolean
function M.check_position(side, what)
  if panel.POSITIONS[side] then
    return true
  end
  notify(
    ("unknown %s position %q; use %s"):format(
      what,
      tostring(side),
      table.concat(panel.ORDER, ", ")
    )
  )
  return false
end

---:IaraTermPosition {side}: where the shell panel opens; a visible panel
---moves there without restarting its job.
---@param side IaraPanelPosition
---@return boolean ok False for an unknown side, which is reported.
function M.set_position(side)
  if not M.check_position(side, "terminal") then
    return false
  end
  shell_panel:set_position(side)
  return true
end

---Space tv, :IaraTermPosition: move the shell panel to the next
---position (bottom, right, top, left, float). A hidden panel shows the
---main terminal at the new position.
function M.toggle_position()
  M.set_position(panel.next_position(shell_panel:position()))
  if not shell_panel:window() then
    M.focus_main()
  end
end

---Space ts: the main terminal in a panel at the right.
function M.show_side()
  M.set_position("right")
  M.focus_main()
end

---Record of the terminal in the current window, else of a panel.
local function target_record()
  local record = record_for_buffer(vim.api.nvim_get_current_buf())
  local shown = shell_panel:buffer() or panel.agent:buffer()
  return record or (shown and record_for_buffer(shown))
end

local function on_target(action)
  return function()
    local record = target_record()
    if not record then
      notify("no Iara terminal here", vim.log.levels.WARN)
      return
    end
    action(record)
  end
end

local function restart(record)
  local restarted, err = registry.restart(record.id)
  if not restarted then
    notify(err.message)
    return
  end
  present(restarted)
end

local function dispose(record)
  local ok, err = registry.dispose(record.id)
  if not ok then
    notify(err.message .. "; stop it first", vim.log.levels.WARN)
  end
end

local function stop(record)
  registry.stop(record.id)
end

local COMMANDS = {
  IaraTermToggle = { M.toggle_main, "Toggle the main terminal" },
  IaraTermFocus = { M.focus_main, "Show and focus the main terminal" },
  IaraTermNew = { M.new, "New terminal at the project root" },
  IaraTermHere = { M.new_here, "New terminal in the file directory" },
  IaraTermSelect = { M.select, "Choose a terminal of any project" },
  IaraTermExit = { M.exit_input, "Leave terminal input mode" },
  IaraTermStop = { on_target(stop), "Stop this terminal's job" },
  IaraTermRestart = { on_target(restart), "Restart this terminal" },
  IaraTermDispose = { on_target(dispose), "Remove this exited terminal" },
}

local function position_command(args)
  if args.args == "" then
    M.toggle_position()
    return
  end
  M.set_position(args.args)
end

local function create_commands()
  for name, command in pairs(COMMANDS) do
    vim.api.nvim_create_user_command(name, function()
      command[1]()
    end, { desc = command[2] })
  end
  vim.api.nvim_create_user_command("IaraTermPosition", position_command, {
    nargs = "?",
    complete = function()
      return vim.deepcopy(panel.ORDER)
    end,
    desc = "Move the terminal panel (no argument: next position)",
  })
end

local SHELL_ROLES = { main = true, shell = true }

local function on_terminal_changed(args)
  local data = args.data
  local record = registry.get(data.id)
  if not record then
    return
  end
  if data.status == "running" and record.bufnr then
    keymaps.map_buffer(M, record.bufnr)
  end
  if data.status == "exited" and close_on_exit and SHELL_ROLES[record.role] then
    -- After the exit event has reached every listener.
    vim.schedule(function()
      M.close(data.id, data.generation)
    end)
  end
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup("IaraTerminal", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraTerminalChanged",
    callback = on_terminal_changed,
  })
end

---Apply `features.terminal`; invalid values are reported and replaced by
---the defaults (position "bottom", close_on_exit true).
local function read_options(config)
  local features = type(config) == "table" and config.features or nil
  local options = type(features) == "table" and features.terminal or nil
  options = type(options) == "table" and options or {}
  local position = options.position or "bottom"
  if not M.set_position(position) then
    shell_panel:set_position("bottom")
  end
  local close = options.close_on_exit
  if close ~= nil and type(close) ~= "boolean" then
    notify("features.terminal.close_on_exit must be a boolean; using true")
    close = true
  end
  close_on_exit = close ~= false
end

---Register commands, mappings, and the terminal listener, once, and
---apply `features.terminal` (`position`, `close_on_exit`).
---@param config table Composed configuration.
function M.setup(config)
  if configured then
    return
  end
  configured = true
  panel.set_title_provider(title.title)
  read_options(config)
  create_commands()
  create_autocmds()
  keymaps.setup(M, type(config) == "table" and config.keymaps or nil)
end

return M
