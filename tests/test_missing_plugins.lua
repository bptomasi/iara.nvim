-- Pinned plugins missing from an installation (task X3): their specs and
-- the specs that need them are disabled, their triggers raise nothing,
-- one notice names them once, and `:IaraRepair` restores them.
local helpers = require("helpers")
local fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

-- Removed from the provisioned release. LuaSnip, cmp_luasnip, and
-- nvim-cmp need friendly-snippets, so they are disabled with it, and
-- cmp-nvim-lsp needs nvim-cmp. lazy.nvim drops cmp-buffer and cmp-path
-- with nvim-cmp. Oil still uses nvim-web-devicons.
local REMOVED = {
  "friendly-snippets",
  "nvim-tree.lua",
  "render-markdown.nvim",
  "snacks.nvim",
  "which-key.nvim",
  "yaml-revealer",
}
local DISABLED = vim.list_extend({
  "LuaSnip",
  "cmp-buffer",
  "cmp-nvim-lsp",
  "cmp-path",
  "cmp_luasnip",
  "nvim-cmp",
}, vim.deepcopy(REMOVED))
table.sort(DISABLED)

local NOTICE = "Iara: 6 pinned plugins are missing (friendly-snippets, "
  .. "nvim-tree.lua, render-markdown.nvim, snacks.nvim, which-key.nvim, "
  .. "yaml-revealer); run :IaraRepair"

local WRITE_MESSAGES = "lua io.stdout:write(vim.fn.execute('messages'))"

local env, project = nil, nil

---Start Iara in the broken installation, run `commands`, and return
---the result with what the commands wrote.
local function start(commands)
  return fixture.start(env, commands, { cwd = project })
end

---Ex command writing `expression` as JSON.
local function write_json(expression)
  return "lua io.stdout:write(vim.json.encode(" .. expression .. "))"
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      env = fixture.provisioned()
      local root = fixture.std_paths(env).current .. "/lazy/"
      for _, name in ipairs(REMOVED) do
        eq(vim.fn.delete(root .. name, "rf"), 0)
      end
      project = helpers.temp_dir()
      helpers.write_file(project .. "/notes.md", "# Notes\n\n**bold**\n")
      helpers.write_file(project .. "/data.yaml", "a:\n  b: 1\n")
      helpers.write_file(project .. "/main.lua", "local x = 1\n")
    end,
  },
})

T["missing plugins and the plugins needing them are disabled"] = function()
  -- Pinned plugins that lazy.nvim does not enable.
  local disabled = "(function() local lazy = require('iara.core.lazy')"
    .. " local lock = lazy.read_lock(lazy.paths().release_lock)"
    .. " local enabled = require('lazy.core.config').plugins"
    .. " local names = vim.tbl_filter(function(name)"
    .. " return not enabled[name] end, vim.tbl_keys(lock))"
    .. " table.sort(names) return names end)()"
  local result = start({
    write_json(disabled),
    "lua io.stdout:write(' ')",
    write_json("require('iara.core.lazy').missing()"),
  })
  eq(result.stderr, "")
  local names, missing = unpack(vim.split(result.stdout, " ", {}))
  eq(vim.json.decode(names), DISABLED)
  eq(vim.json.decode(missing), REMOVED)
end

T["their triggers raise nothing and features fall back"] = function()
  local state = "{ gitsigns = package.loaded.gitsigns ~= nil,"
    .. " rendered = package.loaded['render-markdown'] ~= nil,"
    .. " tree_key = vim.fn.maparg('<C-n>', 'n'),"
    .. " filetype = vim.bo.filetype }"
  local result = start({
    "edit data.yaml",
    "edit main.lua",
    "doautocmd InsertEnter",
    "edit notes.md",
    write_json(state),
    "IaraFiles",
    WRITE_MESSAGES,
  })
  local json, messages = result.stdout:match("^(%b{})(.*)$")
  messages = messages .. result.stderr
  eq(vim.json.decode(json), {
    gitsigns = true,
    rendered = false,
    tree_key = "",
    filetype = "markdown",
  })
  eq(messages:find("Plugin .- is not installed"), nil)
  eq(messages:find("traceback", 1, true), nil)
  -- Search explains what it needs instead of failing.
  match(messages, "search needs snacks%.nvim, which is not installed")
  eq(messages:find("Error executing", 1, true), nil)
end

T["one notice names them once per session"] = function()
  local result = start({
    WRITE_MESSAGES,
    "lua io.stdout:write('|')",
    "doautocmd UIEnter",
    "edit notes.md",
    "edit data.yaml",
    "doautocmd UIEnter",
    WRITE_MESSAGES,
  })
  -- Shown once the screen exists, never before.
  local before, after = result.stdout:match("^(.*)|(.*)$")
  eq(before:find("pinned", 1, true), nil)
  local first = after:find(NOTICE, 1, true)
  MiniTest.expect.no_equality(first, nil)
  eq(after:find(NOTICE, first + 1, true), nil)
  -- Headless Neovim also writes notifications to stderr.
  eq(result.stderr, NOTICE)
end

T[":IaraRepair runs the current release's own repair"] = function()
  local command = "(function() local argv, extra ="
    .. " require('iara.core.repair').command()"
    .. " return { argv = argv, env = extra } end)()"
  local result = start({ write_json(command) })
  -- Through the data directory: it works without the configuration link.
  local current = fixture.std_paths(env).current
  eq(vim.json.decode(result.stdout), {
    argv = {
      vim.v.progpath,
      "-l",
      current .. "/config/scripts/bootstrap.lua",
      "--repair",
    },
    env = { NVIM_APPNAME = env.NVIM_APPNAME },
  })
end

T[":IaraRepair reports a failed repair as an error"] = function()
  local result = start({
    write_json("{ require('iara.core.repair').result_message(1) }"),
  })
  eq(vim.json.decode(result.stdout), {
    "Iara: repair failed (exit 1); its output is in the repair window",
    vim.log.levels.ERROR,
  })
end

T["health lists them with :IaraRepair"] = function()
  local result = start({
    "checkhealth iara",
    "lua io.stdout:write(table.concat("
      .. "vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n'))",
  })
  match(result.stdout, "ERROR missing plugins: friendly%-snippets, nvim%-tree")
  match(result.stdout, "Run :IaraRepair, or: .-bootstrap%.lua %-%-repair")
end

-- Last: it repairs the shared installation.
T[":IaraRepair restores them and the notice goes away"] = function()
  local repair_env = vim.tbl_extend("force", env, {
    IARA_GIT_URL_FORMAT = fixture.url_format(),
    GIT_CONFIG_COUNT = "1",
    GIT_CONFIG_KEY_0 = "protocol.file.allow",
    GIT_CONFIG_VALUE_0 = "always",
  })
  local wait = "lua vim.fn.jobwait({ require('iara.core.repair').run() },"
    .. " 15000)"
  local result = fixture.start(repair_env, {
    wait,
    "sleep 100m",
    WRITE_MESSAGES,
  }, { cwd = project })
  match(result.stdout, "Iara: repair complete; restart Iara")
  local root = fixture.std_paths(env).current .. "/lazy/"
  for _, name in ipairs(REMOVED) do
    eq(vim.uv.fs_stat(root .. name) ~= nil, true)
  end
  local after = start({
    "doautocmd UIEnter",
    "edit notes.md",
    "lua io.stdout:write(tostring(package.loaded['render-markdown'] ~= nil))",
    WRITE_MESSAGES,
  })
  eq(after.stderr, "")
  match(after.stdout, "^true")
  eq(after.stdout:find("pinned", 1, true), nil)
end

return T
