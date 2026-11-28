--- Composite the visible Sixel slices in one terminal update. Ordinary
--- scrolling only repaints page pixels and clears exposed blank cells.
local cache = require("iara.features.pdf.sixel_cache")
local data = require("iara.features.pdf.sixel_data")
local geometry = require("iara.features.pdf.geometry")
local scroll = require("iara.features.pdf.sixel_scroll")
local api = vim.api

local M = {}
local pictures = {}
local previous = {}
local pending = false
local windows = {}
local damage = {}
local previews = 0
local check_overlays = false
local preview_redrawn = false
local preview_repair
local repair_started
local flushing = false
local provider

local function size()
  return require("image/utils/term").get_size()
end

local function pixels(rect)
  return geometry.pixels(rect, size())
end

local function move(row, col)
  return ("\27[%d;%dH"):format(row, col)
end

local function area(win, buf)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then
    return
  end
  if api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage() then
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  local origin = vim.fn.screenpos(win, info.topline, 1)
  if origin.row == 0 or origin.col == 0 then
    return
  end
  return {
    row = origin.row,
    col = origin.col,
    height = api.nvim_win_get_height(win),
    width = api.nvim_win_get_width(win) - info.textoff,
    topline = info.topline,
    buf = buf,
    slices = {},
  }
end

local function covered(win, slice)
  local layer = api.nvim_win_get_config(win).zindex or 0
  for _, other in ipairs(api.nvim_tabpage_list_wins(0)) do
    local config = api.nvim_win_get_config(other)
    if config.relative ~= "" and (config.zindex or 0) > layer then
      local pos = vim.fn.win_screenpos(other)
      local bordered = config.border and config.border ~= "none"
      local inset = bordered and 2 or 0
      if
        pos[1] < slice.row + slice.rows
        and pos[1] + api.nvim_win_get_height(other) + inset > slice.row
        and pos[2] < slice.col + slice.cols
        and pos[2] + api.nvim_win_get_width(other) + inset > slice.col
      then
        return true
      end
    end
  end
  return false
end

local function slice_cells(picture, first, last)
  local cached = picture.slice
  local raster = picture.entry.raster
  if
    cached
    and cached.raster == raster
    and cached.first == first
    and cached.last == last
  then
    return cached
  end
  picture.slice = data.capture(raster, first, last)
  return picture.slice
end

local function placement(picture, region)
  local rect = picture.rect
  local topline = rect.topline and rect.topline() or region.topline
  region.document = rect.topline and topline
  local y = rect.preview and rect.y or rect.y + 2 - topline
  local first = math.max(0, y)
  local available = region.height - (region.bar and 1 or 0)
  local last = math.min(available, y + rect.height)
  local cols = rect.visible_width or rect.width
  if last <= first or rect.x < 0 or rect.x + cols > region.width then
    return
  end
  local cell = size().cell_height
  return {
    row = region.row + first,
    col = region.col + rect.x,
    rows = last - first,
    cols = cols,
    skip = math.floor((first - y) * cell),
    height = math.floor((last - first) * cell),
    cell = cell,
  }
end

local function notify_error(picture)
  if picture.rect.on_error and not picture.failed then
    picture.failed = true
    vim.schedule(function()
      if pictures[picture] then
        picture.rect.on_error("Could not encode the PDF as Sixel.")
      end
    end)
  end
end

