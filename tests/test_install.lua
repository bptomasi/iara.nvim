-- scripts/install.lua and the Makefile, run against temporary HOME and
-- XDG roots only. A stub replaces bootstrap.lua (its own tests cover it).
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local SCRIPT = helpers.iara_dir .. "/scripts/install.lua"
local STAMP = "20260101T000000Z"

-- Stands in for bootstrap.lua: refuses an existing configuration like
-- the real one, records its arguments, and links a minimal release.
local STUB = [[
assert(vim.env.NVIM_APPNAME == "iara", "NVIM_APPNAME must be iara")
local config, data = vim.fn.stdpath("config"), vim.fn.stdpath("data")
if vim.uv.fs_lstat(config) or vim.env.STUB_FAIL then
  io.stderr:write("stub bootstrap refused\n")
  os.exit(1)
end
local release = data .. "/releases/r1/config"
vim.fn.mkdir(release, "p")
vim.fn.writefile({ "vim.g.iara_stub = true" }, release .. "/init.lua")
vim.fn.writefile({ table.concat(_G.arg, " ") }, data .. "/stub-args")
vim.fn.mkdir(vim.fs.dirname(config), "p")
assert(vim.uv.fs_symlink(release, config))
assert(vim.uv.fs_symlink(release .. "/bin/iara", _G.arg[2]))
]]

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Every path below `dir` with its type, mode, content or link target.
local function snapshot(dir, into, prefix)
  into = into or {}
  prefix = prefix or ""
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    local key = prefix .. name
    local stat = assert(vim.uv.fs_lstat(path))
    into[key] = { kind = kind, mode = stat.mode }
    if kind == "link" then
      into[key].target = vim.uv.fs_readlink(path)
    elseif kind == "file" then
      into[key].content = read(path)
    elseif kind == "directory" then
      snapshot(path, into, key .. "/")
    end
  end
  return into
end

---A temporary home; `xdg` sets explicit XDG roots outside it.
local function new_home(xdg)
  local root = helpers.temp_dir()
  local home = root .. "/home"
  vim.fn.mkdir(home, "p")
  local stub = root .. "/bootstrap-stub.lua"
  helpers.write_file(stub, STUB)
  local env = {
    HOME = home,
    PATH = vim.env.PATH,
    -- Without it, `nvim -l` creates nvim.log in the `nvim` state dir.
    NVIM_LOG_FILE = "/dev/null",
    TMPDIR = vim.env.TMPDIR,
    IARA_INSTALL_BOOTSTRAP = stub,
  }
  local dirs = {
    config = home .. "/.config",
    data = home .. "/.local/share",
    state = home .. "/.local/state",
    cache = home .. "/.cache",
  }
  for kind in pairs(dirs) do
    local name = "XDG_" .. kind:upper() .. "_HOME"
    if xdg then
      env[name] = root .. "/xdg-" .. kind
      dirs[kind] = env[name]
    end
  end
  return { root = root, home = home, env = env, dirs = dirs }
end

---Run `argv` with exactly the variables of `env`: the XDG variables and
---NVIM_APPNAME of the test run are not inherited.
local function exec(argv, env)
  local options = { env = env, clear_env = true, text = true }
  local result = vim.system(argv, options):wait(20000)
  if result.signal ~= 0 then
    error("command timed out or was killed: " .. argv[1], 2)
  end
  return result
end

local function run(h, ...)
  return exec({ vim.v.progpath, "--clean", "-l", SCRIPT, ... }, h.env)
end

---Files of a typical NvChad setup in the four `nvim` directories.
local function add_nvchad(h)
  local config = h.dirs.config .. "/nvim"
  helpers.write_file(config .. "/init.lua", "require('chad')\n")
  helpers.write_file(config .. "/lua/chadrc.lua", "return {}\n")
  vim.uv.fs_chmod(config .. "/lua/chadrc.lua", 384)
  assert(vim.uv.fs_symlink("chadrc.lua", config .. "/lua/alias.lua"))
  assert(vim.uv.fs_symlink("/nonexistent/x", config .. "/dangling"))
  helpers.write_file(h.dirs.data .. "/nvim/lazy/NvChad/README.md", "chad\n")
  helpers.write_file(h.dirs.state .. "/nvim/shada/main.shada", "\0\1")
  helpers.write_file(h.dirs.cache .. "/nvim/luac/x", "bytecode")
end

