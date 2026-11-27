--- yaml-revealer under a single owner.
---
--- The plugin's ftplugin installs buffer-local `BufEnter,CursorMoved`
--- autocmds (augroup `YamlRevealer`) that rescan the buffer synchronously
--- on every cursor move. This module removes those handlers from every
--- YAML buffer and installs its own, which call the plugin's display only
--- while the buffer is eligible. It also owns the `Space ys` mapping and
--- the plugin's namespace.
---
--- Per buffer states:
--- - "active": handlers installed, breadcrumb and key search work.
--- - "pending": eligibility is still unknown; nothing runs. The first
---   verdict activates or suspends the buffer.
--- - "suspended": the buffer was conservative. Handlers and virtual text
---   are removed, and only `:IaraYamlResume` (or `resume()`) on an
---   eligible buffer brings them back; becoming eligible again only
---   tells the user how to resume.
local eligibility = require("iara.core.eligibility")

local M = {}

---Settings of the user's NvChad configuration, kept as-is.
M.GLOBALS = {
  yaml_revealer_display_mode = "virtual",
  yaml_revealer_include_current_key = 1,
  yaml_revealer_separator = ".",
  yaml_revealer_compact_separator = 1,
}

M.SEARCH_LHS = "<leader>ys"

local PLUGIN_GROUP = "YamlRevealer"
local NAMESPACE = "yaml_revealer"
local HANDLER_EVENTS = { "BufEnter", "CursorMoved" }

---@class IaraYamlLegacyEntry
---@field state "active"|"pending"|"suspended"
---@field message string? Why the buffer is not active.
---@field resumable boolean Suspended, but eligible again.
---@field handlers integer[] Ids of the owned display autocmds.

---@type table<integer, IaraYamlLegacyEntry>
local entries = {}

local group = nil

local api = vim.api

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.INFO)
end

local function plugin_loaded()
  return vim.fn.exists("*DisplayYamlPath") == 1
end

local function clear_display(bufnr)
  local namespace = api.nvim_create_namespace(NAMESPACE)
  api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

---The plugin's own handlers for `bufnr`; empty before its ftplugin ran.
---@param bufnr integer
---@return table[] autocmds As returned by nvim_get_autocmds.
function M.plugin_handlers(bufnr)
  local ok, found = pcall(api.nvim_get_autocmds, {
    group = PLUGIN_GROUP,
    buffer = bufnr,
  })
  return ok and found or {}
end

local function remove_plugin_handlers(bufnr)
  -- Autocmds defined by `:autocmd` carry no id; clear them by group.
  if #M.plugin_handlers(bufnr) > 0 then
    api.nvim_clear_autocmds({ group = PLUGIN_GROUP, buffer = bufnr })
  end
end

local function remove_handlers(entry)
  for _, id in ipairs(entry.handlers) do
    pcall(api.nvim_del_autocmd, id)
  end
  entry.handlers = {}
end

local apply

local function display(bufnr)
  local entry = entries[bufnr]
  if not entry or entry.state ~= "active" or not plugin_loaded() then
    return
  end
  if not eligibility.is_eligible(bufnr) then
    -- Decide now instead of scanning until the event arrives.
    apply(bufnr)
    return
  end
  vim.fn.DisplayYamlPath()
end

local function install_handlers(bufnr, entry)
  remove_handlers(entry)
  for _, event in ipairs(HANDLER_EVENTS) do
    local id = api.nvim_create_autocmd(event, {
      group = group,
      buffer = bufnr,
      desc = "Iara: yaml-revealer breadcrumb",
      callback = function()
        display(bufnr)
      end,
    })
    table.insert(entry.handlers, id)
  end
end

local function activate(bufnr, entry)
  entry.state, entry.message, entry.resumable = "active", nil, false
  install_handlers(bufnr, entry)
  if bufnr == api.nvim_get_current_buf() then
    display(bufnr)
  end
end

local function stop(bufnr, entry, state, message)
  entry.state, entry.message = state, message
  remove_handlers(entry)
  clear_display(bufnr)
end

local function suspend(bufnr, entry, message)
  entry.resumable = false
  if entry.state == "suspended" then
    entry.message = message
    return
  end
  stop(bufnr, entry, "suspended", message)
  local text = "yaml-revealer suspended in this buffer: " .. message
  notify(text, vim.log.levels.WARN)
end

local RESUME_HINT = "buffer is eligible again; run :IaraYamlResume"

local function offer_resume(entry)
  if entry.resumable then
    return
  end
  entry.resumable = true
  notify("yaml-revealer is still suspended: " .. RESUME_HINT)
end

---Move `bufnr` to the state its eligibility allows. Suspension is sticky.
apply = function(bufnr)
  local entry = entries[bufnr]
  if not entry then
    return
  end
  local result = eligibility.check(bufnr)
  if result.state == "conservative" then
    suspend(bufnr, entry, result.message or result.reason or "conservative")
  elseif entry.state == "suspended" then
    if result.state == "eligible" then
      offer_resume(entry)
    end
  elseif result.state == "eligible" then
    if entry.state ~= "active" then
      activate(bufnr, entry)
    end
  elseif entry.state ~= "pending" then
    stop(bufnr, entry, "pending", result.message or "eligibility unknown")
  end
