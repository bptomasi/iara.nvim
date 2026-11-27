-- Tests for the shared picker helpers (task S8): opening locations and
-- previewing files or lines, used by search (S6) and D4.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = helpers.new_child()

-- A stand-in for the Snacks preview members the helper uses (reset,
-- set_lines, set_title, set_buf, ns, win), over a real window. Like
-- Snacks, reset() drops the title and shows the scratch buffer again;
-- set_buf() shows another buffer and is logged.
local FAKE_PREVIEW = [[
local scratch = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_open_win(scratch, false, {
  relative = "editor", row = 1, col = 1, width = 40, height = 5,
})
local ns = vim.api.nvim_create_namespace("test_picker")
_G.shown_log = {}
_G.preview = {
  win = { buf = scratch, win = win, valid = function()
    return vim.api.nvim_win_is_valid(win)
  end },
  minimal = function() end,
  reset = function(self)
    self.title = nil
    self:set_buf(scratch)
    vim.api.nvim_buf_clear_namespace(scratch, ns, 0, -1)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {})
  end,
  set_title = function(self, title)
    self.title = title
  end,
  set_lines = function(self, lines)
    vim.api.nvim_buf_set_lines(self.win.buf, 0, -1, false, lines)
  end,
  set_buf = function(self, buf)
    self.win.buf = buf
    vim.api.nvim_win_set_buf(win, buf)
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    table.insert(_G.shown_log, first)
  end,
  ns = function()
    return ns
  end,
}
_G.previewer = require("iara.features.picker.preview").new()
_G.shown = function()
  return vim.api.nvim_win_get_buf(win)
end
_G.lines = function()
  return vim.api.nvim_buf_get_lines(shown(), 0, -1, false)
end
---How the shown buffer is highlighted: "treesitter", the syntax name,
---or false.
_G.highlighting = function()
  local buf = shown()
  if vim.treesitter.highlighter.active[buf] then
    return "treesitter"
  end
  local syntax = vim.bo[buf].syntax
  return syntax ~= "" and syntax or false
end
_G.marks = function()
  local found = {}
  local all = vim.api.nvim_buf_get_extmarks(shown(), ns, 0, -1, {
    details = true,
  })
  for _, mark in ipairs(all) do
    local details = mark[4]
    table.insert(found, {
      row = mark[2],
      col = mark[3],
      end_col = details.end_col,
      hl = details.hl_group or details.line_hl_group,
    })
  end
  return found
end
_G.notes = function()
  local found = {}
  local all = vim.api.nvim_buf_get_extmarks(shown(), ns, 0, -1, {
    details = true,
  })
  for _, mark in ipairs(all) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      table.insert(found, line[1][1])
    end
  end
  return found
end
]]

local function write(name, content)
  local path = helpers.temp_dir() .. "/" .. name
  helpers.write_file(path, content)
  return path
end

local function jump(location, command)
  child.lua("require('iara.features.picker.open').jump(...)", {
    location,
    command,
  })
end

local function cursor()
  return child.api.nvim_win_get_cursor(0)
end

local function wait_lines(expected)
  local ok = vim.wait(5000, function()
    return vim.deep_equal(child.lua_get("lines()"), expected)
  end, 10)
  eq(child.lua_get("lines()"), expected)
  return ok
end

---Wait until the child expression `code` is true.
local function wait_true(code)
  eq(
    vim.wait(5000, function()
      return child.lua_get(code) == true
    end, 10),
    true
  )
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

T["jump"] = MiniTest.new_set()

T["jump"]["opens a literal path at its line and byte column"] = function()
  local path = write("dir with spaces/a %b.txt", "one\ntwo two\n")
  jump({ path = path, row = 1, col = 4 })
  eq(child.api.nvim_buf_get_name(0), path)
  eq(cursor(), { 2, 4 })
  eq(child.bo.buflisted, true)
end

T["jump"]["subtracts a disk-byte BOM on the first line"] = function()
  local path = write("bom.txt", "\239\187\191alpha beta\nalpha\n")
  jump({ path = path, row = 0, col = 9, disk_bytes = true })
  eq(cursor(), { 1, 6 })
  jump({ path = path, row = 1, col = 2, disk_bytes = true })
  eq(cursor(), { 2, 2 })
  jump({ path = path, row = 0, col = 9 })
  eq(cursor(), { 1, 9 })
end

