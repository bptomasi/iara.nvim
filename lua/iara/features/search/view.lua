--- Presentation of search snapshots (task UX1): picker rows, their
--- highlighted text, the status and notice lines, the title breadcrumb
--- and switch chips, and the key hints of the footer. Pure functions of
--- the snapshot, so they are tested without a picker; `iara.features.
--- search.ui` hands their output to Snacks.
---
--- Text chunks are `{ text, highlight }`; tables with `col` are extmarks
--- relative to the start of the row (Snacks' picker format). Match marks
--- come after the chunks they cover, so at equal priority they win.
---
--- V10 and V13 (design 09 sections 3.3, 3.4, and 7): titles and
--- breadcrumb steps are plain text on the top border, the current step
--- in the accent (`iara.features.picker.layout`), switch chips read
--- `· regex`, the count is in the tide while results stream, file
--- headers carry a count chip, notices are tinted rows, and empty lists
--- show a centered placeholder with the switches that could help.
local chain = require("iara.features.search.chain")
local icons = require("iara.core.icons")
local layout = require("iara.features.picker.layout")
local modal = require("iara.features.picker.modal")

local M = {}

---Highlight groups and the semantic groups they fall back to when the
---colorscheme does not define them (Iara themes define every one).
M.HIGHLIGHTS = {
  IaraSearchCrumbSeparator = "FloatBorder",
  IaraSearchChip = "Special",
  IaraSearchPrompt = "Special",
  IaraSearchCount = "Comment",
  IaraSearchCountBusy = "DiagnosticInfo",
  IaraSearchSpinner = "DiagnosticInfo",
  IaraSearchGroupCount = "Comment",
  IaraSearchDir = "Comment",
  IaraSearchFile = "Normal",
  IaraSearchMatch = "Special",
  IaraSearchLocation = "LineNr",
  IaraSearchText = "Normal",
  IaraSearchTextMatch = "Search",
  IaraSearchGroupFile = "Directory",
  IaraSearchNotice = "DiagnosticWarn",
  IaraSearchError = "DiagnosticError",
  IaraSearchPlaceholder = "Comment",
  IaraSearchFooter = "Comment",
  IaraSearchFooterKey = "Special",
  IaraSearchPreviewLine = "CursorLine",
  IaraSearchPreviewMatch = "Search",
}

-- Notices lead with the diagnostic glyph of their state (design 2.3:
-- one glyph, one meaning); files without devicons get the status line's
-- file glyph.
local ICONS = {
  notice = icons.DIAGNOSTICS.WARN .. " ",
  error = icons.DIAGNOSTICS.ERROR .. " ",
  file = icons.FILE .. " ",
}
local SPINNER =
  { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 80
local LOCATION_WIDTH = 9
local MAX_HINTS = 5

---Define the fallback links without replacing a theme's groups.
function M.define_highlights()
  for name, link in pairs(M.HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  modal.define_highlights()
  layout.define_highlights()
end

-- Paths and icons ---------------------------------------------------------

---Escaped single-line display of raw path bytes.
---@param path string
---@return string
function M.display_path(path)
  return vim.fn.strtrans((path:gsub("\n", "\\n")))
end

local devicons = nil

---File type icon and its highlight; a plain file icon without devicons.
---@param name string Base name.
---@return string icon With a trailing space.
---@return string highlight
local function icon_for(name)
  if devicons == nil then
    local ok, module = pcall(require, "nvim-web-devicons")
    devicons = ok and module or false
  end
  if not devicons then
    return ICONS.file, "IaraSearchDir"
  end
  local extension = name:match("%.([^.]+)$")
  local icon, highlight = devicons.get_icon(name, extension, { default = true })
  return (icon or "") .. " ", highlight or "IaraSearchDir"
end

local ELLIPSIS = "…"

---Directory part shown before the base name, cut at the left to fit
---`room` columns behind an ellipsis.
---@return string shown
---@return integer cut Bytes of `dir` left out.
local function fit_dir(dir, room)
  if #dir <= room then
    return dir, 0
  end
  if room <= 1 then
    return "", #dir
  end
  local cut = #dir - room + 1
  cut = cut + vim.str_utf_end(dir, cut)
  return ELLIPSIS .. dir:sub(cut + 1), cut
end

---Extmarks of the matched bytes still shown after `cut` bytes were left
---out and `offset` bytes come before the path.
local function match_marks(chunks, positions, cut, offset)
  for _, position in ipairs(positions) do
    if position >= cut then
      local col = offset + position - cut
      table.insert(chunks, {
        col = col,
        end_col = col + 1,
        hl_group = "IaraSearchMatch",
      })
    end
  end
end

---Icon, dimmed directory, bright base name, and the bytes the fuzzy
---matcher matched, fitted into `width` columns.
---@param path string Raw path.
---@param positions integer[]|nil Zero-based matched byte offsets.
---@param width integer
---@param file_hl string Highlight of the base name.
---@return table[] chunks
local function path_chunks(path, positions, width, file_hl)
  local shown = M.display_path(path)
  local dir, base = shown:match("^(.*/)([^/]*)$")
  dir, base = dir or "", base or shown
  local icon, icon_hl = icon_for(base)
  local room = width - vim.api.nvim_strwidth(icon .. base) - 1
  local dir_shown, cut = fit_dir(dir, room)
  local chunks = {
    { icon, icon_hl },
    { dir_shown, "IaraSearchDir" },
    { base, file_hl },
  }
  -- Offsets index the raw path, so they apply only to unescaped paths.
  if positions and shown == path then
    local offset = #icon + (cut > 0 and #ELLIPSIS or 0)
    match_marks(chunks, positions, cut, offset)
  end
  return chunks
end

-- Rows ------------------------------------------------------------------

-- Rows carry a stable `text` (Snacks keys selections by it) and empty
-- `positions`, which stops Snacks from highlighting the query as a
-- regex in rows whose matching it did not do.

local SELECTABLE = { file = true, occurrence = true }

local function data_row(id, data)
  return { text = id, positions = {}, iara = data }
end

---@param row table|nil
---@return boolean
function M.is_selectable(row)
  return row ~= nil and row.iara ~= nil and SELECTABLE[row.iara.kind] == true
end

local function shows_files(request)
  return request.mode ~= "content"
end

local function shows_content(request)
  return request.mode ~= "files"
end

---Lanes the snapshot's mode shows, file names first.
---@param snapshot IaraSearchSnapshot
---@return IaraLaneState[]
local function shown_lanes(snapshot)
  local lanes = {}
  if shows_files(snapshot.request) then
    table.insert(lanes, snapshot.files.lane)
  end
  if shows_content(snapshot.request) then
    table.insert(lanes, snapshot.content.lane)
  end
  return lanes
end

local function result_rows(snapshot)
  local rows = {}
  if shows_files(snapshot.request) then
    for _, record in ipairs(snapshot.files.records) do
      table.insert(rows, data_row(record.id, record))
    end
  end
  if not shows_content(snapshot.request) then
    return rows
  end
  for _, group in ipairs(snapshot.content.groups) do
    local data = { kind = "group", path = group.path, count = #group.records }
    table.insert(rows, data_row("group:" .. group.path, data))
    for _, record in ipairs(group.records) do
      table.insert(rows, data_row(record.id, record))
    end
  end
  return rows
end

local function is_busy(snapshot)
  for _, lane in ipairs(shown_lanes(snapshot)) do
    if lane.state == "loading" then
      return true
    end
  end
  return false
end

---Text shown in place of an empty result list.
---@param snapshot IaraSearchSnapshot
---@return string|nil
local function placeholder(snapshot)
  local request = snapshot.request
  if is_busy(snapshot) then
    return "Searching…"
  end
  local lanes = shown_lanes(snapshot)
  for _, lane in ipairs(lanes) do
    if lane.state == "error" or lane.state == "incomplete" then
      return nil
    end
  end
  local idle = #lanes > 0 and lanes[#lanes].state == "idle"
  if idle then
    return request.mode == "content" and "Type to search inside files"
      or "Type to find files by name"
  end
  return request.mode == "content" and "No matches" or "No files match"
end

---Key hints of the switches that could find more after "No matches".
---@param request IaraSearchRequest
---@return string[][] hints `{ key, description }`
local function widening_hints(request)
  local hints = {}
  if not request.hidden then
    table.insert(hints, { "A-h", "hidden" })
  end
  if not request.ignored then
    table.insert(hints, { "A-i", "ignored" })
  end
  return hints
end

local function placeholder_row(text, hints)
  local data = { kind = "placeholder", text = text, hints = hints }
  return data_row("placeholder", data)
end

---The placeholder row of an empty list, with widening hints when the
---search ran and found nothing.
local function empty_row(snapshot)
  local text = placeholder(snapshot)
  if not text then
    return nil
  end
  local found_nothing = text == "No matches" or text == "No files match"
  local hints = found_nothing and widening_hints(snapshot.request) or nil
  local row = placeholder_row(text, hints)
  row.iara.centered = true
  return row
end

---Calm last row of a listing longer than the quota (UX1b).
local function more_files_row(snapshot)
  local lane = snapshot.files.lane
  local listing = snapshot.request.query == ""
  if not listing or lane.state ~= "truncated" then
    return nil
  end
  local more = chain.count_text(lane.total - lane.count)
  return placeholder_row(("%s more; type to narrow"):format(more))
end

---Picker rows of a snapshot: an optional notice, then file names in rank
---order or content groups in arrival order with their locations, or a
---placeholder when there is nothing to show. A listing longer than the
---quota ends with a row counting the files not shown.
---@param snapshot IaraSearchSnapshot
---@param notice { text: string, level: "notice"|"error" }|nil
---@return table[] rows
function M.rows(snapshot, notice)
  local rows = {}
  if notice then
    table.insert(rows, data_row("notice", { kind = "notice", notice = notice }))
  end
  local results = result_rows(snapshot)
  local empty = #results == 0 and empty_row(snapshot)
  if empty then
    table.insert(rows, empty)
  end
  vim.list_extend(rows, results)
  local more = shows_files(snapshot.request) and more_files_row(snapshot)
  if more then
    table.insert(rows, more)
  end
  return rows
end

-- Row text --------------------------------------------------------------

local function occurrence_chunks(record)
  local text = record.text or ""
  local indent = #(text:match("^%s*"))
  local location = ("%d:%d"):format(record.row + 1, record.byte_start + 1)
  local pad = math.max(LOCATION_WIDTH - #location, 1)
  local prefix = ("  %s%s"):format(location, (" "):rep(pad))
  local chunks = {
    { prefix, "IaraSearchLocation" },
    { text:sub(indent + 1), "IaraSearchText" },
  }
  local first = record.byte_start - indent
  if record.text_exact and first >= 0 and record.byte_end <= #text then
    table.insert(chunks, {
      col = #prefix + first,
      end_col = #prefix + record.byte_end - indent,
      hl_group = "IaraSearchTextMatch",
    })
  end
  return chunks
end

---A file header: icon, bold path, and its match count as a chip at the
---right edge.
local function group_chunks(data, width)
  local count = " " .. data.count .. " "
  local room = width - #count - 1
  local chunks = path_chunks(data.path, nil, room, "IaraSearchGroupFile")
  table.insert(chunks, {
    col = 0,
    virt_text = { { count, "IaraSearchGroupCount" } },
    virt_text_pos = "right_align",
  })
  return chunks
end

---A placeholder followed by its key hints: centered in `width` when it
---stands for an empty list, indented like a row otherwise.
local function placeholder_chunks(data, width)
  local chunks = { { data.text, "IaraSearchPlaceholder" } }
  for _, hint in ipairs(data.hints or {}) do
    table.insert(chunks, { "  " .. hint[1], "IaraSearchMatch" })
    table.insert(chunks, { " " .. hint[2], "IaraSearchPlaceholder" })
  end
  local used = 0
  for _, chunk in ipairs(chunks) do
    used = used + vim.api.nvim_strwidth(chunk[1])
  end
  local center = math.floor((width - used) / 2)
  local pad = data.centered and math.max(center, 2) or 2
  table.insert(chunks, 1, { (" "):rep(pad), "IaraSearchPlaceholder" })
  return chunks
end

---A notice with its severity glyph, tinted across the whole row.
local function notice_chunks(notice)
  local error = notice.level == "error"
  local icon = error and ICONS.error or ICONS.notice
  local highlight = error and "IaraSearchError" or "IaraSearchNotice"
  return {
    { icon .. notice.text, highlight },
    { col = 0, line_hl_group = highlight },
  }
end

---Highlighted text of a row, fitted into `width` display columns.
---@param row table
---@param width integer
---@return table[] chunks
function M.format(row, width)
  local data = row.iara
  if data.kind == "file" then
    return path_chunks(data.path, data.positions, width, "IaraSearchFile")
  end
  if data.kind == "occurrence" then
    return occurrence_chunks(data)
  end
  if data.kind == "group" then
    return group_chunks(data, width)
  end
  if data.kind == "placeholder" then
    return placeholder_chunks(data, width)
  end
  return notice_chunks(data.notice)
end

-- Status and notices ----------------------------------------------------

local function plural(count, singular, many)
  local noun = count == 1 and singular or many
  return chain.count_text(count) .. " " .. noun
end

---Whether the file names are a listing (empty query) rather than the
---best matches of a query: every eligible file matches, so the quota is
---a display limit, not a cut of better matches (UX1b).
local function is_listing(snapshot)
  return snapshot.request.query == ""
end

local function files_status(snapshot)
  local lane = snapshot.files.lane
  if lane.state == "idle" then
    return nil
  end
  if is_listing(snapshot) then
    return plural(lane.total, "file", "files")
  end
  if lane.state == "truncated" then
    return ("%d of %s"):format(lane.count, plural(lane.total, "file", "files"))
  end
  return plural(lane.count, "file", "files")
end

local function content_status(snapshot)
  local lane = snapshot.content.lane
  if lane.state == "idle" then
    return nil
  end
  local files = plural(#snapshot.content.groups, "file", "files")
  local matches = plural(lane.count, "match", "matches")
  if lane.state == "truncated" then
    matches = "first " .. matches
  end
  return ("%s in %s"):format(matches, files)
end

---Right-aligned status of the prompt: a spinner while loading, then the
---result count (`37 files`, `200 of 230 files`, `128 matches in 12
---files`). A listing (empty query) counts every file: `1,284 files`.
---@param snapshot IaraSearchSnapshot
---@param now integer Milliseconds, to pick the spinner frame.
---@return table[] chunks
function M.status(snapshot, now)
  local parts = {}
  if shows_files(snapshot.request) then
    table.insert(parts, files_status(snapshot))
  end
  if shows_content(snapshot.request) then
    table.insert(parts, content_status(snapshot))
  end
  local chunks = {}
  local busy = is_busy(snapshot)
  if busy then
    local frame = math.floor(now / SPINNER_MS) % #SPINNER + 1
    table.insert(chunks, { SPINNER[frame] .. " ", "IaraSearchSpinner" })
  end
  if #parts > 0 then
    -- The tide marks flow: the count is still growing.
    local group = busy and "IaraSearchCountBusy" or "IaraSearchCount"
    table.insert(chunks, { table.concat(parts, " · ") .. " ", group })
  end
  return chunks
end

M.is_busy = is_busy

local function truncation_notice(lane, content)
  if lane.error and lane.error.code == "memory" then
    return lane.error.message .. "; refine the search."
  end
  if content then
    local limit = chain.count_text(lane.limit)
    return ("Stopped at %s matches; refine the search."):format(limit)
  end
  local total = chain.count_text(lane.total)
  -- Short enough for the picker's width after the notice glyph.
  return ("Best %d of %s names shown; type to narrow."):format(
    lane.limit,
    total
  )
end

---The one-line notice a lane needs: its error, its incomplete inventory,
---or its truncation; nil when it is fine.
local function lane_notice(lane, content)
  if lane.state == "error" or lane.state == "incomplete" then
    local message = lane.error and lane.error.message or lane.state
    return { text = message, level = "error" }
  end
  if lane.state == "truncated" then
    local text = truncation_notice(lane, content)
    return { text = text, level = "notice" }
  end
end

---Notice of the shown lanes, errors first; nil when there is none.
---@param snapshot IaraSearchSnapshot
---@return { text: string, level: "notice"|"error" }|nil
function M.notice(snapshot)
  local found = nil
  local files = snapshot.files.lane
  local calm = is_listing(snapshot) and files.state == "truncated"
  if shows_files(snapshot.request) and not calm then
    found = lane_notice(files, false)
  end
  if
    shows_content(snapshot.request) and (not found or found.level ~= "error")
  then
    found = lane_notice(snapshot.content.lane, true) or found
  end
  return found
end

-- Title and footer ------------------------------------------------------

---Switches that differ from their defaults, as short chip labels.
---@param request IaraSearchRequest
---@param root_path string
---@return string[]
function M.chips(request, root_path)
  local chips = {}
  if request.hidden then
    table.insert(chips, "hidden")
  end
  if request.ignored then
    table.insert(chips, "ignored")
  end
  if request.regex and request.mode ~= "files" then
    table.insert(chips, "regex")
  end
  if request.case ~= "smart" then
    table.insert(chips, request.case == "sensitive" and "case" or "ignore case")
  end
  local scope = request.scope
  if scope.kind ~= "root" then
    local relative = vim.fs.relpath(root_path, scope.path) or scope.path
    local shown = M.display_path(relative)
    -- (S9) A directory scope reads as its path: `· lua/iara/core/`.
    table.insert(
      chips,
      scope.kind == "file" and "file: " .. shown or shown .. "/"
    )
  end
  return chips
end

local MODE_TITLES = { files = "Find files", content = "Find in files" }

---Plain title of a request's mode (`Find files`, `Find in files`).
---@param request IaraSearchRequest
---@return string
function M.search_title(request)
  return MODE_TITLES[request.mode] or "Search"
end

---Title chunks: the mode title, or the breadcrumb of a chain
---(`Find files › init`: the current step focused unless `focused` is
---false, earlier steps idle), then the chips of non-default switches
---(`· regex`), padded by one space at each end.
---@param labels string[] Breadcrumb labels (chain.crumbs).
---@param request IaraSearchRequest Current request.
---@param root_path string
---@param focused boolean? The results frame has the focus (default).
---@return table[] chunks
function M.title(labels, request, root_path, focused)
  if #labels == 1 then
    local title = MODE_TITLES[request.mode] or "Search"
    labels = {
      request.glob and ("%s: %s"):format(title, M.display_path(request.glob))
        or title,
    }
  end
  local chunks = { { " ", "IaraSearchCrumbSeparator" } }
  for index, label in ipairs(labels) do
    if index > 1 then
      table.insert(chunks, { " › ", "IaraSearchCrumbSeparator" })
    end
    local current = index == #labels and focused ~= false
    table.insert(chunks, { label, layout.title_group(current) })
  end
  for _, chip in ipairs(M.chips(request, root_path)) do
    table.insert(chunks, { " · " .. chip, "IaraSearchChip" })
  end
  table.insert(chunks, { " ", "IaraSearchCrumbSeparator" })
  return chunks
end

---Title chunks of the preview: idle text (focused while the preview
---has the focus) with the file icon and the path, cut at the left to fit
---`width` columns, and `:line` for an occurrence.
---@param record IaraSearchRecord
---@param width integer Width of the preview window.
---@param focused boolean?
---@return table[] chunks
function M.preview_title(record, width, focused)
  local path = M.display_path(record.path)
  local icon = icon_for(path:match("[^/]*$"))
  local line = record.kind == "occurrence" and (":" .. (record.row + 1)) or ""
  -- Corners, the dash, the padding, and a dash after the title.
  local room = width - vim.api.nvim_strwidth(icon .. line) - 6
  local shown = fit_dir(path, math.max(room, 1))
  return layout.title_chunks(icon .. shown .. line, focused == true)
end

---Chain key hints in priority order for the mode and chain depth.
local function chain_hints(mode, depth)
  local list = {}
  if depth > 1 then
    table.insert(list, { "C-o", "back" })
  end
  if mode == "content" then
    table.insert(list, { "C-g", "filter names" })
  else
    table.insert(list, { "C-g", "grep files" })
  end
  return list
end

---Insert mode key hints in priority order.
local function insert_hints(mode, depth)
  local list = { { "⏎", "open" } }
  vim.list_extend(list, chain_hints(mode, depth))
  if mode == "content" then
    table.insert(list, { "A-r", "regex" })
  else
    table.insert(list, { "A-g", "glob" })
  end
  table.insert(list, { "Tab", "select" })
  table.insert(list, { "C-q", "quickfix" })
  return list
end

---Footer chunks: the most useful key hints of the prompt's mode that
---fit in `width` columns (at most five in Insert mode).
---@param mode "files"|"content"|nil
---@param depth integer Chain depth.
---@param width integer
---@param normal boolean? The prompt is in Normal mode (UX4).
---@return table[] chunks
function M.footer(mode, depth, width, normal)
  if not normal then
    local hints = vim.list_slice(insert_hints(mode, depth), 1, MAX_HINTS)
    return modal.footer(hints, width)
  end
  local extra = chain_hints(mode, depth)
  vim.list_extend(extra, { { "Tab", "select" }, { "p", "preview" } })
  return modal.footer(modal.normal_hints(extra), width)
end

return M
