-- Bootstrap install, repair, parsers, and launcher (F2). Each case runs
-- the bootstrap script, which clones every pinned plugin (X4: slow).
-- iara-test: slow
local helpers = require("helpers")
local fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function head(dir)
  return fixture.git({ "rev-parse", "HEAD" }, dir)
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Every regular file below `dir`, mapped to its content.
local function snapshot(dir)
  local files = {}
  for name, kind in vim.fs.dir(dir, { depth = 10 }) do
    if kind == "file" then
      files[name] = read(dir .. "/" .. name)
    end
  end
  return files
end

---Spec of a plugin served from a local repository.
local function plugin_spec(repo)
  return ("return { { url = %q, name = 'fixture-plugin' } }"):format(
    "file://" .. repo.path
  )
end

local T = MiniTest.new_set()

local install = MiniTest.new_set()
T["install"] = install

install["publishes the pinned manager and links the configuration"] = function()
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env)
  eq(result.code, 0)
  local paths = fixture.std_paths(env)
  -- The configuration is the current release's copy of the checkout.
  eq(vim.uv.fs_readlink(paths.config), paths.current .. "/config")
  eq(read(paths.config .. "/init.lua"), read(helpers.iara_dir .. "/init.lua"))
  eq(exists(paths.config .. "/.tools"), false)
  local manager = paths.current .. "/lazy/lazy.nvim"
  local commit = fixture.release_entry("lazy.nvim").commit
  eq(head(manager), commit)
  eq(
    vim.json.decode(read(paths.current .. "/lazy-lock.json"))["lazy.nvim"],
    fixture.release_entry("lazy.nvim")
  )
  local manifest = vim.json.decode(read(paths.current .. "/release.json"))
  eq({ manifest.complete, manifest.plugins["lazy.nvim"] }, { true, commit })
  -- Every distributed configuration file has a checksum (R2-A).
  local files = manifest.config.files
  eq(files["init.lua"], vim.fn.sha256(read(helpers.iara_dir .. "/init.lua")))
  eq(files["lua/iara/config.lua"] ~= nil, true)
  eq(files["scripts/bootstrap/verify.lua"] ~= nil, true)
  -- Temporary directories and the owner record are gone.
  eq(vim.fn.glob(paths.data .. "/iara-tmp-*", false, true), {})
  eq(exists(paths.data .. "/iara-owner.json"), false)
end

install["an archive ignores an enclosing checkout's metadata"] = function()
  local env = helpers.isolated_env()
  local dir = fixture.checkout()
  local parent = vim.fs.dirname(dir)
  fixture.git({ "init", "--quiet" }, parent)
  fixture.git({ "commit", "--quiet", "--allow-empty", "-m", "Parent" }, parent)
  local local_paths = { ".agents", ".aws", ".claude", ".codex" }
  for _, name in ipairs(local_paths) do
    helpers.write_file(dir .. "/" .. name .. "/local.txt", "fixture\n")
  end
  helpers.write_file(dir .. "/nvim.log", "fixture\n")

  local result = fixture.bootstrap(env, {}, dir)
  eq(result.code, 0)
  local paths = fixture.std_paths(env)
  local manifest = vim.json.decode(read(paths.current .. "/release.json"))
  eq(manifest.config.revision, vim.NIL)
  eq(manifest.config.dirty, false)
  for _, name in ipairs(local_paths) do
    eq(exists(paths.config .. "/" .. name), false)
  end
  eq(exists(paths.config .. "/nvim.log"), false)
end

install["refuses a second install and leaves the first intact"] = function()
  local env = helpers.isolated_env()
  eq(fixture.bootstrap(env).code, 0)
  local paths = fixture.std_paths(env)
  local before = snapshot(paths.data)
  local result = fixture.bootstrap(env)
  eq(result.code, 1)
  match(result.stderr, "refusing to install over existing paths")
  match(result.stderr, vim.pesc(paths.config))
  eq(snapshot(paths.data), before)
  eq(vim.uv.fs_readlink(paths.config), paths.current .. "/config")
end

