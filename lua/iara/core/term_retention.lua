--- Successful-exit retention for Iara-owned terminal buffers.
---
--- Neovim's `nvim.terminal` group ships a TermClose handler that
--- force-deletes a terminal buffer whose job was the unadorned 'shell' and
--- exited with status 0. Iara-owned terminals must keep their transcript,
--- so setup() replaces exactly that handler (identified by a fingerprint
--- of the pinned runtime) with a wrapper that skips owned buffers and
--- calls the original for every other buffer. Any doubt about the handler
--- leaves native defaults untouched and disables Iara terminal creation.
local M = {}

local GROUP = "nvim.terminal"
local EVENT = "TermClose"
local DEFAULTS_PATH = "/lua/vim/_core/defaults.lua"

---Fingerprint of the shipped handler in the pinned runtime (ARCH,
---Terminal and agent lifecycle). A new runtime needs a reviewed update.
local FINGERPRINT = {
  pattern = "*",
  desc = "Automatically close terminal buffers when started with no "
    .. "arguments and exiting without an error",
  source = "@vim/_core/defaults",
  first_line = 581,
  last_line = 590,
  sha256 = "59c5279b602650b42acbb051e6ee5a36dfc6ee1f8f92e625c8d2d4b461f55368",
}

local WRAPPER_DESC = "Iara: " .. FINGERPRINT.desc .. " (Iara-owned kept)"

local NOT_SET_UP = "term_retention.setup() has not run"

---@class IaraRetentionState
---@field ok boolean
---@field reason string|nil
---@field original fun(ev: table): any
---@field wrapper_id integer|nil
---@field wrapper fun(ev: table): any

---@type IaraRetentionState|nil
local state = nil

---@type table<integer, true>
local owned = {}

---@param bufnr integer
---@return integer
local function resolve_buf(bufnr)
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

---@return table[]|nil autocmds TermClose autocmds of the group.
---@return string|nil reason
local function group_autocmds()
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
    group = GROUP,
    event = EVENT,
  })
  if not ok then
    return nil, ("autocmd group %s is missing"):format(GROUP)
  end
  return autocmds
end

---Whether `autocmd` has the shipped handler's options and description.
---@param autocmd table
---@return boolean
local function options_match(autocmd)
  return autocmd.pattern == FINGERPRINT.pattern
    and autocmd.buflocal == false
    and autocmd.once == false
    and autocmd.command == ""
    and autocmd.desc == FINGERPRINT.desc
    and type(autocmd.callback) == "function"
end

---Whether the callback was defined at the fingerprinted source location.
---@param callback function
---@return boolean
local function source_matches(callback)
  local info = debug.getinfo(callback, "S")
  return info.source == FINGERPRINT.source
    and info.linedefined == FINGERPRINT.first_line
    and info.lastlinedefined == FINGERPRINT.last_line
end

---Check the SHA-256 of the runtime's defaults.lua, which also confirms
---the handler is registered with `nested = true`.
---@return string|nil reason Nil when the checksum matches.
local function check_defaults_file()
  local path = (vim.env.VIMRUNTIME or "") .. DEFAULTS_PATH
  local file = io.open(path, "rb")
  if not file then
    return ("cannot read %s"):format(path)
  end
  local content = file:read("*a")
  file:close()
  local actual = vim.fn.sha256(content)
  if actual ~= FINGERPRINT.sha256 then
    return ("%s has SHA-256 %s, expected %s"):format(
      path,
      actual,
      FINGERPRINT.sha256
    )
  end
  return nil
end

---Find exactly one autocmd matching the shipped handler's fingerprint.
---@return table|nil autocmd
---@return string|nil reason
local function find_shipped_handler()
  local autocmds, missing = group_autocmds()
  if not autocmds then
    return nil, missing
  end
  local matches = {}
  for _, autocmd in ipairs(autocmds) do
    if options_match(autocmd) and source_matches(autocmd.callback) then
      table.insert(matches, autocmd)
    end
  end
  if #matches ~= 1 then
    return nil,
      ("expected one shipped %s %s handler, found %d"):format(
        GROUP,
        EVENT,
        #matches
      )
  end
  local file_problem = check_defaults_file()
  if file_problem then
    return nil, file_problem
  end
  return matches[1]