---Snapshot of the four `nvim` directories (links are kept as links).
local function nvim_trees(h)
  local trees = {}
  for kind, dir in pairs(h.dirs) do
    local path = dir .. "/nvim"
    local stat = vim.uv.fs_lstat(path)
    trees[kind] = stat and stat.type == "directory" and snapshot(path)
      or vim.uv.fs_readlink(path)
  end
  return trees
end

local function backup_dir(h, action, stamp)
  local name = (stamp or STAMP) .. "-" .. action
  return h.dirs.data .. "/iara-backups/" .. name
end

---MANIFEST entries as { type, original, backup, target? } lists.
local function manifest_entries(dir)
  local entries = {}
  for line in read(dir .. "/MANIFEST"):gmatch("[^\n]+") do
    local fields = vim.split(line, "\t")
    if fields[1] == "entry" then
      table.insert(entries, vim.list_slice(fields, 2))
    end
  end
  return entries
end

local function install_default(h, stamp)
  return run(h, "default", "--timestamp", stamp or STAMP)
end

local T = MiniTest.new_set()

T["install"] = MiniTest.new_set()

T["install"]["backs up an existing Iara, then bootstraps"] = function()
  local h = new_home()
  local old = h.dirs.config .. "/iara/lua/user.lua"
  helpers.write_file(old, "return { theme = 'old' }\n")
  local result = run(h, "install", "--timestamp", STAMP)
  eq(result.code, 0)
  local backup = backup_dir(h, "install")
  eq(read(backup .. "/config-iara/lua/user.lua"), "return { theme = 'old' }\n")
  eq(manifest_entries(backup), {
    { "dir", h.dirs.config .. "/iara", backup .. "/config-iara" },
  })
  match(read(backup .. "/MANIFEST"), "\naction\tinstall\n")
  local launcher = h.home .. "/.local/bin/iara"
  local args = read(h.dirs.data .. "/iara/stub-args")
  eq(args, "--launcher " .. launcher .. "\n")
  eq(exists(launcher), true)
end

T["install"]["creates no backup when Iara is absent"] = function()
  local h = new_home()
  eq(run(h, "install").code, 0)
  eq(exists(h.dirs.data .. "/iara-backups"), false)
end

T["install"]["names the backup when the bootstrap fails"] = function()
  local h = new_home()
  helpers.write_file(h.dirs.cache .. "/iara/luac", "old")
  h.env.STUB_FAIL = "1"
  local result = run(h, "install", "--timestamp", STAMP)
  eq(result.code, 1)
  match(result.stderr, "bootstrap failed")
  match(
    result.stderr,
    "make restore BACKUP=" .. vim.pesc(backup_dir(h, "install"))
  )
  eq(read(backup_dir(h, "install") .. "/cache-iara/luac"), "old")
end

T["default"] = MiniTest.new_set()

T["default"]["backs up NvChad and makes nvim open Iara"] = function()
  local h = new_home()
  add_nvchad(h)
  local before = nvim_trees(h)
  local result = install_default(h)
  eq(result.code, 0)
  match(result.stdout, "Iara is not installed; installing it first")
  local backup = backup_dir(h, "install-default")
  local expected = {}
  for _, kind in ipairs({ "config", "data", "state", "cache" }) do
    local original = h.dirs[kind] .. "/nvim"
    local saved = backup .. "/" .. kind .. "-nvim"
    table.insert(expected, { "dir", original, saved })
    eq(vim.uv.fs_readlink(original), h.dirs[kind] .. "/iara")
    eq(snapshot(saved), before[kind])
  end
  eq(manifest_entries(backup), expected)
  -- Plain `nvim` (no NVIM_APPNAME) now loads the Iara configuration.
  local probe = "lua io.stdout:write(tostring(vim.g.iara_stub))"
  local argv = { vim.v.progpath, "--headless", "+" .. probe, "+qa!" }
  eq(exec(argv, h.env).stdout, "true")
end