install["refuses a dangling symlink at the configuration path"] = function()
  local env = helpers.isolated_env()
  local paths = fixture.std_paths(env)
  vim.fn.mkdir(env.XDG_CONFIG_HOME, "p")
  assert(vim.uv.fs_symlink(env.XDG_CONFIG_HOME .. "/missing", paths.config))
  local result = fixture.bootstrap(env)
  eq(result.code, 1)
  match(result.stderr, "refusing to install")
  eq(exists(paths.current), false)
  eq(vim.uv.fs_readlink(paths.config), env.XDG_CONFIG_HOME .. "/missing")
end

install["leaves an existing Neovim configuration byte-identical"] = function()
  local env = helpers.isolated_env()
  local nvchad = env.XDG_CONFIG_HOME .. "/nvim"
  helpers.write_file(nvchad .. "/init.lua", "require('nvchad')\n")
  helpers.write_file(nvchad .. "/lua/chadrc.lua", "return { ui = {} }\n")
  helpers.write_file(nvchad .. "/lazy-lock.json", "{}\n")
  local data = env.XDG_DATA_HOME .. "/nvim"
  helpers.write_file(data .. "/lazy/NvChad/init.lua", "return {}\n")
  local before = { config = snapshot(nvchad), data = snapshot(data) }
  eq(fixture.bootstrap(env).code, 0)
  eq({ config = snapshot(nvchad), data = snapshot(data) }, before)
end

install["refuses an application name other than iara"] = function()
  local env = helpers.isolated_env({ NVIM_APPNAME = "nvim" })
  local result = fixture.bootstrap(env)
  eq(result.code, 1)
  match(result.stderr, "NVIM_APPNAME must be 'iara'")
  eq(exists(env.XDG_CONFIG_HOME), false)
  eq(exists(env.XDG_DATA_HOME), false)
end

install["installs plugins at the locked commit, not at the head"] = function()
  local repo = fixture.plugin_repo()
  local lock = { ["fixture-plugin"] = { branch = "main", commit = repo.first } }
  local checkout = fixture.checkout(plugin_spec(repo), lock)
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  eq(result.code, 0)
  local paths = fixture.std_paths(env)
  eq(head(paths.current .. "/lazy/fixture-plugin"), repo.first)
  -- The release lock is never rewritten.
  eq(vim.json.decode(read(checkout .. "/lazy-lock.json"))["fixture-plugin"], {
    branch = "main",
    commit = repo.first,
  })
end

install["rejects an unpinned plugin and removes its partial files"] = function()
  local repo = fixture.plugin_repo()
  local checkout = fixture.checkout(plugin_spec(repo))
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  eq(result.code, 1)
  match(result.stderr, "without a release lock entry: fixture%-plugin")
  match(result.stderr, "Retry with:")
  local paths = fixture.std_paths(env)
  eq(exists(paths.current), false)
  eq(exists(paths.data .. "/releases"), false)
  eq(exists(paths.config), false)
end

install["reports a failed clone and removes its partial install"] = function()
  local env = helpers.isolated_env({
    IARA_GIT_URL_FORMAT = "file:///nonexistent/%s.git",
  })
  local result = fixture.bootstrap(env)
  eq(result.code, 1)
  match(result.stderr, "command failed %(exit %d+%): git clone")
  local paths = fixture.std_paths(env)
  eq(exists(paths.current), false)
  eq(vim.fn.glob(paths.data .. "/iara-tmp-*", false, true), {})
  eq(exists(paths.config), false)
end

install["rejects a lock with an abbreviated commit before writing"] = function()
  local checkout = fixture.checkout(nil, {
    ["lazy.nvim"] = { branch = "main", commit = "85c7ff3" },
  })
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  eq(result.code, 1)
  match(result.stderr, "not a full 40%-character hash")
  eq(exists(env.XDG_DATA_HOME), false)
end

---Replace the parser lock of a copied checkout.
local function write_parser_lock(checkout, entries)
  local lines = {}
  for _, entry in ipairs(entries) do
    vim.list_extend(lines, {
      "parser " .. entry.lang,
      "repo " .. entry.repo,
      "commit " .. entry.commit,
    })
  end
  helpers.write_file(
    checkout .. "/parsers-lock.txt",
    table.concat(lines, "\n") .. "\n"
  )
end

local function yaml_pin()
  local pins = assert(require("iara.core.parsers").read_lock())
  for _, pin in ipairs(pins) do
    if pin.lang == "yaml" then
      return pin
    end
  end
