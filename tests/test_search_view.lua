-- Presentation of search snapshots (task UX1): rows, row text, status,
-- notices, chips, and footer hints, without a picker.
local helpers = require("helpers")
local view = require("iara.features.search.view")

local eq = MiniTest.expect.equality

local match = helpers.expect_match

local function request(fields)
  return vim.tbl_extend("force", {
    query = "",
    hidden = false,
    ignored = false,
    regex = false,
    case = "smart",
    scope = { kind = "root" },
  }, fields or {})
end

local function lane(state, count, total)
  return {
    state = state,
    count = count or 0,
    total = total or count or 0,
    limit = 200,
  }
end

local function snapshot(fields, files, content)
  return {
    request = request(fields),
    root = { path = "/project" },
    generation = 1,
    files = files or { lane = lane("idle"), records = {} },
    content = content or { lane = lane("idle"), groups = {} },
  }
end

local function file_record(path, positions)
  return {
    id = "file:" .. path,
    kind = "file",
    path = path,
    positions = positions,
  }
end

local function occurrence(path, row, first, last, text)
  return {
    id = ("occurrence:%d:%d:%d:%s"):format(row, first, last, path),
    kind = "occurrence",
    path = path,
    row = row,
    byte_start = first,
    byte_end = last,
    text = text,
    text_exact = true,
  }
end

