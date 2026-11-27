-- What startup loads (FU-V12-PERF): the byte-compiled module cache is on
-- before Iara's first module, and features used on demand stay unloaded
-- until used. Runs the real init.lua without plugins installed.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

-- Searcher in front of every other one: records, at the first lookup of
-- an Iara module, whether vim.loader was already enabled. It never finds
-- anything, so lookup continues as usual.
local PROBE = [[lua table.insert(package.loaders, 1, function(name)
  if _G.loader_at_first_iara == nil and name:find('^iara') then
    _G.loader_at_first_iara = vim.loader.enabled
  end
end)]]

---Start Iara headless on `file` (or nothing), run `expression` after
---startup, and return what it wrote.
local function after_startup(expression, file)
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.lua", "local x = 1\n")
  local argv = {
    vim.v.progpath,
    "--headless",
    "-u",
    helpers.iara_dir .. "/init.lua",
    "--cmd",
    PROBE,
  }
  if file then
    table.insert(argv, file)
  end
  vim.list_extend(argv, {
    "+lua io.stdout:write(vim.inspect(" .. expression .. "))",
    "+qa!",
  })
  local result = helpers.run(argv, { env = helpers.isolated_env(), cwd = dir })
  return result.stdout
end

-- Modules that only a command, mapping, or picker needs.
local ON_DEMAND = {
  "iara.features.search",
  "iara.features.search.session",
  "iara.features.search.ui",
  "iara.features.picker.layout",
  "iara.features.picker.modal",
  "iara.features.picker.open",
  "iara.features.picker.preview",
  "iara.features.picker.pool",
  "iara.features.picker.highlight",
  "iara.theme.picker",
  "iara.extras.ai.popup",
  "iara.health",
}

local LOADED_ON_DEMAND = ([[vim.tbl_filter(function(name)
  return package.loaded[name] ~= nil
end, %s)]]):format(vim.inspect(ON_DEMAND, { newline = " ", indent = "" }))

local T = MiniTest.new_set()

T["the module cache is enabled before the first Iara module loads"] = function()
  eq(after_startup("_G.loader_at_first_iara"), "true")
end

for _, case in ipairs({ { "empty", nil }, { "file", "main.lua" } }) do
  local name = "startup on " .. case[1] .. " leaves on-demand modules unloaded"
  T[name] = function()
    eq(after_startup(LOADED_ON_DEMAND, case[2]), "{}")
  end
end

T["startup still runs the steps that load at startup"] = function()
  local loaded = "package.loaded['iara.features.structured.ui'] ~= nil"
    .. " and package.loaded['iara.core.statusline'] ~= nil"
  eq(after_startup(loaded, "main.lua"), "true")
end

return T
