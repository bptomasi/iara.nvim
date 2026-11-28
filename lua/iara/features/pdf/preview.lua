--- First-page preview with the same renderer and text fallback as IaraPDF.
local graphics = require("iara.features.pdf.graphics")
local cache = require("iara.features.pdf.raster_cache")
local source = require("iara.features.pdf.source")
local api = vim.api

local M = {}

local function dimensions(path)
  local file = assert(io.open(path, "rb"))
  if vim.endswith(path, ".ppm") then
    local magic, size = file:read("*l", "*l")
    file:close()
    local w, h = (size or ""):match("^(%d+) (%d+)$")
    assert(magic == "P6" and w and h, "Could not read the PDF thumbnail.")
    return tonumber(w), tonumber(h)
  end
  local header = file:read(24)
  file:close()
  assert(
    header and #header == 24 and header:sub(13, 16) == "IHDR",
    "Could not read the PDF thumbnail."
  )
  local function uint(at)
    local a, b, c, d = header:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return uint(17), uint(21)
end

local function draw(preview, image_path, on_error)
  local w, h = dimensions(image_path)
  local win = preview.win.win
  local gutter = vim.fn.getwininfo(win)[1].textoff
  local cols = math.max(1, api.nvim_win_get_width(win) - gutter)
  local rows = api.nvim_win_get_height(win)
  local width, height =
    graphics.fit(w / h, math.max(1, cols - 2), math.max(1, rows - 2))
  preview:set_lines({ "" })
  return graphics.picture(image_path, win, preview.win.buf, {
    x = math.floor((cols - width) / 2),
    y = math.floor((rows - height) / 2),
    width = width,
    height = height,
    preview = true,
    on_error = on_error,
  })
end

local function show_text(state, preview, path)
  state.job = source.text(path, 1, function(lines, err)
    state.job = nil
    if not state.closed and preview.win:valid() then
      preview:set_lines(lines or { err or "Could not preview this PDF." })
    end
  end)
end

local function finish(state, preview, path, image_path)
  state.job = nil
  if state.closed or not preview.win:valid() then
    return
  end
  if image_path then
    state.image_path = image_path
    local ok, picture = pcall(draw, preview, image_path, function()
      if not state.closed and preview.win:valid() then
        state.picture:clear()
        state.picture = nil
        show_text(state, preview, path)
      end
    end)
    if ok then
      state.picture = picture
      return
    end
  end
  show_text(state, preview, path)
end

local function raster_size(win, cell, format)
  local width = (api.nvim_win_get_width(win) - 2) * cell.cell_width
  local height = (api.nvim_win_get_height(win) - 2) * cell.cell_height
  if format == "ppm" then
    -- A PPM for the full reading height can also open the document directly.
    height = math.max(height, (vim.o.lines - 4) * cell.cell_height)
  end
  local size = math.ceil(math.max(width, height) / 256) * 256
  return math.max(1, math.min(format == "ppm" and 2048 or 1800, size))
end

local function rendered(state, preview, path, image, bytes)
  if image and not state.closed then
    if state.key and state.key == cache.identity(path, state.format) then
      state.raster =
        cache.remember(state.key, state.dir, image, state.size, bytes)
      state.dir = nil
    end
  end
  finish(state, preview, path, image)
end

function M.open(preview, path)
  local state = {}
  local available = graphics.available()
  local cell = available and graphics.size()
  if not cell then
    show_text(state, preview, path)
    return state
  end
  state.format = graphics.virtual_scroll() and "ppm" or "png"
  state.size = raster_size(preview.win.win, cell, state.format)
  state.key = cache.identity(path, state.format)
  state.raster = cache.acquire(state.key, state.size)
  if state.raster then
    finish(state, preview, path, state.raster.path)
    return state
  end
  state.dir = source.directory()
  if state.dir then
    state.job = source.raster(
      path,
      1,
      state.dir .. "/preview",
      state.size,
      function(image_path, _, bytes)
        rendered(state, preview, path, image_path, bytes)
      end,
      state.format
    )
  else
    show_text(state, preview, path)
  end
  return state
end

function M.close(state)
  if state.closed then
    return
  end
  state.closed = true
  if state.job then
    state.job:cancel("PDF preview changed")
  end
  if state.picture then
    state.picture:clear()
  end
  if state.raster then
    cache.release(state.raster)
  elseif state.dir then
    if state.image_path then
      graphics.forget(state.image_path)
    end
    vim.fn.delete(state.dir, "rf")
  end
end

return M
