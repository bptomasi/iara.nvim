--- Preview for Snacks pickers (extracted from the search UI, task S8):
--- a disk file read asynchronously and bounded, or lines the caller
--- already holds, with an optional marked location. See contracts.md,
--- section 9.6, for the preview limits.
---
--- Disk reads of an isolated request start on the next turn of the
--- event loop (S11: the 25 ms wait was most of a single move's preview
--- latency); while requests repeat (a held key), DEBOUNCE_MS after the
--- last one, so most files passed over are never read. They read at most
--- READ_BYTES around the target row (`iara.features.picker.read`), and
--- are abandoned after 250 ms; a newer request or clear() makes an older
--- read publish nothing. A NUL byte marks a binary file, which is not
--- shown. Lines above LINE_BYTES are cut. A window read earlier is shown
--- from the cache once an asynchronous stat confirms the file did not
--- change; otherwise it is read again. When moving within the cached
--- window already on screen, move the mark at once and check the disk
--- after the cursor settles.
---
--- Scrolling (tasks S10, S11): the list must never wait for the preview,
--- and the preview is always highlighted. Content goes into pooled
--- buffers (`iara.features.picker.pool`), so nothing is reset and a
--- window or first screen seen recently comes back as it was. A publish
--- shows the first screen (one window height around the marked row) at
--- once, parsed and highlighted before it is drawn
--- (`iara.features.picker.highlight`); the complete window follows, at
--- once for an isolated request, or once no request came for SETTLE_MS
--- while requests repeat (less than REPEAT_MS apart, a held key), and
--- replaces the screen only after the same rows are parsed, so colors
--- never go away. Buffers get no filetype, so no ftplugin or FileType
--- event runs.
local highlight = require("iara.features.picker.highlight")
local pool = require("iara.features.picker.pool")
local read = require("iara.features.picker.read")

local M = {}

M.DEBOUNCE_MS = 25
M.REPEAT_MS = 100
M.SETTLE_MS = 100

---Groups of the marked line and range (task UX1). Iara themes define
---them; the default links keep other colorschemes working.
local MARK_LINKS = {
  IaraSearchPreviewLine = "CursorLine",
  IaraSearchPreviewMatch = "Search",
}
M.DEADLINE_MS = 250
M.READ_BYTES = read.READ_BYTES
M.LINE_BYTES = read.LINE_BYTES

---@class IaraPreviewTarget
---@field path string? Absolute file to read from disk.
---@field lines string[]? Lines to show at once instead of reading.
---@field filetype string? Highlighting; by default detected from `path`.
---@field row integer? Zero-based line to mark and center.
---@field byte_start integer? Zero-based start of the marked range.
---@field byte_end integer? Exclusive end of the marked range.

---@class IaraPreviewer
---@field token integer Increments with every request; stale reads skip.
---@field closed boolean
---@field moving boolean The last request came within REPEAT_MS.
---@field last_request integer|nil vim.uv.now() of the last request.
---@field shown_window table? Source of the visible buffer.
---@field shown_buf integer?
---@field fresh_timer uv.uv_timer_t? Settled check of an on-screen window.
---@field pool IaraPreviewPool
local Previewer = {}
Previewer.__index = Previewer

---Empty the preview for new content, keeping the title the caller set:
---Snacks' reset() drops it, and an asynchronous read publishes after the
---title was drawn, so a later title redraw would otherwise blank it.
local function reset_content(preview)
  local title = preview.title
  preview:reset()
  preview:set_title(title)
end

local function show_message(preview, message)
  reset_content(preview)
  preview:set_lines({ message })
end

local function set_extmark(preview, row, col, opts)
  local buf = preview.win.buf
  pcall(vim.api.nvim_buf_set_extmark, buf, preview:ns(), row, col, opts)
end

---First line to show so that `line` sits in the middle of `win`,
---counting wrapped lines and virtual lines above it.
local function centered_topline(win, line)
  local half = math.floor((vim.api.nvim_win_get_height(win) - 1) / 2)
  local top, rows = line, 0
  while top > 1 do
    local height = vim.api.nvim_win_text_height(win, {
      start_row = top - 2,
      end_row = top - 2,
    }).all
    if rows + height > half then
      break
    end
    rows, top = rows + height, top - 1
  end
  return top
end

---Put the cursor on `line` (one-based) and center it. Deliberately not
---`normal! zz`: a Normal mode command fires ModeChanged, where
---which-key peeks at pending input, so a `<C-c>` typed while the preview
---is drawn raised "Keyboard interrupt" and left a hit-enter prompt that
---blocked quitting (FU-P3-1). winrestview() changes no mode.
local function center(win, line)
  local topline = centered_topline(win, line)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = line, col = 0, topline = topline })
  end)
end

