local helpers = require("helpers")
local fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Write `expression` (Lua) to stdout after startup.
local function print_lua(expression)
  return "lua io.stdout:write(tostring(" .. expression .. "))"
end

local PLUGINS_LOADED = "package.loaded['lazy'] ~= nil"
  .. " and vim.g.lazy_did_setup == true"

-- One provisioned installation (of a copied checkout) shared by the
-- cases that do not modify it.
local env, checkout = nil, nil

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      env, checkout = fixture.provisioned()
    end,
  },
})

T["ordinary startup loads the pinned manager"] = function()
  local result = fixture.start(env, {
    print_lua(PLUGINS_LOADED .. " and vim.g.iara_mode"),
  })
  eq(result.stderr, "")
  eq(result.stdout, "full")
end

T["safe mode starts without any plugin on the runtimepath"] = function()
  local safe_env = vim.tbl_extend("force", env, { IARA_SAFE = "1" })
  local plugin_paths = "#vim.tbl_filter(function(p)"
    .. " return p:find('/lazy/', 1, true) end, vim.opt.rtp:get())"
  local result = fixture.start(safe_env, {
    print_lua(PLUGINS_LOADED),
    "lua io.stdout:write(' ' .. " .. plugin_paths .. ")",
    "lua io.stdout:write(' ' .. vim.g.iara_mode)",
  })
  eq(result.stdout, "false 0 safe")
end

T["startup never installs a missing plugin"] = function()
  local repo = fixture.plugin_repo()
  local personal = helpers.temp_dir() .. "/user.lua"
  local spec = "{ url = %q, name = 'personal', lazy = false }"
  local source = "return { plugins = { " .. spec .. " } }"
  helpers.write_file(personal, source:format("file://" .. repo.path))
  local personal_env =
    vim.tbl_extend("force", env, { IARA_PERSONAL = personal })
  local result = fixture.start(personal_env, { print_lua(PLUGINS_LOADED) })
  eq(result.stdout, "true")
  eq(exists(fixture.std_paths(env).current .. "/lazy/personal"), false)
end

T["a project .lazy.lua is never executed"] = function()
  local project = helpers.temp_dir()
  local marker = project .. "/executed"
  helpers.write_file(
    project .. "/.lazy.lua",
    ("io.open(%q, 'w'):close() return {}"):format(marker)
  )
  local result = fixture.start(env, { print_lua(PLUGINS_LOADED) }, {
    cwd = project,
  })
  eq(result.stdout, "true")
  eq(exists(marker), false)
end

T["the manager writes its lock outside the release lock"] = function()
  local release = read(checkout .. "/lazy-lock.json")
  local result = fixture.start(env, {
    "lua require('lazy.manage.lock').update()",
  })
  eq(result.code, 0)
  eq(read(checkout .. "/lazy-lock.json"), release)
  -- The installed release keeps its own copy of the release lock.
  eq(read(fixture.std_paths(env).config .. "/lazy-lock.json"), release)
  local written = read(fixture.std_paths(env).current .. "/lazy-lock.json")
  eq(
    vim.json.decode(written)["lazy.nvim"],
    vim.json.decode(release)["lazy.nvim"]
  )
end

T["without the manager startup keeps native editing"] = function()
  local result = fixture.start(helpers.isolated_env(), {
    print_lua(PLUGINS_LOADED .. " or vim.g.iara_mode"),
  }, { init = helpers.iara_dir .. "/init.lua" })
  eq(result.stderr, "")
  eq(result.stdout, "full")
end

return T