end

---A plugin repository whose submodule can no longer be cloned.
local function repo_with_broken_submodule()
  local repo = fixture.plugin_repo()
  local sub = fixture.plugin_repo()
  local add = { "-c", "protocol.file.allow=always", "submodule", "add" }
  vim.list_extend(add, { "--quiet", "file://" .. sub.path, "deps/sub" })
  fixture.git(add, repo.path)
  fixture.git({ "commit", "--quiet", "-m", "add submodule" }, repo.path)
  vim.fn.delete(sub.path, "rf")
  return repo, head(repo.path)
end

install["fails when a plugin clone did not finish"] = function()
  local repo, commit = repo_with_broken_submodule()
  local lock = { ["fixture-plugin"] = { branch = "main", commit = commit } }
  local checkout = fixture.checkout(plugin_spec(repo), lock)
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  eq(result.code, 1)
  match(result.stderr, "fixture%-plugin: .*clone did not finish")
  local paths = fixture.std_paths(env)
  eq(exists(paths.current), false)
  eq(exists(paths.config), false)
end

local parser_set = MiniTest.new_set()
T["parsers"] = parser_set

parser_set["installs pinned parsers that Iara loads"] = function()
  local env, checkout = fixture.provisioned()
  local runtime = fixture.std_paths(env).current .. "/treesitter"
  local pins = assert(require("iara.core.parsers").read_lock())
  for _, pin in ipairs(pins) do
    eq(read(runtime .. "/stamps/" .. pin.lang), pin.commit .. "\n")
  end
  -- Opening a YAML buffer puts the parser directory on 'runtimepath';
  -- block scalars need the grammar's external scanner.
  local file = helpers.temp_dir() .. "/a.yaml"
  helpers.write_file(file, "a: |\n  text\n")
  local probe = "lua io.stdout:write(vim.treesitter.get_parser(0, 'yaml')"
    .. ":parse()[1]:root():sexpr())"
  local result = fixture.start(env, { "edit " .. file, probe })
  eq(result.code, 0)
  match(result.stdout, "block_scalar")
  eq(exists(checkout .. "/.tools"), false)
end

parser_set["refuses a grammar that does not load"] = function()
  local pin = vim.tbl_extend("force", yaml_pin(), { lang = "yamlx" })
  local checkout = fixture.checkout()
  write_parser_lock(checkout, { pin })
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  eq(result.code, 1)
  match(result.stderr, "yamlx parser does not load")
  local paths = fixture.std_paths(env)
  eq(exists(paths.current), false)
  eq(exists(paths.config), false)
  eq(vim.fn.glob(paths.data .. "/iara-tmp-*", false, true), {})
end

parser_set["reports an unavailable grammar commit"] = function()
  local pin = vim.tbl_extend("force", yaml_pin(), { commit = ("0"):rep(40) })
  local checkout = fixture.checkout()
  write_parser_lock(checkout, { pin })
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  eq(result.code, 1)
  match(result.stderr, "parsers%.sh")
  eq(exists(fixture.std_paths(env).current), false)
end

parser_set["repair rebuilds a missing parser only"] = function()
  local env = fixture.provisioned()
  local paths = fixture.std_paths(env)
  local runtime = paths.current .. "/treesitter"
  local json = runtime .. "/parser/json.so"
  local before = vim.uv.fs_stat(json)
  vim.fn.delete(runtime .. "/parser/yaml.so")
  local result = fixture.bootstrap(env, { "--repair" }, paths.config)
  eq(result.code, 0)
  eq(read(runtime .. "/stamps/yaml"), yaml_pin().commit .. "\n")
  eq(exists(runtime .. "/parser/yaml.so"), true)
  eq(vim.uv.fs_stat(json).ino, before.ino)
end

parser_set["repair keeps a parser built from another commit"] = function()
  local env = fixture.provisioned()
  local paths = fixture.std_paths(env)
  local runtime = paths.current .. "/treesitter"
  local stale = ("1"):rep(40) .. "\n"
  helpers.write_file(runtime .. "/stamps/yaml", stale)
  local result = fixture.bootstrap(env, { "--repair" }, paths.config)
  eq(result.code, 1)
  match(result.stderr, "yaml%.so was built from 1+, the release pins")
  eq(read(runtime .. "/stamps/yaml"), stale)