T["jump"]["keeps a disk-byte column when the buffer kept its BOM"] = function()
  local path = write("bom-bin.txt", "\239\187\191alpha beta\n")
  child.cmd("edit ++bin " .. child.fn.fnameescape(path))
  child.cmd("enew")
  jump({ path = path, row = 0, col = 9, disk_bytes = true })
  eq(cursor(), { 1, 9 })
end

T["jump"]["without a row invents no location"] = function()
  local path = write("plain.txt", "a\nb\nc\n")
  child.lua("vim.cmd.edit(...)", { path })
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  local other = write("other.txt", "x\ny\n")
  jump({ path = other })
  eq(cursor(), { 1, 0 })
  -- The jump is recorded: <C-o> returns to the previous position.
  child.type_keys("<C-o>")
  eq({ child.api.nvim_buf_get_name(0), cursor() }, { path, { 3, 0 } })
end

T["jump"]["shows a buffer in a new window and clamps the line"] = function()
  local bufnr = child.api.nvim_create_buf(true, false)
  child.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "{", '  "a": 1', "}" })
  jump({ bufnr = bufnr, row = 9, col = 2 }, "vsplit")
  eq(#child.api.nvim_list_wins(), 2)
  eq(child.api.nvim_get_current_buf(), bufnr)
  eq(cursor(), { 3, 0 })
end

T["preview"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.lua(FAKE_PREVIEW)
    end,
  },
})

T["preview"]["shows given lines at once and marks the location"] = function()
  child.lua([[previewer:show(preview, {
    lines = { "{", '  "key": 1', "}" },
    filetype = "make",
    row = 1, byte_start = 2, byte_end = 7,
  })]])
  eq(child.lua_get("lines()"), { "{", '  "key": 1', "}" })
  eq(child.lua_get("marks()"), {
    { row = 1, col = 0, hl = "IaraSearchPreviewLine" },
    { row = 1, col = 2, end_col = 7, hl = "IaraSearchPreviewMatch" },
  })
  -- No Tree-sitter parser for make: its syntax highlights instead.
  eq(child.lua_get("highlighting()"), "make")
end

T["preview"]["reads a file asynchronously; the latest wins"] = function()
  local first = write("first.txt", "first\n")
  local second = write("second.txt", "second\nline\n")
  -- One call, like two quick moves: the first read never publishes.
  local shown_at_once = child.lua(
    [[local first, second = ...
    previewer:show(preview, { path = first })
    previewer:show(preview, { path = second, row = 1 })
    return lines()]],
    { first, second }
  )
  eq(shown_at_once, { "" }) -- reads are asynchronous
  wait_lines({ "second", "line", "" })
  vim.wait(100)
  eq(child.lua_get("lines()"), { "second", "line", "" })
  eq(
    child.lua_get("marks()")[1],
    { row = 1, col = 0, hl = "IaraSearchPreviewLine" }
  )
end

T["preview"]["keeps the caller's title when a read publishes"] = function()
  local path = write("titled.txt", "titled\n")
  child.lua("preview:set_title('titled.txt')")
  child.lua("previewer:show(preview, { path = ... })", { path })
  wait_lines({ "titled", "" })
  eq(child.lua_get("preview.title"), "titled.txt")
  child.lua("previewer:clear(preview)")
  eq(child.lua_get("preview.title"), vim.NIL)
end

T["preview"]["refuses binary files and cuts long lines"] = function()
  local binary = write("binary.dat", "text\0more\n")
  child.lua("previewer:show(preview, { path = ... })", { binary })
  wait_lines({ "Binary file: no preview." })
  local long = write("long.txt", ("x"):rep(1500) .. "\n")
  child.lua("previewer:show(preview, { path = ... })", { long })
  wait_lines({ ("x"):rep(1000), "" })
  -- Cut lines are short enough for regex syntax (S11).
  eq(child.lua_get("highlighting()"), "text")
end

T["preview"]["PDFs use the first page and respect the capability"] = function()
  local path = write("sample.PDF", "%PDF fixture\0")
  child.lua([[
    require("iara.features.pdf.source").text = function(_, page, done)
      assert(page == 1)
      vim.schedule(function() done({ "PDF first page" }) end)
      return { cancel = function() end }
    end
  ]])
  child.lua("previewer:show(preview, { path = ... })", { path })
  wait_lines({ "PDF first page" })
  local config = write("personal.lua", "return { features = { pdf = false } }")
  child.lua(
    [[
    local path, config = ...
    require("iara.config").load({ personal_path = config })
    previewer:show(preview, { path = path })
  ]],
    { path, config }
  )
  wait_lines({ "Binary file: no preview." })
