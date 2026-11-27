-- Directory navigation and its Oil handoff through the search picker.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local WAIT_MS = 20000

local plugins = {}
local function plugin_dir(repo)
  if not plugins[repo] then
    local name = vim.fs.basename(repo)
    local entry = lazy_fixture.release_entry(name)
    local mirror = lazy_fixture.url_format():format(repo)
    local dir = helpers.temp_dir() .. "/" .. name
    lazy_fixture.git({ "clone", "--quiet", mirror, dir })
    lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
    plugins[repo] = dir
  end
  return plugins[repo]
end

local CHILD_HELPERS = [[
_G.T = {}
function T.picker()
  return _G.Snacks and Snacks.picker.get()[1] or nil
end
function T.ids()
  local ids = {}
  for row in T.picker():iter() do
    table.insert(ids, row.text)
  end
  return ids
end
function T.current()
  local row = T.picker():current({ resolve = false })
  return row and row.text
end
function T.line(id)
  local list = T.picker().list
  for index = 1, list:count() do
    if list:get(index).text == id then
      local buf = list.win.buf
      local row = index - list.top
      return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    end
  end
end
function T.settled()
  local s = T.session:snapshot()
  return s.files.lane.state ~= "loading"
end
function T.notice()
  local row = T.picker().list:get(1)
  return row and row.iara.notice and row.iara.notice.text
end
]]

local child = helpers.new_child()
local root

local function wait_for(code, args)
  local ok = vim.wait(WAIT_MS, function()
    return child.lua_get(code, args) == true
  end, 20)
  if not ok then
    error("timed out waiting for: " .. code, 2)
  end
end

local function has_row(id)
  wait_for("vim.tbl_contains(T.ids(), ...)", { id })
end

local function ids()
  return child.lua_get("T.ids()")
end

local function current()
  return child.lua_get("T.current()")
end

---Open Find files and its directory step in Normal mode.
local function open_step()
  child.lua([[T.session = require("iara.features.search").open(...)]], {
    { mode = "files" },
  })
  wait_for("vim.api.nvim_get_mode().mode == 'i'")
  wait_for("T.settled()")
  child.type_keys("<A-d>")
  has_row("dir_here")
  child.type_keys("<Esc>")
  wait_for("vim.api.nvim_get_mode().mode == 'n'")
end

local function put_cursor(id)
  has_row(id)
  child.lua("T.picker().list:view(vim.fn.index(T.ids(), ...) + 1)", { id })
  eq(current(), id)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local base = helpers.temp_dir()
      root = base .. "/project"
      helpers.write_file(root .. "/src/main.lua", "return 1\n")
      helpers.write_file(root .. "/src/util/helper.lua", "return 2\n")
      helpers.write_file(root .. "/docs/readme.md", "# Readme\n")
      helpers.write_file(root .. "/notes.txt", "notes\n")
      vim.fn.mkdir(root .. "/.git", "p")
      child.restart({ "-u", helpers.minimal_init })
      child.o.columns, child.o.lines = 140, 40
      child.lua(
        "vim.opt.runtimepath:prepend(...)",
        { plugin_dir("folke/snacks.nvim") }
      )
      child.lua("vim.env.HOME = ...", { base })
      child.lua(CHILD_HELPERS)
      child.lua(
        "vim.cmd.edit(vim.fn.fnameescape(...))",
        { root .. "/notes.txt" }
      )
    end,
    post_once = child.stop,
  },
})

T["the step lists directories, then files, as a tree"] = function()
  open_step()
  local shown = ids()
  eq(vim.list_slice(shown, 1, 4), {
    "dir_here",
    "dir:docs",
    "dir:src",
    "entry:notes.txt",
  })
  match(child.lua_get("T.line('dir:src')"), "^ ├ 󰉋 src/")
  match(child.lua_get("T.line('entry:notes.txt')"), "^ └ .* notes%.txt$")
end

T["re-entering the directory step reuses its index"] = function()
  child.lua([[
      local dirs = require("iara.features.search.dirs")
      local index = dirs.index
      T.indexes = 0
      dirs.index = function(...)
        T.indexes = T.indexes + 1
        return index(...)
      end
    ]])
  open_step()
  child.type_keys("<C-o>")
  has_row("file:notes.txt")
  child.type_keys("<A-d>")
  has_row("dir_here")
  eq(child.lua_get("T.indexes"), 1)