end

local launcher = MiniTest.new_set()
T["launcher"] = launcher

launcher["links the launcher at an explicit unused path"] = function()
  local env = helpers.isolated_env()
  local destination = helpers.temp_dir() .. "/iara"
  local result = fixture.bootstrap(env, { "--launcher", destination })
  eq(result.code, 0)
  local current = fixture.std_paths(env).current
  eq(vim.uv.fs_readlink(destination), current .. "/config/bin/iara")
end

launcher["refuses an existing launcher path before any write"] = function()
  local env = helpers.isolated_env()
  local destination = helpers.temp_dir() .. "/iara"
  helpers.write_file(destination, "#!/bin/sh\n")
  local result = fixture.bootstrap(env, { "--launcher", destination })
  eq(result.code, 1)
  match(result.stderr, vim.pesc(destination))
  eq(read(destination), "#!/bin/sh\n")
  eq(exists(fixture.std_paths(env).config), false)
  eq(exists(env.XDG_DATA_HOME), false)
end

launcher["selects the iara application and forwards arguments"] = function()
  local fake_bin = helpers.temp_dir()
  helpers.write_file(
    fake_bin .. "/nvim",
    '#!/bin/sh\nprintf "%s\\n" "$NVIM_APPNAME" "$#" "$@"\n'
  )
  vim.uv.fs_chmod(fake_bin .. "/nvim", 493)
  local result = helpers.run(
    { helpers.iara_dir .. "/bin/iara", "a b", "--", "", "-c", "q" },
    { env = { PATH = fake_bin .. ":" .. vim.env.PATH } }
  )
  eq(result.code, 0)
  eq(result.stdout, "iara\n5\na b\n--\n\n-c\nq\n")
end

local repair = MiniTest.new_set()
T["repair"] = repair

repair["reinstalls a missing plugin at its locked commit"] = function()
  local repo = fixture.plugin_repo()
  local lock = { ["fixture-plugin"] = { branch = "main", commit = repo.first } }
  local checkout = fixture.checkout(plugin_spec(repo), lock)
  local env = helpers.isolated_env()
  eq(fixture.bootstrap(env, {}, checkout).code, 0)
  local paths = fixture.std_paths(env)
  local plugin_dir = paths.current .. "/lazy/fixture-plugin"
  vim.fn.delete(plugin_dir, "rf")
  local result = fixture.bootstrap(env, { "--repair" }, paths.config)
  eq(result.code, 0)
  eq(head(plugin_dir), repo.first)
end

---Distribution directory whose bootstrap the installed editor names
---for `mode` (in health, notices, and `:IaraRepair`).
local function shown_iara_dir(env, mode)
  local probe = "lua io.stdout:write(require('iara.core.lazy')"
    .. (".provision_command(%q))"):format(mode)
  local result = fixture.start(env, { probe })
  eq(result.code, 0)
  return result.stdout:match("nvim %-l (%S+)/scripts/bootstrap%.lua")
end

repair["the shown command restores a missing configuration link"] = function()
  local env = fixture.provisioned()
  local paths = fixture.std_paths(env)
  local iara_dir = shown_iara_dir(env, "repair")
  vim.fn.delete(paths.config)
  local result = fixture.bootstrap(env, { "--repair" }, iara_dir)
  eq(result.code, 0)
  eq(vim.uv.fs_readlink(paths.config), paths.current .. "/config")
  match(result.stdout, "linked " .. vim.pesc(paths.config))
end

repair["refuses a checkout other than the installed one"] = function()
  local env, checkout = fixture.provisioned()
  local result = fixture.bootstrap(env, { "--repair" }, checkout)
  eq(result.code, 1)
  match(result.stderr, "repair runs the installed release's bootstrap")
end

repair["refuses a manager tree at an unexpected revision"] = function()
  local env = helpers.isolated_env()
  local manager = fixture.std_paths(env).data .. "/lazy/lazy.nvim"
  helpers.write_file(manager .. "/README.md", "someone else's tree\n")
  local result = fixture.bootstrap(env, { "--repair" })
  eq(result.code, 1)
  match(result.stderr, "is not lazy.nvim at")
  eq(read(manager .. "/README.md"), "someone else's tree\n")
end

return T