end

T["preview"]["shows the start of a minified file"] = function()
  local path = write("min.json", ('{"k":1},'):rep(40000))
  child.lua("previewer:show(preview, { path = ... })", { path })
  wait_true("#lines() == 1 and #lines()[1] == 1000")
  eq(child.lua_get("lines()")[1]:sub(1, 8), '{"k":1},')
  eq(child.lua_get("highlighting()"), "json")
end

T["preview"]["clear and close drop pending reads"] = function()
  local path = write("pending.txt", "pending\n")
  -- In one call: reads start on the next loop turn, and a second call
  -- could arrive after a fast read already published.
  child.lua(
    "previewer:show(preview, { path = ... }) previewer:clear(preview)",
    {
      path,
    }
  )
  vim.wait(150)
  eq(child.lua_get("lines()"), { "" })
  child.lua("previewer:show(preview, { path = ... }) previewer:close()", {
    path,
  })
  vim.wait(150)
  eq(child.lua_get("lines()"), { "" })
end

---A file of `count` numbered 40-byte lines ("line 000001" and padding).
local function numbered(name, count)
  local lines = {}
  for index = 1, count do
    lines[index] = ("line %06d"):format(index) .. ("."):rep(28)
  end
  return write(name, table.concat(lines, "\n") .. "\n")
end

