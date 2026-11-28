--- Pixel geometry shared by Sixel placement and Poppler's detail crops.
local M = { raster_limit = 3072 }
local max_crop_edge = 4096
local max_crop_pixels = 6 * 1024 * 1024

function M.pixels(rect, cell)
  local visible = rect.visible_width or rect.width
  local width = math.max(1, math.floor(visible * cell.cell_width))
  local page_width = math.max(1, math.floor(rect.width * cell.cell_width))
  local overflow = rect.width - visible
  local position = overflow > 0 and (rect.offset or overflow / 2) / overflow
    or 0
  return {
    width = width,
    height = math.max(6, math.floor(rect.height * cell.cell_height / 6) * 6),
    page_width = page_width,
    offset = math.floor((page_width - width) * position + 0.5),
  }
end

function M.visible(slot, screen)
  local start = screen.top - slot.row - 1
  return math.max(0, start), math.min(slot.height, start + screen.rows)
end

function M.needs_detail(slot, cell)
  return math.max(slot.width * cell.cell_width, slot.height * cell.cell_height)
    > M.raster_limit
end

function M.detail(slot, screen, first, last)
  local shape = M.pixels(slot, screen.cell)
  local needed = last - first
  local height = screen.cell.cell_height
  local budget = math.min(max_crop_edge, max_crop_pixels / shape.width)
  local max_rows = math.floor(budget / height)
  if
    math.max(shape.page_width, shape.height) <= M.raster_limit
    or shape.width > max_crop_edge
    or needed < 1
    or needed > max_rows
  then
    return
  end
  -- Include a small margin so a short scroll can reuse the same crop.
  local margin = math.min(math.floor(needed / 3), max_rows - needed)
  local top = math.max(0, first - math.floor(margin / 3))
  local bottom = math.min(slot.height, top + needed + margin)
  return {
    first = top,
    last = bottom,
    x = shape.offset,
    y = math.floor(top * height),
    width = shape.width,
    height = math.floor((bottom - top) * height / 6) * 6,
    page_width = shape.page_width,
    page_height = math.ceil(slot.height * height),
  }
end

return M
