-- Releases (F2, M2): candidate updates, whole-release promotion, offline
-- rollback, and the exclusive owner record of provisioning runs.
-- Each case provisions with the bootstrap script (X4: slow).
-- iara-test: slow
local helpers = require("helpers")
local fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function head(dir)
  return fixture.git({ "rev-parse", "HEAD" }, dir)
end

local function realpath(path)
  return vim.uv.fs_realpath(path)
end

---Identity of every entry below `dir` (inode, size, modification time).
local function fingerprint(dir)
  local entries = {}
  for name in vim.fs.dir(dir, { depth = 50 }) do
    local stat = assert(vim.uv.fs_lstat(dir .. "/" .. name))
    entries[name] = ("%d:%d:%d"):format(stat.ino, stat.size, stat.mtime.nsec)
  end
  return entries
end

---A copied checkout whose fixture plugin is locked at `commit`.
local function checkout_at(repo, commit)
  local spec = ("return { { url = %q, name = 'fixture-plugin' } }"):format(
    "file://" .. repo.path
  )
  local lock = { ["fixture-plugin"] = { branch = "main", commit = commit } }
  return fixture.checkout(spec, lock)
end

---Version the installed editor loads from the fixture plugin.
local function loaded_version(env)
  local result = fixture.start(env, {
    "lua io.stdout:write(require('fixture_plugin').version)",
  })
  eq(result.code, 0)
  return result.stdout
end

---Run a step in `env`; `extra` adds environment variables.
local function step(env, args, iara_dir, extra)
  return fixture.bootstrap(
    vim.tbl_extend("force", env, extra or {}),
    args,
    iara_dir
  )
end

---Environment of a run without network access and without Git: every
---Git call fails and is recorded in the returned log.
local function offline_without_git()
  local bin = helpers.temp_dir()
  local log = bin .. "/git-calls"
  helpers.write_file(
    bin .. "/git",
    ('#!/bin/sh\necho "$*" >> %q\nexit 1\n'):format(log)
  )
  vim.uv.fs_chmod(bin .. "/git", 493)
  return {
    PATH = bin .. ":" .. vim.env.PATH,
    IARA_GIT_URL_FORMAT = "file:///nonexistent/%s.git",
  },
    log
end

local function releases(env)
  local dir = fixture.std_paths(env).data .. "/releases"
  return vim.fn.glob(dir .. "/*", true, true)
end

---Install the fixture plugin at its first commit, then update to its
---second commit from another checkout.
local function installed_then_updated()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout_at(repo, repo.first)).code, 0)
  local first = realpath(fixture.std_paths(env).current)
  local result = step(env, { "--update" }, checkout_at(repo, repo.second))
  eq(result.code, 0)
  return env, repo, first
end

local T = MiniTest.new_set()

local update = MiniTest.new_set()
T["update"] = update

update["promotes a candidate built apart from the active release"] = function()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout_at(repo, repo.first)).code, 0)
  local paths = fixture.std_paths(env)
  local first = realpath(paths.current)
  local before = fingerprint(first)
  local result = step(env, { "--update" }, checkout_at(repo, repo.second))
  eq(result.code, 0)
  match(result.stdout, "restart Iara")
  eq(fingerprint(first), before)
  eq(realpath(paths.previous), first)
  eq(realpath(paths.current) ~= first, true)
  eq(head(paths.current .. "/lazy/fixture-plugin"), repo.second)
  eq(vim.uv.fs_readlink(paths.config), paths.current .. "/config")
  eq(loaded_version(env), "2")
  eq(exists(paths.data .. "/iara-owner.json"), false)
end

