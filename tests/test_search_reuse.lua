local helpers = require("helpers")
local search = require("iara.features.search")
local eq = MiniTest.expect.equality

local root, home, walks, current
local original_spawn = vim.uv.spawn
local ui_module = "iara.features.search.ui"
local original_ui = package.loaded[ui_module]
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local base = helpers.temp_dir()
      root, home = base .. "/project", base .. "/home"
      vim.fn.mkdir(home, "p")
      vim.fn.mkdir(root .. "/.git/info", "p")
      vim.fn.mkdir(root .. "/empty", "p")
      helpers.write_file(root .. "/one.txt", "needle")
      helpers.write_file(root .. "/nested/two.txt", "needle")
      local variables = { "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL" }
      for _, key in ipairs(variables) do
        saved[key] = { vim.env[key] }
      end
      vim.env.HOME = home
      vim.env.XDG_CONFIG_HOME = home .. "/config"
      vim.env.GIT_CONFIG_GLOBAL = nil
      package.loaded[ui_module] = { open = function() end }
      walks = 0
      vim.uv.spawn = function(exe, opts, ...)
        if exe == "rg" and vim.list_contains(opts.args, "--files") then
          walks = walks + 1
        end
        return original_spawn(exe, opts, ...)
      end
      vim.cmd.edit(vim.fn.fnameescape(root .. "/one.txt"))
    end,
    post_case = function()
      if current then
        current:close()
      end
      vim.uv.spawn = original_spawn
      package.loaded[ui_module] = original_ui
      for key, value in pairs(saved) do
        vim.env[key] = value[1]
      end
      vim.cmd.bwipeout({ bang = true })
    end,
  },
})

local function paths(session)
  local snapshot
  eq(
    vim.wait(5000, function()
      snapshot = session:snapshot()
      return snapshot.files.lane.state ~= "loading"
    end, 1),
    true
  )
  eq(snapshot.files.lane.state, "complete")
  local names = {}
  for _, record in ipairs(snapshot.files.records) do
    table.insert(names, record.path)
  end
  table.sort(names)
  return names
end

local function reopen(request)
  current =
    search.open(vim.tbl_extend("force", { mode = "files" }, request or {}))
  return paths(current)
end

T["a second picker reuses an unchanged root and can refresh it"] = function()
  eq(reopen(), { "nested/two.txt", "one.txt" })
  eq(reopen(), { "nested/two.txt", "one.txt" })
  eq(walks, 1)
  current:refresh()
  eq(paths(current), { "nested/two.txt", "one.txt" })
  eq(walks, 2)
end

T["file creation, rename, and removal invalidate reuse"] = function()
  reopen()
  helpers.write_file(root .. "/empty/new.txt", "needle")
  assert(
    vim.uv.fs_rename(root .. "/nested/two.txt", root .. "/nested/moved.txt")
  )
  eq(reopen(), { "empty/new.txt", "nested/moved.txt", "one.txt" })
  assert(vim.uv.fs_unlink(root .. "/empty/new.txt"))
  eq(reopen(), { "nested/moved.txt", "one.txt" })
  eq(walks, 3)
end

T["nested ignore and git exclude edits invalidate reuse"] = function()
  local ignore = root .. "/nested/.ignore"
  local exclude = root .. "/.git/info/exclude"
  helpers.write_file(ignore, "# rules\n")
  helpers.write_file(exclude, "# rules\n")
  eq(reopen(), { "nested/two.txt", "one.txt" })
  helpers.write_file(ignore, "two.txt\n")
  eq(reopen(), { "one.txt" })
  helpers.write_file(exclude, "one.txt\n")
  eq(reopen(), {})
  eq(reopen({ ignored = true }), { "nested/two.txt", "one.txt" })
  eq(walks, 4)
end

T["ancestor and custom global ignore rules invalidate reuse"] = function()
  local inherited = vim.fs.dirname(root) .. "/.ignore"
  local global = home .. "/custom-ignore"
  helpers.write_file(
    home .. "/.gitconfig",
    "[core]\nexcludesFile = ~/custom-ignore\n"
  )
  helpers.write_file(inherited, "# rules\n")
  helpers.write_file(global, "# rules\n")
  eq(reopen(), { "nested/two.txt", "one.txt" })
  eq(reopen(), { "nested/two.txt", "one.txt" })
  eq(walks, 1)
  helpers.write_file(inherited, "one.txt\n")
  eq(reopen(), { "nested/two.txt" })
  helpers.write_file(global, "two.txt\n")
  eq(reopen(), {})
  eq(walks, 3)
end

T["cached paths still search the current file contents"] = function()
  reopen()
  helpers.write_file(root .. "/nested/two.txt", "new contents")
  current = search.open({ mode = "content", query = "new contents" })
  local groups
  eq(
    vim.wait(5000, function()
      local lane = current:snapshot().content
      groups = lane.groups
      return lane.lane.state == "complete"
    end, 1),
    true
  )
  eq(
    vim.tbl_map(function(group)
      return group.path
    end, groups),
    { "nested/two.txt" }
  )
  eq(walks, 1)
end

return T