T["default"]["changes nothing when nvim opens Iara already"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(install_default(h).code, 0)
  local result = install_default(h, "20260102T000000Z")
  eq(result.code, 0)
  match(result.stdout, "nvim opens Iara already")
  eq(exists(backup_dir(h, "install-default", "20260102T000000Z")), false)
end

T["default"]["backs up a path recreated since, in a new backup"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(install_default(h).code, 0)
  vim.uv.fs_unlink(h.dirs.cache .. "/nvim")
  helpers.write_file(h.dirs.cache .. "/nvim/new", "new")
  eq(install_default(h, "20260102T000000Z").code, 0)
  local backup = backup_dir(h, "install-default", "20260102T000000Z")
  eq(manifest_entries(backup), {
    { "dir", h.dirs.cache .. "/nvim", backup .. "/cache-nvim" },
  })
  eq(vim.uv.fs_readlink(h.dirs.cache .. "/nvim"), h.dirs.cache .. "/iara")
end

T["default"]["refuses an existing backup path and changes nothing"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(run(h, "install").code, 0)
  vim.fn.mkdir(backup_dir(h, "install-default"), "p")
  local before = snapshot(h.root)
  local result = install_default(h)
  eq(result.code, 1)
  match(result.stderr, "exists already; nothing was changed")
  eq(snapshot(h.root), before)
end

T["default"]["honors XDG base directory overrides"] = function()
  local h = new_home(true)
  add_nvchad(h)
  eq(install_default(h).code, 0)
  eq(vim.uv.fs_readlink(h.dirs.data .. "/nvim"), h.dirs.data .. "/iara")
  eq(exists(backup_dir(h, "install-default") .. "/data-nvim"), true)
  eq(vim.fn.isdirectory(h.home .. "/.config"), 0)
end

T["restore"] = MiniTest.new_set()

T["restore"]["returns NvChad byte for byte, links included"] = function()
  local h = new_home()
  add_nvchad(h)
  local before = nvim_trees(h)
  eq(install_default(h).code, 0)
  local result = run(h, "restore", "--timestamp", "20260102T000000Z")
  eq(result.code, 0)
  eq(nvim_trees(h), before)
  -- The Iara links that occupied the paths were backed up, not removed.
  local displaced = backup_dir(h, "restore", "20260102T000000Z")
  eq(vim.uv.fs_readlink(displaced .. "/config-nvim"), h.dirs.config .. "/iara")
  eq(exists(backup_dir(h, "install-default") .. "/RESTORED"), true)
  eq(exists(h.dirs.config .. "/iara"), true)
end

T["restore"]["refuses a backup restored already"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(install_default(h).code, 0)
  eq(run(h, "restore", "--timestamp", "20260102T000000Z").code, 0)
  local name = STAMP .. "-install-default"
  local result = run(h, "restore", "--backup", name)
  eq(result.code, 1)
  match(result.stderr, "was restored already")
end

T["restore"]["refuses a backup that does not match its MANIFEST"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(install_default(h).code, 0)
  local saved = backup_dir(h, "install-default") .. "/cache-nvim"
  vim.fn.delete(saved, "rf")
  helpers.write_file(saved, "not a directory")
  local before = snapshot(h.root)
  local result = run(h, "restore", "--timestamp", "20260102T000000Z")
  eq(result.code, 1)
  match(result.stderr, "does not match its MANIFEST; nothing was changed")
  match(result.stderr, "cache%-nvim is file, the MANIFEST records dir")
  eq(snapshot(h.root), before)
end

T["restore"]["moves paths back into absent locations directly"] = function()
  local h = new_home()
  add_nvchad(h)
  local before = nvim_trees(h)
  eq(install_default(h).code, 0)
  for kind in pairs(h.dirs) do
    vim.uv.fs_unlink(h.dirs[kind] .. "/nvim")
  end
  local result = run(h, "restore", "--timestamp", "20260102T000000Z")
  eq(result.code, 0)
  eq(nvim_trees(h), before)
  eq(exists(backup_dir(h, "restore", "20260102T000000Z")), false)
end

T["uninstall"] = MiniTest.new_set()

T["uninstall"]["backs up Iara and the nvim links to it"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(install_default(h).code, 0)
  local result = run(h, "uninstall", "--timestamp", "20260102T000000Z")
  eq(result.code, 0)
  local backup = backup_dir(h, "uninstall", "20260102T000000Z")
  local names = {}
  for _, entry in ipairs(manifest_entries(backup)) do
    table.insert(names, vim.fs.basename(entry[3]))
    eq(exists(entry[2]), false)
  end
  table.sort(names)
  eq(names, {
    "cache-iara",
    "cache-nvim",
    "config-iara",
    "config-nvim",
    "data-iara",
    "data-nvim",
    "launcher-iara",
    "state-iara",
    "state-nvim",
  })
  local previous = vim.pesc(backup_dir(h, "install-default"))
  match(result.stdout, "make restore BACKUP=" .. previous)
end

T["uninstall"]["reports when nothing is installed"] = function()
  local h = new_home()
  local result = run(h, "uninstall")
  eq(result.code, 0)
  match(result.stdout, "nothing to uninstall")
end

T["dry run"] = MiniTest.new_set()

T["dry run"]["changes nothing for any action"] = function()
  local h = new_home()
  add_nvchad(h)
  helpers.write_file(h.dirs.state .. "/iara/theme", "chocolate")
  local before = snapshot(h.root)
  for _, action in ipairs({ "install", "default", "uninstall" }) do
    local result = run(h, action, "--dry-run")
    eq(result.code, 0)
    match(result.stdout, "would ")
    eq(snapshot(h.root), before)
  end
  eq(install_default(h).code, 0)
  local installed = snapshot(h.root)
  local result = run(h, "restore", "--dry-run")
  eq(result.code, 0)
  match(result.stdout, "would restore install%-default backup")
  eq(snapshot(h.root), installed)
end

T["backups"] = MiniTest.new_set()

T["backups"]["lists each backup with its action and state"] = function()
  local h = new_home()
  add_nvchad(h)
  eq(install_default(h).code, 0)
  eq(run(h, "restore", "--timestamp", "20260102T000000Z").code, 0)
  local stdout = run(h, "backups").stdout
  match(
    stdout,
    STAMP .. "%-install%-default  install%-default, 4 path%(s%), restored"
  )
  match(stdout, "%-restore  restore, 4 path%(s%), not restored")
end

T["Makefile"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if vim.fn.executable("make") == 0 then
        MiniTest.skip("make is not installed")
      end
    end,
  },
})

local function make(h, ...)
  local argv = { "make", "--no-print-directory", "-C", helpers.iara_dir, ... }
  -- The Makefile must keep Neovim's log out of the `nvim` state dir.
  local env = vim.deepcopy(h.env)
  env.NVIM_LOG_FILE = nil
  return exec(argv, env)
end

T["Makefile"]["help lists every target"] = function()
  local h = new_home()
  local result = make(h)
  eq(result.code, 0)
  local makefile = read(helpers.iara_dir .. "/Makefile")
  local phony = makefile:match("%.PHONY:(.-)\n\n"):gsub("\\\n", " ")
  for target in phony:gmatch("[%w-]+") do
    match("\n" .. result.stdout, "\n  " .. vim.pesc(target) .. " +%S")
  end
end

T["Makefile"]["targets call the existing scripts"] = function()
  local h = new_home()
  local expected = {
    check = "scripts/check%.sh",
    test = "scripts/test%.sh tests/test_x%.lua",
    bench = "tests/bench_fuzzy%.lua",
    ["install-default"] = "install%.lua default +%-%-launcher",
    restore = "install%.lua restore +%-%-backup b1",
    update = "scripts/bootstrap%.lua %-%-update",
    repair = "bootstrap%.lua.* %-%-repair",
  }
  for target, pattern in pairs(expected) do
    local result = make(h, "-n", target, "TEST=tests/test_x.lua", "BACKUP=b1")
    eq(result.code, 0)
    match(result.stdout, pattern)
  end
end

T["Makefile"]["DRY_RUN=1 install-default changes nothing"] = function()
  local h = new_home()
  add_nvchad(h)
  local before = snapshot(h.root)
  local result = make(h, "install-default", "DRY_RUN=1")
  eq(result.code, 0)
  match(result.stdout, "would link " .. vim.pesc(h.dirs.config) .. "/nvim")
  eq(snapshot(h.root), before)
end

T["Makefile"]["repair and rollback use the stored bootstrap"] = function()
  local h = new_home()
  local legacy = h.dirs.config .. "/iara/scripts/bootstrap.lua"
  local result = make(h, "repair", "DRY_RUN=1")
  eq(result.code, 0)
  match(
    result.stdout,
    "nvim %-%-clean %-l " .. vim.pesc(legacy) .. " %-%-repair"
  )
  -- With a current release, its own copy: no configuration link needed.
  local stored = h.dirs.data .. "/iara/current/config/scripts/bootstrap.lua"
  helpers.write_file(stored, "")
  for _, step in ipairs({ "repair", "rollback" }) do
    result = make(h, step, "DRY_RUN=1")
    eq(result.code, 0)
    match(
      result.stdout,
      "nvim %-%-clean %-l " .. vim.pesc(stored) .. " %-%-" .. step
    )
  end
  eq(exists(h.dirs.config .. "/iara"), false)
end

T["Makefile"]["keeps lines within 80 characters"] = function()
  local makefile = read(helpers.iara_dir .. "/Makefile")
  for line in makefile:gmatch("[^\n]+") do
    eq(#line <= 80, true)
  end
end

return T