update["a failed update keeps the current release active"] = function()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout_at(repo, repo.first)).code, 0)
  local paths = fixture.std_paths(env)
  local first = realpath(paths.current)
  local result = step(env, { "--update" }, checkout_at(repo, ("0"):rep(40)))
  eq(result.code, 1)
  match(result.stderr, "fixture%-plugin")
  match(result.stderr, "Retry with: .*%-%-update")
  eq(realpath(paths.current), first)
  eq(exists(paths.previous), false)
  eq(#releases(env), 1)
  eq(vim.fn.glob(paths.data .. "/iara-tmp-*", false, true), {})
  eq(exists(paths.data .. "/iara-owner.json"), false)
  eq(loaded_version(env), "1")
end

update["refuses a candidate that does not start cleanly"] = function()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout_at(repo, repo.first)).code, 0)
  local first = realpath(fixture.std_paths(env).current)
  local broken = checkout_at(repo, repo.first)
  helpers.write_file(
    broken .. "/lua/iara/core/keymaps.lua",
    "error('broken keymaps')\n"
  )
  local result = step(env, { "--update" }, broken)
  eq(result.code, 1)
  match(result.stderr, "does not start cleanly")
  match(result.stderr, "broken keymaps")
  eq(realpath(fixture.std_paths(env).current), first)
  eq(#releases(env), 1)
end

update["offline, reuses retained trees and fails for new pins"] = function()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout_at(repo, repo.first)).code, 0)
  local paths = fixture.std_paths(env)
  local first = realpath(paths.current)
  -- No source is reachable any more: neither the mirror nor the plugin.
  local offline = { IARA_GIT_URL_FORMAT = "file:///nonexistent/%s.git" }
  vim.fn.delete(repo.path, "rf")
  local newer = checkout_at(repo, repo.second)
  local changed = step(env, { "--update" }, newer, offline)
  eq(changed.code, 1)
  eq(realpath(paths.current), first)
  local same = checkout_at(repo, repo.first)
  helpers.write_file(same .. "/release-note.txt", "new configuration\n")
  eq(step(env, { "--update" }, same, offline).code, 0)
  eq(realpath(paths.previous), first)
  local current = realpath(paths.current)
  local repeated = step(env, { "--update" }, same, offline)
  eq(repeated.code, 0)
  match(repeated.stdout, "current release already matches")
  eq(realpath(paths.current), current)
  eq(realpath(paths.previous), first)
  eq(#releases(env), 2)
  eq(loaded_version(env), "1")
end

update["a failed config link preserves both releases"] = function()
  local env, repo = installed_then_updated()
  local paths = fixture.std_paths(env)
  local before = { realpath(paths.current), realpath(paths.previous) }
  local blocked = helpers.temp_dir() .. "/config-file"
  helpers.write_file(blocked, "ordinary file")
  local result = step(env, { "--update" }, checkout_at(repo, repo.first), {
    XDG_CONFIG_HOME = blocked,
  })
  eq(result.code, 1)
  eq({ realpath(paths.current), realpath(paths.previous) }, before)
  eq(#releases(env), 2)
  eq(loaded_version(env), "2")
end

update["prunes obsolete releases and preserves linked directories"] = function()
  local env, repo, first = installed_then_updated()
  local store = vim.fs.dirname(first)
  local outside = helpers.temp_dir()
  helpers.write_file(outside .. "/release.json", read(first .. "/release.json"))
  helpers.write_file(outside .. "/marker", "keep")
  assert(vim.uv.fs_symlink(outside, store .. "/linked"))
  vim.fn.mkdir(store .. "/ordinary")
  local checkout = checkout_at(repo, repo.first)
  helpers.write_file(checkout .. "/prune-note.txt", "new configuration\n")
  eq(step(env, { "--update" }, checkout).code, 0)
  eq(exists(first), false)
  eq(vim.uv.fs_readlink(store .. "/linked"), outside)
  eq(read(outside .. "/marker"), "keep")
  eq(exists(store .. "/ordinary"), true)
end

update["does not reuse modified plugin files at the pinned commit"] = function()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  local checkout = checkout_at(repo, repo.first)
  eq(step(env, {}, checkout).code, 0)
  local paths = fixture.std_paths(env)
  local first = realpath(paths.current)
  local module = "/lazy/fixture-plugin/lua/fixture_plugin/init.lua"
  helpers.write_file(first .. module, "return { version = 99 }\n")
  eq(head(first .. "/lazy/fixture-plugin"), repo.first)
  eq(step(env, { "--update" }, checkout).code, 0)
  eq(realpath(paths.previous), first)
  eq(loaded_version(env), "1")
  match(read(first .. module), "99")
end

update["carries the personal file into the new release"] = function()
  local repo = fixture.plugin_repo()
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout_at(repo, repo.first)).code, 0)
  local paths = fixture.std_paths(env)
  local personal = "return { options = { shiftwidth = 7 } }\n"
  helpers.write_file(paths.config .. "/lua/user.lua", personal)
  eq(step(env, { "--update" }, checkout_at(repo, repo.first)).code, 0)
  eq(read(paths.config .. "/lua/user.lua"), personal)
