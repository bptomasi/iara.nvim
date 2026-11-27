-- Directory tree of the directory step (task S9): indexing, typed paths,
-- listing, filtering, and completion, through the public module.
local helpers = require("helpers")
local dirs = require("iara.features.search.dirs")

local eq = MiniTest.expect.equality

local PATHS = {
  "README.md",
  "lua/iara/core/root.lua",
  "lua/iara/core/proc.lua",
  "lua/iara/features/search/ui.lua",
  "lua/iara/init.lua",
  "tests/test_root.lua",
  "tests/fixtures/a.txt",
}

---A root on disk with the directories of PATHS and one more that holds
---no eligible file (`node_modules`).
local function disk_root()
  local root = helpers.temp_dir() .. "/project"
  for _, path in ipairs(PATHS) do
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
  end
  vim.fn.mkdir(root .. "/node_modules/pkg", "p")
  return root
end

local function labels(listing)
  return vim.tbl_map(function(item)
    return item.label
  end, listing.entries)
end

local T = MiniTest.new_set()

T["index counts eligible files below each directory"] = function()
  local tree = dirs.index(PATHS)
  eq(tree.dirs[""].files, 7)
  eq(tree.dirs["lua"].files, 4)
  eq(tree.dirs["lua/iara/core"].files, 2)
  eq(tree.dirs["tests"].children, { "tests/fixtures" })
  eq(tree.dirs["lua/iara"].children, {
    "lua/iara/core",
    "lua/iara/features",
  })
  eq(tree.dirs[""].children, { "lua", "tests" })
  eq(tree.complete, true)
  eq(dirs.index({}, false).complete, false)
end

T["index keeps the file names of each directory"] = function()
  local tree = dirs.index(PATHS)
  eq(tree.dirs[""].names, { "README.md" })
  eq(tree.dirs["lua/iara/core"].names, { "proc.lua", "root.lua" })
  eq(tree.dirs["lua/iara"].names, { "init.lua" })
  eq(tree.dirs["lua"].names, {})
end

T["add_dir lists a new empty directory and its parents"] = function()
  local tree = dirs.index(PATHS)
  dirs.add_dir(tree, "tests/new/deep")
  eq(tree.dirs["tests"].children, { "tests/fixtures", "tests/new" })
  eq(tree.dirs["tests/new"].children, { "tests/new/deep" })
  eq(tree.dirs["tests/new/deep"].files, 0)
  eq(vim.tbl_contains(tree.list, "tests/new/deep"), true)
  -- Adding again changes nothing.
  dirs.add_dir(tree, "tests/new")
  eq(tree.dirs["tests"].children, { "tests/fixtures", "tests/new" })
end

T["parent goes up to the root and no further"] = function()
  eq(dirs.parent("lua/iara"), "lua")
  eq(dirs.parent("lua"), "")
  eq(dirs.parent(""), nil)
end

T["typed paths resolve lexically inside the root"] = function()
  local root = "/work/project"
  eq(dirs.normalize(root, "lua", "iara/core"), "lua/iara/core")
  eq(dirs.normalize(root, "lua/iara", "../../tests"), "tests")
  eq(dirs.normalize(root, "lua", "./iara//core/"), "lua/iara/core")
  eq(dirs.normalize(root, "lua", ".."), "")
  eq(dirs.normalize(root, "", ".."), nil)
  eq(dirs.normalize(root, "lua", "../../.."), nil)
  eq(dirs.normalize(root, "", "/work/project/lua"), "lua")
  eq(dirs.normalize(root, "lua", "/work/project"), "")
  eq(dirs.normalize(root, "", "/work/other"), nil)
  eq(dirs.normalize(root, "", "/work/project/../other"), nil)
end