---Highlight the target's line and range, and center it. `first_row` is
---the file line shown on the first preview line.
local function mark(preview, target, line_count, first_row)
  if target.row == nil then
    return center(preview.win.win, 1)
  end
  local row = target.row - first_row
  if row < 0 or row >= line_count then
    return show_message(preview, "Location is beyond the preview limit.")
  end
  local buf = preview.win.buf
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  set_extmark(preview, row, 0, { line_hl_group = "IaraSearchPreviewLine" })
  if target.byte_start then
    local stop = math.min(target.byte_end or target.byte_start, #line)
    set_extmark(preview, row, target.byte_start, {
      end_col = math.max(stop, target.byte_start),
      hl_group = "IaraSearchPreviewMatch",
    })
  end
  center(preview.win.win, row + 1)
end

---Note above the first line of a window that starts inside the file.
local function mark_skipped(preview, first_row)
  if first_row == 0 then
    return
  end
  local note = ("[lines 1-%d not shown]"):format(first_row)
  set_extmark(preview, 0, 0, {
    virt_lines = { { { note, "Comment" } } },
    virt_lines_above = true,
  })
end

---Lines of the window around the marked row (the top without a row)
---that one window height can show: one height above and below it.
---@return integer first
---@return integer last
local function screen_range(preview, target, window)
  local height = vim.api.nvim_win_get_height(preview.win.win)
  local row = math.max((target.row or 0) - window.first_row, 0) + 1
  local first = math.max(row - height, 1)
  return first, math.min(row + height, #window.lines)
end

function Previewer:is_current(token, preview)
  return self.token == token and not self.closed and preview.win:valid()
end

---Show the entry, then mark and center the target in it.
local function present(self, preview, target, window, entry)
  pool.show(preview, entry)
  self.shown_window, self.shown_buf = window, entry.buf
  vim.api.nvim_buf_clear_namespace(entry.buf, preview:ns(), 0, -1)
  local first_row = window.first_row + entry.first - 1
  mark_skipped(preview, first_row)
  mark(preview, target, entry.last - entry.first + 1, first_row)
end

---@class IaraPreviewRequest
---@field target IaraPreviewTarget
---@field window IaraPreviewWindow|table
---@field first integer First line of the first screen in `window.lines`.
---@field last integer Its last line.
---@field filetype string|nil Detected on first use (`languages`).
---@field lang string|nil Tree-sitter language, when installed.
---@field detected boolean

---The request's filetype and Tree-sitter language, detected once.
local function languages(request)
  if not request.detected then
    request.detected = true
    request.filetype = highlight.filetype(request.target, request.window.lines)
    request.lang = highlight.lang(request.filetype)
  end
  return request.filetype, request.lang
end

---Highlight a filled entry for the request's filetype.
local function attach(entry, request)
  highlight.attach(entry, languages(request))
end

---The first screen of the request, highlighted before it is shown.
function Previewer:first_screen(preview, request)
  local first, last = request.first, request.last
  local filetype = languages(request)
  local shown = preview.win.buf
  local entry = self.pool:screen(request.window, first, last, shown, filetype)
  attach(entry, request)
  highlight.parse(entry, 0, last - first + 1)
  return entry
end

---Fill a complete entry and show it once the rows of the first screen
---are parsed, so it shows the same colors.
function Previewer:complete(preview, request)
  local token, window = self.token, request.window
  local entry = self.pool:take(window, preview.win.buf)
  attach(entry, request)
  highlight.parse(entry, request.first - 1, request.last, function()
    if self:is_current(token, preview) then
      present(self, preview, request.target, window, entry)
    end
  end)
end

---Complete the window after `delay` ms unless a newer request came.
function Previewer:complete_later(preview, request, delay)
  local token = self.token
  vim.defer_fn(function()
    if self:is_current(token, preview) then
      self:complete(preview, request)
    end
  end, delay)
end

---Show `window` (read from disk, or the caller's lines): from the pool
---when it was shown recently; otherwise its first screen, highlighted,
---at once. A first screen is followed by the complete window, SETTLE_MS
---after the last request while the list moves.
function Previewer:publish(preview, target, window)
  local first, last = screen_range(preview, target, window)
  local request = { target = target, window = window, detected = false }
  request.first, request.last = first, last
  local entry = self.pool:find(window, first, last)
    or self:first_screen(preview, request)
  present(self, preview, target, window, entry)
  if entry.first > 1 or entry.last < #window.lines then
    self:complete_later(preview, request, self.moving and M.SETTLE_MS or 0)
  end
end

---@param window IaraPreviewWindow
function Previewer:show_window(preview, target, window)
  if window.binary then
    return show_message(preview, "Binary file: no preview.")
  end
  if window.beyond then
    return show_message(preview, "Location is beyond the preview limit.")
  end
  self:publish(preview, target, window)
end

---Publish a finished read started at `started` (vim.uv.now()).
function Previewer:publish_read(preview, target, started, err, window)
  if vim.uv.now() - started > M.DEADLINE_MS then
    return show_message(preview, "Preview took too long; skipped.")
  end
  if not window then
    return show_message(preview, "Cannot read file: " .. tostring(err))
  end
  self:show_window(preview, target, window)
end

---Read the window of `target` after the debounce; cache it, and publish
---it unless superseded.
function Previewer:read(preview, target, delay)
  local token = self.token
  delay = delay or (self.moving and M.DEBOUNCE_MS or 0)
  vim.defer_fn(function()
    if not self:is_current(token, preview) then
      return
    end
    local started = vim.uv.now()
    read.window(target.path, target.row, function(err, window)
      vim.schedule(function()
        if window then
          read.store(window)
        end
        if self:is_current(token, preview) then
          self:publish_read(preview, target, started, err, window)
        end
      end)
    end)
  end, delay)
end

local function shows(self, preview, window)
  return self.shown_window == window and self.shown_buf == preview.win.buf
end

---Validate cached content before showing it or after moving its mark.
function Previewer:validate_cached(preview, target, window, already_shown)
  local token = self.token
  read.fresh(
    window,
    vim.schedule_wrap(function(fresh)
      if not self:is_current(token, preview) then
        return
      end
      if fresh then
        if not already_shown or not shows(self, preview, window) then
          self:show_window(preview, target, window)
        end
        return
      end
      if read.cached(target.path, target.row) == window then
        read.forget(target.path)
      end
      self:read(preview, target, already_shown and 0 or nil)
    end)
  )
end

---A move within the same displayed snapshot only changes the mark.
function Previewer:show_cached(preview, target, window)
  if not self.moving or not shows(self, preview, window) then
    return self:validate_cached(preview, target, window, false)
  end
  self:show_window(preview, target, window)
  self.fresh_timer = self.fresh_timer or vim.uv.new_timer()
  if not self.fresh_timer then
    return self:validate_cached(preview, target, window, true)
  end
  local token = self.token
  self.fresh_timer:start(
    M.SETTLE_MS,
    0,
    vim.schedule_wrap(function()
      if self:is_current(token, preview) then
        self:validate_cached(preview, target, window, true)
      end
    end)
  )
end

local function clear_pdf(self)
  if self.pdf then
    require("iara.features.pdf.preview").close(self.pdf)
    self.pdf = nil
  end
end

local function is_pdf(path)
  return require("iara.features.pdf").matches(path)
    and vim.g.iara_mode ~= "safe"
    and require("iara.config").enabled("features.pdf")
end

local function show_pdf(self, preview, path)
  show_message(preview, "Loading PDF preview…")
  preview:minimal()
  local token = self.token
  vim.defer_fn(function()
    if self:is_current(token, preview) then
      self.pdf_cache = self.pdf_cache or {}
      self.pdf =
        require("iara.features.pdf.preview").open(preview, path, self.pdf_cache)
    end
  end, self.moving and M.DEBOUNCE_MS or 0)
end

local function supersede(self)
  clear_pdf(self)
  self.token = self.token + 1
  if self.fresh_timer then
    self.fresh_timer:stop()
  end
end

---Count a request; it is part of a movement when the previous one came
---less than REPEAT_MS ago.
function Previewer:request()
  local now = vim.uv.now()
  self.moving = self.last_request ~= nil
    and now - self.last_request < M.REPEAT_MS
  self.last_request = now
  supersede(self)
end

---Show `target` in a Snacks preview: its lines at once, or its file
---after the debounce. Supersedes every earlier request.
---@param preview table Snacks picker preview (`ctx.preview`).
---@param target IaraPreviewTarget
function Previewer:show(preview, target)
  self:request()
  if target.lines then
    local window = { lines = target.lines, first_row = 0, cut = false }
    return self:publish(preview, target, window)
  end
  if type(target.path) ~= "string" then
    error("picker.preview: target needs lines or a path", 2)
  end
  if is_pdf(target.path) then
    return show_pdf(self, preview, target.path)
  end
  local window = read.cached(target.path, target.row)
  if window then
    return self:show_cached(preview, target, window)
  end
  self:read(preview, target)
end

---Empty the preview and drop pending reads, for rows without a target.
---@param preview table Snacks picker preview.
function Previewer:clear(preview)
  supersede(self)
  self.shown_window, self.shown_buf = nil, nil
  preview:reset()
end

---Stop publishing; pending reads are dropped and the pooled buffers
---deleted. Idempotent.
function Previewer:close()
  clear_pdf(self)
  if self.pdf_cache then
    require("iara.features.pdf.preview").close_cache(self.pdf_cache)
    self.pdf_cache = nil
  end
  self.closed = true
  if self.fresh_timer then
    self.fresh_timer:close()
    self.fresh_timer = nil
  end
  self.shown_window, self.shown_buf = nil, nil
  self.pool:close()
end

---A previewer for one picker; close it with the picker.
---@return IaraPreviewer
function M.new()
  for name, link in pairs(MARK_LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  return setmetatable(
    { token = 0, closed = false, pool = pool.new() },
    Previewer
  )
end

return M
