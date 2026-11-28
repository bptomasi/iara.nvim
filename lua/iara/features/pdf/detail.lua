--- Render and reuse native-resolution PDF crops within a fixed cache budget.
local geometry = require("iara.features.pdf.geometry")
local graphics = require("iara.features.pdf.graphics")
local source = require("iara.features.pdf.source")
local M = {}
local cache_limit = 24 * 1024 * 1024
local cache_entries = 4

function M.new(path, dir, ready)
  return {
    path = path,
    dir = dir,
    ready = ready,
    sequence = 0,
    cache = {},
    bytes = 0,
  }
end

function M.discard(entry)
  if entry.path then
    graphics.forget(entry.path)
    vim.uv.fs_unlink(entry.path)
    entry.path = nil
  elseif entry.job and not entry.cancelled then
    entry.cancelled = true
    entry.job:cancel("PDF detail viewport moved")
  end
end

local function remove(state, index)
  local entry = table.remove(state.cache, index)
  state.bytes = state.bytes - entry.bytes
  return entry
end

local function remember(state, entry)
  if not entry.path or state.closed then
    return M.discard(entry)
  end
  table.insert(state.cache, entry)
  state.bytes = state.bytes + entry.bytes
  while state.bytes > cache_limit or #state.cache > cache_entries do
    M.discard(remove(state, 1))
  end
end

function M.prune(state, pane, first, last)
  if not state then
    return
  end
  for page, entry in pairs(pane.detail or {}) do
    if not first or page < first or page > last then
      pane.detail[page] = nil
      remember(state, entry)
    end
  end
  local work = state.work
  if not first and work and work.ahead and work.pane == pane then
    M.discard(work)
  end
end

function M.close(state, panes)
  if not state then
    return
  end
  state.closed = true
  for _, pane in pairs(panes) do
    M.prune(state, pane)
  end
  while #state.cache > 0 do
    M.discard(remove(state, #state.cache))
  end
end

local function variant(page, slot, cell)
  return table.concat({
    page,
    slot.width,
    slot.height,
    slot.visible_width,
    slot.offset or 0,
    cell.cell_width,
    cell.cell_height,
  }, ":")
end

local function covers(entry, key, first, last)
  return entry
    and not entry.cancelled
    and entry.key == key
    and entry.crop.first <= first
    and entry.crop.last >= last
end

local function cached(state, key, first, last)
  for index = #state.cache, 1, -1 do
    if covers(state.cache[index], key, first, last) then
      return index
    end
  end
end

local function attach(state, pane, page, entry)
  local previous = pane.detail[page]
  if previous then
    remember(state, previous)
  end
  pane.detail[page] = entry
end

local function finish(state, entry, path, bytes)
  state.work, entry.job, entry.pane = nil, nil, nil
  if path then
    entry.path = path
    entry.bytes = bytes or entry.crop.width * entry.crop.height * 3
    if state.closed or entry.cancelled then
      M.discard(entry)
    elseif entry.ahead then
      remember(state, entry)
      if entry.path then
        graphics.warm_zoom(entry.path, entry.warm)
      end
      entry.warm = nil
    end
  elseif entry.ahead and not entry.cancelled then
    state.failed_ahead = entry
  end
  if not state.closed then
    state.ready()
  end
end

local function start(state, pane, page, entry)
  if not entry.ahead then
    attach(state, pane, page, entry)
  end
  state.sequence = state.sequence + 1
  state.work = entry
  local prefix = ("%s/detail-%d"):format(state.dir, state.sequence)
  entry.job = source.crop(
    state.path,
    page,
    prefix,
    entry.crop,
    function(path, _, bytes)
      finish(state, entry, path, bytes)
    end
  )
end

function M.picture(state, pane, page, slot, screen)
  local first, last = geometry.visible(slot, screen)
  if first >= last or not geometry.needs_detail(slot, screen.cell) then
    return
  end
  pane.detail = pane.detail or {}
  local entry = pane.detail[page]
  local key = variant(page, slot, screen.cell)
  if covers(entry, key, first, last) then
    return entry.path and entry
  end
  -- Keep moving with the current image or the base raster. Installing a
  -- different crop mid-scroll forces a full repaint and can stall input.
  if screen.moving then
    return
  end
  local index = cached(state, key, first, last)
  if index then
    entry = remove(state, index)
    attach(state, pane, page, entry)
    return entry
  end
  if state.work or not screen.settled then
    return
  end
  local crop = geometry.detail(slot, screen, first, last)
  if crop then
    start(state, pane, page, {
      key = key,
      crop = crop,
    })
  end
end

function M.prefetch(state, pane, page, slot, screen, first, last)
  if state.work or first >= last then
    return
  end
  local key = variant(page, slot, screen.cell)
  local entry = pane.detail and pane.detail[page]
  if
    covers(entry, key, first, last)
    or covers(state.failed_ahead, key, first, last)
    or cached(state, key, first, last)
  then
    return
  end
  local crop = geometry.detail(slot, screen, first, last)
  if crop then
    start(state, pane, page, {
      key = key,
      crop = crop,
      pane = pane,
      ahead = true,
      warm = {
        width = slot.visible_width,
        height = crop.last - crop.first,
        skip = first - crop.first,
        rows = last - first,
      },
    })
  end
end

return M
