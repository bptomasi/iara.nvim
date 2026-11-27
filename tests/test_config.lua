local helpers = require("helpers")
local config = require("iara.config")

local expect = MiniTest.expect
local eq = expect.equality
local match = helpers.expect_match

---Write a personal file returning `body` and load it with `project_dir`.
local function load_personal(body, project_dir)
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/user.lua", body)
  return config.load({
    personal_path = dir .. "/user.lua",
    project_dir = project_dir or dir,
  })
end

---Create a project directory whose policy file returns `body`.
local function make_project(body)
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/" .. config.PROJECT_FILE, body)
  return dir
end

local function trusting(dir, rest)
  return ("return { trusted_projects = { %q }, %s }"):format(dir, rest or "")
end

local T = MiniTest.new_set()

local defaults = MiniTest.new_set()
T["defaults"] = defaults

defaults["apply when no personal configuration exists"] = function()
  local result = config.load({ personal_path = "/nonexistent/user.lua" })
  eq(result.mode, "full")
  eq(result.errors, {})
  eq(result.config, config.defaults())
end

defaults["enable agents"] = function()
  config.load({ personal_path = "/nonexistent/user.lua" })
  eq(config.enabled("extras.agents"), true)
  eq(config.enabled("features.search"), true)
end

local personal = MiniTest.new_set()
T["personal layer"] = personal

personal["merges maps and keeps unrelated defaults"] = function()
  local result =
    load_personal("return { features = { search = { hidden = true } } }")
  eq(result.config.features.search, { hidden = true })
  eq(result.config.features.terminal, {})
  eq(result.config.formatters.lua, { "stylua" })
end

personal["replaces lists instead of concatenating"] = function()
  local result = load_personal("return { formatters = { lua = { 'mine' } } }")
  eq(result.config.formatters.lua, { "mine" })
end

personal["removes a capability with false"] = function()
  local result = load_personal("return { features = { terminal = false } }")
  eq(result.config.features.terminal, false)
  eq(config.enabled("features.terminal"), false)
  eq(config.enabled("features.terminal.scrollback"), false)
end

personal["enables an extra with true"] = function()
  load_personal("return { extras = { agents = true } }")
  eq(config.get("extras.agents"), {})
  eq(config.enabled("extras.agents"), true)
end

personal["treats a file that returns nothing as empty"] = function()
  local result = load_personal("local unused = 1")
  eq(result.mode, "full")
  eq(result.config, config.defaults())
end

local project = MiniTest.new_set()
T["project policy"] = project

project["is ignored unless personally trusted"] = function()
  local dir = make_project("return { features = { search = { x = 1 } } }")
  local result = load_personal("return {}", dir)
  eq(result.sources.project, nil)
  eq(result.config.features.search, {})
end

project["applies after personal choices when trusted"] = function()
  local dir = make_project("return { formatters = { lua = { 'proj' } } }")
  local body = trusting(dir, "formatters = { lua = { 'mine' } }")
  local result = load_personal(body, dir)
  eq(result.mode, "full")
  eq(result.config.formatters.lua, { "proj" })
end

project["cannot re-enable a personal disable"] = function()
  local dir = make_project([[
    return { features = { terminal = { scrollback = 5 } },
             extras = { agents = true } }
  ]])
  local body = trusting(dir, "features = { terminal = false }")
  local result = load_personal(body, dir)
  eq(result.config.features.terminal, false)
  eq(result.config.extras.agents, {})
end

project["cannot grant trust and fails into safe mode"] = function()
  local dir = make_project("return { trusted_projects = { '/' } }")
  local result = load_personal(trusting(dir), dir)
  eq(result.mode, "safe")
  eq(result.errors[1].source, "project")
  eq(result.errors[1].path, "trusted_projects")
end

local malformed = MiniTest.new_set()
T["malformed configuration"] = malformed

malformed["falls back to defaults on a syntax error"] = function()
  local result = load_personal("return {")
  eq(result.mode, "safe")
  eq(result.config, config.defaults())
  eq(result.errors[1].kind, "load")
  match(result.errors[1].message, "user%.lua")
end

malformed["reports the traceback of a runtime error"] = function()
  local result = load_personal("error('personal failure')")
  eq(result.mode, "safe")
  match(result.errors[1].message, "personal failure")
  match(result.errors[1].message, "stack traceback")
end

malformed["rejects an unknown top-level key"] = function()
  local result = load_personal("return { featurs = {} }")
  eq(result.mode, "safe")
  eq(result.errors[1].kind, "structure")
  eq(result.errors[1].path, "featurs")
end

malformed["rejects a configuration that is not a table"] = function()
  local result = load_personal("return 'text'")
  eq(result.mode, "safe")
  eq(result.errors[1].kind, "structure")
end

malformed["rejects a hook that is not a function"] = function()
  local result = load_personal("return { hooks = { early = 1 } }")
  eq(result.mode, "safe")
  eq(result.errors[1].path, "hooks.early")
end

malformed["rejects malformed trusted_projects before reading them"] = function()
  local shapes = {
    "42",
    "'/tmp'",
    "{ 1 }",
    "{ dir = '/tmp' }",
    "{ '/tmp', 2 }",
    "function() end",
  }
  for _, shape in ipairs(shapes) do
    local result =
      load_personal("return { trusted_projects = " .. shape .. " }")
    eq({ shape, result.mode, result.errors[1].kind, result.errors[1].path }, {
      shape,
      "safe",
      "structure",
      "trusted_projects",
    })
  end
end

malformed["discards configuration from a failed load"] = function()
  load_personal("return { features = { search = false } }")
  load_personal("return {")
  eq(config.enabled("features.search"), true)
end

local capability = MiniTest.new_set()
T["malformed capability"] = capability

capability["disables only that capability"] = function()
  local result = load_personal([[
    return { languages = { python = "yes" },
             features = { search = { hidden = true } } }
  ]])
  eq(result.mode, "full")
  eq(result.config.languages.python, false)
  eq(result.config.languages.lua, {})
  eq(result.config.features.search, { hidden = true })
  eq(result.errors[1].kind, "capability")
  eq(result.errors[1].path, "languages.python")
end

capability["rejects a second formatting owner"] = function()
  local result = load_personal(
    "return { formatters = { python = { 'ruff_format', 'black' } } }"
  )
  eq(result.config.formatters.python, false)
  eq(result.errors[1].path, "formatters.python")
  match(result.errors[1].message, "ruff_format and black")
end

return T
