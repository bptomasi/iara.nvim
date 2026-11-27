--- First-page preview with the same renderer and text fallback as IaraPDF.
local graphics = require("iara.features.pdf.graphics")
local source = require("iara.features.pdf.source")
local api = vim.api

local M = {}

local function discard(thumbnail)
  if thumbnail.image_path then
    graphics.forget(thumbnail.image_path)
  end
  if thumbnail.dir then
    vim.fn.delete(thumbnail.dir, "rf")
  end
end

local function fingerprint(path, size)
  local info = vim.uv.fs_stat(path)
  if info then
    return table.concat({
      path,
      size,
      info.ino,
      info.size,
      info.mtime.sec,
      info.mtime.nsec,
    }, "\0")
  end
end

local function cached(cache, key)
  for index, entry in ipairs(cache) do
    if key == entry.key then
      table.remove(cache, index)
      cache[#cache + 1] = entry
      return entry
    end
  end
end

local function remember(state)
  if state.key and state.cache and state.dir then
    local cache = state.cache
    cache[#cache + 1] = {
      key = state.key,
      image_path = state.image_path,
      dir = state.dir,
    }
    state.dir, state.retained = nil, true
    if #cache > 4 then
      discard(table.remove(cache, 1))
    end
  end
end

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
    remember(state)
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

local function raster_size(win, cell)
  local width = (api.nvim_win_get_width(win) - 2) * cell.cell_width
  local height = (api.nvim_win_get_height(win) - 2) * cell.cell_height
  return math.max(1, math.min(1800, math.ceil(math.max(width, height))))
end

function M.open(preview, path, cache)
  local state = { cache = cache }
  local available = graphics.available()
  local cell = available and graphics.size()
  if not cell then
    show_text(state, preview, path)
    return state
  end
  local size = raster_size(preview.win.win, cell)
  state.key = fingerprint(path, size)
  local thumbnail = cache and cached(cache, state.key)
  if thumbnail then
    state.retained = true
    finish(state, preview, path, thumbnail.image_path)
    return state
  end
  state.dir = source.directory()
  if state.dir then
    state.job = source.raster(
      path,
      1,
      state.dir .. "/preview",
      size,
      function(image_path)
        finish(state, preview, path, image_path)
      end,
      graphics.virtual_scroll() and "ppm" or "png"
    )
  else
    show_text(state, preview, path)
  end
  return state
end

function M.close(state)
  state.closed = true
  if state.job then
    state.job:cancel("PDF preview changed")
  end
  if state.picture then
    state.picture:clear()
  end
  if not state.retained then
    discard(state)
  end
end

function M.close_cache(cache)
  for _, entry in ipairs(cache) do
    discard(entry)
  end
end

return M
