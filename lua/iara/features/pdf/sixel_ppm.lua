--- Encode visible bands of Poppler's PPM pages in a libuv worker.
local ffi = require("ffi")
ffi.cdef("int memcmp(const void *, const void *, size_t);")
local memcmp = ffi.C.memcmp

local LEVELS = 64
local WHITE = LEVELS - 1
local RED_LEVELS, GREEN_LEVELS, BLUE_LEVELS = 6, 6, 5
local COLORS = LEVELS + RED_LEVELS * GREEN_LEVELS * BLUE_LEVELS
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
  if span.grayscale ~= nil then
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

local function paint_band(out, masks, first, last, width, count)
  -- PDF pages are opaque. Paint white first, then overprint darker pixels.
  out[#out + 1] = "#" .. WHITE .. "!" .. width .. "~"
  for color = 0, count - 1 do
    if last[color] >= 0 then
      out[#out + 1] = "$#" .. color
      repeat_pattern(out, 63, first[color])
      local base = color * width
      color_plane(out, masks, base + first[color], base + last[color])
      ffi.fill(masks + base + first[color], last[color] - first[color] + 1)
      first[color] = width
      last[color] = -1
    end
  end
end

local function mark(masks, first, last, width, x, color, mask)
  if color ~= WHITE then
    local index = color * width + x
    masks[index] = masks[index] + mask
    first[color] = math.min(first[color], x)
    last[color] = math.max(last[color], x)
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
    mark(masks, first, last, image.width, x, gray, mask)
  end
end

local function palette(grayscale)
  local colors = {}
  for gray = 0, WHITE do
    local value = floor(gray / WHITE * 100 + 0.5)
    colors[#colors + 1] = ("#%d;2;%d;%d;%d"):format(gray, value, value, value)
  end
  if not grayscale then
    -- Every band uses the same palette, including bands produced by
    -- different workers as the viewport moves.
    for r = 0, RED_LEVELS - 1 do
      for g = 0, GREEN_LEVELS - 1 do
        for b = 0, BLUE_LEVELS - 1 do
          colors[#colors + 1] = ("#%d;2;%d;%d;%d"):format(
            #colors,
            floor(r * 100 / (RED_LEVELS - 1) + 0.5),
            floor(g * 100 / (GREEN_LEVELS - 1) + 0.5),
            floor(b * 100 / (BLUE_LEVELS - 1) + 0.5)
          )
        end
      end
    end
  end
  return table.concat(colors)
end

local function rgb_index(r, g, b)
  if r == g and r == b then
    return floor(r * (WHITE / 255) + 0.5)
  end
  local red = floor(r * ((RED_LEVELS - 1) / 255) + 0.5)
  local green = floor(g * ((GREEN_LEVELS - 1) / 255) + 0.5)
  local blue = floor(b * ((BLUE_LEVELS - 1) / 255) + 0.5)
  return LEVELS + (red * GREEN_LEVELS + green) * BLUE_LEVELS + blue
end

local function interpolate(pixels, left, right, dx)
  local a = pixels[left]
  return a + (pixels[right] - a) * dx
end

local function channel(pixels, a, b, c, d, dx, dy)
  local upper = interpolate(pixels, a, b, dx)
  local lower = interpolate(pixels, c, d, dx)
  return floor(upper + (lower - upper) * dy + 0.5)
end

local function sample_color_row(image, masks, first, last, y, mask)
  local cols, rows, pixels = image.cols, image.rows, image.pixels
  local upper = (rows.lower[y] - image.source_first) * image.source_width
  local lower = (rows.upper[y] - image.source_first) * image.source_width
  local dy = rows.fraction[y]
  for x = 0, image.width - 1 do
    local left, right, dx = cols.lower[x], cols.upper[x], cols.fraction[x]
    local a, b = upper + left, upper + right
    local c, d = lower + left, lower + right
    local r = channel(pixels, a, b, c, d, dx, dy)
    local g = channel(pixels, a + 1, b + 1, c + 1, d + 1, dx, dy)
    local blue = channel(pixels, a + 2, b + 2, c + 2, d + 2, dx, dy)
    mark(masks, first, last, image.width, x, rgb_index(r, g, blue), mask)
  end
end

local function native_row(image, y)
  local row = (image.rows.lower[y] - image.source_first) * image.source_width
  return image.pixels + row + image.left
end

local function native_gray_row(image, masks, first, last, y, mask)
  local pixels = native_row(image, y)
  for x = 0, image.width - 1 do
    local gray = floor(pixels[x * 3] * (WHITE / 255) + 0.5)
    mark(masks, first, last, image.width, x, gray, mask)
  end
end

local function native_color_row(image, masks, first, last, y, mask)
  local pixels = native_row(image, y)
  for x = 0, image.width - 1 do
    local offset = x * 3
    local color =
      rgb_index(pixels[offset], pixels[offset + 1], pixels[offset + 2])
    mark(masks, first, last, image.width, x, color, mask)
  end
end

local function blank_source_row(image, row)
  local index = row - image.source_first
  local seen = image.blank[index]
  if seen == 0 then
    local start = index * image.source_width + image.left
    -- Keep one result per source row since neighboring samples share it.
    seen = memcmp(image.pixels + start, image.white, #image.white) == 0 and 2
      or 1
    image.blank[index] = seen
  end
  return seen == 2
end

local function row_has_ink(image, y)
  return not blank_source_row(image, image.rows.lower[y])
    or (not image.native and not blank_source_row(image, image.rows.upper[y]))
end

local function row_sampler(native, grayscale)
  if native then
    return grayscale and native_gray_row or native_color_row
  end
  return grayscale and sample_row or sample_color_row
end

local function scan(image, rows, grayscale)
  local width = image.width
  local count = grayscale and LEVELS or COLORS
  local sample = row_sampler(image.native, grayscale)
  local masks = ffi.new("uint8_t[?]", width * count)
  local first = ffi.new("int[?]", count)
  local last = ffi.new("int[?]", count)
  for color = 0, count - 1 do
    first[color], last[color] = width, -1
  end
  local bands, bytes = {}, 0
  for row = 0, rows - 1, 6 do
    for bit = 0, 5 do
      local y = row + bit
      if row_has_ink(image, y) then
        sample(image, masks, first, last, y, 2 ^ bit)
      end
    end
    local out = {}
    paint_band(out, masks, first, last, width, count)
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
  local grayscale = span.grayscale
  if grayscale == nil then
    grayscale = is_gray(pixels, #rgb)
  end
  local cols = samples(source_width, page_width, width, span.left, 3)
  local left, right = cols.lower[0], cols.upper[width - 1]
  -- Poppler's detail crop already matches the requested pixel grid.
  local native = source_width == page_width
    and source_height == height
    and span.left % 1 == 0
    and span.left >= 0
    and span.left + width <= page_width
  return {
    blank = ffi.new("uint8_t[?]", #rgb / (source_width * 3)),
    left = left,
    white = ("\255"):rep(right - left + 3),
    bytes = rgb, -- Keep the string alive while sampling its bytes via FFI.
    pixels = pixels,
    source_width = source_width * 3,
    source_first = first,
    width = width,
    native = native,
    cols = cols,
    rows = samples(source_height, height, span.rows, span.offset, 1),
  },
    grayscale
end

return function(
  path,
  width,
  height,
  page_width,
  first_band,
  last_band,
  grayscale,
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
    grayscale = grayscale,
    left = left or floor((page_width - width) / 2),
  }
  if span.offset < 0 or span.rows < 6 or span.offset + span.rows > height then
    return
  end
  if width * span.rows > 12 * 1024 * 1024 then
    return
  end
  local image, gray = prepare(path, width, height, page_width, span)
  if image then
    local bands = scan(image, span.rows, gray)
    return bands, bands and palette(gray), gray
  end
end