end

---Turn a provisioned installation into the layout of releases before
---M2: trees directly in the data directory, configuration linked to the
---checkout.
local function make_legacy(env, checkout)
  local paths = fixture.std_paths(env)
  local release = realpath(paths.current)
  for _, name in ipairs({ "lazy", "lazy-lock.json", "treesitter" }) do
    assert(vim.uv.fs_rename(release .. "/" .. name, paths.data .. "/" .. name))
  end
  vim.fn.delete(paths.current)
  vim.fn.delete(paths.data .. "/releases", "rf")
  vim.fn.delete(paths.config)
  assert(vim.uv.fs_symlink(checkout, paths.config))
end

update["moves an installation without releases to a release"] = function()
  local repo = fixture.plugin_repo()
  local checkout = checkout_at(repo, repo.first)
  local env = helpers.isolated_env()
  eq(step(env, {}, checkout).code, 0)
  make_legacy(env, checkout)
  local paths = fixture.std_paths(env)
  eq(loaded_version(env), "1")
  local legacy = fingerprint(paths.data .. "/lazy")
  eq(step(env, { "--update" }, checkout).code, 0)
  eq(vim.uv.fs_readlink(paths.config), paths.current .. "/config")
  eq(head(paths.current .. "/lazy/fixture-plugin"), repo.first)
  -- The old trees are left for the user to remove.
  eq(fingerprint(paths.data .. "/lazy"), legacy)
  eq(loaded_version(env), "1")
end

local rollback = MiniTest.new_set()
T["rollback"] = rollback

rollback["restores the previous release offline without Git"] = function()
  local env, repo, first = installed_then_updated()
  local paths = fixture.std_paths(env)
  local second = realpath(paths.current)
  vim.fn.delete(repo.path, "rf")
  local offline, git_log = offline_without_git()
  local result = step(env, { "--rollback" }, paths.config, offline)
  eq(result.code, 0)
  match(result.stdout, "rolled back to release")
  match(result.stdout, "configuration unknown revision")
  eq(exists(git_log), false)
  eq(realpath(paths.current), first)
  eq(realpath(paths.previous), second)
  eq(loaded_version(env), "1")
  -- Rolling back again returns to the newer release.
  eq(step(env, { "--rollback" }, paths.config, offline).code, 0)
  eq(loaded_version(env), "2")
end

rollback["recovers from broken lockfiles in the active release"] = function()
  local env, _, first = installed_then_updated()
  local paths = fixture.std_paths(env)
  local second = realpath(paths.current)
  helpers.write_file(paths.config .. "/lazy-lock.json", "{")
  helpers.write_file(paths.config .. "/parsers-lock.txt", "invalid pin")
  local offline, git_log = offline_without_git()
  eq(step(env, { "--rollback" }, paths.config, offline).code, 0)
  eq(exists(git_log), false)
  eq(realpath(paths.current), first)
  eq(realpath(paths.previous), second)
  eq(loaded_version(env), "1")
end

