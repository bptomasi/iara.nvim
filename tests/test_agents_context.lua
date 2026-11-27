local helpers = require("helpers")

local expect = MiniTest.expect
local eq = expect.equality
local match = helpers.expect_match

local child = nil

-- Child-side helpers. Snapshots stay in the child (`_G.snap`), because the
-- module tracks retained snapshots by id.
local CHILD_SETUP = [[
ctx = require("iara.extras.agents.context")

function set_lines(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  vim.bo.modified = false
end

function capture(opts)
  local snap, err = ctx.capture(opts or {})
  _G.snap = snap or _G.snap
  return { snap = snap, err = err }
end

function fake_clipboard()
  _G.copied = {}
  vim.g.clipboard = {
    name = "test",
    copy = {
      ["+"] = function(lines) _G.copied["+"] = lines end,
      ["*"] = function(lines) _G.copied["*"] = lines end,
    },
    paste = {
      ["+"] = function() return _G.copied["+"] or {} end,
      ["*"] = function() return _G.copied["*"] or {} end,
    },
  }
end
]]

local function set_lines(lines)
  child.lua("set_lines(...)", { lines })
end

---Type `keys` (a Visual selection) and capture while still in Visual mode.
local function capture_after(keys, opts)
  child.type_keys(keys)
  return child.lua("return capture(...)", { opts or {} })
end

---Native yank of the current Visual selection: the reference result.
local function native_yank()
  child.type_keys("y")
  return child.fn.getreg('"')
end

local function payload()
  return child.lua("return { ctx.format(_G.snap) }")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
      child.lua(CHILD_SETUP)
    end,
    post_case = function()
      child.stop()
    end,
  },
})

-- Selections ----------------------------------------------------------------

local selections = MiniTest.new_set()
T["selections"] = selections

selections["charwise keeps multibyte boundaries like a yank"] = function()
  set_lines({ "aé漢b", "x字y" })
  local result = capture_after("gg0lvj0l")
  eq(result.err, nil)
  eq(result.snap.mode, "charwise")
  eq(result.snap.text, "é漢b\nx字")
  -- é starts at byte 1; 字 ends at byte 4 (exclusive end).
  eq(result.snap.range, { 0, 1, 1, 4 })
  eq(result.snap.text, native_yank())
end

selections["normalizes a reversed charwise range"] = function()
  set_lines({ "alpha beta", "gamma delta" })
  local result = capture_after("2G03lvk0w")
  eq(result.snap.text, "beta\ngamm")
  eq(result.snap.range, { 0, 6, 1, 4 })
  eq(result.snap.text, native_yank())
end

selections["honors exclusive charwise selection"] = function()
  child.o.selection = "exclusive"
  set_lines({ "abcdef" })
  local result = capture_after("0lv3l")
  eq(result.snap.text, "bcd")
  eq(result.snap.range, { 0, 1, 0, 4 })
  eq(result.snap.text, native_yank())
end

selections["includes a line break when selecting past the end"] = function()
  set_lines({ "one", "two" })
  local result = capture_after("gg0v$")
  eq(result.snap.text, "one\n")
  eq(result.snap.range, { 0, 0, 1, 0 })
  eq(result.snap.text, native_yank())
  match(payload()[1], "Note: the text ends with a line break%.")
  -- The last line has no following line break to include.
  local last = capture_after("G0v$")
  eq(last.snap.text, "two")
  eq(last.snap.range, { 1, 0, 1, 3 })
  eq(last.snap.text, native_yank())
end

selections["linewise keeps whole lines and discloses the newline"] = function()
  set_lines({ "  indented", "\tTabbed", "last" })
  local result = capture_after("ggVj")
  eq(result.snap.mode, "linewise")
  eq(result.snap.text, "  indented\n\tTabbed\n")
  eq(result.snap.range, { 0, 0, 2, 0 })
  eq(result.snap.text, native_yank())
  local text = payload()[1]
  match(text, "Selection: linewise, lines 1%-2%.")
  match(text, "line%-ending bytes are not claimed")