T["preview"]["shows the lines around a row far into a large file"] = function()
  local path = numbered("large.txt", 30000) -- 1.2 MB, row past 256 KiB
  child.lua("previewer:show(preview, ...)", {
    { path = path, row = 20000, byte_start = 0, byte_end = 4 },
  })
  local expected = ("line %06d"):format(20001) .. ("."):rep(28)
  local marked
  vim.wait(5000, function()
    for _, mark in ipairs(child.lua_get("marks()")) do
      marked = mark.hl == "IaraSearchPreviewLine" and mark or marked
    end
    return marked ~= nil
  end, 10)
  eq(child.lua_get("lines()")[marked.row + 1], expected)
  eq(marked.hl, "IaraSearchPreviewLine")
  -- The window starts inside the file, and says so.
  local first = child.lua_get("lines()")[1]
  local first_row = tonumber(first:match("^line (%d+)")) - 1
  eq(first_row + marked.row, 20000)
  eq(child.lua_get("notes()"), {
    ("[lines 1-%d not shown]"):format(first_row),
  })
  eq(#child.lua_get("lines()") * 40 <= 256 * 1024, true)
end

T["preview"]["finds a binary byte past the first chunk"] = function()
  local lines = {}
  for index = 1, 10000 do
    lines[index] = ("text line %06d ......................"):format(index)
  end
  lines[9000] = "binary\0byte"
  local path = write("late-binary.txt", table.concat(lines, "\n"))
  child.lua("previewer:show(preview, { path = ..., row = 9500 })", { path })
  wait_lines({ "Binary file: no preview." })
end

T["preview"]["reports a row past the end of the file"] = function()
  local path = numbered("short.txt", 3)
  child.lua("previewer:show(preview, { path = ..., row = 50 })", { path })
  wait_lines({ "Location is beyond the preview limit." })
end

T["preview"]["shows a cached window at once, rereads a change"] = function()
  local path = write("cached.txt", "old\n")
  local other = write("other.txt", "other\n")
  child.lua("previewer:show(preview, { path = ... })", { path })
  wait_lines({ "old", "" })
  child.lua("previewer:show(preview, { path = ... })", { other })
  wait_lines({ "other", "" })
  -- With a long debounce, only the cache can show the file quickly.
  child.lua("require('iara.features.picker.preview').DEBOUNCE_MS = 3000")
  child.lua("previewer:show(preview, { path = ... })", { path })
  eq(
    vim.wait(1500, function()
      return vim.deep_equal(child.lua_get("lines()"), { "old", "" })
    end, 10),
    true
  )
  -- A changed file is not shown from the cache: it is read again.
  helpers.write_file(path, "new content\n")
  child.lua("require('iara.features.picker.preview').DEBOUNCE_MS = 25")
  child.lua("previewer:show(preview, { path = ... })", { other })
  child.lua("previewer:show(preview, { path = ... })", { path })
  wait_lines({ "new content", "" })
end

T["preview"]["moves the mark and checks the saved file once"] = function()
  local path = write("moving.txt", "one\ntwo\nthree\n")
  child.lua("previewer:show(preview, { path = ..., row = 0 })", { path })
  wait_lines({ "one", "two", "three", "" })
  local before = child.lua(
    [[
      local path = ...
      require("iara.features.picker.preview").REPEAT_MS = 1000
      local read = require("iara.features.picker.read")
      local fresh = read.fresh
      _G.checks = 0
      read.fresh = function(...)
        _G.checks = _G.checks + 1
        return fresh(...)
      end
      for _, row in ipairs({ 1, 0, 1, 2 }) do
        previewer:show(preview, { path = path, row = row })
      end
      vim.fn.writefile({ "new one", "new two", "new three" }, path)
      return { _G.checks, marks()[1].row }
    ]],
    { path }
  )
  eq(before, { 0, 2 })
  wait_lines({ "new one", "new two", "new three", "" })
  eq(child.lua_get("checks"), 1)
  eq(child.lua_get("marks()[1].row"), 2)
end

T["preview"]["clearing drops a queued check for the shown window"] = function()
  local path = write("cleared.txt", "one\ntwo\n")
  child.lua("previewer:show(preview, { path = ..., row = 0 })", { path })
  wait_lines({ "one", "two", "" })
  local result = child.lua(
    [[
    require("iara.features.picker.preview").REPEAT_MS = 1000
    local checks = 0
    local read = require("iara.features.picker.read")
    local fresh = read.fresh
    read.fresh = function(...)
      checks = checks + 1
      return fresh(...)
    end
    previewer:show(preview, { path = ..., row = 1 })
    previewer:clear(preview)
    vim.wait(180, function() return checks > 0 end)
    return { checks, lines() }
  ]],
    { path }
  )
  eq(result, { 0, { "" } })
end

---Show `count` numbered lines with `row` marked and return the preview
---window's cursor line and first visible line.
local function show_numbered(count, row)
  return child.lua(
    [[
    local count, row = ...
    local lines = {}
    for index = 1, count do
      lines[index] = ("line %d"):format(index)
    end
    previewer:show(preview, { lines = lines, row = row })
    local view = vim.api.nvim_win_call(preview.win.win, vim.fn.winsaveview)
    return { view.lnum, view.topline }
  ]],
    { count, row }
  )
end

---Text of the first line shown in the preview window.
local function top_text()
  return child.lua_get([[vim.api.nvim_buf_get_lines(shown(),
    vim.fn.line("w0", preview.win.win) - 1,
    vim.fn.line("w0", preview.win.win), false)[1]
  ]])
end

T["preview"]["centers the marked line in the window"] = function()
  -- The window is 5 lines high: two lines above the marked one. The
  -- first screen (lines 16-26) shows the same view as the complete
  -- window that replaces it.
  eq(show_numbered(40, 20), { 6, 4 })
  eq(top_text(), "line 19")
  wait_true("#lines() == 40")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(preview.win.win)"), { 21, 0 })
  eq(top_text(), "line 19")
  eq(show_numbered(40, 1), { 2, 1 })
end

T["preview"]["counts wrapped lines when centering"] = function()
  child.lua("vim.wo[preview.win.win].wrap = true")
  child.lua([[previewer:show(preview, {
    lines = { "a", "b", ("x"):rep(60), "target", "c", "d" }, row = 3,
  })]])
  local view = child.lua_get("vim.fn.getwininfo(preview.win.win)[1]")
  -- The 60-byte line takes two of the two rows above the target.
  eq(child.lua_get("vim.api.nvim_win_get_cursor(preview.win.win)"), { 4, 0 })
  eq(view.topline, 3)
end

-- which-key's ModeChanged handler peeks at pending input. A `<C-c>`
-- typed while a preview is drawn makes that peek raise "Keyboard
-- interrupt", which aborted the preview and left a hit-enter prompt
-- (FU-P3-1). The handler below types the `<C-c>` at that moment.
T["preview"]["survives a <C-c> typed while it is drawn"] = function()
  child.type_keys("i")
  child.lua([[
    _G.mode_changes = 0
    vim.api.nvim_create_autocmd("ModeChanged", {
      callback = function()
        _G.mode_changes = _G.mode_changes + 1
        vim.api.nvim_input("<C-c>")
        vim.fn.getcharstr(1)
      end,
    })
  ]])
  local result = child.lua([[
    local ok, err = pcall(previewer.show, previewer, preview, {
      lines = { "one", "two", "three" }, row = 2,
    })
    return { ok, tostring(err) }
  ]])
  eq(result, { true, "nil" })
  eq(child.lua_get("_G.mode_changes"), 0)
  eq(child.lua_get("marks()")[1].row, 2)
  eq(child.api.nvim_get_mode().mode, "i")
end

-- Scrolling (S10, S11): the list never waits for the preview, and the
-- preview is highlighted from its first frame.

local function lua_lines(count)
  local lines = {}
  for index = 1, count do
    lines[index] = ("local value_%d = %d"):format(index, index)
  end
  return lines
end

---Highlight captures drawn on the shown buffer's first line, by asking
---the active Tree-sitter highlighter, as a redraw would.
local HIGHLIGHTED_NOW = [[
local buf = shown()
local highlighter = vim.treesitter.highlighter.active[buf]
if not highlighter then
  return false
end
return highlighter.tree:is_valid(false, { 0, 1 })
]]

T["preview"]["while the list moves, stale previews never show"] = function()
  local paths = {
    write("a.lua", "local a = 1\n"),
    write("b.lua", "local b = 2\n"),
    write("c.lua", "local c = 3\n"),
  }
  child.lua(
    [[for _, path in ipairs(...) do
      previewer:show(preview, { path = path })
    end]],
    { paths }
  )
  -- Requests return before any read: nothing was published yet.
  eq(child.lua_get("#shown_log"), 0)
  wait_lines({ "local c = 3", "" })
  eq(child.lua_get("highlighting()"), "treesitter")
  for _, first in ipairs(child.lua_get("shown_log")) do
    eq(first, "local c = 3")
  end
end

T["preview"]["a first screen is highlighted when it is shown"] = function()
  child.lua("require('iara.features.picker.preview').SETTLE_MS = 300")
  local lines = lua_lines(200)
  child.lua("previewer:show(preview, { lines = { 'first' } })")
  child.lua("previewer:show(preview, { lines = ..., filetype = 'lua' })", {
    lines,
  })
  -- The second request came at once (a held key): only the lines one
  -- window height around the top, already parsed and highlighted.
  eq(child.lua_get("lines()"), vim.list_slice(lines, 1, 6))
  eq(child.lua_get("highlighting()"), "treesitter")
  eq(child.lua(HIGHLIGHTED_NOW), true)
  wait_true("#lines() == 200")
  eq(child.lua_get("highlighting()"), "treesitter")
  eq(child.lua(HIGHLIGHTED_NOW), true)
  -- Settling keeps the view: the top is still the first line.
  eq(child.lua_get("vim.fn.line('w0', preview.win.win)"), 1)
end

T["preview"]["highlighting persists through a burst"] = function()
  child.lua("require('iara.features.picker.preview').SETTLE_MS = 300")
  local paths = {}
  for index = 1, 12 do
    paths[index] = write(
      ("burst%d.lua"):format(index),
      table.concat(lua_lines(index * 20), "\n") .. "\n"
    )
  end
  -- Read every file once so the burst publishes synchronously from the
  -- cache, as a held key over files seen before does.
  for _, path in ipairs(paths) do
    child.lua("previewer:show(preview, { path = ... })", { path })
    wait_true(("lines()[1] == %q"):format("local value_1 = 1"))
    vim.wait(20)
  end
  child.lua([[_G.unhighlighted = 0
    local pool = require("iara.features.picker.pool")
    local show = pool.show
    pool.show = function(...)
      show(...)
      if highlighting() ~= "treesitter" then
        _G.unhighlighted = _G.unhighlighted + 1
      end
    end]])
  for index = #paths, 1, -1 do
    child.lua("previewer:show(preview, { path = ... })", { paths[index] })
    vim.wait(15)
  end
  vim.wait(400)
  eq(child.lua_get("_G.unhighlighted"), 0)
  eq(child.lua_get("highlighting()"), "treesitter")
end

T["preview"]["a newer request cancels the pending completion"] = function()
  child.lua("require('iara.features.picker.preview').SETTLE_MS = 150")
  child.lua("previewer:show(preview, { lines = { 'one' } })")
  child.lua("previewer:show(preview, { lines = ..., filetype = 'lua' })", {
    lua_lines(50),
  })
  child.lua("previewer:clear(preview)")
  vim.wait(300)
  eq(child.lua_get("lines()"), { "" })
  eq(child.lua_get("highlighting()"), false)
  eq(#child.lua_get("previewer.pool:buffers()"), 0)
end

T["preview"]["markdown previews skip the conceal_lines work"] = function()
  local path = write("note.md", "# Title\n\n```lua\nlocal x = 1\n```\n")
  child.lua("previewer:show(preview, { path = ... })", { path })
  wait_lines({ "# Title", "", "```lua", "local x = 1", "```", "" })
  eq(child.lua_get("highlighting()"), "treesitter")
  local flag = child.lua_get([[
    vim.treesitter.query.get("markdown", "highlights").has_conceal_line
  ]])
  eq(flag, false)
  eq(
    child.lua_get("vim.treesitter.highlighter.active[shown()]._conceal_line"),
    false
  )
end

T["preview"]["a file shown recently comes back from its buffer"] = function()
  local a = write("again.lua", "local again = true\n")
  local b = write("between.lua", "local between = true\n")
  child.lua("previewer:show(preview, { path = ... })", { a })
  wait_lines({ "local again = true", "" })
  local first = child.lua_get("shown()")
  vim.wait(150)
  child.lua("previewer:show(preview, { path = ... })", { b })
  wait_lines({ "local between = true", "" })
  vim.wait(150)
  child.lua("previewer:show(preview, { path = ... })", { a })
  wait_lines({ "local again = true", "" })
  eq(child.lua_get("shown()"), first)
  eq(child.lua_get("highlighting()"), "treesitter")
end

T["preview"]["the screen cache is bounded"] = function()
  local limit = child.lua_get("require('iara.features.picker.pool').SCREENS")
  for index = 1, limit + 4 do
    local line = ("local x%d"):format(index)
    local path = write(("more%d.lua"):format(index), line .. "\n")
    child.lua("previewer:show(preview, { path = ... })", { path })
    wait_lines({ line, "" })
  end
  eq(#child.lua_get("previewer.pool:buffers('screens')"), limit)
  local size = child.lua_get("require('iara.features.picker.pool').SIZE")
  child.lua("require('iara.features.picker.preview').SETTLE_MS = 0")
  for index = 1, size + 2 do
    child.lua("previewer:show(preview, { lines = ..., filetype = 'lua' })", {
      lua_lines(100 + index),
    })
    wait_true(("#lines() == %d"):format(100 + index))
  end
  eq(#child.lua_get("previewer.pool:buffers()"), size)
end

T["preview"]["close deletes the pooled buffers"] = function()
  child.lua("previewer:show(preview, { lines = { 'one' } })")
  vim.wait(150)
  child.lua("previewer:show(preview, { lines = { 'two' } })")
  local buffers = child.lua_get("previewer.pool:buffers('screens')")
  eq(#buffers, 2)
  child.lua("previewer:close()")
  -- The one on screen goes once the preview shows something else.
  child.lua("preview:reset()")
  for _, buf in ipairs(buffers) do
    eq(child.api.nvim_buf_is_valid(buf), false)
  end
end

T["read cache"] = MiniTest.new_set()

T["read cache"]["keeps the most recent windows within its limits"] = function()
  local paths = {
    write("a.txt", "a\n"),
    write("b.txt", "b\n"),
    write("c.txt", "c\n"),
  }
  child.lua("_G.read = require('iara.features.picker.read')")
  child.lua("read.CACHE_ENTRIES = 2")
  for _, path in ipairs(paths) do
    child.lua(
      [[
      local done = false
      read.window(..., nil, function(_, window)
        read.store(window)
        done = true
      end)
      vim.wait(2000, function() return done end, 5)
    ]],
      { path }
    )
  end
  eq(child.lua_get("{ read.usage() }")[1], 2)
  eq(child.lua_get("read.cached(...) == nil", { paths[1] }), true)
  eq(child.lua_get("read.cached(...).lines", { paths[3] }), { "c", "" })
  child.lua("read.CACHE_BYTES = 10")
  child.lua([[read.store({ path = "big", lines = {}, bytes = 11 })]])
  eq(child.lua_get("read.cached('big') == nil"), true)
end

return T
