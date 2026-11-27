local helpers = require("helpers")

local expect = MiniTest.expect
local eq = expect.equality
local match = helpers.expect_match

local child = nil

---Run git with a fixed identity so commits work without user config.
local function git(cwd, ...)
  local argv = {
    "git",
    "-c",
    "user.name=Iara Test",
    "-c",
    "user.email=iara@example.invalid",
    "-c",
    "init.defaultBranch=main",
    ...,
  }
  local result = helpers.run(argv, { cwd = cwd })
  eq(result.code, 0)
end

---Create a repository with one commit at `path`.
local function make_repo(path)
  vim.fn.mkdir(path, "p")
  git(path, "init", "-q")
  git(path, "commit", "-q", "--allow-empty", "-m", "initial")
  return path
end

---Canonical spelling of an existing directory.
local function real(path)
  return vim.fs.normalize(assert(vim.uv.fs_realpath(path)))
end

---Start Iara in the child from `startup_dir` and record root events.
---The ceiling keeps repositories above the test's temporary directory
---(a stray /tmp/.git, for example) out of every resolution.
local function start_in(startup_dir, ceiling)
  child.lua(
    [[
    local startup_dir, ceiling = ...
    vim.env.GIT_CEILING_DIRECTORIES = ceiling
    vim.cmd.cd(startup_dir)
    require("iara").setup()
    _G.events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "IaraRootChanged",
      callback = function(args) table.insert(_G.events, args.data) end,
    })
  ]],
    { startup_dir, ceiling }
  )
end

local function edit(path)
  child.cmd("edit " .. vim.fn.fnameescape(path))
end

local function resolve(bufnr)
  return child.lua("return require('iara.core.root').resolve(...)", { bufnr })
end

local function root_call(name, ...)
  local code = ("return require('iara.core.root').%s(...)"):format(name)
  return child.lua(code, { ... })
end

local workspace = nil

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
      workspace = real(helpers.temp_dir())
      vim.fn.mkdir(workspace .. "/startup", "p")
      start_in(workspace .. "/startup", vim.fs.dirname(workspace))
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local resolution = MiniTest.new_set()
T["resolution"] = resolution

resolution["picks the nearest repository of nested ones"] = function()
  local outer = make_repo(workspace .. "/outer")
  local inner = make_repo(outer .. "/inner")
  helpers.write_file(inner .. "/src/a.lua", "")
  helpers.write_file(outer .. "/b.lua", "")

  edit(inner .. "/src/a.lua")
  local inner_root = resolve()
  eq(inner_root.path, inner)
  eq(inner_root.provenance, "git")
  eq(inner_root.worktree_id, "git:" .. inner)
  eq(inner_root.label, "inner (git)")

  edit(outer .. "/b.lua")
  eq(resolve().path, outer)
end

resolution["gives each worktree its own identity"] = function()
  local main = make_repo(workspace .. "/main")
  local linked = workspace .. "/linked"
  git(main, "worktree", "add", "-q", linked)
  helpers.write_file(main .. "/a.txt", "")
  helpers.write_file(linked .. "/sub/b.txt", "")

  edit(main .. "/a.txt")
  local main_root = resolve()
  edit(linked .. "/sub/b.txt")
  local linked_root = resolve()

  eq(vim.fn.filereadable(linked .. "/.git"), 1)
  eq(linked_root.path, linked)
  eq(linked_root.provenance, "git")
  eq(linked_root.worktree_id, "git:" .. linked)
  expect.no_equality(linked_root.worktree_id, main_root.worktree_id)
end

resolution["shares identity between symlinked aliases"] = function()
  local repo = make_repo(workspace .. "/repo")
  helpers.write_file(repo .. "/a.txt", "")
  local alias = workspace .. "/alias"
  assert(vim.uv.fs_symlink(repo, alias))

  edit(alias .. "/a.txt")
  local through_alias = resolve()
  edit(repo .. "/a.txt")
  local direct = resolve()

  eq(through_alias.path, repo)
  eq(through_alias.worktree_id, direct.worktree_id)
end

