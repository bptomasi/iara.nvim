--- Pack cached Sixel bands for the visible viewport.
local ffi = require("ffi")
local M = {}
local masks = {}
local scratch_size = 64 * 1024
local scratch = ffi.new("uint8_t[?]", scratch_size)

function M.decode(data)
  local width, height, body =
    data:match('^\27P[0-9;]*q"1;1;(%d+);(%d+)(.*)\27\\$')
  if not body or body:find("%c") then
    return nil
  end
  local colors = {}
  body = body:gsub("#%d+;%d+;%d+;%d+;%d+", function(definition)
    colors[#colors + 1] = definition
    return ""
  end)
  local bands = vim.split(body, "-", { plain = true })
  local color = "#0"
  for i, band in ipairs(bands) do
    bands[i] = color .. band
    color = band:match("^.*(#%d+)") or color
  end
  return {
    width = tonumber(width),
    height = tonumber(height),
    palette = table.concat(colors),
    bands = bands,
  }
end

function M.bounds(page_height, skip, height)
  -- Round the top down by at most five pixels. Limit the bottom to
  -- complete bands so the terminal cannot paint across a window border.
  local first = math.floor(skip / 6) + 1
  local last =
    math.min(first + math.floor(height / 6) - 1, math.ceil(page_height / 6))
  if last >= first then
    return first, last
  end
end

---Pin the bands of a frame. The cache can evict them while this frame is
---still on screen and may need repainting.
function M.capture(raster, first, last)
  if not raster then
    return
  end
  local bands = {}
  for band = first, last do
    local bytes = raster.bands[band]
    if not bytes then
      return
    end
    bands[#bands + 1] = bytes
  end
  return { raster = raster, first = first, last = last, bands = bands }
end

local function packet(frame, pixels, body)
  return ('\27P0;1;0q"1;1;%d;%d%s%s\27\\'):format(
    frame.raster.width,
    pixels,
    frame.raster.palette,
    body
  )
end

function M.pack(frame, first, last)
  local pixels = (last - first + 1) * 6
  local offset = 1 - frame.first
  local body = table.concat(frame.bands, "-", first + offset, last + offset)
  return packet(frame, pixels, body), pixels
end

local function translation(shift, rows)
  local key = shift * 8 + rows
  local map = masks[key]
  if not map then
    map = ffi.new("uint8_t[256]")
    for byte = 0, 255 do
      map[byte] = byte
    end
    -- Only the Sixel pixel masks occupy ASCII 63–126.
    local scale, modulo = 2 ^ shift, 2 ^ rows
    for bits = 0, 63 do
      map[63 + bits] = 63 + math.floor(bits * scale) % modulo
    end
    masks[key] = map
  end
  return map
end

local function translate(bytes, shift, rows)
  if shift == 0 and rows == 6 then
    return bytes
  end
  local count = #bytes
  local map = translation(shift, rows)
  local output = count <= scratch_size and scratch
    or ffi.new("uint8_t[?]", count)
  local source = ffi.cast("const uint8_t*", bytes)
  for index = 0, count - 1 do
    output[index] = map[source[index]]
  end
  return ffi.string(output, count)
end

local function band_at(frame, index)
  return frame.bands[index - frame.first + 1] or frame.raster.bands[index]
end

local function band_bytes(frame, first, last)
  local total = 0
  for index = first, last do
    local band = band_at(frame, index)
    if not band then
      return
    end
    total = total + #band
  end
  return total
end

---Size of a strip's pixel data, including band and plane separators.
function M.row_bytes(frame, source, height)
  local index, phase = math.floor(source / 6) + 1, source % 6
  local count = math.ceil(height / 6)
  local upper = band_bytes(frame, index, index + count - 1)
  if not upper then
    return
  end
  if phase == 0 then
    return upper + count - 1
  end
  local joined = math.floor((height + phase - 1) / 6)
  local lower = band_bytes(frame, index + 1, index + joined)
  if lower then
    return upper + lower + joined + count - 1
  end
end

local function encode_rows(frame, index, phase, rows)
  local upper = band_at(frame, index)
  if not upper then
    return
  end
  upper = translate(upper, -phase, rows)
  if rows + phase <= 6 then
    return upper
  end
  local lower = band_at(frame, index + 1)
  if lower then
    -- Both color planes start at column zero and occupy disjoint bits.
    return upper .. "$" .. translate(lower, 6 - phase, rows)
  end
end

---Encode a strip at an exact pixel offset using the existing palette.
function M.pack_rows(frame, source, height)
  local index, phase = math.floor(source / 6) + 1, source % 6
  local last = index + math.ceil(height / 6) - 1
  if
    phase == 0
    and height % 6 == 0
    and index >= frame.first
    and last <= frame.last
  then
    return (M.pack(frame, index, last))
  end
  local bands = {}
  for row = 0, height - 1, 6 do
    local encoded = encode_rows(frame, index, phase, math.min(6, height - row))
    if not encoded then
      return
    end
    bands[#bands + 1] = encoded
    index = index + 1
  end
  return packet(frame, height, table.concat(bands, "-"))
end

return M
