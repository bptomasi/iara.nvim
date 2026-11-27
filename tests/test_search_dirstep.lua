-- Directory step of the search picker (task S9), driven headless in a
-- child Neovim with the pinned snacks.nvim, real ripgrep, and the S1
-- corpus.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local fixture =
  dofile(helpers.iara_dir .. "/tests/fixtures/make_search_fixture.lua")

local WAIT_MS = 20000

local shared_manifest, snacks_path
local function manifest()
  shared_manifest = shared_manifest or fixture.build(helpers.temp_dir())
  return shared_manifest
end

local function snacks_dir()
  if not snacks_path then
    local entry = lazy_fixture.release_entry("snacks.nvim")
    local mirror = lazy_fixture.url_format():format("folke/snacks.nvim")
    local dir = helpers.temp_dir() .. "/snacks.nvim"
    lazy_fixture.git({ "clone", "--quiet", mirror, dir })
    lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
    snacks_path = dir
  end
  return snacks_path
end

local CHILD_HELPERS = [[
_G.T = {}
function T.open(request)
  T.session = require("iara.features.search").open(request)
end
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
function T.list_lines()
  return vim.api.nvim_buf_get_lines(T.picker().list.win.buf, 0, -1, false)
end
function T.title()
  local chunks = vim.api.nvim_win_get_config(T.picker().input.win.win).title
  local parts = {}
  for index = 2, #chunks do
    table.insert(parts, chunks[index][1])
  end
  return table.concat(parts)
end
function T.footer()
  local config = vim.api.nvim_win_get_config(T.picker().list.win.win)
  local parts = {}
  for _, chunk in ipairs(config.footer or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end
function T.status()
  local buf = T.picker().input.win.buf
  local ns = vim.api.nvim_create_namespace("iara.search.status")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1,
    { details = true })
  local parts = {}
  for _, chunk in ipairs(marks[1] and marks[1][4].virt_text or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end
function T.request()
  return T.session:snapshot().request
end
function T.scope_rel()
  local s = T.session:snapshot()
  local scope = s.request.scope
  if scope.kind == "root" then
    return ""
  end
  return vim.fs.relpath(s.root.path, scope.path)
end
function T.settled()
  local s = T.session:snapshot()
  return s.files.lane.state ~= "loading"
    and s.content.lane.state ~= "loading"
end
function T.paths(kind)
  local s, paths = T.session:snapshot(), {}
  if kind == "files" then
    for _, record in ipairs(s.files.records) do
      table.insert(paths, record.path)
    end
  else
    for _, group in ipairs(s.content.groups) do
      table.insert(paths, group.path)
    end
  end
  table.sort(paths)
  return paths
end
]]

local child = helpers.new_child()

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

local function query_line()
  return child.lua_get("T.picker().input:get()")
end

---Open a search from the fixture buffer (the root comes from it).
local function open(request)
  child.lua("if T.picker() then T.picker():close() end")
  wait_for("vim.api.nvim_get_mode().mode == 'n'")
  child.lua("T.open(...)", { request })
  wait_for("vim.api.nvim_get_mode().mode == 'i'")
  wait_for("T.settled()")
end

---Open the directory step and wait for its listing.
local function open_step()
  child.type_keys("<A-d>")
  has_row("dir_here")
end

---Type `text` into the prompt and wait until the step lists for it.
local function type_text(text)
  child.type_keys(text)
  wait_for("T.picker().input:get() == ...", { text })
end

---Wait until the notice row reads `pattern`.
local function notice(pattern)
  wait_for(
    [[(function(pattern)
    for _, line in ipairs(T.list_lines()) do
      if line:find(pattern) then
        return true
      end
    end
    return false
  end)(...)]],
    { pattern }
  )
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.o.columns, child.o.lines = 140, 40
      child.lua("vim.opt.runtimepath:prepend(...)", { snacks_dir() })
      child.lua("for k, v in pairs(...) do vim.env[k] = v end", {
        manifest().env,
      })
      child.lua(CHILD_HELPERS)
      local path = manifest().root .. "/content-only.txt"
      child.lua("vim.cmd.edit(vim.fn.fnameescape(...))", { path })
    end,
    post_once = child.stop,
  },
})