rollback["refuses a plugin changed at the same commit"] = function()
  local env, repo, first = installed_then_updated()
  local paths = fixture.std_paths(env)
  local second = realpath(paths.current)
  local plugin = first .. "/lazy/fixture-plugin"
  helpers.write_file(plugin .. "/lua/fixture_plugin/init.lua", "return {}\n")
  eq(head(plugin), repo.first)
  local result = step(env, { "--rollback" }, paths.config)
  eq(result.code, 1)
  match(result.stderr, "fixture%-plugin does not match its content checksum")
  eq(realpath(paths.current), second)
  eq(realpath(paths.previous), first)
end

rollback["refuses a damaged previous release and changes nothing"] = function()
  local env = installed_then_updated()
  local paths = fixture.std_paths(env)
  local current, previous = realpath(paths.current), realpath(paths.previous)
  local parser = previous .. "/treesitter/parser/json.so"
  local file = assert(io.open(parser, "ab"))
  file:write("damage")
  file:close()
  local result = step(env, { "--rollback" }, paths.config)
  eq(result.code, 1)
  match(result.stderr, "is damaged")
  match(result.stderr, "json%.so does not match its checksum")
  eq(
    { realpath(paths.current), realpath(paths.previous) },
    { current, previous }
  )
end

local function overwrite(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

---Run a rollback that must be refused and check that nothing changed.
local function refused_rollback(env)
  local paths = fixture.std_paths(env)
  local before = { realpath(paths.current), realpath(paths.previous) }
  local result = step(env, { "--rollback" }, paths.config)
  eq(result.code, 1)
  eq({ realpath(paths.current), realpath(paths.previous) }, before)
  eq(vim.fn.glob(paths.data .. "/iara-tmp-*", false, true), {})
  eq(loaded_version(env), "2")
  return result
end

rollback["rollback can retry after a blocked staging path"] = function()
  local env = installed_then_updated()
  local paths = fixture.std_paths(env)
  local temporary = paths.current .. ".new"
  assert(vim.uv.fs_mkdir(temporary, 448))
  local result = refused_rollback(env)
  match(result.stderr, "cannot stage .*current")
  assert(vim.uv.fs_rmdir(temporary))
  eq(step(env, { "--rollback" }, paths.config).code, 0)
  eq(loaded_version(env), "1")
end

rollback["a failed current rename restores the previous link"] = function()
  local env = installed_then_updated()
  local paths = fixture.std_paths(env)
  local before = { realpath(paths.current), realpath(paths.previous) }
  local hook = helpers.temp_dir() .. "/fail-rename.lua"
  helpers.write_file(
    hook,
    [[
    local rename = vim.uv.fs_rename
    vim.uv.fs_rename = function(from, to, ...)
      if to == vim.fn.stdpath("data") .. "/current" then
        return nil, "EIO: injected current-link failure", "EIO"
      end
      return rename(from, to, ...)
    end
  ]]
  )
  local result = helpers.run({
    vim.v.progpath,
    "--cmd",
    "luafile " .. vim.fn.fnameescape(hook),
    "-l",
    paths.config .. "/scripts/bootstrap.lua",
    "--rollback",
  }, { env = env, cwd = helpers.temp_dir() })
  eq(result.code, 1)
  match(result.stderr, "cannot switch .*current: EIO")
  eq({ realpath(paths.current), realpath(paths.previous) }, before)
  eq(exists(paths.current .. ".new"), false)
  eq(exists(paths.previous .. ".new"), false)
  eq(step(env, { "--rollback" }, paths.config).code, 0)
  eq(loaded_version(env), "1")
end

rollback["refuses a previous release whose configuration changed"] = function()
  local env = installed_then_updated()
  local previous = realpath(fixture.std_paths(env).previous)
  overwrite(previous .. "/config/lua/iara/config.lua", "return nil +\n")
  local result = refused_rollback(env)
  match(result.stderr, "is damaged")
  match(result.stderr, "lua/iara/config%.lua does not match its checksum")
end

rollback["refuses a previous release that does not start"] = function()
  local env = installed_then_updated()
  local previous = realpath(fixture.std_paths(env).previous)
  -- The personal file is the user's, outside the checksums; Iara falls
  -- back to safe mode when it fails.
  overwrite(previous .. "/config/lua/user.lua", "error('broken personal')\n")
  local result = refused_rollback(env)
  match(result.stderr, "does not start cleanly")
  match(result.stderr, "full mode")
end

rollback["refuses a release without configuration checksums"] = function()
  local env = installed_then_updated()
  local previous = realpath(fixture.std_paths(env).previous)
  local manifest = vim.json.decode(read(previous .. "/release.json"))
  manifest.format, manifest.config.files = 1, nil
  overwrite(previous .. "/release.json", vim.json.encode(manifest))
  local result = refused_rollback(env)
  match(result.stderr, "no checksums of its configuration")
end

rollback["without a previous release changes nothing"] = function()
  local env = fixture.provisioned()
  local paths = fixture.std_paths(env)
  local current = realpath(paths.current)
  local result = step(env, { "--rollback" }, paths.config)
  eq(result.code, 1)
  match(result.stderr, "no previous release is retained")
  eq(realpath(paths.current), current)
end

local owner = MiniTest.new_set()
T["owner record"] = owner

---A Git wrapper that delays the manager clone, holding ownership.
local function slow_git_env()
  local bin = helpers.temp_dir()
  local script = '#!/bin/sh\ncase "$*" in *lazy.nvim.git*) sleep 3 ;; esac\n'
    .. ('exec %q "$@"\n'):format(vim.fn.exepath("git"))
  helpers.write_file(bin .. "/git", script)
  vim.uv.fs_chmod(bin .. "/git", 493)
  return { PATH = bin .. ":" .. vim.env.PATH }
end

owner["refuses a concurrent run while the first one completes"] = function()
  local env = helpers.isolated_env()
  local paths = fixture.std_paths(env)
  local record = paths.data .. "/iara-owner.json"
  local first = vim.system({
    vim.v.progpath,
    "-l",
    helpers.iara_dir .. "/scripts/bootstrap.lua",
  }, {
    env = vim.tbl_extend("force", env, slow_git_env(), {
      IARA_GIT_URL_FORMAT = fixture.url_format(),
      GIT_CONFIG_COUNT = "1",
      GIT_CONFIG_KEY_0 = "protocol.file.allow",
      GIT_CONFIG_VALUE_0 = "always",
    }),
    text = true,
  })
  eq(
    vim.wait(20000, function()
      return exists(record)
    end, 20),
    true
  )
  local second = step(env, { "--update" })
  eq(second.code, 1)
  match(second.stderr, "another provisioning run owns")
  eq(first:wait(120000).code, 0)
  eq(exists(record), false)
  eq(exists(paths.current .. "/lazy/lazy.nvim"), true)
end

---Write the record an interrupted run leaves, with a process that ended.
local function leave_interrupted_record(env)
  local ended = vim.system({ "true" })
  local pid = ended.pid
  ended:wait()
  local data = fixture.std_paths(env).data
  helpers.write_file(
    data .. "/iara-owner.json",
    vim.json.encode({
      pid = pid,
      host = vim.uv.os_gethostname(),
      mode = "update",
      started = "2026-11-19T00:00:00Z",
      token = "interrupted",
    })
  )
  helpers.write_file(data .. "/iara-tmp-abcdef/release/partial", "x")
end

owner["an interrupted run blocks every step until repair"] = function()
  local env = fixture.provisioned()
  local paths = fixture.std_paths(env)
  leave_interrupted_record(env)
  for _, args in ipairs({ { "--update" }, { "--rollback" } }) do
    local result = step(env, args, paths.config)
    eq(result.code, 1)
    match(result.stderr, "an interrupted provisioning run left")
    match(result.stderr, "%-%-repair")
  end
  eq(exists(paths.data .. "/iara-tmp-abcdef"), true)
  local repaired = step(env, { "--repair" }, paths.config)
  eq(repaired.code, 0)
  match(repaired.stdout, "took over from an interrupted run")
  eq(exists(paths.data .. "/iara-tmp-abcdef"), false)
  eq(exists(paths.data .. "/iara-owner.json"), false)
end

return T