resolution["finds the repository of a file in a missing directory"] = function()
  local repo = make_repo(workspace .. "/repo")
  edit(repo .. "/not/yet/created.lua")
  eq(resolve().path, repo)
end

resolution["falls back to the startup dir outside a repository"] = function()
  helpers.write_file(workspace .. "/loose/a.txt", "")
  edit(workspace .. "/loose/a.txt")
  local root = resolve()
  eq(root.path, workspace .. "/startup")
  eq(root.provenance, "startup")
  eq(root.worktree_id, "dir:" .. workspace .. "/startup")
end

resolution["resolves an unnamed buffer to the startup directory"] = function()
  child.cmd("enew")
  local root = resolve(0)
  eq(root.path, workspace .. "/startup")
  eq(root.provenance, "startup")
end

resolution["uses the context root set on a special buffer"] = function()
  local repo = make_repo(workspace .. "/repo")
  child.cmd("enew")
  child.lua("vim.bo.buftype = 'nofile'; vim.b.iara_context_root = ...", {
    repo,
  })
  eq(resolve().path, repo)
  eq(resolve().provenance, "git")
end

resolution["follows a context root set after the first resolve"] = function()
  local repo = make_repo(workspace .. "/repo")
  child.cmd("enew")
  child.lua("vim.bo.buftype = 'nofile'")
  eq(resolve().provenance, "startup")
  eq(root_call("statusline"), "startup (startup)")

  child.lua("vim.b.iara_context_root = ...", { repo })
  eq(resolve().path, repo)
  eq(root_call("statusline"), "repo (git)")
end

resolution["follows a changed context root"] = function()
  local first = make_repo(workspace .. "/first")
  local second = make_repo(workspace .. "/second")
  child.cmd("enew")
  child.lua("vim.bo.buftype = 'nofile'; vim.b.iara_context_root = ...", {
    first,
  })
  eq(resolve().path, first)

  child.lua("vim.b.iara_context_root = ...", { second })
  eq(resolve().path, second)
  child.lua("vim.b.iara_context_root = nil")
  eq(resolve().provenance, "startup")
end

resolution["keeps the cached root while the context is unchanged"] = function()
  local repo = make_repo(workspace .. "/repo")
  child.cmd("enew")
  child.lua("vim.bo.buftype = 'nofile'; vim.b.iara_context_root = ...", {
    repo,
  })
  local first = resolve()
  -- Marker changes are seen only after an explicit refresh, so with an
  -- unchanged context the cached root stays.
  vim.fn.delete(repo .. "/.git", "rf")
  child.lua("vim.b.iara_context_root = ...", { repo })
  eq(resolve(), first)
end

resolution["uses the startup fallback when the context vanished"] = function()
  local repo = make_repo(workspace .. "/repo")
  child.cmd("enew")
  child.lua("vim.bo.buftype = 'nofile'; vim.b.iara_context_root = ...", {
    repo,
  })
  vim.fn.delete(repo, "rf")
  eq(resolve().provenance, "startup")
end

resolution["re-resolves when the cached root was removed"] = function()
  local repo = make_repo(workspace .. "/repo")
  helpers.write_file(repo .. "/sub/a.txt", "")
  edit(repo .. "/sub/a.txt")
  eq(resolve().path, repo)

  vim.fn.delete(repo, "rf")
  local root = resolve()
  eq(root.path, workspace .. "/startup")
  eq(root.provenance, "startup")
end

resolution["never changes the working directory"] = function()
  local repo = make_repo(workspace .. "/repo")
  helpers.write_file(repo .. "/a.txt", "")
  edit(repo .. "/a.txt")
  resolve()
  root_call("set_override", repo)
  eq(child.fn.getcwd(), workspace .. "/startup")
end

resolution["rejects an invalid buffer handle"] = function()
  expect.error(function()
    resolve(999999)
  end, "invalid buffer")
end

resolution["does not search above a Git ceiling directory"] = function()
  local outer = make_repo(workspace .. "/outer")
  helpers.write_file(outer .. "/fenced/deep/a.txt", "")
  child.lua("vim.env.GIT_CEILING_DIRECTORIES = ...", { outer .. "/fenced" })
  edit(outer .. "/fenced/deep/a.txt")
  eq(resolve().provenance, "startup")
