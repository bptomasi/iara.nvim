--- Configuration composition.
---
--- Layers apply in order: defaults, personal configuration, then the policy
--- of an explicitly trusted project. Maps merge recursively, lists replace,
--- `false` removes an optional capability, and personal `false` values win
--- over the project policy. See contracts.md, section `iara.config`.
local M = {}

---@class IaraConfigError
---@field kind "load"|"structure"|"capability"
---@field source "personal"|"project"
---@field path string|nil Dotted path, for example "languages.python".
---@field message string Includes the traceback for load errors.

---@class IaraLoadResult
---@field config table Composed configuration (defaults in safe mode).
---@field mode "full"|"safe"
---@field errors IaraConfigError[]
---@field sources { personal: string|nil, project: string|nil }

---@class IaraLoadOptions
---@field personal_path string|nil Defaults to $IARA_PERSONAL or
---  stdpath("config")/lua/user.lua.
---@field project_dir string|nil Defaults to the current directory.
---@field safe boolean|nil Skip the personal and project layers.

M.PROJECT_FILE = ".iara.lua"

-- Groups whose entries are optional capabilities: each entry can be
-- removed with `false`, and a malformed entry only disables itself.
local CAPABILITY_GROUPS = {
  features = "map",
  languages = "map",
  extras = "map",
  formatters = "list",
}

local function default_values()
  return {
    options = {},
    keymaps = {},
    plugins = {},
    features = { search = {}, terminal = {}, structured = {} },
    languages = { lua = {} },
    formatters = { lua = { "stylua" } },
    extras = { agents = true, ai = true },
    -- Startup theme; see iara.theme for its precedence over the last
    -- theme chosen with :IaraTheme. `start_screen = false` starts on an
    -- empty buffer instead of the start screen. `messages = "ui2"` tries
    -- Neovim's experimental message UI (iara.core.messages, V11).
    ui = {
      theme = "chocolate",
      start_screen = true,
      wave_animation = true,
      messages = "native",
      terminal_background = true,
    },
    trusted_projects = {},
    hooks = {},
  }
end

---@return table defaults A fresh copy of the default configuration.
function M.defaults()
  return default_values()
end

local function is_list(value)
  return type(value) == "table" and next(value) ~= nil and vim.islist(value)
end

---Merge `override` into `base`; returns a new value.
local function merge(base, override)
  if type(base) ~= "table" or type(override) ~= "table" then
    return vim.deepcopy(override)
  end
  if is_list(base) or is_list(override) then
    return vim.deepcopy(override)
  end
  local result = vim.deepcopy(base)
  for key, value in pairs(override) do
    result[key] = merge(result[key], value)
  end
  return result
end

local function is_string_list(value)
  if type(value) ~= "table" or not vim.islist(value) then
    return false
  end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

local function capability_problem(shape, value)
  if value == false then
    return nil
  end
  if shape == "list" then
    if not is_string_list(value) then
      return "must be a list of strings or false"
    end
    -- One owner per capability: a second owner is a pre-activation error.
    if #value > 1 then
      return ("conflicting owners %s and %s"):format(value[1], value[2])
    end
    return nil
  end
  if value == true or (type(value) == "table" and not is_list(value)) then
    return nil
  end
  return "must be a table, true, or false"
end

---Disable malformed capability entries in place; returns their errors.
local function check_capabilities(layer, source)
  local errors = {}
  for group, shape in pairs(CAPABILITY_GROUPS) do
    for name, value in pairs(layer[group] or {}) do
      local problem = capability_problem(shape, value)
      if problem then
        layer[group][name] = false
        table.insert(errors, {
          kind = "capability",
          source = source,
          path = group .. "." .. tostring(name),
          message = problem,
        })
      elseif value == true then
        layer[group][name] = {}
      end
    end
  end
  return errors
end

-- Keys a project policy may not set: they grant trust or run code
-- outside the owners' setup.
local PERSONAL_ONLY = {
  trusted_projects = "only personal configuration can grant trust",
  hooks = "only personal configuration can define hooks",
}

local HOOK_NAMES = { early = true, late = true }

local function hooks_problem(hooks)
  for name, hook in pairs(hooks) do
    if not HOOK_NAMES[name] then
      return "hooks." .. tostring(name), "unknown hook"
    end
    if type(hook) ~= "function" then
      return "hooks." .. name, "must be a function"
    end
  end
end

local function special_key_problem(layer, source)
  for key, message in pairs(PERSONAL_ONLY) do
    if source == "project" and layer[key] ~= nil then
      return key, message
    end
  end
  if layer.trusted_projects and not is_string_list(layer.trusted_projects) then
    return "trusted_projects", "must be a list of directory paths"
  end
  return hooks_problem(layer.hooks or {})
end

local function structure_problem(layer, source)
  if type(layer) ~= "table" then
    return nil, "configuration must return a table"
  end
  local defaults = default_values()
  for key, value in pairs(layer) do
    if defaults[key] == nil then
      return tostring(key), "unknown top-level key"
    end
    if type(value) ~= "table" then
      return key, "must be a table"
    end
  end
  return special_key_problem(layer, source)
end

---Structure error of one layer, or nil when its global structure is
---valid.
---@return IaraConfigError|nil
local function structure_error(layer, source)
  local path, problem = structure_problem(layer, source)
  if problem then
    return {
      kind = "structure",
      source = source,
      path = path,
      message = problem,
    }
  end
end

