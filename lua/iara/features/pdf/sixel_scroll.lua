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
  return (slice.frame.first - 1) * 6 + (row - slice.row) * slice.cell
end

local function same_row(old, new, row, delta)
  if not old or not new then
    return old == new
  end
  local source = pixel_row(old, row + delta)
  local target = pixel_row(new, row)
  return old.frame.raster == new.frame.raster
    and old.cell == new.cell
    and old.cell % 1 == 0
    and old.col == new.col
    and old.cols == new.cols
    and source == target
    and math.min(old.cell, old.frame.last * 6 - source)
      == math.min(new.cell, new.frame.last * 6 - target)
end

local function matching_rows(before, after, first, last, delta)
  local overlap = false
  for row = first, last do
    local old = at_row(before.slices, row + delta)
    local new = at_row(after.slices, row)
    if not same_row(old, new, row, delta) then
      return false
    end
    overlap = overlap or new ~= nil
  end
  return overlap
end

local function edge(slice, first, last)
  local bottom = slice.row + slice.rows - 1
  local start, finish = math.max(slice.row, first), math.min(bottom, last)
  if start > finish then
    return
  end
  -- Overdraw adjacent rows as needed to start and end on a band boundary.
  while (start - slice.row) * slice.cell % 6 ~= 0 do
    start = start - 1
  end
  while finish < bottom and (finish - start + 1) * slice.cell % 6 ~= 0 do
    finish = finish + 1
  end
  local skip = pixel_row(slice, start)
  local height = (finish - start + 1) * slice.cell
  local low, high = data.bounds(slice.frame.last * 6, skip, height)
  if low then
    return ("\27[%d;%dH"):format(start, slice.col)
      .. data.pack(slice.frame, low, high)
  end
end

local function exposed(out, frame, first, last)
  for _, slice in ipairs(frame.slices) do
    local draw = edge(slice, first, last)
    if draw then
      out[#out + 1] = draw
    end
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
  -- Repaint the last old row when scrolling down. It may have been
  -- truncated to a partial cell and will now sit above the new pixels.
  local first = top - math.min(0, delta)
  local last = bottom - math.max(0, delta + 1)
  if delta == 0 or not matching_rows(before, after, first, last, delta) then
    return
  end
  local out = {
    ("\27[%d;%dr\27[%d%s\27[r"):format(
      top,
      bottom,
      math.abs(delta),
      delta > 0 and "S" or "T"
    ),
  }
  if delta > 0 then
    local seam = last + 1
    out[#out + 1] = ("\27[%d;1;%d;%d$z"):format(seam, seam, after.width)
    exposed(out, after, seam, bottom)
  else
    exposed(out, after, top, first - 1)
  end
  return table.concat(out)
end

return M