end

---@param original fun(ev: table): any
---@return fun(ev: table): any
local function make_wrapper(original)
  return function(ev)
    if M.is_owned(ev.buf) then
      return
    end
    -- Returning the original's result keeps its once-deletion semantics.
    return original(ev)
  end
end

---@param callback fun(ev: table): any
---@param desc string
---@return integer id
local function create_handler(callback, desc)
  return vim.api.nvim_create_autocmd(EVENT, {
    group = GROUP,
    pattern = FINGERPRINT.pattern,
    once = false,
    nested = true,
    desc = desc,
    callback = callback,
  })
end

---Replace the shipped handler with the wrapper.
---@param handler table The autocmd found by find_shipped_handler().
---@return IaraRetentionState
local function install(handler)
  local original = handler.callback
  local wrapper = make_wrapper(original)
  local created, wrapper_id = pcall(create_handler, wrapper, WRAPPER_DESC)
  if not created then
    return { ok = false, reason = "cannot create wrapper: " .. wrapper_id }
  end
  local deleted, err = pcall(vim.api.nvim_del_autocmd, handler.id)
  if not deleted then
    -- The original is deleted last, so removing the wrapper is a full
    -- rollback to native behavior.
    pcall(vim.api.nvim_del_autocmd, wrapper_id)
    return { ok = false, reason = "cannot delete shipped handler: " .. err }
  end
  return {
    ok = true,
    original = original,
    wrapper_id = wrapper_id,
    wrapper = wrapper,
  }
end

---Check that the installed wrapper is still registered unchanged.
---@param installed IaraRetentionState
---@return string|nil reason Nil when the wrapper is intact.
local function validate_wrapper(installed)
  local autocmds, missing = group_autocmds()
  if not autocmds then
    return missing
  end
  for _, autocmd in ipairs(autocmds) do
    local same_id = autocmd.id == installed.wrapper_id
    if same_id and rawequal(autocmd.callback, installed.wrapper) then
      return nil
    end
  end
  return "the Iara TermClose wrapper is no longer registered"
end

---@param reason string
local function report_disabled(reason)
  vim.notify(
    "Iara terminals disabled (incompatible runtime): " .. reason,
    vim.log.levels.WARN
  )
end

---Install the wrapper around the shipped `nvim.terminal` TermClose
---handler. Mismatch or ambiguity leaves native defaults and makes
---available() false. Repeated calls validate the existing wrapper.
---@param config table|nil Composed configuration (unused).
function M.setup(config)
  local _ = config
  if state and state.ok then
    local problem = validate_wrapper(state)
    if problem then
      -- Without the wrapper the original is gone too; restore it so
      -- unowned terminals keep native behavior.
      pcall(vim.api.nvim_del_autocmd, state.wrapper_id)
      pcall(create_handler, state.original, FINGERPRINT.desc)
      state = { ok = false, reason = problem }
      report_disabled(problem)
    end
    return
  end
  local handler, reason = find_shipped_handler()
  state = handler and install(handler) or { ok = false, reason = reason }
  if not state.ok then
    report_disabled(state.reason)
  end
end

---@return boolean ok
---@return string|nil reason Why Iara terminal creation is disabled.
function M.available()
  if not state then
    return false, NOT_SET_UP
  end
  return state.ok, state.reason
end

---Owned buffers survive a successful exit; unowned behave natively.
---@param bufnr integer Terminal buffer, 0 for the current buffer.
function M.own(bufnr)
  bufnr = resolve_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error(("invalid buffer %d"):format(bufnr), 2)
  end
  -- Buffer numbers are never reused, so stale entries are only garbage.
  for stale in pairs(owned) do
    if not vim.api.nvim_buf_is_valid(stale) then
      owned[stale] = nil
    end
  end
  owned[bufnr] = true
end

---Return `bufnr` to native successful-exit behavior.
---@param bufnr integer Buffer, 0 for the current buffer.
function M.disown(bufnr)
  owned[resolve_buf(bufnr)] = nil
end

---@param bufnr integer Buffer, 0 for the current buffer.
---@return boolean
function M.is_owned(bufnr)
  bufnr = resolve_buf(bufnr)
  return owned[bufnr] == true and vim.api.nvim_buf_is_valid(bufnr)
end

return M
