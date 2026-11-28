--- Render bounded, native-resolution crops after a large zoom settles.
local geometry = require("iara.features.pdf.geometry")
local graphics = require("iara.features.pdf.graphics")
local source = require("iara.features.pdf.source")
local M = {}

function M.new(path, dir, ready)
  return { path = path, dir = dir, ready = ready, sequence = 0 }
end

function M.discard(entry)
  if entry.path then
    graphics.forget(entry.path)
    vim.uv.fs_unlink(entry.path)
    entry.path = nil
  elseif entry.job then
    entry.job:cancel("PDF detail viewport moved")
  end
end

function M.prune(pane, first, last)
  for page, entry in pairs(pane.detail or {}) do
    if not first or page < first or page > last then
      pane.detail[page] = nil
      M.discard(entry)
    end
  end
end

function M.close(state, panes)
  if not state then
    return
  end
  state.closed = true
  for _, pane in pairs(panes) do
    M.prune(pane)
  end
end

local function start(state, entries, page, entry)
  local old = entries[page]
  if old then
    M.discard(old)
  end
  entries[page] = entry
  state.sequence = state.sequence + 1
  state.work = entry
  local prefix = ("%s/detail-%d"):format(state.dir, state.sequence)
  entry.job = source.crop(state.path, page, prefix, entry.crop, function(path)
    state.work, entry.job = nil, nil
    if not state.closed and entries[page] == entry then
      entry.path = path
    elseif path then
      vim.uv.fs_unlink(path)
    end
    if not state.closed then
      state.ready()
    end
  end)
end

function M.picture(state, pane, page, slot, screen)
  local first, last = geometry.visible(slot, screen)
  if first >= last then
    return
  end
  pane.detail = pane.detail or {}
  local entry = pane.detail[page]
  if
    entry
    and entry.slot == slot
    and entry.offset == slot.offset
    and entry.crop.first <= first
    and entry.crop.last >= last
  then
    return entry.path and entry
  end
  if state.work or not screen.settled then
    return
  end
  local crop = geometry.detail(slot, screen, first, last)
  if crop then
    start(state, pane.detail, page, {
      slot = slot,
      offset = slot.offset,
      crop = crop,
    })
  end
end

return M
