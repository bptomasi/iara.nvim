--- Encode Poppler's grayscale PPM pages directly in a libuv worker.
local ffi = require("ffi")

local LEVELS = 64
local WHITE = LEVELS - 1
local MAX_EDGE = 4096
local MAX_BYTES = 8 * 1024 * 1024
local floor = math.floor
local char = string.char

local function sample_at(from, ratio, position)
  local at = (position + 0.5) * ratio - 0.5
  return math.max(0, math.min(from - 1, at))
end

local function source_rows(height, target, span)
  local ratio = height / target
  local first = floor(sample_at(height, ratio, span.offset))
  local last = sample_at(height, ratio, span.offset + span.rows - 1)
  return first, math.min(height - 1, floor(last) + 1)
end

local function read_ppm(path, target, span)
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local magic, dimensions, range = file:read("*l", "*l", "*l")
  local width, height = (dimensions or ""):match("^(%d+) (%d+)$")
  width, height = tonumber(width), tonumber(height)
  if magic ~= "P6" or range ~= "255" or not width or not height then
    file:close()
    return
  end
  if width < 1 or height < 1 or math.max(width, height) > MAX_EDGE then
    file:close()
    return
  end
  local first, last = 0, height - 1
  if span.known_gray then
    first, last = source_rows(height, target, span)
  end
  local length = width * (last - first + 1) * 3
  local position = file:seek("cur", width * first * 3)
  local rgb = position and file:read(length)
  file:close()
  if rgb and #rgb == length then
    return rgb, width, height, first
  end
end

local function is_gray(pixels, bytes)
  for offset = 0, bytes - 3, 3 do
    local red = pixels[offset]
    if red ~= pixels[offset + 1] or red ~= pixels[offset + 2] then
      return false
    end
  end
  return true
end

local function samples(from, to, count, offset, stride)
  local lower = ffi.new("int[?]", count)
  local upper = ffi.new("int[?]", count)
  local fraction = ffi.new("float[?]", count)
  local ratio = from / to
  for x = 0, count - 1 do
    local at = sample_at(from, ratio, x + offset)
    local left = floor(at)
    lower[x] = left * stride
    upper[x] = math.min(from - 1, left + 1) * stride
    fraction[x] = at - left
  end
  return { lower = lower, upper = upper, fraction = fraction }
end

local function repeat_pattern(out, pattern, count)
  if count >= 4 then
    out[#out + 1] = "!" .. count .. char(pattern)
  elseif count > 0 then
    out[#out + 1] = char(pattern):rep(count)
  end
end

local function color_plane(out, masks, first, last)
  local pattern, run = -1, 0
  for x = first, last do
    local next_pattern = masks[x] + 63
    if pattern == next_pattern then
      run = run + 1
    else
      repeat_pattern(out, pattern, run)
      pattern, run = next_pattern, 1
    end
  end
  repeat_pattern(out, pattern, run)
end

local function paint_band(out, masks, first, last, width)
  -- PDF pages are opaque. Paint white first, then overprint darker pixels.
  out[#out + 1] = "#" .. WHITE .. "!" .. width .. "~"
  for gray = 0, WHITE - 1 do
    if last[gray] >= 0 then
      out[#out + 1] = "$#" .. gray
      repeat_pattern(out, 63, first[gray])
      local base = gray * width
      color_plane(out, masks, base + first[gray], base + last[gray])
      first[gray] = width
      last[gray] = -1
    end
  end
end

local function sample_row(image, masks, first, last, y, mask)
  local cols, rows = image.cols, image.rows
  local row1 = (rows.lower[y] - image.source_first) * image.source_width
  local row2 = (rows.upper[y] - image.source_first) * image.source_width
  local dy = rows.fraction[y]
  local source = image.pixels
  for x = 0, image.width - 1 do
    local left, right = cols.lower[x], cols.upper[x]
    local dx = cols.fraction[x]
    local a, b = source[row1 + left], source[row2 + left]
    a = a + (source[row1 + right] - a) * dx
    b = b + (source[row2 + right] - b) * dx
    local gray = floor((a + (b - a) * dy) * (WHITE / 255) + 0.5)
    if gray < WHITE then
      local index = gray * image.width + x
      masks[index] = masks[index] + mask
      first[gray] = math.min(first[gray], x)
      last[gray] = math.max(last[gray], x)
    end
  end
end

local function palette()
  local colors = {}
  for gray = 0, WHITE do
    local value = floor(gray / WHITE * 100 + 0.5)
    colors[#colors + 1] = ("#%d;2;%d;%d;%d"):format(gray, value, value, value)
  end
  return table.concat(colors)
end

local function scan(image, rows)
  local width = image.width
  local masks = ffi.new("uint8_t[?]", width * LEVELS)
  local first = ffi.new("int[?]", LEVELS)
  local last = ffi.new("int[?]", LEVELS)
  for gray = 0, WHITE - 1 do
    first[gray], last[gray] = width, -1
  end
  local bands, bytes = {}, 0
  for row = 0, rows - 1, 6 do
    ffi.fill(masks, width * LEVELS)
    for bit = 0, 5 do
      sample_row(image, masks, first, last, row + bit, 2 ^ bit)
    end
    local out = {}
    paint_band(out, masks, first, last, width)
    local band = table.concat(out)
    bytes = bytes + #band + 1
    if bytes > MAX_BYTES then
      return
    end
    bands[#bands + 1] = band
  end
  return table.concat(bands, "-")
end

local function prepare(path, width, height, page_width, span)
  local rgb, source_width, source_height, first = read_ppm(path, height, span)
  if not rgb then
    return
  end
  local pixels = ffi.cast("const uint8_t*", rgb)
  if not span.known_gray and not is_gray(pixels, #rgb) then
    return
  end
  return {
    bytes = rgb, -- Keep the string alive while sampling its bytes via FFI.
    pixels = pixels,
    source_width = source_width * 3,
    source_first = first,
    width = width,
    cols = samples(source_width, page_width, width, span.left, 3),
    rows = samples(source_height, height, span.rows, span.offset, 1),
  }
end

return function(
  path,
  width,
  height,
  page_width,
  first_band,
  last_band,
  known_gray,
  left
)
  first_band, last_band = first_band or 1, last_band or height / 6
  if width < 1 or height < 6 or height % 6 ~= 0 then
    return
  end
  if width > page_width or width > MAX_EDGE then
    return
  end
  local span = {
    offset = (first_band - 1) * 6,
    rows = (last_band - first_band + 1) * 6,
    known_gray = known_gray,
    left = left or floor((page_width - width) / 2),
  }
  if span.offset < 0 or span.rows < 6 or span.offset + span.rows > height then
    return
  end
  if width * span.rows > 12 * 1024 * 1024 then
    return
  end
  local image = prepare(path, width, height, page_width, span)
  if image then
    return scan(image, span.rows), palette()
  end
end