end

T["Snacks redraws reuse unchanged search title chunks"] = function()
  child.lua([[
    local view = require("iara.features.search.view")
    local title = view.title
    T.titles = 0
    view.title = function(...)
      T.titles = T.titles + 1
      return title(...)
    end
    T.session = require("iara.features.search").open({ mode = "files" })
  ]])
  has_row("file:notes.txt")
  wait_for("T.settled()")
  local titles = child.lua_get("T.titles")
  eq(titles > 0, true)
  child.lua("T.picker():update_titles(); T.picker():update_titles()")
  eq(child.lua_get("T.titles"), titles)
  child.type_keys("<A-h>")
  wait_for("T.titles > ...", { titles })
  eq(
    child.lua_get([[
    vim.tbl_contains(vim.tbl_map(function(chunk) return chunk[1] end,
      T.picker().input.win.opts.title), " · hidden")
  ]]),
    true
  )
end

T["Enter expands and collapses a directory in place"] = function()
  open_step()
  put_cursor("dir:src")
  child.type_keys("<CR>")
  has_row("dir:src/util")
  eq(vim.list_slice(ids(), 3, 6), {
    "dir:src",
    "dir:src/util",
    "entry:src/main.lua",
    "entry:notes.txt",
  })
  eq(current(), "dir:src")
  match(child.lua_get("T.line('dir:src')"), "^ ├ 󰝰 src/")
  match(child.lua_get("T.line('dir:src/util')"), "^ │ ├ 󰉋 util/")
  match(
    child.lua_get("T.line('entry:src/main.lua')"),
    "^ │ └ .* main%.lua$"
  )
  -- Nested directories expand too; Enter again collapses.
  put_cursor("dir:src/util")
  child.type_keys("<CR>")
  has_row("entry:src/util/helper.lua")
  put_cursor("dir:src")
  child.type_keys("<CR>")
  wait_for("not vim.tbl_contains(T.ids(), 'dir:src/util')")
  eq(current(), "dir:src")
end

T["l goes into a directory and h goes up"] = function()
  open_step()
  put_cursor("dir:src")
  child.type_keys("l")
  has_row("dir_up")
  eq(vim.tbl_contains(ids(), "entry:src/main.lua"), true)
  eq(vim.tbl_contains(ids(), "entry:notes.txt"), false)
  child.type_keys("h")
  has_row("entry:notes.txt")
  eq(current(), "dir:src")
end

T["Enter on a file opens it"] = function()
  open_step()
  put_cursor("entry:notes.txt")
  child.type_keys("<CR>")
  wait_for("T.picker() == nil")
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"), root .. "/notes.txt")
end

T["E opens Oil at the selected directory, including spaces"] = function()
  helpers.write_file(root .. "/more docs/readme.md", "# Readme\n")
  child.lua(
    [[
    vim.opt.runtimepath:prepend(...)
    require("oil").setup({ default_file_explorer = false })
  ]],
    { plugin_dir("stevearc/oil.nvim") }
  )
  open_step()
  put_cursor("dir:more docs")
  child.type_keys("E")
  wait_for("vim.bo.filetype == 'oil' and T.picker() == nil")
  local opened = child.lua_get("require('oil').get_current_dir()")
  eq(vim.fs.normalize(opened), root .. "/more docs")
end

T["E opens Oil at the parent of the selected file"] = function()
  child.lua([[
    vim.api.nvim_create_user_command("Oil", function(opts)
      T.oil_path = opts.args
    end, { nargs = "?" })
  ]])
  open_step()
  put_cursor("dir:src")
  child.type_keys("<CR>")
  put_cursor("entry:src/main.lua")
  child.type_keys("E")
  wait_for("T.oil_path ~= nil and T.picker() == nil")
  eq(child.lua_get("T.oil_path"), root .. "/src")
end

T["E keeps directory navigation open when Oil is unavailable"] = function()
  open_step()
  put_cursor("dir:src")
  child.type_keys("E")
  wait_for("T.notice() == 'Oil is unavailable'")
  has_row("dir:src")
end

return T
