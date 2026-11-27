--- A small pool of preview buffers (tasks S10, S11). See contracts.md,
--- section 9.6.
---
--- Snacks' preview resets and refills one buffer per item: stopping
--- Tree-sitter, emptying the buffer, and resetting its options cost up
--- to 14 ms per item on a 256 KiB file, while the list waits. The pool
--- keeps scratch buffers instead, in two least recently used lists:
--- SIZE buffers for complete windows (up to 256 KiB each) and SCREENS
--- buffers for first screens (the lines around the marked row, a few
--- KiB). A window or screen shown recently is shown again by swapping
--- its buffer in, with its lines and highlighting intact; new content
--- goes into the least recently used buffer that is not on screen,
--- preferably one already highlighted for the same filetype, so its
--- highlighter is kept. Buffers never get a filetype, so no FileType
--- event, ftplugin, or syntax file runs for them, and they are created
--- and swapped in with events ignored.
local M = {}

M.SIZE = 3
M.SCREENS = 8

---@class IaraPreviewEntry
---@field buf integer
---@field window table|nil Content source (`IaraPreviewWindow` or lines).
---@field first integer First line of `window.lines` held (one-based).
---@field last integer Last line of `window.lines` held.
---@field filetype string|nil Filetype it is highlighted for.
---@field highlight string|nil How it is highlighted, nil for plain.
---@field mapped boolean The preview window's keys are mapped.

---@class IaraPreviewPool
---@field entries IaraPreviewEntry[] Complete windows, least recent first.
---@field screens IaraPreviewEntry[] First screens, least recent first.
local Pool = {}
Pool.__index = Pool

---Run `fn` with every autocommand event ignored.
local function quietly(fn, ...)
  local saved = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, result = pcall(fn, ...)
  vim.o.eventignore = saved
  if not ok then
    error(result, 0)
  end
  return result
end

local function new_entry()
  local buf = quietly(function()
    local created = vim.api.nvim_create_buf(false, true)
    vim.bo[created].swapfile = false
    vim.bo[created].undolevels = -1
    vim.bo[created].modifiable = false
    vim.b[created].iara_preview = true
    return created
  end)
  return { buf = buf, mapped = false, first = 1, last = 0 }
end

local function set_lines(entry, lines)
  local buf = entry.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---Two windows hold the same disk content: same file, start, length,
---and stat. Lines given by a caller match only themselves.
local function same(a, b)
  if a == b then
    return true
  end
  return a ~= nil
    and a.path ~= nil
    and a.path == b.path
    and a.first_row == b.first_row
    and #a.lines == #b.lines
    and vim.deep_equal(a.stat, b.stat)
end

local function valid(entry)
  return vim.api.nvim_buf_is_valid(entry.buf)
end

---Index of the entry of `list` holding lines `first`..`last` of `window`.
local function holding(list, window, first, last)
  for index, entry in ipairs(list) do
    if
      valid(entry)
      and same(entry.window, window)
      and entry.first <= first
      and entry.last >= last
    then
      return index
    end
  end
end

---The entry holding lines `first`..`last` of `window` (all by default):
---a complete window, else a first screen; made the most recently used.
---@param window table
---@param first integer?
---@param last integer?
---@return IaraPreviewEntry|nil
function Pool:find(window, first, last)
  first, last = first or 1, last or #window.lines
  for _, list in ipairs({ self.entries, self.screens }) do
    local index = holding(list, window, first, last)
    if index then
      local entry = table.remove(list, index)
      table.insert(list, entry)
      return entry
    end
  end
end

---Index of the entry to reuse: the least recently used one not on
---screen, preferring one highlighted for `filetype`.
local function reusable(list, shown, filetype)
  local fallback
  for index, entry in ipairs(list) do
    if entry.buf ~= shown then
      if filetype ~= nil and entry.filetype == filetype then
        return index
      end
      fallback = fallback or index
    end
  end
  return fallback
end

---A free entry of `list`: a new buffer below `limit`, else one reused
---(`shown` is the buffer on screen, which is kept).
local function spare(list, limit, shown, filetype)
  for index = #list, 1, -1 do
    if not valid(list[index]) then
      table.remove(list, index)
    end
  end
  local index = #list >= limit and reusable(list, shown, filetype)
  if not index then
    return new_entry()
  end
  return table.remove(list, index)
end

local function fill(list, entry, window, first, last)
  entry.window, entry.first, entry.last = window, first, last
  set_lines(entry, vim.list_slice(window.lines, first, last))
  table.insert(list, entry)
  return entry
end

---Put all lines of `window` into a new buffer, the most recently used
---entry; a reused entry's buffer is deleted instead of refilled. Its
---Tree-sitter parser stays attached after the highlighter stops, and
---replacing 256 KiB of a parsed buffer re-parses the old tree in the
---same call: 15 ms, against 0.6 ms for a new buffer (S11).
---@param window table
---@param shown integer|nil Buffer on screen, which is kept.
---@return IaraPreviewEntry
function Pool:take(window, shown)
  local old = spare(self.entries, M.SIZE, shown)
  local entry = old.window and new_entry() or old
  if entry ~= old then
    pcall(vim.api.nvim_buf_delete, old.buf, { force = true })
  end
  return fill(self.entries, entry, window, 1, #window.lines)
end

---Put lines `first`..`last` of `window` (a first screen) into a free
---screen entry, the most recently used.
---@param window table
---@param first integer
---@param last integer
---@param shown integer|nil Buffer on screen, which is kept.
---@param filetype string|nil Filetype it will be highlighted for.
---@return IaraPreviewEntry
function Pool:screen(window, first, last, shown, filetype)
  local entry = spare(self.screens, M.SCREENS, shown, filetype)
  return fill(self.screens, entry, window, first, last)
end

---Show the entry in the Snacks preview window, with that window's keys.
---@param preview table Snacks picker preview.
---@param entry IaraPreviewEntry
function M.show(preview, entry)
  if preview.win.buf == entry.buf then
    return
  end
  quietly(function()
    preview:set_buf(entry.buf)
    if not entry.mapped and preview.win.map then
      preview.win:map()
    end
  end)
  entry.mapped = true
end

---Delete the buffers; one still on screen goes when it is hidden.
function Pool:close()
  local all = vim.list_extend(vim.list_slice(self.screens), self.entries)
  for _, entry in ipairs(all) do
    if valid(entry) then
      if vim.fn.bufwinid(entry.buf) == -1 then
        pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
      else
        vim.bo[entry.buf].bufhidden = "wipe"
      end
    end
  end
  self.entries, self.screens = {}, {}
end

---Buffers of the pool, least recently used first (for tests).
---@param kind "entries"|"screens"|nil Complete windows by default.
---@return integer[]
function Pool:buffers(kind)
  local buffers = {}
  for _, entry in ipairs(self[kind or "entries"]) do
    table.insert(buffers, entry.buf)
  end
  return buffers
end

---@return IaraPreviewPool
function M.new()
  return setmetatable({ entries = {}, screens = {} }, Pool)
end

return M
