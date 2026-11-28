--- Split ImageMagick's Sixel raster into six-pixel bands once. Each
--- viewport slice carries the palette and starts on a complete band.
local M = {}

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
    for selected in band:gmatch("#%d+") do
      color = selected
    end
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

function M.pack(frame, first, last)
  local pixels = (last - first + 1) * 6
  local offset = 1 - frame.first
  return ('\27P0;1;0q"1;1;%d;%d%s%s\27\\'):format(
    frame.raster.width,
    pixels,
    frame.raster.palette,
    table.concat(frame.bands, "-", first + offset, last + offset)
  ),
    pixels
end

return M
