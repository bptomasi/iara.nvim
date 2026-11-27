--- Structured data commands and mappings: the `features.structured` init
--- step (task D4). See contracts.md, section 11.3.
---
--- JSON buffers get the breadcrumb, show and copy path, key search, and
--- jumps to recorded locations (iara.features.structured.ui on top of
--- the JSON extractor). YAML buffers keep yaml-revealer through
--- iara.features.structured.yaml_legacy (task D1): `Space ys` routes to
--- its key search, and show or copy explain where YAML paths live until
--- a YAML adapter exists. Explicit actions refuse with a visible reason
--- in conservative buffers and never fall back to an unbounded scan.
---
--- Mappings (normal mode, under the `Space y` group): `ys` key search,
--- `yc` copy path, `yp` show path, `yt` toggle the breadcrumb. A
--- `config.keymaps` entry for the same "<mode> <lhs>" wins.
local json = require("iara.features.structured.json")
local path = require("iara.features.structured.path")
local ui = require("iara.features.structured.ui")

local M = {}

---@class IaraStructuredSettings
---@field breadcrumb boolean Show the JSON breadcrumb (default true).
M.DEFAULTS = { breadcrumb = true }

---@class IaraStructuredMapping
---@field lhs string
---@field desc string
---@field action string Name of the function of this module to call.

---@type IaraStructuredMapping[]
M.MAPPINGS = {
  {
    lhs = "<leader>ys",
    desc = "Search structured keys",
    action = "search_keys",
  },
  { lhs = "<leader>yc", desc = "Copy structured path", action = "copy_path" },
  { lhs = "<leader>yp", desc = "Show structured path", action = "show_path" },
  {
    lhs = "<leader>yt",
    desc = "Toggle structured breadcrumb",
    action = "toggle_breadcrumb",
  },
}

-- An explicit request superseded by the breadcrumb's own is retried.
local MAX_ATTEMPTS = 3

local api = vim.api
local group = nil

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.INFO)
end

local function warn(message)
  notify(message, vim.log.levels.WARN)
end

local function yaml_legacy()
  return require("iara.features.structured.yaml_legacy")
end

---@return "json"|"yaml"|nil
local function format_of(bufnr)
  local filetype = vim.bo[bufnr].filetype
  if filetype == "json" or filetype == "yaml" then
    return filetype
  end
end

-- Targets ------------------------------------------------------------------

local function request_target(bufnr, row, col, attempt, on_done)
  json.target_at(bufnr, row, col, function(target, err)
    local retry = err
      and err.code == "stale"
      and attempt < MAX_ATTEMPTS
      and api.nvim_buf_is_valid(bufnr)
    if retry then
      return request_target(bufnr, row, col, attempt + 1, on_done)
    end
    on_done(target, err)
  end)
end

---Target under the cursor of the current JSON buffer: the breadcrumb's
---cached one when it matches this text and cursor, else a new request.
local function cursor_target(action, on_done)
  local bufnr = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local cached = ui.cached_target(bufnr, row, col)
  if cached then
    return on_done(cached)
  end
  request_target(bufnr, row, col, 1, function(target, err)
    -- This request may have superseded the breadcrumb's.
    ui.schedule_breadcrumb()
    if err then
      return warn(("cannot %s: %s"):format(action, err.message))
    end
    -- A parse succeeded: a paused breadcrumb may run again.
    ui.resume_breadcrumb(bufnr)
    on_done(target)
  end)
end

---`file:line:column` of a target's recorded start (one-based byte
---column), offered when no canonical path exists.
---@param target IaraStructuredTarget
---@return string
function M.source_reference(target)
  local name = api.nvim_buf_get_name(target.bufnr)
  if name == "" then
    name = ("[buffer %d]"):format(target.bufnr)
  end
  return name .. ":" .. ui.location_label(target)
end

local function uniqueness_note(target)
  if target.certainty.unique == "unverified" then
    return " (uniqueness unverified)"
  end
  return ""
end

-- Clipboard ----------------------------------------------------------------

---Copy `text` to "+" when a clipboard exists, else the unnamed register.
---@return string register
local function copy_text(text)
  local register = vim.fn.has("clipboard") == 1 and "+" or '"'
  vim.fn.setreg(register, text, "v")
  return register
end

local function offer_source(target, err)
  local reference = M.source_reference(target)
  warn(("cannot copy path: %s"):format(err.message))
  local choice = "Copy source location " .. reference
  vim.ui.select({ choice }, {
    prompt = ("No canonical path (%s). Copy the source location?"):format(
      err.code
    ),
  }, function(selected)
    if selected then
      local register = copy_text(reference)
      notify(("copied %s to register %s"):format(reference, register))
    end
  end)
end

local function copy_target(target)
  local rendered, err = path.render(target)
  if not rendered then
    return offer_source(target, err)
  end
  local register = copy_text(rendered)
  local text = "copied %s to register %s%s"
  notify(text:format(rendered, register, uniqueness_note(target)))
end

local function show_target(target)
  local display = path.breadcrumb(target)
  local rendered, err = path.render(target)
  if rendered then
    notify(("%s  %s%s"):format(display, rendered, uniqueness_note(target)))
    return
  end
  local text = "%s  no canonical path: %s; source %s"
  notify(text:format(display, err.message, M.source_reference(target)))
end

-- YAML ---------------------------------------------------------------------