end

local override = MiniTest.new_set()
T["override"] = override

override["resolves a relative override against the startup dir"] = function()
  vim.fn.mkdir(workspace .. "/startup/sub", "p")
  local repo = make_repo(workspace .. "/repo")
  helpers.write_file(repo .. "/a.txt", "")
  edit(repo .. "/a.txt")
  child.cmd("cd " .. vim.fn.fnameescape(repo))

  local root = root_call("set_override", "sub")
  eq(root.path, workspace .. "/startup/sub")
  eq(root.provenance, "override")
  eq(resolve().path, workspace .. "/startup/sub")
  eq(root_call("override"), workspace .. "/startup/sub")
end

override["reports a path that is not a directory"] = function()
  helpers.write_file(workspace .. "/startup/file.txt", "")
  local result = child.lua(
    [[
    local root, err = require("iara.core.root").set_override(...)
    return { root = root, err = err }
  ]],
    { "file.txt" }
  )
  eq(result.root, nil)
  eq(result.err.code, "not_directory")
  eq(root_call("override"), vim.NIL)
end

override["reset restores repository resolution and announces it"] = function()
  local repo = make_repo(workspace .. "/repo")
  helpers.write_file(repo .. "/a.txt", "")
  edit(repo .. "/a.txt")
  resolve()
  root_call("set_override", workspace .. "/startup")
  root_call("clear_override")

  eq(resolve().provenance, "git")
  local events = child.lua_get("_G.events")
  eq(#events, 2)
  eq(events[1].cause, "override")
  eq(events[1].root.provenance, "override")
  eq(events[1].previous.provenance, "git")
  eq(events[2].cause, "reset")
  eq(events[2].root.path, repo)
  eq(events[2].bufnr, nil)
end

local invalidation = MiniTest.new_set()
T["invalidation"] = invalidation

invalidation["follows save-as into another repository"] = function()
  local first = make_repo(workspace .. "/first")
  local second = make_repo(workspace .. "/second")
  helpers.write_file(first .. "/a.txt", "")
  edit(first .. "/a.txt")
  eq(resolve().path, first)

  child.cmd("saveas " .. vim.fn.fnameescape(second .. "/a.txt"))
  eq(resolve().path, second)
  -- :saveas also renames the new alternate buffer; check the edited one.
  local current = child.api.nvim_get_current_buf()
  local renamed = vim.tbl_filter(function(event)
    return event.bufnr == current
  end, child.lua_get("_G.events"))
  eq(#renamed, 1)
  eq(renamed[1].cause, "rename")
  eq(renamed[1].previous.path, first)
  eq(renamed[1].root.path, second)
end

invalidation["picks up a new repository marker only on refresh"] = function()
  helpers.write_file(workspace .. "/later/a.txt", "")
  edit(workspace .. "/later/a.txt")
  eq(resolve().provenance, "startup")

  make_repo(workspace .. "/later")
  eq(resolve().provenance, "startup")
  root_call("refresh", 0)
  eq(resolve().path, workspace .. "/later")
  eq(child.lua_get("_G.events")[1].cause, "refresh")
end

invalidation["announces directory context changes"] = function()
  child.cmd("cd " .. vim.fn.fnameescape(workspace))
  eq(child.lua_get("_G.events")[1].cause, "dirchange")
end

local commands = MiniTest.new_set()
T["commands"] = commands

commands["set, show, and reset the root"] = function()
  vim.fn.mkdir(workspace .. "/startup/sub", "p")
  child.lua([[
    _G.shown = {}
    vim.notify = function(message) table.insert(_G.shown, message) end
  ]])

  child.cmd("IaraRootSet sub")
  eq(root_call("statusline"), "sub (override)")
  child.cmd("IaraRoot")
  child.cmd("IaraRootSet missing")
  child.cmd("IaraRootReset")

  local shown = child.lua_get("_G.shown")
  match(shown[2], "/startup/sub %(override%)")
  match(shown[3], "not a directory")
  eq(root_call("override"), vim.NIL)
  eq(root_call("statusline"), "startup (startup)")
end

return T