end

local function search_refusal(entry)
  if not entry then
    return "not a YAML buffer"
  end
  if entry.state == "suspended" then
    return "yaml-revealer is suspended: " .. entry.message
  end
  if entry.state ~= "active" then
    return "yaml-revealer is waiting for the size check"
  end
  if not plugin_loaded() then
    return "yaml-revealer is not loaded"
  end
end

---Prompt for a separator-joined key path and jump to it, as `Space ys`
---did in NvChad. Refused, with the reason shown, unless active.
---@param bufnr integer? 0 or nil for the current buffer.
function M.search_keys(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  apply(bufnr)
  local refusal = search_refusal(entries[bufnr])
  if refusal then
    notify(refusal, vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(vim.fn.SearchYamlKey)
  -- E684: the plugin indexes an empty input; cancelling is not an error.
  if not ok and not tostring(err):match("E684") then
    notify(tostring(err), vim.log.levels.ERROR)
  end
end

local function map_search(bufnr)
  vim.keymap.set("n", M.SEARCH_LHS, function()
    M.search_keys(bufnr)
  end, { buffer = bufnr, desc = "Search YAML key" })
end

---Take over a YAML buffer: drop the plugin's handlers, map `Space ys`,
---and apply eligibility. Idempotent; a suspended buffer stays suspended.
local function adopt(bufnr)
  if not api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "yaml" then
    return
  end
  remove_plugin_handlers(bufnr)
  if entries[bufnr] then
    return
  end
  entries[bufnr] = { state = "pending", resumable = false, handlers = {} }
  map_search(bufnr)
  apply(bufnr)
end

local function release(bufnr)
  local entry = entries[bufnr]
  if not entry then
    return
  end
  entries[bufnr] = nil
  remove_handlers(entry)
  pcall(vim.keymap.del, "n", M.SEARCH_LHS, { buffer = bufnr })
  if api.nvim_buf_is_valid(bufnr) then
    clear_display(bufnr)
  end
end

local function on_filetype(args)
  if args.match ~= "yaml" then
    release(args.buf)
    return
  end
  adopt(args.buf)
  -- The ftplugin may be sourced after this handler (lazy.nvim replays
  -- FileType when it loads the plugin): strip its handlers once more.
  vim.schedule(function()
    adopt(args.buf)
  end)
end

---@class IaraYamlLegacyStatus
---@field state "active"|"pending"|"suspended"|"unmanaged"
---@field message string? Suspension reason, with a resume hint once the
---  buffer is eligible again.

---State of yaml-revealer in `bufnr`.
---@param bufnr integer? 0 or nil for the current buffer.
---@return IaraYamlLegacyStatus
function M.status(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local entry = entries[bufnr]
  if not entry then
    return { state = "unmanaged" }
  end
  local message = entry.message
  if entry.resumable then
    message = message .. "; " .. RESUME_HINT
  end
  return { state = entry.state, message = message }
end

---Explicitly resume a suspended buffer once it is eligible again.
---Error codes: "unmanaged" (not a YAML buffer), "ineligible".
---@param bufnr integer? 0 or nil for the current buffer.
---@return boolean ok
---@return IaraError|nil err
function M.resume(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local entry = entries[bufnr]
  if not entry then
    return false, { code = "unmanaged", message = "not a YAML buffer" }
  end
  local result = eligibility.check(bufnr)
  if result.state ~= "eligible" then
    local reason = result.message or "eligibility check pending"
    return false, { code = "ineligible", message = reason }
  end
  activate(bufnr, entry)
  return true
end

local function resume_command()
  local ok, err = M.resume(0)
  if ok then
    notify("yaml-revealer resumed in this buffer")
  else
    local text = "cannot resume yaml-revealer: " .. err.message
    notify(text, vim.log.levels.WARN)
  end
end

local function create_autocmds()
  api.nvim_create_autocmd("FileType", {
    group = group,
    callback = on_filetype,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = function(args)
      apply(args.data.bufnr)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      entries[args.buf] = nil
    end,
  })
end

---Apply the plugin settings and take over loaded YAML buffers. Called
---from the plugin spec before the plugin's ftplugin first runs.
---@param _ table? Composed configuration (unused).
function M.setup(_)
  if group then
    return
  end
  for name, value in pairs(M.GLOBALS) do
    vim.g[name] = value
  end
  group = api.nvim_create_augroup("IaraYamlLegacy", { clear = true })
  create_autocmds()
  api.nvim_create_user_command("IaraYamlResume", resume_command, {
    desc = "Resume yaml-revealer in a buffer that is eligible again",
  })
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    adopt(bufnr)
  end
end

return M
