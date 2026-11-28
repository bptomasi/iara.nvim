-- Search UI (tasks S6 and UX1) driven headless in a child Neovim with the
-- pinned snacks.nvim, real ripgrep, and the S1 corpus.
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

---Checkout of the locked snacks.nvim commit from the shared test mirror.
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

-- Helpers defined inside the child; `T.session` is the open session.
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
  local picker = T.picker()
  for row in picker:iter() do
    table.insert(ids, row.text)
  end
  return ids
end
function T.current()
  local row = T.picker():current({ resolve = false })
  return row and row.text
end
function T.list_lines()
  local buf = T.picker().list.win.buf
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
function T.query_line()
  return T.picker().input:get()
end
function T.record_ids()
  local s, ids = T.session:snapshot(), {}
  if s.request.mode ~= "content" then
    for _, record in ipairs(s.files.records) do
      table.insert(ids, record.id)
    end
  end
  if s.request.mode ~= "files" then
    for _, group in ipairs(s.content.groups) do
      table.insert(ids, "group:" .. group.path)
      for _, record in ipairs(group.records) do
        table.insert(ids, record.id)
      end
    end
  end
  return ids
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
function T.go(id)
  for row, index in T.picker():iter() do
    if row.text == id then
      return T.picker().list:view(index)
    end
  end
  error("no row " .. id)
end
-- The title of the results frame, without the border dash it starts
-- with (`┌─ Find files ─`, V10, V13).
function T.title()
  local win = T.picker().input.win.win
  local chunks = vim.api.nvim_win_get_config(win).title
  assert(chunks[1][1] == "─", "title must start with a border dash")
  local parts = {}
  for index = 2, #chunks do
    table.insert(parts, chunks[index][1])
  end
  return table.concat(parts)
end
function T.results_frame(picker)
  local input = vim.api.nvim_win_get_config(picker.input.win.win)
  local list = vim.api.nvim_win_get_config(picker.list.win.win)
  return {
    row = input.row, col = input.col, width = input.width,
    height = input.height + 1 + list.height,
  }
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

---Every shown lane finished and the picker shows the session's records.
local function settled()
  wait_for([[(function()
    local s = T.session:snapshot()
    local busy = s.files.lane.state == "loading"
      or s.content.lane.state == "loading"
    if busy then
      return false
    end
    local shown = vim.tbl_filter(function(id)
      return id ~= "notice" and id ~= "placeholder"
    end, T.ids())
    return vim.deep_equal(shown, T.record_ids())
  end)()]])
end

local function type_query(text)
  child.lua("vim.api.nvim_set_current_win(T.picker().input.win.win)")
  child.type_keys(text)
  wait_for("T.session:snapshot().request.query == ...", { text })
end

---Open a search from the fixture buffer (the root comes from it).
local function open(request)
  child.lua("if T.picker() then T.picker():close() end")
  -- Leaving the old prompt stops Insert mode later; let that happen
  -- before the next picker starts its own Insert mode.
  wait_for("vim.api.nvim_get_mode().mode == 'n'")
  child.lua("T.open(...)", { request })
  wait_for("vim.api.nvim_get_mode().mode == 'i'")
  settled()
end

---Wait until the rendered list shows a line matching `pattern`.
local function rendered(pattern)
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

---Occurrences of documented query `id` with the default switches.
local function default_hits(id)
  local m = manifest()
  local eligible = fixture.eligible(m, false, false)
  return #fixture.expected_matches(m, id, eligible)
end

local function close_picker()
  child.type_keys("<Esc>", "<Esc>")
  wait_for("T.picker() == nil")
end

local function title()
  return child.lua_get("T.title()")
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

T["Find files lists only file names, in rank order"] = function()
  open({ mode = "files", query = "needle", case = "sensitive" })
  eq(child.lua_get("T.ids()"), {
    "file:needle-both.txt",
    "file:needle-name-only.txt",
  })
  eq(child.lua_get("T.session:snapshot().content.lane.state"), "idle")
  match(title(), "^ Find files ")
  eq(child.lua_get("T.status()"), "2 files ")
end

local function mock_pdf_preview()
  child.lua([[
    local api = vim.api
    local function noop() end
    package.loaded["iara.features.pdf.sixel_cache"] = {
      want = noop, drop = noop, hold = noop, release = noop,
      prepare = function()
        return { height = 18, raster = {
          width = 40, height = 18, palette = "#0;2;100;100;100",
          bands = { "#0!40~", "#0!40~", "#0!40~" },
        } }
      end,
    }
    package.loaded["image/utils/term"] = {
      get_size = function() return { cell_width = 10, cell_height = 18 } end,
    }
    api.nvim_ui_send = function() T.pdf_drawn = true end
    api.nvim_set_decoration_provider = noop
    local picker = T.picker()
    local win = picker.preview.win.win
    local picture = require("iara.features.pdf.sixel").picture(
      "preview.ppm", win, api.nvim_win_get_buf(win), {
        x = 1, y = 0, width = 4, height = 1, preview = true,
      })
    api.nvim_create_autocmd("TextChangedI", {
      buffer = picker.input.win.buf, once = true,
      callback = function()
        picture:clear()
        vim.schedule(function() T.pdf_cleared = true end)
      end,
    })
  ]])
  wait_for("T.pdf_drawn == true")
