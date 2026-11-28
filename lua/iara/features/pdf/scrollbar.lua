--- Map a page's horizontal crop to a scrollbar in terminal cells.
local M = {}

local function round(value)
  return math.floor(value + 0.5)
end

function M.offset(width, visible, position)
  return round((width - visible) * (position or 0.5))
end

function M.track(slot, cols, position)
  local width = slot.visible_width
  local overflow = slot.width - width
  if overflow == 0 or width < 2 then
    return
  end
  local thumb =
    math.max(1, math.min(width - 1, round(width * width / slot.width)))
  local offset = M.offset(slot.width, width, position)
  return {
    x = math.floor((cols - width) / 2),
    width = width,
    thumb = thumb,
    start = round(offset / overflow * (width - thumb)),
    overflow = overflow,
  }
end

function M.drag_offset(track, col)
  local offset = col - track.x - 1 - track.start
  if offset >= 0 and offset < track.thumb then
    return offset, true
  end
  return math.floor(track.thumb / 2)
end

function M.position(track, col, grab)
  local offset = col - track.x - 1 - grab
  local travel = track.width - track.thumb
  return math.max(0, math.min(1, offset / travel))
end

return M
