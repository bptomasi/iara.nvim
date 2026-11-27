local helpers = require("helpers")

local expect = MiniTest.expect
local eq = expect.equality
local match = helpers.expect_match

local child = nil

---Module source whose setup records its name and the composed config.
local RECORDING_MODULE = [[
return {
  setup = function(config)
    _G.calls = _G.calls or {}
    table.insert(_G.calls, { name = %q, search = config.features.search })
  end,
}
]]

---Create a runtime directory with recording modules (and `extra` files).
local function fake_runtime(modules, extra)
  local dir = helpers.temp_dir()
  for _, name in ipairs(modules) do
    local path = dir .. "/lua/" .. name:gsub("%.", "/") .. ".lua"
    helpers.write_file(path, RECORDING_MODULE:format(name))
  end
  for relative, content in pairs(extra or {}) do
    helpers.write_file(dir .. "/" .. relative, content)
  end
  return dir
end

local function personal_file(body)
  local path = helpers.temp_dir() .. "/user.lua"
  helpers.write_file(path, body)
  return path
end

---Run setup in the child and return its status, calls, and errors shown.
---`absent_module`, when given, is added as an extra step whose module
---never exists, so tests do not depend on which real steps are built.
local function setup_in_child(runtime, personal_path, absent_module)
  return child.lua(
    [[
    local runtime, personal_path, absent_module = ...
    vim.opt.runtimepath:prepend(runtime)
    if absent_module then
      local steps = require("iara").STEPS
      table.insert(steps, #steps, { module = absent_module, safe = true })
    end
    local shown = {}
    vim.notify = function(message) table.insert(shown, message) end
    local status = require("iara").setup({
      personal_path = personal_path,
      project_dir = runtime,
    })
    return { status = status, calls = _G.calls or {}, shown = shown }
  ]],
    { runtime, personal_path, absent_module }
  )
end

local function step_states(status)
  local states = {}
  for _, step in ipairs(status.steps) do
    states[step.name] = step.state
  end
  return states
end

local function call_names(calls)
  return vim.tbl_map(function(call)
    return call.name
  end, calls)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local startup = MiniTest.new_set()
T["startup"] = startup

startup["starts the skeleton headless without errors"] = function()
  local result = helpers.run({
    vim.v.progpath,
    "--headless",
    "-u",
    helpers.iara_dir .. "/init.lua",
    "+lua io.stdout:write(vim.g.iara_mode)",
    "+qa",
  }, { env = helpers.isolated_env(), cwd = helpers.temp_dir() })
  eq(result.code, 0)
  eq(result.stderr, "")
  eq(result.stdout, "full")
end

startup["runs installed steps in order with the composed config"] = function()
  local runtime =
    fake_runtime({ "iara.core.root", "iara.core.options", "iara.core.lazy" })
  local personal = personal_file("return { features = { search = { x = 1 } } }")
  local absent = "iara.tests.never_installed"
  local result = setup_in_child(runtime, personal, absent)
  eq(result.status.mode, "full")
  eq(
    call_names(result.calls),
    { "iara.core.options", "iara.core.root", "iara.core.lazy" }
  )
  eq(result.calls[1].search, { x = 1 })
  eq(step_states(result.status)[absent], "missing")
end

startup["records a failing step and continues with the next"] = function()
  local runtime = fake_runtime({ "iara.core.root" }, {
    ["lua/iara/core/options.lua"] = "error('options exploded')",
  })
  local result = setup_in_child(runtime, nil)
  local states = step_states(result.status)
  eq(states["iara.core.options"], "failed")
  eq(states["iara.core.root"], "loaded")
  match(result.status.steps[1].error, "options exploded")
  match(result.shown[1], "iara.core.options failed")
end

startup["skips steps of disabled capabilities"] = function()
  local runtime = fake_runtime({ "iara.features.terminal" })
  local personal = personal_file("return { features = { terminal = false } }")
  local result = setup_in_child(runtime, personal)
  eq(step_states(result.status)["iara.features.terminal"], "disabled")
  eq(result.calls, {})
end

startup["runs personal hooks after options and after all steps"] = function()
  local runtime = fake_runtime({ "iara.core.options", "iara.core.keymaps" })
  local personal = personal_file([[
    local function record(name)
      return function()
        table.insert(_G.calls, { name = name })
      end
    end
    return { hooks = { early = record("early"), late = record("late") } }
  ]])
  local result = setup_in_child(runtime, personal)
  eq(
    call_names(result.calls),
    { "iara.core.options", "early", "iara.core.keymaps", "late" }
  )
end

startup["runs steps once when setup is called again"] = function()
  local runtime = fake_runtime({ "iara.core.options" })
  setup_in_child(runtime, nil)
  local calls = child.lua([[
    require("iara").setup()
    return #_G.calls
  ]])
  eq(calls, 1)
end

local safe = MiniTest.new_set()
T["safe mode"] = safe

safe["IARA_SAFE skips personal configuration and plugin steps"] = function()
  local runtime = fake_runtime({ "iara.core.options", "iara.core.lazy" })
  local personal = personal_file("return { features = { search = false } }")
  child.lua("vim.env.IARA_SAFE = '1'")
  local result = setup_in_child(runtime, personal)
  eq(result.status.mode, "safe")
  eq(result.status.reason, "requested")
  eq(call_names(result.calls), { "iara.core.options" })
  eq(result.calls[1].search, {})
  eq(step_states(result.status)["iara.core.lazy"], "skipped")
end

safe["malformed personal configuration falls back to safe mode"] = function()
  local runtime = fake_runtime({ "iara.core.options", "iara.core.lazy" })
  local personal = personal_file("error('typo in personal config')")
  local result = setup_in_child(runtime, personal)
  eq(result.status.mode, "safe")
  eq(result.status.reason, "config_error")
  eq(call_names(result.calls), { "iara.core.options" })
  match(result.shown[1], "typo in personal config")
  match(result.shown[1], "stack traceback")
  match(result.shown[2], "safe native editing")
  eq(child.lua_get("vim.g.iara_mode"), "safe")
end

safe["malformed shapes keep a status in safe mode"] = function()
  local runtime = fake_runtime({ "iara.core.options", "iara.core.lazy" })
  local shapes = {
    "{ trusted_projects = 42 }",
    "{ trusted_projects = '/tmp' }",
    "{ keymaps = 42 }",
    "{ extras = 'none' }",
    "{ ui = true }",
    "42",
  }
  for _, shape in ipairs(shapes) do
    child.restart({ "-u", helpers.minimal_init })
    local result = setup_in_child(runtime, personal_file("return " .. shape))
    local status = child.lua_get("require('iara').status()")
    eq({ shape, status.mode, status.reason }, { shape, "safe", "config_error" })
    eq(call_names(result.calls), { "iara.core.options" })
    match(result.shown[1], "structure error")
  end
end

safe["a defect while loading the config yields safe mode"] = function()
  local runtime = fake_runtime({ "iara.core.options", "iara.core.lazy" })
  child.lua([[
    local config = require("iara.config")
    local load = config.load
    config.load = function(opts)
      if not opts.safe then
        error("loader defect")
      end
      return load(opts)
    end
  ]])
  local result = setup_in_child(runtime, nil)
  eq(result.status.mode, "safe")
  eq(result.status.reason, "config_error")
  eq(result.status.errors[1].kind, "load")
  match(result.status.errors[1].message, "loader defect")
  eq(call_names(result.calls), { "iara.core.options" })
  match(result.shown[1], "loader defect")
end

return T