---Plain text of formatted chunks.
local function text_of(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    if type(chunk[1]) == "string" then
      table.insert(parts, chunk[1])
    end
  end
  return table.concat(parts)
end

local function marks(chunks, group)
  local found = {}
  for _, chunk in ipairs(chunks) do
    if chunk.hl_group == group then
      table.insert(found, { chunk.col, chunk.end_col })
    end
  end
  return found
end

local T = MiniTest.new_set()

T["an idle step shows only a placeholder"] = function()
  local rows = view.rows(snapshot({ mode = "files" }))
  eq(#rows, 1)
  eq(rows[1].iara.text, "Type to find files by name")
  eq(view.is_selectable(rows[1]), false)
  rows = view.rows(snapshot({ mode = "content" }))
  eq(rows[1].iara.text, "Type to search inside files")
  eq(view.status(snapshot({ mode = "files" }), 0), {})
end

T["file names show directory, base name, and matched bytes"] = function()
  local record = file_record("src/hooks/useFetch.ts", { 10, 11, 12 })
  local chunks = view.format({ iara = record }, 80)
  match(text_of(chunks), "src/hooks/useFetch%.ts$")
  local dir_chunk = chunks[2]
  eq({ dir_chunk[1], dir_chunk[2] }, { "src/hooks/", "IaraSearchDir" })
  eq({ chunks[3][1], chunks[3][2] }, { "useFetch.ts", "IaraSearchFile" })
  local prefix = #chunks[1][1]
  eq(marks(chunks, "IaraSearchMatch"), {
    { prefix + 10, prefix + 11 },
    { prefix + 11, prefix + 12 },
    { prefix + 12, prefix + 13 },
  })
end

T["long directories are cut at the left, keeping the base name"] = function()
  local path = "a/very/long/directory/chain/that/does/not/fit/name.lua"
  local record = file_record(path, { #path - 8 })
  local chunks = view.format({ iara = record }, 30)
  local text = text_of(chunks)
  match(text, "….*/fit/name%.lua$")
  local mark = marks(chunks, "IaraSearchMatch")[1]
  eq(text:sub(mark[1] + 1, mark[2]), "n")
end

T["occurrences show a muted location and the marked match"] = function()
  local record = occurrence("a.ts", 11, 4, 13, "    useEffect(() => {})")
  local chunks = view.format({ iara = record }, 80)
  local text = text_of(chunks)
  match(text, "^  12:5%s+useEffect%(")
  local mark = marks(chunks, "IaraSearchTextMatch")[1]
  eq(text:sub(mark[1] + 1, mark[2]), "useEffect")
  record.text_exact = false
  eq(marks(view.format({ iara = record }, 80), "IaraSearchTextMatch"), {})
end

T["content rows group occurrences under a file header"] = function()
  local groups = {
    {
      path = "src/a.ts",
      records = {
        occurrence("src/a.ts", 0, 0, 1, "x"),
        occurrence("src/a.ts", 3, 0, 1, "x"),
      },
    },
  }
  local s = snapshot(
    { mode = "content", query = "x" },
    nil,
    { lane = lane("complete", 2), groups = groups }
  )
  local rows = view.rows(s)
  eq(rows[1].text, "group:src/a.ts")
  eq(view.is_selectable(rows[1]), false)
  eq(view.is_selectable(rows[2]), true)
  local header = view.format(rows[1], 60)
  eq(header[#header].virt_text, { { " 2 ", "IaraSearchGroupCount" } })
  eq(text_of(view.status(s, 0)), "2 matches in 1 file ")
end

T["status counts files and shows a spinner while loading"] = function()
  local records = { file_record("a"), file_record("b") }
  local loading = snapshot(
    { mode = "files", query = "a" },
    { lane = lane("loading", 2), records = records }
  )
  local chunks = view.status(loading, 0)
  eq(chunks[1][2], "IaraSearchSpinner")
  eq({ chunks[2][1], chunks[2][2] }, { "2 files ", "IaraSearchCountBusy" })
  -- Done: the count turns muted and the spinner is gone.
  loading.files.lane.state = "complete"
  eq(view.status(loading, 0), { { "2 files ", "IaraSearchCount" } })
  local truncated = snapshot(
    { mode = "files", query = "a" },
    { lane = lane("truncated", 200, 1234), records = records }
  )
  eq(text_of(view.status(truncated, 0)), "200 of 1,234 files ")
end

T["a listing shows a calm total and counts the rows not shown"] = function()
  local records = { file_record("a"), file_record("b") }
  local listing = snapshot(
    { mode = "files" },
    { lane = lane("truncated", 200, 1284), records = records }
  )
  eq(text_of(view.status(listing, 0)), "1,284 files ")
  eq(view.notice(listing), nil)
  local rows = view.rows(listing, view.notice(listing))
  eq(#rows, 3)
  eq(rows[1].text, "file:a")
  eq(rows[3].iara.text, "1,084 more; type to narrow")
  eq(view.is_selectable(rows[3]), false)
  -- While the walk runs, the count grows with the files listed so far.
  local loading = snapshot(
    { mode = "files" },
    { lane = lane("loading", 2, 37), records = records }
  )
  eq(view.status(loading, 0)[2][1], "37 files ")
  eq(#view.rows(loading), 2)
end

T["notices disclose truncation and errors in one line"] = function()
  local truncated = snapshot(
    { mode = "files", query = "a" },
    { lane = lane("truncated", 200, 950), records = {} }
  )
  eq(view.notice(truncated), {
    text = "Best 200 of 950 names shown; type to narrow.",
    level = "notice",
  })
  local failed_lane = lane("error")
  failed_lane.error = { code = "regex", message = "invalid regex: (" }
  local failed = snapshot(
    { mode = "content", query = "(" },
    nil,
    { lane = failed_lane, groups = {} }
  )
  eq(view.notice(failed), { text = "invalid regex: (", level = "error" })
  local rows = view.rows(failed, view.notice(failed))
  eq(#rows, 1)
  eq(rows[1].iara.kind, "notice")
  -- A content step does not report the idle file name lane, and vice
  -- versa.
  eq(view.notice(snapshot({ mode = "content", query = "x" })), nil)
end

T["chips name only switches that differ from their defaults"] = function()
  eq(view.chips(request({ mode = "files" }), "/p"), {})
  eq(
    view.chips(request({ mode = "files", hidden = true, regex = true }), "/p"),
    { "hidden" }
  )
  local all = request({
    mode = "content",
    hidden = true,
    ignored = true,
    regex = true,
    case = "insensitive",
    scope = { kind = "directory", path = "/p/src" },
  })
  eq(view.chips(all, "/p"), {
    "hidden",
    "ignored",
    "regex",
    "ignore case",
    "src/",
  })
end

T["titles name the mode or the breadcrumb"] = function()
  local title = view.title({ "x" }, request({ mode = "files" }), "/p")
  eq(text_of(title), " Find files ")
  eq(title[2][2], "IaraSearchTitle")
  title = view.title({ "x" }, request({ mode = "files", glob = "*.ts" }), "/p")
  eq(text_of(title), " Find files: *.ts ")
  -- With the preview focused the title is idle (muted).
  title = view.title({ "x" }, request({ mode = "files" }), "/p", false)
  eq(title[2][2], "IaraSearchCrumb")
  title = view.title(
    { "Files: test (5)", "Contains: x" },
    request({ mode = "content", ignored = true }),
    "/p"
  )
  eq(text_of(title), " Files: test (5) › Contains: x · ignored ")
  eq(title[2][2], "IaraSearchCrumb")
  eq(title[4][2], "IaraSearchTitle")
  eq(title[5][2], "IaraSearchChip")
end

T["the footer keeps the most useful hints that fit"] = function()
  local wide = text_of(view.footer("files", 1, 120))
  eq(
    wide,
    " ⏎ open · C-g grep files · A-g glob · Tab select · C-q quickfix "
  )
  local chained = text_of(view.footer("content", 2, 120))
  match(chained, "^ ⏎ open · C%-o back · C%-g filter names ")
  local narrow = text_of(view.footer("files", 1, 30))
  eq(narrow, " ⏎ open · C-g grep files ")
end

T["the Normal mode footer leads with the list keys"] = function()
  local wide = text_of(view.footer("files", 1, 120, true))
  eq(
    wide,
    " j/k move · i insert · ⏎ open · q close · C-g grep files"
      .. " · Tab select · p preview "
  )
  local chained = text_of(view.footer("content", 2, 120, true))
  match(chained, " q close · C%-o back · C%-g filter names ")
  local narrow = text_of(view.footer("files", 1, 40, true))
  eq(narrow, " j/k move · i insert · ⏎ open ")
end

T["no matches is centered and offers the switches still off"] = function()
  local s = snapshot(
    { mode = "content", query = "zzz", hidden = true },
    nil,
    { lane = lane("complete", 0), groups = {} }
  )
  local rows = view.rows(s)
  eq(#rows, 1)
  local chunks = view.format(rows[1], 40)
  eq(text_of(chunks), "        No matches  A-i ignored")
  eq(chunks[3][2], "IaraSearchMatch")
  -- An idle step has no hints to offer.
  local idle = view.format(view.rows(snapshot({ mode = "files" }))[1], 40)
  eq(vim.trim(text_of(idle)), "Type to find files by name")
end

T["notices tint their whole row by severity"] = function()
  local notice = { text = "invalid regex", level = "error" }
  local s = snapshot({ mode = "content", query = "(" })
  local chunks = view.format(view.rows(s, notice)[1], 60)
  eq(chunks[1][2], "IaraSearchError")
  eq(chunks[2].line_hl_group, "IaraSearchError")
end

T["notices lead with their state's glyph in the state color"] = function()
  local glyphs = require("iara.core.icons").DIAGNOSTICS
  local s = snapshot({ mode = "content", query = "(" })
  local cases = {
    { "error", glyphs.ERROR, "IaraSearchError" },
    { "notice", glyphs.WARN, "IaraSearchNotice" },
  }
  for _, case in ipairs(cases) do
    local notice = { text = "invalid regex", level = case[1] }
    local chunks = view.format(view.rows(s, notice)[1], 60)
    eq(chunks[1], { case[2] .. " invalid regex", case[3] })
  end
end

-- V10 picker groups: the surface their text sits on ("bg" is the
-- group's own) and the contrast it needs (3:1 for glyphs).
local READABLE = {
  { "IaraSearchTitle", "bg", 4.5 },
  { "IaraSearchCrumb", "bg", 4.5 },
  { "IaraSearchCountBusy", "mantle", 4.5 },
  { "IaraSearchSpinner", "mantle", 3 },
  { "IaraSearchChip", "mantle", 4.5 },
  { "IaraSearchGroupCount", "bg", 4.5 },
  { "IaraSearchNotice", "bg", 4.5 },
  { "IaraSearchError", "bg", 4.5 },
  { "IaraSearchTextMatch", "bg", 4.5 },
  { "IaraSearchFile", "overlay", 4.5 },
  { "IaraSearchDir", "overlay", 4.5 },
  { "IaraSearchSelectionBar", "bg", 3 },
  { "IaraSearchPreviewMatch", "accent_soft", 4.5 },
  { "IaraThemeMark", "overlay", 3 },
  { "IaraThemeType", "mantle", 4.5 },
  { "IaraSelectKey", "mantle", 4.5 },
  { "IaraSelectText", "mantle", 4.5 },
}

T["picker groups are readable in every palette"] = function()
  local theme = require("iara.theme")
  local hl = require("iara.theme.highlights")
  local roles = require("iara.theme.roles")
  local failures = {}
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, r = hl.resolve(palette), roles.resolve(palette)
    for _, entry in ipairs(READABLE) do
      local spec = groups[entry[1]]
      local surface = entry[2] == "bg" and spec.bg or r[entry[2]]
      local ratio = hl.contrast(spec.fg, surface)
      if ratio < entry[3] then
        table.insert(failures, ("%s %s %.2f"):format(name, entry[1], ratio))
      end
    end
  end
  eq(failures, {})
end

T["the preview title is plain text cut at the left with the line"] = function()
  local record = occurrence("src/deep/path/file.ts", 4, 0, 1, "x")
  local title = text_of(view.preview_title(record, 80))
  eq(vim.endswith(title, " src/deep/path/file.ts:5 "), true)
  eq(view.preview_title(record, 80)[1][2], "IaraSearchCrumb")
  local narrow = text_of(view.preview_title(record, 24))
  eq(narrow:find("…", 1, true) ~= nil, true)
  eq(vim.endswith(narrow, "/file.ts:5 "), true)
  -- Corners, the dash before the title, and one after it stay free.
  eq(vim.api.nvim_strwidth(narrow) <= 24 - 4, true)
  local focused = view.preview_title(file_record("a.ts"), 80, true)
  eq(focused[1][2], "IaraSearchTitle")
end

return T