end

selections["blockwise replaces partial tab cells with spaces"] = function()
  set_lines({ "abcdefghij", "\tx", "abcdefghij" })
  local result = capture_after("gg3|<C-v>2j5|")
  eq(result.snap.mode, "blockwise")
  eq(result.snap.text, "cde\n   \ncde")
  eq(result.snap.text, native_yank())
  eq(result.snap.columns, { 2, 5 })
  local text = payload()[1]
  match(text, "display column 3 to column 5")
  match(text, "1 partially selected cells")
end

selections["blockwise replaces partial wide characters"] = function()
  set_lines({ "abcdef", "a漢字b", "abcdef" })
  local result = capture_after("gg3|<C-v>2j4|")
  eq(result.snap.text, "cd\n  \ncd")
  eq(result.snap.text, native_yank())
  match(payload()[1], "2 partially selected cells")
end

selections["blockwise keeps whole tabs and short rows"] = function()
  set_lines({ "a\tb", "ab", "a\tbc" })
  local result = capture_after("gg0<C-v>2j$h")
  eq(result.snap.text, native_yank())
  match(payload()[1], "block rows are not padded")
end

selections["blockwise to line end extends every row"] = function()
  set_lines({ "ab", "abcdef", "abc" })
  local result = capture_after("gg2|<C-v>2j$")
  eq(result.snap.text, "b\nbcdef\nbc")
  eq(result.snap.text, native_yank())
  match(payload()[1], "display column 2 to end of line")
end

selections["uses the last selection after Visual mode ends"] = function()
  set_lines({ "first", "second" })
  child.type_keys("gg0lvl<Esc>G")
  local result = child.lua("return capture()")
  eq(result.snap.text, "ir")
  eq(result.snap.range, { 0, 1, 0, 3 })
end

selections["refuses when no selection exists"] = function()
  set_lines({ "text" })
  local result = child.lua("return capture()")
  eq(result.snap, nil)
  eq(result.err.code, "no_selection")
end

selections["keeps NUL bytes and discloses control escapes"] = function()
  child.lua([[set_lines({ "a\0b\27c" })]])
  local result = capture_after("0v$h")
  eq(result.snap.text, "a\0b\27c")
  local text = payload()[1]
  match(text, "a\\x00b\\x1Bc")
  match(text, "Note: 2 control bytes are shown as \\xNN escapes%.")
end

selections["fences text containing backtick runs"] = function()
  child.bo.filetype = "lua"
  set_lines({ "x = [[```]]" })
  capture_after("0v$h")
  local text = payload()[1]
  match(text, "\n````lua\nx = %[%[```%]%]\n````$")
end

-- Buffer identity -------------------------------------------------------------

local identity = MiniTest.new_set()
T["identity"] = identity

identity["labels unsaved changes of a named buffer"] = function()
  local path = helpers.temp_dir() .. "/notes.txt"
  helpers.write_file(path, "saved\n")
  child.cmd("edit " .. path)
  child.type_keys("ccchanged<Esc>")
  local result = capture_after("0vl")
  eq(result.snap.path, vim.uv.fs_realpath(path))
  eq(result.snap.unsaved, true)
  local text = payload()[1]
  match(text, "Path: " .. vim.pesc(vim.uv.fs_realpath(path)))
  match(text, "with unsaved changes %(differs from disk%)")
  match(text, "\nch\n")
end

identity["labels an unnamed buffer as unsaved with a stable name"] = function()
  set_lines({ "scratch" })
  local result = capture_after("0vl")
  local bufnr = child.api.nvim_get_current_buf()
  eq(result.snap.path, nil)
  eq(result.snap.unsaved, true)
  eq(result.snap.buffer_label, ("[No Name] (buffer %d)"):format(bufnr))
  match(payload()[1], "not saved to any file")
end