T["Alt-d lists eligible directories in the same frame"] = function()
  open({ mode = "files" })
  type_text("needle")
  open_step()
  eq(query_line(), "")
  local shown = ids()
  eq(shown[1], "dir_here")
  for _, id in ipairs({ "dir:src", "dir:bulk", "dir:vendor", "dir:my.git" }) do
    eq(vim.tbl_contains(shown, id), true)
  end
  -- Hidden, ignored, and Git metadata directories stay out.
  for _, id in ipairs({ "dir:.git", "dir:.config", "dir:build" }) do
    eq(vim.tbl_contains(shown, id), false)
  end
  -- No `..` at the root: the step never goes above it.
  eq(vim.tbl_contains(shown, "dir_up"), false)
  eq(current(), "dir:bulk")
  local root_name = vim.fs.basename(manifest().root)
  match(child.lua_get("T.title()"), "Find files › .*" .. root_name)
  match(child.lua_get("T.status()"), "^%d+ directories $")
  match(child.lua_get("T.footer()"), "A%-d search here")
  -- Ctrl-o cancels: the query is back, the scope unchanged.
  child.type_keys("<C-o>")
  wait_for("T.picker().input:get() == 'needle'")
  eq(child.lua_get("T.scope_rel()"), "")
  eq(vim.tbl_contains(ids(), "dir_here"), false)
end

T["l goes into a directory and Backspace goes back up"] = function()
  open({ mode = "files" })
  open_step()
  child.lua("T.picker().list:view(vim.fn.index(T.ids(), 'dir:vendor') + 1)")
  child.type_keys("<Esc>", "l")
  has_row("dir:vendor/lib")
  eq(vim.tbl_contains(ids(), "dir_up"), true)
  match(child.lua_get("T.title()"), "/vendor ")
  child.type_keys("i")
  wait_for("vim.api.nvim_get_mode().mode == 'i'")
  child.type_keys("<BS>")
  has_row("dir:src")
  eq(current(), "dir:vendor")
  -- Backspace at the root stays in the step.
  child.type_keys("<BS>")
  eq(ids()[1], "dir_here")
end

T["typed relative paths jump on Enter or explain why not"] = function()
  open({ mode = "files" })
  open_step()
  type_text("vendor/lib")
  child.type_keys("<CR>")
  has_row("dir_up")
  eq(query_line(), "")
  match(child.lua_get("T.title()"), "/vendor/lib ")
  type_text("../../..")
  child.type_keys("<CR>")
  notice("Outside the project root")
  child.type_keys(("<BS>"):rep(8))
  type_text("../nope")
  child.type_keys("<CR>")
  notice("No such directory: %.%./nope")
  child.type_keys(("<BS>"):rep(7))
  -- An ignored directory exists but has nothing searchable.
  type_text("../../build")
  child.type_keys("<CR>")
  notice("No searchable files in %.%./%.%./build")
  child.type_keys(("<BS>"):rep(11))
  type_text("..")
  child.type_keys("<CR>")
  has_row("dir:vendor/lib")
  eq(vim.tbl_contains(ids(), "dir:vendor/lib"), true)
end

T["Tab completes path segments"] = function()
  open({ mode = "files" })
  open_step()
  type_text("ven")
  child.type_keys("<Tab>")
  wait_for("T.picker().input:get() == 'vendor/'")
  has_row("dir:vendor/lib")
  child.type_keys("<Tab>")
  wait_for("T.picker().input:get() == 'vendor/lib/'")
  -- No prefix completes: the row under the cursor is taken.
  child.type_keys(("<BS>"):rep(11))
  type_text("vlib")
  has_row("dir:vendor/lib")
  child.type_keys("<Tab>")
  wait_for("T.picker().input:get() == 'vendor/lib/'")
end