end

T["Find files keeps typing in order when clearing a PDF preview"] = function()
  open({ mode = "files" })
  mock_pdf_preview()
  child.type_keys("u")
  wait_for("T.pdf_cleared == true")
  child.type_keys("fpr")
  eq(child.lua_get("T.query_line()"), "ufpr")
end

T["closing the picker starts the idle collection"] = function()
  child.lua([[package.loaded["iara.features.search.collect"] = {
    start = function() _G.collect_starts = (_G.collect_starts or 0) + 1 end,
  }]])
  open({ mode = "files", query = "needle" })
  eq(child.lua_get("_G.collect_starts"), vim.NIL)
  close_picker()
  eq(child.lua_get("_G.collect_starts"), 1)
end

T["Find in files groups occurrences by file"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  local ids = child.lua_get("T.ids()")
  local group = vim.fn.index(ids, "group:repeated.txt") + 1
  eq(ids[group + 1], "occurrence:0:0:6:repeated.txt")
  eq(ids[group + 4], "occurrence:2:0:6:repeated.txt")
  -- A file matching by name is still listed by its content.
  eq(vim.tbl_contains(ids, "occurrence:0:0:6:needle-both.txt"), true)
  eq(vim.tbl_contains(ids, "file:needle-both.txt"), false)
  -- Snacks neither filters nor reorders: rows keep snapshot order.
  eq(ids, child.lua_get("T.record_ids()"))
  local hits = default_hits("needle")
  local groups = #child.lua_get("T.paths('content')")
  eq(
    child.lua_get("T.status()"),
    ("%d matches in %d files "):format(hits, groups)
  )
  match(title(), "^ Find in files ")
end

T["rows carry no debug text"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  rendered("^%s+%d+:%d+%s+%S")
  for _, line in ipairs(child.lua_get("T.list_lines()")) do
    eq(line:find("occurrence:", 1, true), nil)
    eq(line:find("/1000", 1, true), nil)
    eq(line:find("complete", 1, true), nil)
  end
  eq(title():find("|", 1, true), nil)
end

T["passes the query verbatim without trimming or parsing"] = function()
  open({ mode = "content", case = "sensitive" })
  type_query("alpha -- beta ")
  settled()
  eq(child.lua_get("T.query_line()"), "alpha -- beta ")
  child.type_keys("<BS>")
  wait_for("T.session:snapshot().request.query == 'alpha -- beta'")
  settled()
  local ids = child.lua_get("T.ids()")
  eq(vim.tbl_contains(ids, "occurrence:0:0:13:dashes.txt"), true)
end

T["errors and truncation get a one-line notice"] = function()
  open({ mode = "content", query = "(unclosed", regex = true })
  eq(child.lua_get("T.ids()"), { "notice" })
  rendered("invalid regex")
  open({ mode = "files", query = "bulk" })
  rendered("Best 200 of 240 names shown; type to narrow%.")
  eq(child.lua_get("T.status()"), "200 of 240 files ")
  open({ mode = "content", query = "bulkmark" })
  rendered("Stopped at 1,000 matches; refine the search%.")
  match(child.lua_get("T.status()"), "^first 1,000 matches in %d+ files $")
end

T["Find files lists every file as it opens"] = function()
  local eligible = #fixture.eligible(manifest(), false, false)
  open({ mode = "files" })
  local ids = child.lua_get("T.ids()")
  -- The invoking buffer is the one recently used file of the project.
  eq(ids[1], "file:content-only.txt")
  eq(#ids, 201)
  eq(ids[201], "placeholder")
  eq(vim.tbl_contains(ids, "notice"), false)
  eq(child.lua_get("T.status()"), ("%d files "):format(eligible))
  local last = child.lua_get([[(function()
    local text
    for row in T.picker():iter() do
      text = row.iara.text
    end
    return text
  end)()]])
  eq(last, ("%d more; type to narrow"):format(eligible - 200))
  -- The cursor starts on the first file, and the preview shows it.
  eq(child.lua_get("T.current()"), "file:content-only.txt")
  wait_for([[vim.tbl_contains(vim.api.nvim_buf_get_lines(
    T.picker().preview.win.buf, 0, -1, false), "a line with needle inside")]])
  type_query("needle-b")
  settled()
  eq(child.lua_get("T.ids()")[1], "file:needle-both.txt")
  eq(child.lua_get("T.status()"), "1 file ")
end

T["Find in files waits for a query with a quiet preview"] = function()
  open({ mode = "content" })
  eq(child.lua_get("T.ids()"), { "placeholder" })
  rendered("Type to search inside files")
  wait_for([[vim.tbl_contains(vim.api.nvim_buf_get_lines(
    T.picker().preview.win.buf, 0, -1, false), "  Nothing selected")]])
  eq(child.lua_get("vim.wo[T.picker().preview.win.win].number"), false)
  eq(child.lua_get("T.status()"), "")
  eq(child.lua_get("T.session:snapshot().content.lane.state"), "idle")
  eq(child.lua_get("T.session:snapshot().files.lane.state"), "idle")
end

T["switch chips appear only when not at their default"] = function()
  open({ mode = "content", case = "sensitive" })
  type_query("needle")
  settled()
  eq(title(), " Find in files · case ")
  child.type_keys("<A-h>", "<A-i>")
  wait_for("T.session:snapshot().request.ignored == true")
  settled()
  eq(title(), " Find in files · hidden · ignored · case ")
  has_row("occurrence:0:6:12:.env")
  child.type_keys("<A-r>", "<A-c>")
  wait_for("T.session:snapshot().request.case == 'insensitive'")
  match(title(), "regex · ignore case $")
  eq(child.lua_get("T.query_line()"), "needle")
  eq(child.lua_get("T.session:snapshot().request.query"), "needle")
end

T["scope cycles through the invoking file's directory and file"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  child.type_keys("<A-s>")
  wait_for("T.session:snapshot().request.scope.kind == 'directory'")
  match(title(), " · %./ ")
  child.type_keys("<A-s>")
  wait_for("T.session:snapshot().request.scope.kind == 'file'")
  settled()
  match(title(), " file: content%-only%.txt ")
  eq(child.lua_get("T.ids()"), {
    "group:content-only.txt",
    "occurrence:0:12:18:content-only.txt",
  })
  child.type_keys("<A-s>")
  wait_for("T.session:snapshot().request.scope.kind == 'root'")
end

local function stub_input(value)
  child.lua(
    [[
    local value = ...
    vim.ui.input = function(opts, on_confirm)
      _G.glob_default = opts.default
      on_confirm(value)
    end
  ]],
    { value }
  )
end

T["a typed glob becomes the file filter"] = function()
  open({ mode = "files" })
  type_query("src/**")
  stub_input("src/**")
  child.type_keys("<A-g>")
  wait_for("T.session:snapshot().request.glob == 'src/**'")
  settled()
  eq(child.lua_get("_G.glob_default"), "src/**")
  eq(child.lua_get("T.query_line()"), "")
  eq(title(), " Find files: src/** ")
  match(table.concat(child.lua_get("T.ids()"), " "), "file:src/main%.lua")
  stub_input("[")
  child.type_keys("<A-g>")
  rendered("glob")
  eq(child.lua_get("T.ids()")[1], "notice")
  stub_input("")
  child.type_keys("<A-g>")
  wait_for("T.session:snapshot().request.glob == nil")
  eq(title(), " Find files ")
end

---First and last occurrence rows; content groups keep arrival order,
---which differs between runs.
local function occurrence_ids()
  local occurrences = vim.tbl_filter(function(id)
    return vim.startswith(id, "occurrence:")
  end, child.lua_get("T.ids()"))
  return occurrences[1], occurrences[#occurrences]
end

T["movement skips file headers and notices"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  local first, last = occurrence_ids()
  eq(child.lua_get("T.current()"), first)
  child.type_keys("<Up>")
  eq(child.lua_get("T.current()"), last)
  child.type_keys("<Down>")
  eq(child.lua_get("T.current()"), first)
  open({ mode = "files", query = "bulk" })
  eq(child.lua_get("T.ids()")[1], "notice")
  eq(child.lua_get("T.current()"), child.lua_get("T.ids()")[2])
end

local function open_row(id)
  child.lua("T.go(...)", { id })
  child.type_keys("<CR>")
  wait_for("vim.bo.filetype ~= 'snacks_picker_input'")
  return {
    name = child.lua_get("vim.api.nvim_buf_get_name(0)"),
    cursor = child.lua_get("vim.api.nvim_win_get_cursor(0)"),
  }
end

T["opens occurrences at their line and byte column"] = function()
  local request = { mode = "content", query = "needle", case = "sensitive" }
  open(request)
  local opened = open_row("occurrence:0:7:13:unicode.txt")
  match(opened.name, "/unicode%.txt$")
  eq(opened.cursor, { 1, 7 })
  open(request)
  opened = open_row("occurrence:2:0:6:repeated.txt")
  eq(opened.cursor, { 3, 0 })
  -- Neovim strips the BOM that ripgrep counts.
  open(request)
  eq(open_row("occurrence:0:3:9:bom.txt").cursor, { 1, 0 })
end

T["opens special file names without inventing a location"] = function()
  local path = "dir with spaces/file name with spaces.txt"
  open({ mode = "files", query = "file name with", case = "sensitive" })
  local opened = open_row("file:" .. path)
  eq(opened.name, manifest().root .. "/" .. path)
  eq(opened.cursor, { 1, 0 })
end

T["exports selected records to a titled quickfix list"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  child.lua("T.go(...)", { "occurrence:0:7:13:repeated.txt" })
  child.type_keys("<Tab>")
  child.lua("T.go(...)", { "occurrence:0:7:13:unicode.txt" })
  child.type_keys("<Tab>", "<C-q>")
  wait_for("vim.fn.getqflist({ size = 0 }).size == 2")
  local list = child.lua_get([[(function()
    local info = vim.fn.getqflist({ title = 0, items = 0 })
    local items = {}
    for _, item in ipairs(info.items) do
      local name = vim.fn.bufname(item.bufnr):match("[^/]+$")
      table.insert(items, { name, item.lnum, item.col })
    end
    return { title = info.title, items = items }
  end)()]])
  eq(list.title, "Iara search: needle")
  eq(list.items, { { "repeated.txt", 1, 8 }, { "unicode.txt", 1, 8 } })
end

T["exports every record when nothing is selected"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  child.type_keys("<C-q>")
  local size = default_hits("needle")
  wait_for("vim.fn.getqflist({ size = 0 }).size == ...", { size })
end

T["selection and cursor survive result updates"] = function()
  local id = "occurrence:0:0:6:repeated.txt"
  open({ mode = "content", query = "needle", case = "sensitive" })
  child.lua("T.go(...)", { id })
  child.type_keys("<Tab>")
  child.lua("T.go(...)", { id })
  child.type_keys("<A-h>")
  wait_for("T.session:snapshot().request.hidden == true")
  settled()
  eq(child.lua_get("T.current()"), id)
  eq(child.lua_get("T.picker().list:is_selected(T.picker():current())"), true)
  eq(child.lua_get("#T.picker():selected()"), 1)
  match(child.lua_get("T.status()"), "^1 selected · ")
end

T["a record the user returns to keeps the cursor after updates"] = function()
  local id = "file:keep.log"
  open({ mode = "files", query = "log", hidden = true })
  -- The UI placed the cursor on the first record; the user moves away
  -- and back, which makes it a choice rather than a placement.
  eq(child.lua_get("T.current()"), id)
  child.type_keys("<Tab>")
  eq(child.lua_get("T.current()") ~= id, true)
  child.lua("T.go(...)", { id })
  child.type_keys("<A-i>")
  wait_for("T.session:snapshot().request.ignored == true")
  settled()
  -- An ignored file now ranks first, so following the results would
  -- move the cursor away from the chosen record.
  eq(child.lua_get("T.ids()[1]"), "file:.hidden-ignored.log")
  eq(child.lua_get("T.current()"), id)
  eq(child.lua_get("T.picker().list:is_selected(T.picker():current())"), true)
end

T["previews asynchronously at the occurrence line"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  -- The read is debounced, so the preview cannot change synchronously.
  local before = child.lua_get([[(function()
    T.go("occurrence:2:0:6:repeated.txt")
    T.picker():show_preview()
    local buf = T.picker().preview.win.buf
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)()]])
  eq(vim.tbl_contains(before, "needle at start"), false)
  wait_for([[vim.tbl_contains(vim.api.nvim_buf_get_lines(
    T.picker().preview.win.buf, 0, -1, false), "needle at start")]])
  local cursor =
    child.lua_get("vim.api.nvim_win_get_cursor(T.picker().preview.win.win)")
  eq(cursor[1], 3)
  -- The title survives the asynchronous read and later title redraws.
  local preview_title = child.lua_get([[(function()
    T.picker():update_titles()
    local win = T.picker().preview.win.win
    local parts = {}
    for _, chunk in ipairs(vim.api.nvim_win_get_config(win).title) do
      table.insert(parts, chunk[1])
    end
    return table.concat(parts)
  end)()]])
  -- Plain text naming the file and the occurrence's line.
  match(preview_title, " repeated%.txt:3 $")
end

T["preview refuses binary files"] = function()
  open({ mode = "files", query = "binary-late", case = "sensitive" })
  child.lua("T.go('file:binary-late-nul.dat')")
  wait_for([[vim.api.nvim_buf_get_lines(T.picker().preview.win.buf, 0, 1,
    false)[1] == "Binary file: no preview."]])
end

-- Chained filters ---------------------------------------------------------

---Go to the next step and wait until it shows its first results.
local function chain_next(query)
  local mode = child.lua_get("T.session:snapshot().request.mode")
  local next_mode = mode == "files" and "content" or "files"
  child.type_keys("<C-g>")
  wait_for("T.session:snapshot().request.mode == ...", { next_mode })
  if query then
    type_query(query)
  end
  settled()
end

T["a chained step searches exactly the previous step's files"] = function()
  open({ mode = "files", query = "bulk-1" })
  local named = child.lua_get("T.paths('files')")
  -- More files than the list shows, all within the quota.
  eq(#named > 60 and #named < 200, true)
  eq(child.lua_get("T.session:snapshot().files.lane.state"), "complete")
  chain_next("bulkmark")
  eq(child.lua_get("T.session:snapshot().request.mode"), "content")
  eq(child.lua_get("T.paths('content')"), named)
  eq(title(), (" Files: bulk-1 (%d) › Contains: bulkmark "):format(#named))
end

T["a truncated file step discloses what it hands over"] = function()
  open({ mode = "files", query = "bulk" })
  chain_next("bulkmark")
  rendered("Searching the best 200 of 240 files by name%.")
  eq(#child.lua_get("T.paths('content')"), 200)
end

T["going back restores the previous step"] = function()
  open({ mode = "files", query = "needle", case = "sensitive" })
  local before = child.lua_get("T.ids()")
  chain_next("needle")
  eq(child.lua_get("T.paths('content')"), { "needle-both.txt" })
  child.type_keys("<C-o>")
  wait_for("T.session:snapshot().request.mode == 'files'")
  settled()
  eq(child.lua_get("T.query_line()"), "needle")
  eq(child.lua_get("T.ids()"), before)
  eq(child.lua_get("T.session:snapshot().request.within"), vim.NIL)
  eq(title(), " Find files · case ")
  -- Backspace on an empty prompt goes back too.
  chain_next()
  eq(child.lua_get("T.query_line()"), "")
  child.type_keys("<BS>")
  wait_for("T.session:snapshot().request.mode == 'files'")
  eq(child.lua_get("T.query_line()"), "needle")
end

T["content results narrow by name in the next step"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  local found = child.lua_get("T.paths('content')")
  chain_next()
  -- An empty query lists every file of the previous step.
  eq(child.lua_get("T.paths('files')"), found)
  type_query("unicode")
  settled()
  eq(child.lua_get("T.paths('files')"), { "unicode.txt" })
  chain_next("needle")
  eq(child.lua_get("T.paths('content')"), { "unicode.txt" })
  match(title(), "^ Contains: needle %(%d+%) › Files: unicode %(1%) › ")
end

T["refuses to chain without results"] = function()
  open({ mode = "content" })
  child.type_keys("<C-g>")
  rendered("Type the text to search for first%.")
  eq(child.lua_get("T.session:snapshot().request.mode"), "content")
end

T["a glob step hands over the glob, not the listing"] = function()
  open({ mode = "files" })
  stub_input("bulk/**")
  child.type_keys("<A-g>")
  wait_for("T.session:snapshot().request.glob == 'bulk/**'")
  settled()
  chain_next("bulkmark")
  local request = child.lua_get("T.session:snapshot().request")
  eq(request.glob, "bulk/**")
  eq(request.within, nil)
  match(title(), "^ Files: bulk/%*%* %(240%) › Contains: bulkmark ")
end

T["chaining from an empty Find files searches every eligible file"] = function()
  local eligible = #fixture.eligible(manifest(), false, false)
  open({ mode = "files" })
  -- src/main.lua is eligible but not among the 200 rows listed.
  eq(vim.tbl_contains(child.lua_get("T.ids()"), "file:src/main.lua"), false)
  chain_next("needle")
  eq(child.lua_get("T.session:snapshot().request.within"), vim.NIL)
  eq(
    vim.tbl_contains(child.lua_get("T.paths('content')"), "src/main.lua"),
    true
  )
  local crumb = (" Files (%d) › Contains: needle "):format(eligible)
  eq(title(), crumb)
end

T["resume restores controls, the chain, and the cursor record"] = function()
  open({ mode = "files", query = "needle", case = "sensitive", hidden = true })
  chain_next("needle")
  child.lua("T.go(...)", { "occurrence:0:0:6:needle-both.txt" })
  close_picker()
  child.lua("T.session = require('iara.features.search').resume()")
  settled()
  eq(child.lua_get("T.query_line()"), "needle")
  match(title(), "^ Files: needle %(%d%) › Contains: needle · hidden ")
  eq(child.lua_get("T.current()"), "occurrence:0:0:6:needle-both.txt")
  child.type_keys("<C-o>")
  wait_for("T.session:snapshot().request.mode == 'files'")
end

T["closing the picker cancels the session"] = function()
  open({ mode = "content", query = "bulkmark" })
  close_picker()
  child.lua("T.session:update({ query = 'needle' })")
  eq(child.lua_get("T.session:snapshot().request.query"), "bulkmark")
end

T["creates the picker without FileType events, keeping filetypes"] = function()
  child.lua([[
    vim.o.eventignore = "CursorHold"
    _G.filetype_events = {}
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "snacks_*",
      callback = function(args)
        table.insert(_G.filetype_events, args.match)
      end,
    })
  ]])
  open({ mode = "content", query = "needle" })
  eq(child.lua_get("_G.filetype_events"), {})
  eq(child.o.eventignore, "CursorHold")
  eq(
    child.lua_get("vim.bo[T.picker().list.win.buf].filetype"),
    "snacks_picker_list"
  )
end

T["reports a missing snacks.nvim and closes the session"] = function()
  child.lua("vim.opt.runtimepath:remove(...)", { snacks_dir() })
  child.lua([[
    _G.notes = {}
    vim.notify = function(message, level)
      table.insert(_G.notes, { message, level })
    end
  ]])
  child.lua("T.open({ query = 'needle' })")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  match(notes[1][1], "^Iara: search needs snacks%.nvim")
  eq(notes[1][2], vim.log.levels.ERROR)
  child.lua("T.session:update({ query = 'other' })")
  eq(child.lua_get("T.session:snapshot().request.query"), "needle")
end

-- Normal mode (UX4) -------------------------------------------------------

local function mode()
  return child.api.nvim_get_mode().mode
end

local function normal_mode()
  child.type_keys("<Esc>")
  wait_for("vim.api.nvim_get_mode().mode == 'n'")
end

local function cursor_col()
  return child.lua_get("vim.api.nvim_win_get_cursor(0)[2]")
end

local function footer()
  return child.lua_get([[(function()
    local list = T.picker().list.win.win
    local parts = {}
    for _, chunk in ipairs(vim.api.nvim_win_get_config(list).footer) do
      table.insert(parts, chunk[1])
    end
    return table.concat(parts)
  end)()]])
end

---Occurrence rows in display order.
local function occurrence_rows()
  return vim.tbl_filter(function(id)
    return vim.startswith(id, "occurrence:")
  end, child.lua_get("T.ids()"))
end

T["a search reopened over an open one starts in Insert mode"] = function()
  open({ mode = "files", query = "needle" })
  for _ = 1, 3 do
    -- Closing the open picker and opening the next in one call.
    child.lua("T.open(...)", { { mode = "files", query = "needle" } })
    vim.wait(300)
    eq(mode(), "i")
    eq(child.bo.filetype, "snacks_picker_input")
  end
end

T["Esc leaves Insert mode and keeps the picker open"] = function()
  open({ mode = "files", query = "needle", case = "sensitive" })
  eq(mode(), "i")
  match(footer(), "^ ⏎ open · C%-g grep files ")
  normal_mode()
  eq(child.lua_get("T.picker() ~= nil"), true)
  eq(child.bo.filetype, "snacks_picker_input")
  match(child.lua_get("T.status()"), "^ NORMAL  2 files")
  match(child.wo.statuscolumn, "❮")
  match(
    footer(),
    "^ j/k move · i insert · ⏎ open · q close · C%-g grep files "
  )
  child.type_keys("i")
  eq(mode(), "i")
  eq(child.lua_get("T.status()"), "2 files ")
  match(child.wo.statuscolumn, "❯")
  match(footer(), "^ ⏎ open · C%-g grep files ")
end

T["the list window conceals nothing"] = function()
  -- Conceal on made every drawn list line call Tree-sitter's
  -- conceal-line callback (S11); the rows conceal nothing.
  open({ mode = "files", query = "needle", case = "sensitive" })
  eq(child.lua_get("vim.wo[T.picker().list.win.win].conceallevel"), 0)
end

T["j, k, counts, gg, G, and paging move over records only"] = function()
  open({ mode = "content", query = "needle", case = "sensitive" })
  local rows = occurrence_rows()
  eq(#rows > 6, true)
  normal_mode()
  local function after(keys, expected)
    child.type_keys(keys)
    eq(child.lua_get("T.current()"), expected)
  end
  after("j", rows[2])
  after("k", rows[1])
  -- The group headers between them are not counted.
  after("3j", rows[4])
  after("G", rows[#rows])
  after("j", rows[1])
  after("k", rows[#rows])
  after("gg", rows[1])
  after("<Down>", rows[2])
  after("<Up>", rows[1])
  after("H", rows[1])
  child.type_keys("<C-d>")
  local down = vim.fn.index(rows, child.lua_get("T.current()")) + 1
  eq(down > 1, true)
  child.type_keys("<C-u>")
  local up = vim.fn.index(rows, child.lua_get("T.current()")) + 1
  eq(up >= 1 and up < down, true)
  -- `Ctrl-f` pages the list (not the preview) in Normal mode.
  child.type_keys("gg", "<C-f>")
  local paged = child.lua_get("T.current()")
  eq(vim.tbl_contains(rows, paged) and paged ~= rows[1], true)
  child.type_keys("L")
  eq(vim.tbl_contains(rows, child.lua_get("T.current()")), true)
  eq(mode(), "n")
end

T["i, a, A, I, and / return to Insert mode keeping the query"] = function()
  open({ mode = "files", query = "needle", case = "sensitive" })
  -- `i` returns where Insert mode was left, here two bytes before the end.
  child.type_keys("<Left>", "<Left>")
  normal_mode()
  child.type_keys("i")
  eq(mode(), "i")
  eq(cursor_col(), #"needle" - 2)
  for _, key in ipairs({ "a", "A", "/" }) do
    normal_mode()
    child.type_keys(key)
    eq(mode(), "i")
    eq(cursor_col(), #"needle")
  end
  normal_mode()
  child.type_keys("I")
  eq(mode(), "i")
  eq(cursor_col(), 0)
  child.type_keys("x")
  wait_for("T.session:snapshot().request.query == 'xneedle'")
  eq(child.lua_get("T.query_line()"), "xneedle")
end

T["q and a second Esc close the picker"] = function()
  for _, keys in ipairs({ { "q" }, { "<Esc>" } }) do
    open({ mode = "files", query = "needle" })
    normal_mode()
    child.type_keys(unpack(keys))
    wait_for("T.picker() == nil")
    eq(child.bo.filetype ~= "snacks_picker_input", true)
  end
end

T["Enter, o, and l open the record at its position"] = function()
  local request = { mode = "content", query = "needle", case = "sensitive" }
  for _, key in ipairs({ "<CR>", "o", "l" }) do
    open(request)
    normal_mode()
    child.lua("T.go(...)", { "occurrence:0:7:13:unicode.txt" })
    child.type_keys(key)
    wait_for("T.picker() == nil and vim.bo.filetype ~= 'snacks_picker_input'")
    match(child.api.nvim_buf_get_name(0), "/unicode%.txt$")
    eq(child.api.nvim_win_get_cursor(0), { 1, 7 })
    eq(mode(), "n")
  end
end

T["v and s open the record in a split"] = function()
  local request = { mode = "files", query = "unicode", case = "sensitive" }
  for _, case in ipairs({ { "v", "row" }, { "s", "col" } }) do
    child.cmd("only")
    open(request)
    normal_mode()
    child.type_keys(case[1])
    wait_for("T.picker() == nil")
    eq(child.fn.winlayout()[1], case[2])
    match(child.api.nvim_buf_get_name(0), "/unicode%.txt$")
  end
  child.cmd("only")
end

T["Ctrl-g and Ctrl-o chain steps in Normal mode"] = function()
  open({ mode = "files", query = "needle", case = "sensitive" })
  normal_mode()
  child.type_keys("<C-g>")
  wait_for("T.session:snapshot().request.mode == 'content'")
  eq(mode(), "n")
  match(footer(), "C%-o back")
  child.type_keys("<C-o>")
  wait_for("T.session:snapshot().request.mode == 'files'")
  settled()
  eq(child.lua_get("T.query_line()"), "needle")
  eq(child.lua_get("T.picker() ~= nil"), true)
end

T["a record reached in Normal mode keeps the cursor after updates"] = function()
  local id = "file:keep.log"
  open({ mode = "files", query = "log", hidden = true })
  eq(child.lua_get("T.current()"), id)
  normal_mode()
  child.type_keys("j")
  eq(child.lua_get("T.current()") ~= id, true)
  child.type_keys("k")
  eq(child.lua_get("T.current()"), id)
  child.type_keys("<A-i>")
  wait_for("T.session:snapshot().request.ignored == true")
  settled()
  eq(child.lua_get("T.ids()[1]"), "file:.hidden-ignored.log")
  eq(child.lua_get("T.current()"), id)
end

---Outer frames of the results box and the preview window.
local function panes()
  return child.lua_get([[(function()
    local picker = T.picker()
    local function frame(win)
      local config = vim.api.nvim_win_get_config(win)
      return {
        row = config.row, col = config.col,
        width = config.width, height = config.height,
      }
    end
    return {
      list = T.results_frame(picker),
      preview = frame(picker.preview.win.win),
    }
  end)()]])
end

---Inner width of one box spanning both panes and their borders.
local function frames_width(frames)
  return frames.list.width + frames.preview.width + 2
end

---Characters of a border given as `{ char, group }` cells.
local function border_chars(border)
  return vim.tbl_map(function(cell)
    return cell[1]
  end, border)
end

---Distinct groups of a border given as `{ char, group }` cells.
local function border_groups(border)
  local seen = {}
  for _, cell in ipairs(border) do
    seen[cell[2]] = true
  end
  return vim.tbl_keys(seen)
end

T["the panes have straight frames joined at the prompt"] = function()
  open({ mode = "files", query = "needle" })
  local frames = child.lua_get([[(function()
    local picker = T.picker()
    local function config(win)
      return vim.api.nvim_win_get_config(win.win)
    end
    return {
      input = config(picker.input.win),
      list = config(picker.list.win),
      preview = config(picker.preview.win),
    }
  end)()]])
  -- The prompt draws the top edge and a separator joined to the sides.
  eq(
    border_chars(frames.input.border),
    { "┌", "─", "┐", "│", "┤", "─", "├", "│" }
  )
  eq(
    border_chars(frames.list.border),
    { "", "", "", "│", "┘", "─", "└", "│" }
  )
  eq(
    border_chars(frames.preview.border),
    { "┌", "─", "┐", "│", "┘", "─", "└", "│" }
  )
  eq(frames.input.title_pos, "left")
  -- Hidden and shown again, the preview keeps its frame.
  normal_mode()
  child.type_keys("p")
  wait_for("not T.picker().preview.win:valid()")
  child.type_keys("p")
  wait_for("T.picker().preview.win:valid()")
  local preview = "vim.api.nvim_win_get_config(T.picker().preview.win.win)"
  eq(child.lua_get(preview .. ".border[1][1]"), "┌")
end

---Border groups of the results frame and the preview, and the group of
---the dash that starts each title.
local function frame_groups()
  return child.lua_get([[(function()
    local picker = T.picker()
    local function frame(win)
      local config = vim.api.nvim_win_get_config(win.win)
      local title = config.title or {}
      return { border = config.border, dash = title[1] and title[1][2] }
    end
    return {
      input = frame(picker.input.win),
      list = vim.api.nvim_win_get_config(picker.list.win.win).border,
      preview = frame(picker.preview.win),
    }
  end)()]])
end

T["focus is the border color and follows the focused pane"] = function()
  open({ mode = "files", query = "needle" })
  wait_for("T.picker().preview.win:valid()")
  -- The prompt has the focus: the results frame is `border_focus`, the
  -- preview's frame the idle `border`, titles' dashes included.
  local frames = frame_groups()
  eq(border_groups(frames.input.border), { "IaraSearchBorderFocus" })
  eq(border_groups(frames.list), { "IaraSearchBorderFocus" })
  eq(border_groups(frames.preview.border), { "IaraSearchBorder" })
  eq(frames.input.dash, "IaraSearchBorderFocus")
  child.lua("vim.api.nvim_set_current_win(T.picker().preview.win.win)")
  frames = frame_groups()
  eq(border_groups(frames.input.border), { "IaraSearchBorder" })
  eq(border_groups(frames.list), { "IaraSearchBorder" })
  eq(border_groups(frames.preview.border), { "IaraSearchBorderFocus" })
  eq(frames.input.dash, "IaraSearchBorder")
  -- A preview title, once drawn, starts with a dash in its frame color.
  local dash = frames.preview.dash
  eq(dash == nil or dash == "IaraSearchBorderFocus", true)
end

T["the list and the preview are equal panes"] = function()
  for _, columns in ipairs({ 120, 121 }) do
    child.o.columns = columns
    open({ mode = "files", query = "needle" })
    local frames = panes()
    eq(frames.list.width, frames.preview.width)
    eq(frames.list.height, frames.preview.height)
    eq(frames.list.row, frames.preview.row)
    -- Side by side, their borders touching.
    eq(frames.preview.col, frames.list.col + frames.list.width + 2)
  end
  -- Without the preview (`p`), the list takes both halves.
  local both = frames_width(panes())
  normal_mode()
  child.type_keys("p")
  wait_for("not T.picker().preview.win:valid()")
  local box = child.lua_get("T.results_frame(T.picker())")
  eq(box.width, both)
  child.type_keys("p")
  wait_for("T.picker().preview.win:valid()")
  child.o.columns = 100
  open({ mode = "files", query = "needle" })
  local frames = panes()
  eq(frames.list.width, frames.preview.width)
  eq(frames.list.height, frames.preview.height)
  eq(frames.preview.row, frames.list.row + frames.list.height + 2)
  child.o.columns = 140
end
return T