identity["disk reference omits text and names unsaved edits"] = function()
  local path = helpers.temp_dir() .. "/ref.txt"
  helpers.write_file(path, "disk\n")
  child.cmd("edit " .. path)
  child.type_keys("ccbuffer<Esc>")
  local result = child.lua("return capture({ mode = 'reference' })")
  eq(result.snap.mode, "reference")
  eq(result.snap.text, nil)
  local text = payload()[1]
  match(text, "the agent reads the file on disk, which lacks")
  expect.no_equality(text:find("buffer\n", 1, true) ~= nil, true)
end

identity["refuses a disk reference for an unnamed buffer"] = function()
  local result = child.lua("return capture({ mode = 'reference' })")
  eq(result.err.code, "no_path")
end

-- Diagnostics -----------------------------------------------------------------

local diagnostics = MiniTest.new_set()
T["diagnostics"] = diagnostics

local ADD_DIAGNOSTICS = [[
local rows, message = ...
local ns = vim.api.nvim_create_namespace("test")
local items = {}
for _, row in ipairs(rows) do
  table.insert(items, {
    lnum = row, col = 0, severity = vim.diagnostic.severity.ERROR,
    message = message or ("problem " .. row), source = "test",
  })
end
vim.diagnostic.set(ns, 0, items)
]]

