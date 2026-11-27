local helpers = require("helpers")
local fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local PRINT_REPORT = "lua io.stdout:write(table.concat("
  .. "vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n'))"

---Text of `:checkhealth iara` in `env`.
local function health_report(env, opts)
  local result = fixture.start(env, { "checkhealth iara", PRINT_REPORT }, opts)
  eq(result.code, 0)
  return result.stdout
end

local T = MiniTest.new_set()

T["reports a missing manager with the repair command"] = function()
  local report = health_report(helpers.isolated_env(), {
    init = helpers.iara_dir .. "/init.lua",
  })
  match(report, "ERROR lazy.nvim is not installed")
  match(report, "nvim %-l .-/scripts/bootstrap%.lua %-%-repair")
end

T["reports a missing locked plugin and a healthy manager"] = function()
  local repo = fixture.plugin_repo()
  local lock = { ["fixture-plugin"] = { branch = "main", commit = repo.first } }
  local spec = ("return { { url = %q, name = 'fixture-plugin' } }"):format(
    "file://" .. repo.path
  )
  local env = fixture.provisioned(spec, lock)
  local healthy = health_report(env)
  match(healthy, "OK lazy.nvim at the release commit")
  match(healthy, "OK all %d+ locked plugins are installed")
  vim.fn.delete(fixture.std_paths(env).current .. "/lazy/fixture-plugin", "rf")
  local broken = health_report(env)
  match(broken, "ERROR missing plugins: fixture%-plugin")
  match(broken, "Run :IaraRepair, or: .-%-%-repair")
end

T["reports installed, missing, and stale parsers"] = function()
  local env = fixture.provisioned()
  local runtime = fixture.std_paths(env).current .. "/treesitter"
  local pins = assert(require("iara.core.parsers").read_lock())
  local healthy = health_report(env)
  for _, pin in ipairs(pins) do
    local text = "OK %s parser at the pinned commit %s"
    match(healthy, text:format(pin.lang, pin.commit))
  end
  vim.fn.delete(runtime .. "/parser/yaml.so")
  helpers.write_file(runtime .. "/stamps/json", ("1"):rep(40) .. "\n")
  local broken = health_report(env)
  match(broken, "ERROR yaml parser is missing %(pinned tree%-sitter%-grammars")
  match(broken, "bootstrap%.lua %-%-repair")
  match(broken, "WARNING json parser was built from 1+, the release pins")
end

T["reports releases and an interrupted provisioning run"] = function()
  local env = fixture.provisioned()
  local healthy = health_report(env)
  match(healthy, "OK current release %d+T%d+Z%-%w+")
  match(healthy, "no previous release: rollback is unavailable")
  local ended = vim.system({ "true" })
  local pid = ended.pid
  ended:wait()
  local record = {
    pid = pid,
    host = vim.uv.os_gethostname(),
    mode = "update",
    started = "2026-11-19T00:00:00Z",
    token = "interrupted",
  }
  local owner = fixture.std_paths(env).data .. "/iara-owner.json"
  helpers.write_file(owner, vim.json.encode(record))
  local broken = health_report(env)
  match(broken, "ERROR an interrupted provisioning run %(pid " .. pid)
  match(broken, "bootstrap%.lua %-%-repair")
end

T["reports missing tools with what they are needed for"] = function()
  local env = helpers.isolated_env({ PATH = helpers.temp_dir() })
  local report = health_report(env, { init = helpers.iara_dir .. "/init.lua" })
  match(report, "ERROR rg not found; needed for project content search")
  match(report, "Install rg and make it available on PATH")
  match(report, "stylua not found; needed for the optional Lua formatting")
  eq(report:find("WARNING stylua", 1, true), nil)
end

T["reports safe mode and its reason"] = function()
  local env = helpers.isolated_env({ IARA_SAFE = "1" })
  local report = health_report(env, { init = helpers.iara_dir .. "/init.lua" })
  match(report, "WARNING safe mode %(requested%)")
end

return T
