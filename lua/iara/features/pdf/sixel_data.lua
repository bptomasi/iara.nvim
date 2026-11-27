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

function M.slice(raster, skip, height)
  -- Round the top down by at most five pixels. Limit the bottom to
  -- complete bands so the terminal cannot paint across a window border.
  local first = math.floor(skip / 6) + 1
  local last = math.min(
    first + math.floor(height / 6) - 1,
    math.ceil(raster.height / 6),
    #raster.bands
  )
  if last < first then
    return nil
  end
  local pixels = (last - first + 1) * 6
  return ('\27P0;1;0q"1;1;%d;%d%s%s\27\\'):format(
    raster.width,
    pixels,
    raster.palette,
    table.concat(raster.bands, "-", first, last)
  ),
    pixels
end

return M