diagnostics["are attached only on request and only in range"] = function()
  set_lines({ "a", "b", "c", "d" })
  child.lua(ADD_DIAGNOSTICS, { { 0, 2 } })
  local plain = capture_after("2GVj")
  eq(plain.snap.diagnostics, nil)
  child.type_keys("<Esc>")
  local with = capture_after("2GVj", { diagnostics = true })
  eq(#with.snap.diagnostics, 1)
  eq(with.snap.diagnostics[1].row, 2)
  match(payload()[1], "Diagnostics %(1%):\n%- line 3, column 1, error %(test%)")
end

diagnostics["refuse more than 100 buffer diagnostics"] = function()
  local lines = {}
  for index = 1, 101 do
    lines[index] = "x"
  end
  set_lines(lines)
  child.lua(ADD_DIAGNOSTICS, { vim.fn.range(0, 100) })
  local result = capture_after("ggv", { diagnostics = true })
  eq(result.err.code, "too_large")
  match(result.err.message, "101 diagnostics")
end

diagnostics["refuse a message over 4 KiB"] = function()
  set_lines({ "x" })
  child.lua(ADD_DIAGNOSTICS, { { 0 }, ("m"):rep(5000) })
  local result = capture_after("ggv", { diagnostics = true })
  eq(result.err.code, "too_large")
end

-- Caps and changes ------------------------------------------------------------

local caps = MiniTest.new_set()
T["caps"] = caps

caps["refuse a charwise selection over 512 lines"] = function()
  child.lua("set_lines(vim.fn['repeat']({ 'x' }, 600))")
  local result = capture_after("ggv512j")
  eq(result.err.code, "too_large")
  match(result.err.message, "513 lines")
end

caps["refuse a tiny selection inside a line over 64 KiB"] = function()
  child.lua("set_lines({ ('x'):rep(70000) })")
  local result = capture_after("0vl")
  eq(result.err.code, "too_large")
  match(result.err.message, "long lines count fully")
end

caps["refuse a block wider than 256 display columns"] = function()
  child.lua("set_lines({ ('x'):rep(300), ('x'):rep(300) })")
  local result = capture_after("gg0<C-v>j280|")
  eq(result.err.code, "too_large")
  match(result.err.message, "display columns")
end

caps["refuse a block over 256 lines"] = function()
  child.lua("set_lines(vim.fn['repeat']({ 'xy' }, 300))")
  local result = capture_after("gg0<C-v>256j")
  eq(result.err.code, "too_large")
end

caps["refuse a payload whose escapes exceed 128 KiB"] = function()
  child.lua([[set_lines({ ("\1"):rep(40000) })]])
  local result = capture_after("0v$h")
  eq(result.err, nil)
  local formatted = payload()
  eq(formatted[1], vim.NIL)
  eq(formatted[2].code, "too_large")
  local copied = child.lua("return { ctx.copy(_G.snap, 'a') }")
  eq(copied[1], false)
  eq(child.fn.getreg("a"), "")
end

caps["retain at most four snapshots until one is released"] = function()
  set_lines({ "abc" })
  child.type_keys("0vl")
  local ids = child.lua([[
    local ids = {}
    for _ = 1, 4 do table.insert(ids, ctx.capture({}).id) end
    return ids
  ]])
  local refused = child.lua("return capture()")
  eq(refused.err.code, "retention_cap")
  child.lua("ctx.release(...)", { ids[1] })
  eq(child.lua("return capture()").err, nil)
end

caps["refuse copy and preview after the buffer changed"] = function()
  set_lines({ "abc" })
  capture_after("0vl")
  child.type_keys("<Esc>")
  child.api.nvim_buf_set_lines(0, 0, -1, true, { "edited" })
  local copied = child.lua("return { ctx.copy(_G.snap, 'a') }")
  eq(copied[1], false)
  eq(copied[2].code, "changed")
  local previewed = child.lua("return { ctx.preview(_G.snap) }")
  eq(previewed[2].code, "changed")
  eq(#child.api.nvim_list_wins(), 1)
end

-- Preview and copy ------------------------------------------------------------

local delivery = MiniTest.new_set()
T["delivery"] = delivery

delivery["copies to the + register when a clipboard exists"] = function()
  child.lua("fake_clipboard()")
  set_lines({ "copy me" })
  capture_after("0v$h")
  local result = child.lua("return { ctx.copy(_G.snap) }")
  eq(result[1], true)
  eq(result[3], "+")
  local expected = payload()[1]
  local copied = child.lua("return table.concat(_G.copied['+'], '\\n')")
  eq(copied, expected)
end

delivery["falls back to the unnamed register without a clipboard"] = function()
  child.g.loaded_clipboard_provider = 1
  set_lines({ "copy me" })
  capture_after("0v$h")
  child.type_keys("<Esc>")
  local result = child.lua("return { ctx.copy(_G.snap) }")
  eq(result[1], true)
  eq(result[3], '"')
  eq(child.fn.getreg('"'), payload()[1])
end

delivery["preview shows the exact payload and copies with y"] = function()
  child.g.loaded_clipboard_provider = 1
  child.bo.filetype = "lua"
  set_lines({ "local x = 1", "return x" })
  capture_after("ggVj")
  child.type_keys("<Esc>")
  eq(child.lua("return { ctx.preview(_G.snap) }")[1], true)
  local win = child.api.nvim_get_current_win()
  local config = child.api.nvim_win_get_config(win)
  eq(config.relative, "editor")
  -- Straight, with the title and keys inline on its edges (UX5, V13).
  eq(config.border, { "┌", "─", "┐", "│", "┘", "─", "└", "│" })
  -- The preview has the focus: its frame takes the focus color.
  match(
    child.api.nvim_get_option_value("winhighlight", { win = win }),
    "FloatBorder:IaraFloatBorderFocus"
  )
  -- Title and footer hints (V11, see test_context_look.lua).
  local function text(chunks)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, chunks))
  end
  match(text(config.title), " Agent context ")
  match(text(config.footer), "y copy · q close")
  local shown = child.api.nvim_buf_get_lines(0, 0, -1, true)
  eq(table.concat(shown, "\n"), payload()[1])
  eq(child.bo.buftype, "nofile")
  child.type_keys("y")
  eq(child.fn.getreg('"'), payload()[1])
  child.type_keys("q")
  eq(#child.api.nvim_list_wins(), 1)
end

delivery["release closes an open preview"] = function()
  set_lines({ "abc" })
  capture_after("0vl")
  child.type_keys("<Esc>")
  child.lua("ctx.preview(_G.snap)")
  eq(#child.api.nvim_list_wins(), 2)
  child.lua("ctx.release(_G.snap.id)")
  eq(#child.api.nvim_list_wins(), 1)
  expect.error(function()
    child.lua("ctx.copy(_G.snap, 'a')")
  end, "released snapshot")
end

return T