local function collect_picture(picture, region, focused)
  local entry = picture.entry
  local slice = placement(picture, region)
  if not slice then
    cache.drop(entry, picture)
    return true
  end
  local preview = picture.rect.preview
  if preview and covered(picture.win, slice) then
    cache.drop(entry, picture)
    return false
  end

  local first, last = data.bounds(entry.height, slice.skip, slice.height)
  if not first then
    cache.drop(entry, picture)
    return true
  end
  cache.want(entry, picture, first, last, focused == picture.win)
  local frame = slice_cells(picture, first, last)
  if frame then
    slice.frame = frame
    slice.rows = math.ceil((last - first + 1) * 6 / slice.cell)
    region.slices[#region.slices + 1] = slice
    region.preview = preview
  elseif entry.failed then
    notify_error(picture)
  else
    region.waiting = true
  end
  return true
end

local function collect()
  local regions = {}
  local focused = api.nvim_get_current_win()
  for picture in pairs(pictures) do
    local win = picture.win
    local region = regions[win] or area(win, picture.buf)
    if region and picture.rect.scrollbar then
      region.bar = picture.rect.scrollbar()
    end
    if region and collect_picture(picture, region, focused) then
      regions[win] = region
    else
      cache.drop(picture.entry, picture)
      regions[win] = nil
    end
  end
  for _, region in pairs(regions) do
    table.sort(region.slices, function(a, b)
      return a.row < b.row
    end)
  end
  return regions
end

local function paint_region(out, region, old, strips)
  if strips then
    out[#out + 1] = strips
    return
  end
  -- Foot removes the old Sixel cells here, including short edge bands.
  -- Erase and paint are sent in the same synchronized terminal update.
  for _, slice in ipairs(old and old.slices or {}) do
    out[#out + 1] = ("\27[%d;%d;%d;%d$z"):format(
      slice.row,
      slice.col,
      slice.row + slice.rows - 1,
      slice.col + slice.cols - 1
    )
  end
  for _, slice in ipairs(region.slices) do
    local frame = slice.frame
    if slice.source then
      slice.source, slice.limit = nil, nil
      slice.rows = math.ceil((frame.last - frame.first + 1) * 6 / slice.cell)
    end
    frame.graphic = frame.graphic or data.pack(frame, frame.first, frame.last)
    out[#out + 1] = move(slice.row, slice.col) .. frame.graphic
  end
end

local function sgr(layer, color)
  if not color then
    return ("\27[%dm"):format(layer + 1)
  end
  local r = math.floor(color / 65536)
  local g = math.floor(color / 256) % 256
  return ("\27[%d;2;%d;%d;%dm"):format(layer, r, g, color % 256)
end

local function normal_background()
  return sgr(48, api.nvim_get_hl(0, { name = "Normal", link = false }).bg)
end

local function paint_scrollbar(out, region)
  local bar = region.bar
  local track = api.nvim_get_hl(0, { name = "PmenuThumb", link = false })
  local thumb = api.nvim_get_hl(0, { name = "FloatTitle", link = false })
  local track_fg = sgr(38, track.bg or 0x424242)
  local thumb_fg = sgr(38, thumb.fg or 0x888888)
  out[#out + 1] = move(region.row + region.height - 1, region.col + bar.x)
    .. track_fg
    .. ("▁"):rep(bar.start)
    .. thumb_fg
    .. ("▂"):rep(bar.thumb)
    .. track_fg
    .. ("▁"):rep(bar.width - bar.start - bar.thumb)
    .. sgr(38)
end

local function same_scrollbar(before, after)
  return before == after
    or (
      before
      and after
      and before.width == after.width
      and before.x == after.x
      and before.thumb == after.thumb
      and before.start == after.start
    )
end

local function erase_scrollbar(out, region)
  local bar = region.bar
  local row = region.row + region.height - 1
  local col = region.col + bar.x
  out[#out + 1] = ("\27[%d;%d;%d;%d$z"):format(
    row,
    col,
    row,
    col + bar.width - 1
  )
end

local function needs_clear(regions)
  for win, old in pairs(previous) do
    local now = regions[win]
    if
      not now
      or old.row ~= now.row
      or old.col ~= now.col
      or old.width ~= now.width
      or old.height ~= now.height
      or old.buf ~= now.buf
    then
      return true
    end
  end
  return false
end

local function same_slices(before, after)
  if not before or #before.slices ~= #after.slices then
    return false
  end
  for i, current in ipairs(after.slices) do
    local old = before.slices[i]
    if
      old.row ~= current.row
      or old.col ~= current.col
      or old.frame ~= current.frame
    then
      return false
    end
  end
  return true
end

local function keep_previous_frame(region, before)
  -- Replacing only the ready slices can expose an unrendered page as a
  -- black rectangle. Keep the whole previous frame until every slice fits.
  if region.waiting and before and not before.preview then
    region.document = before.document
    region.slices = before.slices
  end
end

local function scroll_pages(win, before, region)
  if
    not before
    or not region.document
    or before.document == region.document
    or region.col ~= 1
    or region.width ~= vim.o.columns
    or vim.fn.pumvisible() == 1
  then
    return
  end
  local viewport = {
    row = region.row,
    col = region.col,
    rows = region.height,
    cols = region.width,
  }
  if not covered(win, viewport) then
    return scroll.update(before, region)
  end
end

local function stale_region(before, same, preview)
  if not same or preview then
    return before
  end
  for _, slice in ipairs(before.slices) do
    if slice.source then
      return before
    end
  end
end

local function update_region(out, win, region, before, repair)
  keep_previous_frame(region, before)
  local same = same_slices(before, region)
  local repaint = repair or not same
  local old_bar = before and before.bar
  local bar_changed = not same_scrollbar(old_bar, region.bar)
  if old_bar and bar_changed and not region.bar then
    erase_scrollbar(out, before)
  end
  if repaint then
    -- Erase the damaged preview and repaint it in the same terminal update.
    local strips = not repair and scroll_pages(win, before, region)
    paint_region(
      out,
      region,
      stale_region(before, same, region.preview),
      strips
    )
  else
    -- Keep the actual pixel offset of the image already on the terminal.
    region.slices = before.slices
  end
  if region.bar and (repaint or bar_changed) then
    paint_scrollbar(out, region)
  end
  return repair or (not same and region.preview)
end

local function collect_updates(regions, old, damaged)
  local out, flush = {}, false
  for win, region in pairs(regions) do
    flush = update_region(out, win, region, old[win], damaged[win]) or flush
  end
  return out, flush
end

local function sync_start_cover(regions)
  local motion = package.loaded["iara.core.start_motion"]
  if not motion then
    return
  end
  local overlays
  for _, region in pairs(regions) do
    if region.preview then
      overlays = overlays or {}
      vim.list_extend(overlays, region.slices)
    end
  end
  motion.set_cover(overlays)
end

local function clear_grid()
  -- Ctrl-L resends the terminal grid, but :normal can move an Insert-mode
  -- caret back onto the preceding character, including in a picker prompt.
  local mode = api.nvim_get_mode().mode:sub(1, 1)
  local view = (mode == "i" or mode == "R") and vim.fn.winsaveview()
  flushing = true
  vim.cmd.normal({ args = { "\12" }, bang = true })
  if view then
    vim.fn.winrestview(view)
  end
  api.nvim__redraw({ flush = true })
  flushing = false
end

local function paint(damaged)
  local regions = collect()
  sync_start_cover(regions)
  -- The old image cells may now contain editor text or window chrome.
  local old = previous
  if needs_clear(regions) then
    clear_grid()
    old = {}
  end
  previous = regions
  local out, flush = collect_updates(regions, old, damaged)
  if #out == 0 then
    return
  end
  if flush then
    flushing = true
    api.nvim__redraw({ flush = true })
    flushing = false
  end
  api.nvim_ui_send(
    "\27[?2026h\0277"
      .. normal_background()
      .. table.concat(out)
      .. "\0278\27[?2026l"
  )
end

function M.refresh()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    local damaged = damage
    damage, pending = {}, false
    paint(damaged)
  end)
end

function M.invalidate(win)
  if windows[win] then
    damage[win] = true
    M.refresh()
  end
end

local function repair_preview()
  repair_started = nil
  if previews == 0 or vim.fn.pumvisible() == 1 then
    return
  end
  for win, region in pairs(previous) do
    if region.preview then
      M.invalidate(win)
    end
  end
end

local function schedule_preview_repair()
  -- The TUI compositor can erase Sixel while redrawing another layer,
  -- without visiting the preview window. Repair once after the burst.
  preview_repair = preview_repair or vim.uv.new_timer()
  if not preview_repair then
    return vim.schedule(repair_preview)
  end
  local now = vim.uv.now()
  repair_started = repair_started or now
  local delay = math.min(80, math.max(1, 160 - (now - repair_started)))
  preview_repair:start(delay, 0, vim.schedule_wrap(repair_preview))
end

local function finish_redraw()
  if flushing then
    return
  end
  if next(damage) or check_overlays then
    check_overlays = false
    M.refresh()
  end
  if preview_redrawn then
    if preview_repair then
      preview_repair:stop()
      repair_started = nil
    end
  elseif previews > 0 then
    schedule_preview_repair()
  end
  preview_redrawn = false
end

local function watch_redraws()
  if provider then
    return
  end
  provider = api.nvim_create_namespace("iara.pdf.sixel")
  api.nvim_set_decoration_provider(provider, {
    on_start = function()
      return not flushing and next(windows) ~= nil
    end,
    on_win = function(_, win)
      if windows[win] then
        damage[win] = true
        preview_redrawn = preview_redrawn
          or (previous[win] and previous[win].preview)
      elseif previews > 0 and api.nvim_win_get_config(win).relative ~= "" then
        check_overlays = true
      end
      return false
    end,
    on_end = finish_redraw,
  })
  api.nvim_create_autocmd({ "WinClosed", "WinResized", "TabEnter" }, {
    group = api.nvim_create_augroup("IaraPdfSixel", { clear = true }),
    callback = function()
      if previews > 0 then
        M.refresh()
      end
    end,
  })
end

local function screen_bands()
  return math.max(1, math.floor(vim.o.lines * size().cell_height / 6))
end

function M.warm(path, rect)
  cache.warm(path, pixels(rect), screen_bands(), M.refresh)
end

function M.ready(path, rect)
  return cache.ready(path, pixels(rect))
end

function M.warm_zoom(path, rect)
  local shape = pixels(rect)
  local cell = size().cell_height
  local skip = math.floor(rect.skip * cell)
  local height = math.floor(rect.rows * cell)
  local first, last = data.bounds(shape.height, skip, height)
  if first then
    cache.stage(path, shape, first, last)
  end
end

local function clear_picture(picture)
  if not pictures[picture] then
    return
  end
  local win = picture.win
  pictures[picture] = nil
  cache.drop(picture.entry, picture)
  cache.release(picture.entry)
  local count = windows[win] - 1
  windows[win] = count > 0 and count or nil
  if picture.rect.preview then
    previews = previews - 1
    if previews == 0 and preview_repair then
      preview_repair:close()
      preview_repair, repair_started = nil, nil
    end
  end
  M.refresh()
end

function M.picture(path, win, buf, rect)
  local function ready()
    M.refresh()
    if rect.on_ready then
      rect.on_ready()
    end
  end
  local picture = {
    win = win,
    buf = buf,
    rect = rect,
    entry = cache.prepare(path, pixels(rect), ready),
  }
  cache.hold(picture.entry)
  pictures[picture] = true
  windows[win] = (windows[win] or 0) + 1
  if rect.preview then
    previews = previews + 1
  end
  watch_redraws()
  M.refresh()
  return {
    clear = function()
      clear_picture(picture)
    end,
  }
end

M.forget = cache.forget
M.retain = cache.retain

return M
