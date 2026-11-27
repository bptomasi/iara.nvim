--- Encode Poppler's grayscale PPM pages directly in a libuv worker.
local ffi = require("ffi")

local LEVELS = 64
local WHITE = LEVELS - 1
local MAX_EDGE = 4096
local MAX_BYTES = 8 * 1024 * 1024
local floor = math.floor
local char = string.char

local function read_ppm(path)
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
  local rgb = file:read(width * height * 3)
  file:close()
  if rgb and #rgb == width * height * 3 then
    return rgb, width, height
  end
end

local function grayscale(rgb, pixels)
  local gray = ffi.new("uint8_t[?]", pixels)
  -- This loop allocates nothing while reading the string's bytes via FFI.
  local source = ffi.cast("const uint8_t*", rgb)
  for i = 0, pixels - 1 do
    local offset = i * 3
    local red = source[offset]
    if red ~= source[offset + 1] or red ~= source[offset + 2] then
      return
    end
    gray[i] = red
  end
  return gray
end

local function samples(from, to, count, offset)
  local lower = ffi.new("int[?]", count)
  local upper = ffi.new("int[?]", count)
  local fraction = ffi.new("float[?]", count)
  local ratio = from / to
  for x = 0, count - 1 do
    local at = (x + offset + 0.5) * ratio - 0.5
    at = math.max(0, math.min(from - 1, at))
    lower[x] = floor(at)
    upper[x] = math.min(from - 1, lower[x] + 1)
    fraction[x] = at - lower[x]
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
  local row1 = rows.lower[y] * image.source_width
  local row2 = rows.upper[y] * image.source_width
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

local function scan(image, height)
  local width = image.width
  local masks = ffi.new("uint8_t[?]", width * LEVELS)
  local first = ffi.new("int[?]", LEVELS)
  local last = ffi.new("int[?]", LEVELS)
  for gray = 0, WHITE - 1 do
    first[gray], last[gray] = width, -1
  end
  local bands, bytes = {}, 0
  for row = 0, height - 1, 6 do
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

return function(path, width, height, page_width)
  if width < 1 or height < 6 or height % 6 ~= 0 then
    return
  end
  if width > page_width or width > MAX_EDGE or height > 8192 then
    return
  end
  if width * height > 12 * 1024 * 1024 then
    return
  end
  local rgb, source_width, source_height = read_ppm(path)
  if not rgb then
    return
  end
  local pixels = grayscale(rgb, source_width * source_height)
  if not pixels then
    return
  end
  local image = {
    pixels = pixels,
    source_width = source_width,
    width = width,
    cols = samples(
      source_width,
      page_width,
      width,
      floor((page_width - width) / 2)
    ),
    rows = samples(source_height, height, height, 0),
  }
  return scan(image, height), palette()
end