---Validate one layer. Returns a sanitized copy and its errors, or nil
---when the layer's global structure is invalid.
---@return table|nil layer
---@return IaraConfigError[] errors
local function validate_layer(layer, source)
  local error = structure_error(layer, source)
  if error then
    return nil, { error }
  end
  local copy = vim.deepcopy(layer)
  return copy, check_capabilities(copy, source)
end

---Force every `false` leaf of the personal layer into `config`.
local function apply_disables(config, personal)
  for key, value in pairs(personal) do
    if value == false then
      config[key] = false
    elseif type(value) == "table" and type(config[key]) == "table" then
      apply_disables(config[key], value)
    end
  end
end

local function append_all(target, items)
  for _, item in ipairs(items) do
    table.insert(target, item)
  end
end

---Compose the configuration from optional personal and project layers.
---@param personal table|nil
---@param project table|nil
---@return table|nil config Nil when a layer has an invalid global structure.
---@return IaraConfigError[] errors
function M.compose(personal, project)
  local errors = {}
  local layers = { { "personal", personal }, { "project", project } }
  local config = default_values()
  local sanitized = {}
  for _, entry in ipairs(layers) do
    local source, layer = entry[1], entry[2]
    if layer ~= nil then
      local valid, layer_errors = validate_layer(layer, source)
      append_all(errors, layer_errors)
      if not valid then
        return nil, errors
      end
      sanitized[source] = valid
      config = merge(config, valid)
    end
  end
  apply_disables(config, sanitized.personal or {})
  return config, errors
end

---Run a Lua configuration file. Missing files yield nil without error;
---a file that returns nothing counts as an empty layer.
---@return any layer
---@return IaraConfigError|nil error
local function read_layer(path, source)
  if vim.fn.filereadable(path) == 0 then
    return nil, nil
  end
  local chunk, load_error = loadfile(path)
  local ok, value = false, load_error
  if chunk then
    ok, value = xpcall(chunk, debug.traceback)
  end
  if ok then
    return value == nil and {} or value, nil
  end
  local message = path .. ": " .. tostring(value)
  return nil, { kind = "load", source = source, message = message }
end

local function default_personal_path()
  if vim.env.IARA_PERSONAL and vim.env.IARA_PERSONAL ~= "" then
    return vim.env.IARA_PERSONAL
  end
  return vim.fn.stdpath("config") .. "/lua/user.lua"
end

local function canonical(path)
  return vim.uv.fs_realpath(vim.fn.fnamemodify(path, ":p")) or nil
end

---Return the project policy path when `dir` is explicitly trusted.
local function trusted_project_file(dir, trusted)
  local real_dir = canonical(dir)
  if not real_dir then
    return nil
  end
  for _, candidate in ipairs(trusted or {}) do
    if canonical(candidate) == real_dir then
      return real_dir .. "/" .. M.PROJECT_FILE
    end
  end
end

local current = default_values()
-- Layers read by the last load, for `is_explicit`.
local explicit_layers = {}

local function safe_result(errors, sources)
  current = default_values()
  explicit_layers = {}
  return { config = current, mode = "safe", errors = errors, sources = sources }
end

---Read the personal file, then the trusted project policy, and compose.
---Any load error or invalid global structure yields safe mode.
---@param opts IaraLoadOptions|nil
---@return IaraLoadResult
function M.load(opts)
  opts = opts or {}
  local sources = {}
  if opts.safe then
    return safe_result({}, sources)
  end
  sources.personal = opts.personal_path or default_personal_path()
  local personal, error = read_layer(sources.personal, "personal")
  if error then
    return safe_result({ error }, sources)
  end
  -- trusted_projects is read before composition: validate it first.
  error = personal ~= nil and structure_error(personal, "personal") or nil
  if error then
    return safe_result({ error }, sources)
  end
  local trusted = personal and personal.trusted_projects
  local project_dir = opts.project_dir or vim.fn.getcwd()
  sources.project = trusted_project_file(project_dir, trusted)
  local project
  if sources.project then
    project, error = read_layer(sources.project, "project")
    if error then
      return safe_result({ error }, sources)
    end
  end
  local config, errors = M.compose(personal, project)
  if not config then
    return safe_result(errors, sources)
  end
  current = config
  explicit_layers = { personal, project }
  return { config = config, mode = "full", errors = errors, sources = sources }
end

---Value at a dotted path inside `root`; nil when a step is missing.
local function lookup(root, path)
  local value = root
  for key in vim.gsplit(path or "", ".", { plain = true, trimempty = true }) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return value
end

---Return the current composed configuration or a value inside it.
---The returned table is shared; callers must treat it as read-only.
---@param path string|nil Dotted path such as "features.search".
---@return any
function M.get(path)
  return lookup(current, path)
end

---Whether the personal configuration or the trusted project policy of
---the last load sets a value at `path` (defaults do not count).
---@param path string Dotted path such as "ui.theme".
---@return boolean
function M.is_explicit(path)
  for _, layer in pairs(explicit_layers) do
    if lookup(layer, path) ~= nil then
      return true
    end
  end
  return false
end

---Whether the capability at `path` is enabled: present and neither it nor
---any ancestor is `false`.
---@param path string Dotted path such as "extras.agents".
---@return boolean
function M.enabled(path)
  local value = current
  for key in vim.gsplit(path, ".", { plain = true, trimempty = true }) do
    if type(value) ~= "table" or value[key] == nil or value[key] == false then
      return false
    end
    value = value[key]
  end
  return true
end

return M
