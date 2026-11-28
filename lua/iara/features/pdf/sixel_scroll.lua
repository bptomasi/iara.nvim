--- Translate exact Sixel rows already present in a full-width Foot window.
local data = require("iara.features.pdf.sixel_data")
local M = {}

local function at_row(slices, row)
  for _, slice in ipairs(slices) do
    if row >= slice.row and row < slice.row + slice.rows then
      return slice
    end
  end
end

local function pixel_row(slice, row)
  local source = slice.source or (slice.frame.first - 1) * 6
  return source + (row - slice.row) * slice.cell
end

local function pixel_limit(slice)
  return slice.limit or slice.frame.last * 6
end

local function same_raster(old, new)
  return old
    and old.frame.raster == new.frame.raster
    and old.cell == new.cell
    and old.cell % 1 == 0
    and old.col == new.col
    and old.cols == new.cols
end

local function continue_slice(slice, old, row, delta)
  if not same_raster(old, slice) then
    return slice
  end
  local inset = (row - slice.row) * slice.cell
  local source = pixel_row(old, row + delta) - inset
  local skip = slice.skip
  if
    old.skip + (row + delta - old.row) * old.cell - inset ~= skip
    or source < 0
    or source > skip
    or source < skip - 5
  then
    return slice
  end
  -- Keep the pixel offset of the retained rows, including partial bands.
  local limit = math.min(slice.frame.raster.height, source + slice.height)
  if source == pixel_row(slice, slice.row) and limit == pixel_limit(slice) then
    return slice
  end
  return vim.tbl_extend("force", {}, slice, {
    source = source,
    limit = limit,
    rows = math.ceil((limit - source) / slice.cell),
  })
end

local function continued_slices(before, after, first, delta)
  local slices = {}
  for index, slice in ipairs(after) do
    local row = math.max(first, slice.row)
    local old = row < slice.row + slice.rows and at_row(before, row + delta)
    slices[index] = continue_slice(slice, old, row, delta)
  end
  return slices
end

local function same_row(old, new, row, delta)
  if not old or not new then
    return old == new
  end
  local source = pixel_row(old, row + delta)
  local target = pixel_row(new, row)
  return same_raster(old, new)
    and source == target
    and math.min(old.cell, pixel_limit(old) - source)
      == math.min(new.cell, pixel_limit(new) - target)
end

local function matching_rows(before, after, first, last, delta)
  local overlap = false
  for row = first, last do
    local old = at_row(before, row + delta)
    local new = at_row(after, row)
    if not same_row(old, new, row, delta) then
      return false
    end
    overlap = overlap or new ~= nil
  end
  return overlap
end

local function aligned_edge(slice, start, finish, skip, height)
  if skip % 6 == 0 or slice.cell % 1 ~= 0 then
    return start, skip, height
  end
  local rows =
    math.min(5, start - slice.row, math.ceil((finish - start + 1) / 2))
  for offset = 1, rows do
    local inset = offset * slice.cell
    local source = skip - inset
    if source % 6 == 0 then
      local exact = data.row_bytes(slice.frame, skip, height)
      local aligned = data.row_bytes(slice.frame, source, height + inset)
      -- Repaint a few retained rows only when the aligned packet drops
      -- enough bytes to offset the extra pixels sent to the terminal.
      if exact and aligned and aligned <= exact * 0.8 then
        return start - offset, source, height + inset
      end
      break
    end
  end
  return start, skip, height
end

local function edge(slice, first, last)
  local bottom = slice.row + slice.rows - 1
  local start, finish = math.max(slice.row, first), math.min(bottom, last)
  if start > finish then
    return ""
  end
  local skip = pixel_row(slice, start)
  local height =
    math.min((finish - start + 1) * slice.cell, pixel_limit(slice) - skip)
  start, skip, height = aligned_edge(slice, start, finish, skip, height)
  local graphic = data.pack_rows(slice.frame, skip, height)
  if graphic then
    return ("\27[%d;%dH"):format(start, slice.col) .. graphic
  end
end

local function exposed(out, slices, first, last)
  for _, slice in ipairs(slices) do
    local draw = edge(slice, first, last)
    if not draw then
      return false
    end
    out[#out + 1] = draw
  end
  return true
end

local function erase_rows(first, last, width)
  return ("\27[%d;1;%d;%d$z"):format(first, last, width)
end

local function scroll_rows(viewport)
  local top, bottom, delta = viewport.top, viewport.bottom, viewport.delta
  local first, last = top, top + delta - 1
  if delta < 0 then
    first, last = bottom + delta + 1, bottom
  end
  -- Cut off outgoing parts of Sixel images before the terminal recycles
  -- those rows. Foot can otherwise drop the whole image, including its tail.
  return erase_rows(first, last, viewport.width)
    .. ("\27[%d;%dr\27[%d%s\27[r"):format(
      top,
      bottom,
      math.abs(delta),
      delta > 0 and "S" or "T"
    )
end

local function redraw_edges(out, slices, viewport)
  local top, bottom, delta = viewport.top, viewport.bottom, viewport.delta
  if delta < 0 and not exposed(out, slices, top, top - delta - 1) then
    return false
  end
  local seam = bottom - math.max(0, delta)
  if viewport.tail_dirty then
    out[#out + 1] = erase_rows(seam, seam, viewport.width)
  else
    seam = seam + 1
  end
  return exposed(out, slices, seam, bottom)
end

local function retain_rows(before, after, viewport)
  local delta = viewport.delta
  local first = viewport.top - math.min(0, delta)
  local last = viewport.bottom - math.max(0, delta)
  local slices = continued_slices(before, after, first, delta)
  local old, new = at_row(before, last + delta), at_row(slices, last)
  viewport.tail_dirty = not same_row(old, new, last, delta)
  if viewport.tail_dirty then
    last = last - 1
  end
  if matching_rows(before, slices, first, last, delta) then
    return slices
  end
end

function M.update(before, after)
  if
    not before
    or not before.document
    or not after.document
    or (before.bar ~= nil) ~= (after.bar ~= nil)
  then
    return
  end
  local delta = after.document - before.document
  local top = after.row
  local bottom = top + after.height - (after.bar and 2 or 1)
  if delta == 0 or math.abs(delta) > bottom - top then
    return
  end
  local viewport =
    { top = top, bottom = bottom, delta = delta, width = after.width }
  local slices = retain_rows(before.slices, after.slices, viewport)
  if not slices then
    return
  end
  local out = { scroll_rows(viewport) }
  if not redraw_edges(out, slices, viewport) then
    return
  end
  after.slices = slices
  return table.concat(out)
end

return M