T["confirming a directory scopes Find files and Find in files"] = function()
  open({ mode = "files" })
  open_step()
  type_text("src")
  child.type_keys("<A-d>")
  wait_for("T.scope_rel() == 'src'")
  wait_for("T.settled()")
  wait_for("T.picker().input:get() == ''")
  match(child.lua_get("T.title()"), "^ Find files · src/ $")
  eq(child.lua_get("T.paths('files')"), { "src/main.lua" })
  -- Enter on the `.` row confirms too; Alt-x clears the scope.
  open({ mode = "content", case = "sensitive" })
  open_step()
  child.lua("T.picker().list:view(vim.fn.index(T.ids(), 'dir:src') + 1)")
  child.type_keys("<Esc>", "l")
  has_row("dir_up")
  child.lua("T.picker().list:view(1)")
  child.type_keys("<CR>")
  wait_for("T.scope_rel() == 'src'")
  child.type_keys("i")
  type_text("needle")
  wait_for("T.settled() and T.request().query == 'needle'")
  eq(child.lua_get("T.paths('content')"), { "src/main.lua" })
  child.type_keys("<A-x>")
  wait_for("T.scope_rel() == ''")
  wait_for("T.settled()")
  eq(#child.lua_get("T.paths('content')") > 1, true)
end

T["the chain keeps working within the scope"] = function()
  open({ mode = "files", case = "sensitive" })
  open_step()
  -- Typed ahead in one input, before the prompt's change events.
  child.api.nvim_input("src<A-d>")
  wait_for("T.scope_rel() == 'src'")
  wait_for("T.settled()")
  child.type_keys("<C-g>")
  wait_for("T.request().mode == 'content'")
  type_text("needle")
  wait_for("T.settled() and T.request().query == 'needle'")
  eq(child.lua_get("T.paths('content')"), { "src/main.lua" })
  eq(child.lua_get("T.scope_rel()"), "src")
  child.type_keys(("<BS>"):rep(6), "<C-o>")
  wait_for("T.request().mode == 'files'")
  eq(child.lua_get("T.scope_rel()"), "src")
end

T["keys typed ahead of the directory listing are not lost"] = function()
  -- One input: the step opens and Enter arrives before its tree is
  -- listed (the listing is delivered on the event loop, after the
  -- typeahead). Enter must still go into `src`.
  open({ mode = "files" })
  child.api.nvim_input("<A-d>src<CR>")
  has_row("dir_up")
  match(child.lua_get("T.title()"), "/src ")
  eq(query_line(), "")
  -- Alt-d typed ahead scopes the search the same way.
  open({ mode = "files" })
  child.api.nvim_input("<A-d>vendor<A-d>")
  wait_for("T.scope_rel() == 'vendor'")
  -- Tab typed ahead completes the name.
  open({ mode = "files" })
  child.api.nvim_input("<A-d>vend<Tab>")
  wait_for("T.picker().input:get() == 'vendor/'")
end

T["hidden and ignored directories follow the switches"] = function()
  open({ mode = "files" })
  open_step()
  eq(vim.tbl_contains(ids(), "dir:.config"), false)
  child.type_keys("<A-h>")
  has_row("dir:.config")
  eq(vim.tbl_contains(ids(), "dir:build"), false)
  eq(vim.tbl_contains(ids(), "dir:.git"), false)
  child.type_keys("<A-i>")
  has_row("dir:build")
  eq(vim.tbl_contains(ids(), "dir:.git"), false)
  type_text("generated")
  has_row("dir:src/generated")
  eq(child.lua_get("T.request().hidden and T.request().ignored"), true)
end

T["Normal mode keys move, enter, and go up"] = function()
  open({ mode = "files" })
  open_step()
  child.type_keys("<Esc>")
  wait_for("vim.api.nvim_get_mode().mode == 'n'")
  match(child.lua_get("T.footer()"), "h up")
  child.type_keys("gg")
  eq(current(), "dir_here")
  child.type_keys("G")
  local last = ids()[#ids()]
  eq(current(), last)
  child.lua("T.picker().list:view(vim.fn.index(T.ids(), 'dir:vendor') + 1)")
  child.type_keys("l")
  has_row("dir:vendor/lib")
  eq(current(), "dir:vendor/lib")
  child.type_keys("k")
  eq(current(), "dir_up")
  child.type_keys("j")
  eq(current(), "dir:vendor/lib")
  child.type_keys("k")
  child.type_keys("h")
  has_row("dir:src")
  eq(current(), "dir:vendor")
  child.type_keys("l", "-")
  has_row("dir:src")
  child.type_keys("i")
  wait_for("vim.api.nvim_get_mode().mode == 'i'")
  eq(ids()[1], "dir_here")
end

return T
