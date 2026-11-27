--- Composite the visible Sixel slices in one terminal update. Ordinary
--- scrolling only repaints page pixels and clears exposed blank cells.
local cache = require("iara.features.pdf.sixel_cache")
local data = require("iara.features.pdf.sixel_data")
local api = vim.api

local M = {}
local pictures = {}
local previous = {}
local pending = false
local windows = {}
local damage = {}
local previews = 0
local redraw_previews = false
local flushing = false
local provider

local function size()
  return require("image/utils/term").get_size()
end

local function pixels(rect)
  local cell = size()
  local visible = rect.visible_width or rect.width
  return math.max(1, math.floor(visible * cell.cell_width)),
    math.max(6, math.floor(rect.height * cell.cell_height / 6) * 6),
    math.max(1, math.floor(rect.width * cell.cell_width))
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

local function preview_covered(win, slice)
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

local function slice_cells(picture, skip, height)
  local cached = picture.slice
  if cached and cached.skip == skip and cached.height == height then
    return cached.graphic, cached.painted
  end
  local graphic, painted = data.slice(picture.entry.raster, skip, height)
  if graphic and picture.rect.preview then
    graphic = graphic:gsub("^\27P0;1;0q", "\27P0;0;0q", 1)
  end
  picture.slice = {
    skip = skip,
    height = height,
    graphic = graphic,
    painted = painted,
  }
  return graphic, painted
end

local function collect_slice(picture, region)
  local rect = picture.rect
  local topline = rect.topline and rect.topline() or region.topline
  local y = rect.preview and rect.y or rect.y + 2 - topline
  local first = math.max(0, y)
  local last = math.min(region.height, y + rect.height)
  local cols = rect.visible_width or rect.width
  if last <= first or rect.x < 0 or rect.x + cols > region.width then
    return
  end
  local cell_height = size().cell_height
  local skip = math.floor((first - y) * cell_height)
  local height = math.floor((last - first) * cell_height)
  local graphic, painted = slice_cells(picture, skip, height)
  if graphic then
    local slice = {
      row = region.row + first,
      col = region.col + rect.x,
      rows = math.ceil(painted / cell_height),
      cols = cols,
      graphic = graphic,
    }
    if rect.preview then
      if preview_covered(picture.win, slice) then
        return false
      end
      region.preview = true
    end
    region.slices[#region.slices + 1] = slice
    region.first_ready = math.min(region.first_ready or math.huge, rect.y)
  end
  return true
end

local function collect_picture(picture, region)
  local entry = picture.entry
  if entry.raster then
    return collect_slice(picture, region)
  end
  if not entry.failed then
    region.first_pending =
      math.min(region.first_pending or math.huge, picture.rect.y)
  elseif picture.rect.on_error and not picture.failed then
    picture.failed = true
    vim.schedule(function()
      if pictures[picture] then
        picture.rect.on_error("Could not encode the PDF as Sixel.")
      end
    end)
  end
  return true
end

local function collect()
  local regions = {}
  for picture in pairs(pictures) do
    local win = picture.win
    local region = regions[win] or area(win, picture.buf)
    if region and collect_picture(picture, region) then
      regions[win] = region
    else
      regions[win] = nil
    end
  end
  return regions
end

local function paint_region(out, region, old)
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
    out[#out + 1] = move(slice.row, slice.col) .. slice.graphic
  end
end

local function background()
  local color = api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  if not color then
    return "\27[49m"
  end
  local r = math.floor(color / 65536)
  local g = math.floor(color / 256) % 256
  return ("\27[48;2;%d;%d;%dm"):format(r, g, color % 256)
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
      or old.graphic ~= current.graphic
    then
      return false
    end
  end
  return true
end

local function collect_updates(regions, old, damaged, repair_preview)
  local out, flush = {}, false
  for win, region in pairs(regions) do
    local before = old[win]
    -- Keep the previous frame until the leading page is ready. An adjacent
    -- page still being encoded should not delay the new zoom level.
    local waiting = region.first_pending
      and region.first_pending < (region.first_ready or math.huge)
    if waiting and before and not before.preview and #before.slices > 0 then
      region = before
      regions[win] = before
    end
    local same = same_slices(before, region)
    local repair = damaged[win] or (repair_preview and region.preview)
    if repair or not same then
      -- The same image already covers its own cells when repairing damage.
      flush = flush or region.preview or repair
      paint_region(out, region, not same and before or nil)
    end
  end
  return out, flush
end

local function paint(damaged, repair_preview)
  local regions = collect()
  -- The old image cells may now contain editor text or window chrome.
  local old = previous
  if needs_clear(regions) then
    -- Ctrl-L clears and resends the terminal grid. A plain :redraw! can
    -- leave old graphics and skip text the UI considers already drawn.
    flushing = true
    vim.cmd.normal({ args = { "\12" }, bang = true })
    api.nvim__redraw({ flush = true })
    flushing = false
    old = {}
  end
  previous = regions
  local out, flush = collect_updates(regions, old, damaged, repair_preview)
  if #out == 0 then
    return
  end
  if flush then
    flushing = true
    api.nvim__redraw({ flush = true })
    flushing = false
  end
  api.nvim_ui_send(
    "\27[?2026h\0277" .. background() .. table.concat(out) .. "\0278\27[?2026l"
  )
end

function M.refresh(repair_preview)
  redraw_previews = redraw_previews or repair_preview == true
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    local damaged, repair = damage, redraw_previews
    damage, pending, redraw_previews = {}, false, false
    paint(damaged, repair)
  end)
end

function M.invalidate(win)
  if windows[win] then
    damage[win] = true
    M.refresh()
  end
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
      if windows[win] and not flushing then
        damage[win] = true
      end
      return false
    end,
    on_end = function()
      if not flushing and (previews > 0 or next(damage)) then
        M.refresh(previews > 0)
      end
    end,
  })
end

function M.warm(path, rect)
  local width, height, page_width = pixels(rect)
  cache.prepare(path, width, height, M.refresh, false, page_width)
end

function M.ready(path, rect)
  return cache.ready(path, pixels(rect))
end

function M.warm_zoom(path, rect)
  cache.stage(path, pixels(rect))
end

function M.picture(path, win, buf, rect)
  local width, height, page_width = pixels(rect)
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
    entry = cache.prepare(path, width, height, ready, true, page_width),
  }
  pictures[picture] = true
  windows[win] = (windows[win] or 0) + 1
  if rect.preview then
    previews = previews + 1
  end
  watch_redraws()
  M.refresh()
  return {
    clear = function()
      if pictures[picture] then
        pictures[picture] = nil
        local count = windows[win] - 1
        windows[win] = count > 0 and count or nil
        if rect.preview then
          previews = previews - 1
        end
        M.refresh()
      end
    end,
  }
end

M.forget = cache.forget
M.retain = cache.retain

return M