local function yaml_path_notice(action)
  local status = yaml_legacy().status(0)
  if status.state ~= "active" then
    local reason = status.message or ("yaml-revealer is " .. status.state)
    return warn(("cannot %s: %s"):format(action, reason))
  end
  if action == "show the path" then
    return notify("the YAML path is the yaml-revealer breadcrumb")
  end
  warn("copying YAML paths needs the YAML adapter (not yet available)")
end

-- Actions ------------------------------------------------------------------

---Refuse, with a notice, buffers that are neither JSON nor YAML.
local function unsupported(action)
  if format_of(0) then
    return false
  end
  warn(("cannot %s: not a JSON or YAML buffer"):format(action))
  return true
end

---Show the breadcrumb and canonical path under the cursor, or why no
---canonical path exists together with its source location.
function M.show_path()
  local action = "show the path"
  if unsupported(action) then
    return
  end
  if format_of(0) == "yaml" then
    return yaml_path_notice(action)
  end
  cursor_target(action, show_target)
end

---Copy the canonical path under the cursor. An incomplete, ambiguous,
---source-only, or too long path is refused with its reason, and the
---source location is offered instead.
function M.copy_path()
  local action = "copy the path"
  if unsupported(action) then
    return
  end
  if format_of(0) == "yaml" then
    return yaml_path_notice(action)
  end
  cursor_target(action, copy_target)
end

local function on_index(bufnr, result)
  if result.state == "cancelled" then
    return
  end
  if result.state == "error" then
    return warn("cannot search keys: " .. result.error.message)
  end
  if #result.targets == 0 then
    return notify("no keys to search in this buffer")
  end
  ui.open_key_search(bufnr, result)
end

---Key search with preview: JSON through the bounded index and a Snacks
---picker; YAML through yaml-revealer's `Space ys` prompt.
function M.search_keys()
  local action = "search keys"
  if unsupported(action) then
    return
  end
  local bufnr = api.nvim_get_current_buf()
  if format_of(bufnr) == "yaml" then
    return yaml_legacy().search_keys(bufnr)
  end
  json.index(bufnr, function(result)
    on_index(bufnr, result)
  end)
end

---Deliberate bounded retry after a parse watchdog: lift the suspension
---of the current JSON buffer and make one attempt for the path under
---the cursor, itself bounded by the watchdog.
function M.retry()
  local bufnr = api.nvim_get_current_buf()
  if format_of(bufnr) ~= "json" then
    return warn("cannot retry: not a JSON buffer")
  end
  if not json.retry(bufnr) then
    return notify("nothing to retry: JSON parsing is not suspended here")
  end
  cursor_target("retry", show_target)
end

---Turn the JSON breadcrumb on or off for every window.
function M.toggle_breadcrumb()
  local enabled = not ui.breadcrumb_enabled()
  ui.set_breadcrumb(enabled)
  notify("JSON breadcrumb " .. (enabled and "on" or "off"))
end

---Jump to a recorded location; never reparses a display path. Refused
---with a notice when the buffer changed since the target was recorded.
---@param target IaraStructuredTarget
---@return boolean jumped
function M.jump(target)
  if type(target) ~= "table" or type(target.bufnr) ~= "number" then
    error("target must be an IaraStructuredTarget", 2)
  end
  return ui.jump(target)
end

-- Setup --------------------------------------------------------------------

---@return IaraStructuredSettings
local function read_settings(config)
  local features = type(config) == "table" and config.features or nil
  local own = type(features) == "table" and features.structured or nil
  local settings = vim.deepcopy(M.DEFAULTS)
  if type(own) ~= "table" or own.breadcrumb == nil then
    return settings
  end
  if type(own.breadcrumb) ~= "boolean" then
    warn("features.structured.breadcrumb must be a boolean; using true")
    return settings
  end
  settings.breadcrumb = own.breadcrumb
  return settings
end

local function create_mappings(user_keymaps)
  for _, mapping in ipairs(M.MAPPINGS) do
    if user_keymaps["n " .. mapping.lhs] == nil then
      vim.keymap.set("n", mapping.lhs, function()
        M[mapping.action]()
      end, { desc = mapping.desc })
    end
  end
end

local function create_commands()
  local commands = {
    IaraStructuredSearch = { "search_keys", "Search JSON or YAML keys" },
    IaraStructuredCopy = { "copy_path", "Copy the structured path" },
    IaraStructuredPath = { "show_path", "Show the structured path" },
    IaraStructuredBreadcrumb = {
      "toggle_breadcrumb",
      "Toggle the JSON breadcrumb",
    },
    IaraStructuredRetry = { "retry", "Retry JSON parsing after a watchdog" },
  }
  for name, spec in pairs(commands) do
    api.nvim_create_user_command(name, function()
      M[spec[1]]()
    end, { desc = spec[2] })
  end
end

---Register the breadcrumb, commands, and mappings. Runs only when
---`features.structured` is enabled (init skips the step otherwise).
---@param config table Composed configuration.
function M.setup(config)
  if group then
    return
  end
  local settings = read_settings(config)
  group = api.nvim_create_augroup("IaraStructured", { clear = true })
  ui.setup(group, settings.breadcrumb)
  create_commands()
  local user_keymaps = type(config) == "table" and config.keymaps or nil
  create_mappings(type(user_keymaps) == "table" and user_keymaps or {})
end

return M