T["resolve accepts listed directories and explains the rest"] = function()
  local root = disk_root()
  local tree = dirs.index(PATHS)
  eq(dirs.resolve(tree, root, "", "lua/iara/core"), "lua/iara/core")
  eq(dirs.resolve(tree, root, "lua/iara", "../../tests"), "tests")
  local path, message = dirs.resolve(tree, root, "", "missing")
  eq(path, nil)
  eq(message, "No such directory: missing")
  path, message = dirs.resolve(tree, root, "lua", "../..")
  eq(path, nil)
  eq(message, "Outside the project root: ../..")
  -- On disk but without eligible files: the switches hide it.
  path, message = dirs.resolve(tree, root, "", "node_modules")
  eq(path, nil)
  eq(message, "No searchable files in node_modules")
  -- A file is not a directory.
  vim.fn.writefile({}, root .. "/README.md")
  eq(
    select(2, dirs.resolve(tree, root, "", "README.md")),
    "No such directory: README.md"
  )
end

T["an incomplete tree accepts directories it did not list"] = function()
  local root = disk_root()
  local tree = dirs.index({ "README.md" }, false)
  eq(dirs.resolve(tree, root, "", "node_modules/pkg"), "node_modules/pkg")
  eq(select(2, dirs.resolve(tree, root, "", "nope")), "No such directory: nope")
end

T["an empty query lists the subdirectories with counts"] = function()
  local tree = dirs.index(PATHS)
  local listing = dirs.list(tree, "/r", "lua/iara", "")
  eq(listing.base, "lua/iara")
  eq(listing.filtered, false)
  eq(labels(listing), { "core", "features" })
  eq(listing.entries[1].files, 2)
  eq(listing.entries[1].path, "lua/iara/core")
end

T["typing filters every directory below fuzzily"] = function()
  local tree = dirs.index(PATHS)
  local listing = dirs.list(tree, "/r", "", "core")
  eq(listing.filtered, true)
  eq(labels(listing), { "lua/iara/core" })
  eq(listing.entries[1].positions, { 9, 10, 11, 12 })
  eq(dirs.list(tree, "/r", "lua", "fix").total, 0)
  eq(labels(dirs.list(tree, "/r", "lua", "srch")), { "iara/features/search" })
end

T["a typed directory part lists or filters that directory"] = function()
  local tree = dirs.index(PATHS)
  local listing = dirs.list(tree, "/r", "lua/iara", "../../tests/")
  eq(listing.base, "tests")
  eq(labels(listing), { "../../tests/fixtures" })
  listing = dirs.list(tree, "/r", "", "lua/iara/f")
  eq(labels(listing), { "lua/iara/features", "lua/iara/features/search" })
  eq(listing.entries[1].positions, { 9 })
  local none, message = dirs.list(tree, "/r", "", "nope/x")
  eq(none, nil)
  eq(message, "No directory nope/")
  eq(
    select(2, dirs.list(tree, "/r", "", "../")),
    "Outside the project root: ../"
  )
end

T["Tab completes the last segment like a shell"] = function()
  local tree = dirs.index(PATHS)
  eq(dirs.complete(tree, "/r", "", "l"), "lua/")
  eq(dirs.complete(tree, "/r", "", "lua/iara/c"), "lua/iara/core/")
  eq(dirs.complete(tree, "/r", "lua/iara/core", "../f"), "../features/")
  local shared = dirs.index({ "alpha1/a", "alpha2/b" })
  eq(dirs.complete(shared, "/r", "", "a"), "alpha")
  eq(dirs.complete(shared, "/r", "", "alpha"), nil)
  eq(dirs.complete(tree, "/r", "", "zzz"), nil)
  eq(dirs.complete(tree, "/r", "", "nope/x"), nil)
end

T["breadcrumbs start at the root's name"] = function()
  eq(dirs.crumb("/work/project", ""), "project")
  eq(dirs.crumb("/work/project", "lua/iara"), "project/lua/iara")
  eq(dirs.crumb("/", "etc"), "/etc")
  eq(dirs.crumb("/", ""), "/")
end

return T
