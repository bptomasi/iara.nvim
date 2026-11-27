--- Ordered composition of the distribution.
---
--- `setup()` checks compatibility, captures the startup directory, composes
--- the configuration (iara.config), then runs the steps below in order.
--- Each step module exports `setup(config)`; a hook step calls a personal
--- hook. Steps whose module is not installed yet are recorded as "missing",
--- so the skeleton starts while later tasks fill in modules.
--- See contracts.md, section `iara`.
local config = require("iara.config")

local M = {}

M.MINIMUM_NVIM = "0.12"

---@class IaraStep
---@field module string|nil Module exporting setup(config).
---@field hook "early"|"late"|nil Personal hook run at this point instead.
---@field safe boolean Also runs in safe mode (must not need plugins).
---@field capability string|nil Skipped when this capability is disabled.

---@type IaraStep[]
M.STEPS = {
  -- Leaders and native options come before anything that maps keys.
  { module = "iara.core.options", safe = true },
  -- Colors right after options, also in safe mode (no plugins needed).
  { module = "iara.theme", safe = true },
  -- vim.ui.select in Iara's float (V10); no plugin, so also safe.
  { module = "iara.core.select", safe = true },
  -- Opt-in ui2 messages (V11 spike); early, so startup messages use it.
  { module = "iara.core.messages", safe = false },
  { hook = "early", safe = false },
  { module = "iara.core.root", safe = true },
  { module = "iara.core.eligibility", safe = true },
  { module = "iara.core.reconcile", safe = true },
  { module = "iara.core.term_retention", safe = false },
  { module = "iara.core.lazy", safe = false },
  { module = "iara.core.keymaps", safe = false },
  {
    module = "iara.features.format_lua",
    safe = false,
    capability = "formatters.lua",
  },
  {
    module = "iara.features.search.keymaps",
    safe = false,
    capability = "features.search",
  },
  {
    module = "iara.features.terminal",
    safe = false,
    capability = "features.terminal",
  },
  {
    module = "iara.features.structured",
    safe = false,
    capability = "features.structured",
  },
  {
    module = "iara.extras.agents",
    safe = false,
    capability = "extras.agents",
  },
  { module = "iara.extras.ai", safe = false, capability = "extras.ai" },
  -- Last: the start screen offers the commands defined above.
  { module = "iara.core.start", safe = false },
  { hook = "late", safe = false },
}

---@class IaraStepResult
---@field name string Module name, or "hooks.early"/"hooks.late".
---@field state "loaded"|"missing"|"failed"|"skipped"|"disabled"
---@field error string|nil Message with traceback when state is "failed".

---@class IaraStatus
---@field mode "full"|"safe"
---@field reason "requested"|"config_error"|"incompatible"|nil
---@field startup_dir string Absolute working directory at setup time.
---@field errors IaraConfigError[]
---@field steps IaraStepResult[]

---@type IaraStatus|nil
local status = nil

local function report(message)
  vim.notify("Iara: " .. message, vim.log.levels.ERROR)
end

-- vim.loader's index of 'runtimepath' answers without searching every
-- entry twice per step, as nvim_get_runtime_file did (FU-V12-PERF).
local function module_installed(module)
  return #vim.loader.find(module) > 0
end

local function call_module(module, composed)
  local loaded = require(module)
  if type(loaded) ~= "table" or type(loaded.setup) ~= "function" then
    error(module .. " does not export setup(config)", 0)
  end
  loaded.setup(composed)
end

---Return the function to call for `step`, or the state explaining why
---nothing runs.
local function step_action(step, mode, composed)
  if mode == "safe" and not step.safe then
    return nil, "skipped"
  end
  if step.capability and not config.enabled(step.capability) then
    return nil, "disabled"
  end
  if step.hook then
    local hook = composed.hooks[step.hook]
    return hook, hook == nil and "missing" or nil
  end
  if not module_installed(step.module) then
    return nil, "missing"
  end
  return function(composed_config)
    call_module(step.module, composed_config)
  end
end

---@param step IaraStep
---@param mode "full"|"safe"
---@return IaraStepResult
local function run_step(step, mode, composed)
  local name = step.module or ("hooks." .. step.hook)
  local action, state = step_action(step, mode, composed)
  local result = { name = name, state = state or "loaded" }
  if not action then
    return result
  end
  local ok, problem = xpcall(action, debug.traceback, composed)
  if not ok then
    result.state, result.error = "failed", problem
    report(name .. " failed:\n" .. problem)
  end
  return result
end

local function report_config_errors(errors)
  for _, error in ipairs(errors) do
    local where = error.path and (" at " .. error.path) or ""
    local text = "%s configuration %s error%s: %s"
    report(text:format(error.source, error.kind, where, error.message))
  end
end

---Decide the mode before reading any configuration.
local function requested_safety(opts)
  if vim.fn.has("nvim-" .. M.MINIMUM_NVIM) == 0 then
    report("Neovim " .. M.MINIMUM_NVIM .. " or newer is required")
    return "incompatible"
  end
  if opts.safe or vim.env.IARA_SAFE == "1" then
    return "requested"
  end
end

---config.load(), or safe defaults with a load error when it raises: a
---defect in composition must not cost the safe mode and its status.
---@return IaraLoadResult
local function protected_load(load_opts)
  local ok, result = xpcall(config.load, debug.traceback, load_opts)
  if ok then
    return result
  end
  local loaded = config.load({ safe = true })
  loaded.errors = {
    { kind = "load", source = "personal", message = tostring(result) },
  }
  return loaded
end

local function load_config(opts)
  local reason = requested_safety(opts)
  local load_opts = vim.tbl_extend("force", opts, { safe = reason ~= nil })
  local loaded = protected_load(load_opts)
  report_config_errors(loaded.errors)
  if loaded.mode == "safe" and not reason then
    reason = "config_error"
    report("falling back to safe native editing; fix the error and restart")
  end
  return loaded, reason
end

---Compose configuration and run every step once. Later calls return the
---first status without running steps again.
---@param opts IaraLoadOptions|nil `safe` defaults to $IARA_SAFE == "1".
---@return IaraStatus
function M.setup(opts)
  if status then
    return status
  end
  local startup_dir = vim.fn.getcwd()
  local loaded, reason = load_config(opts or {})
  status = {
    mode = loaded.mode,
    reason = reason,
    startup_dir = startup_dir,
    errors = loaded.errors,
    steps = {},
  }
  vim.g.iara_mode = status.mode
  for _, step in ipairs(M.STEPS) do
    table.insert(status.steps, run_step(step, status.mode, loaded.config))
  end
  return status
end

---@return IaraStatus|nil status Nil before setup() ran.
function M.status()
  return status
end

---Working directory captured when setup() started (the root fallback).
---@return string
function M.startup_dir()
  return status and status.startup_dir or vim.fn.getcwd()
end

return M
