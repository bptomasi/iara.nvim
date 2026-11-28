--- Produce Sixel bands off the editor thread. The color converters supply
--- a single shared palette for the whole page, so only gray work is partial.
local proc = require("iara.core.proc")
local data = require("iara.features.pdf.sixel_data")
local source = debug.getinfo(1, "S").source:sub(2)
local gray_module = vim.fs.joinpath(vim.fs.dirname(source), "sixel_gray.lua")
local M = {}

local function fast_command(entry)
  local argv = { "img2sixel" }
  vim.list_extend(
    argv,
    { "-w", tostring(entry.width), "-h", tostring(entry.height) }
  )
  vim.list_extend(argv, { "-d", "none", "-p", "64" })
  return vim.list_extend(argv, { "-t", "rgb", "-E", "size", entry.path })
end

local function crop(argv, width, height, left)
  local geometry = ("%dx%d+%d+0"):format(width, height, left)
  vim.list_extend(argv, { "-crop", geometry, "+repage" })
end

local function extent(path)
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local header = file:read(80)
  file:close()
  local width, height = (header or ""):match("^P6\n(%d+) (%d+)\n255\n")
  return tonumber(width), tonumber(height)
end

local function resize(argv, entry)
  local width, left = entry.page_width, entry.offset
  if entry.width < width then
    local source_width, source_height = extent(entry.path)
    if source_width and source_width > 0 and source_height > 0 then
      local scale = width / source_width
      -- Keep the resampling neighborhood around the visible columns.
      local padding = math.max(4, math.ceil(4 / scale))
      local first = math.max(0, math.floor(left / scale) - padding)
      local last = math.min(
        source_width,
        math.ceil((left + entry.width) / scale) + padding
      )
      crop(argv, last - first, source_height, first)
      local start = math.floor(first * scale + 0.5)
      width, left = math.floor(last * scale + 0.5) - start, left - start
    end
  end
  local size = ("%dx%d!"):format(width, entry.height)
  vim.list_extend(argv, { "-resize", size })
  if entry.width < width then
    crop(argv, entry.width, entry.height, left)
  end
end

local function magick_command(entry)
  local converter = vim.fn.executable("magick") == 1 and "magick" or "convert"
  local argv = { converter, "-limit", "thread", "2", entry.path }
  vim.list_extend(argv, { "-filter", "Lanczos" })
  resize(argv, entry)
  return vim.list_extend(
    argv,
    { "-alpha", "off", "+dither", "-colors", "64", "sixel:-" }
  )
end

local function decoded(entry, result)
  if result.code ~= 0 or result.status ~= "exited" then
    return
  end
  local raster = data.decode(result.stdout or "")
  if
    raster
    and raster.width == entry.width
    and raster.height == entry.height
  then
    return raster
  end
end

local function command(entry, task, fast, done)
  local argv = fast and fast_command(entry) or magick_command(entry)
  task.first, task.last = 1, entry.height / 6
  task.job = proc.spawn(argv, {
    cwd = vim.fs.dirname(entry.path),
    timeout_ms = 10000,
    stdout = { max_bytes = 8 * 1024 * 1024 },
    on_complete = function(result)
      task.job = nil
      if task.cancelled then
        return done()
      end
      local raster = decoded(entry, result)
      if not raster and fast then
        return command(entry, task, false, done)
      end
      done(raster, true)
    end,
  })
end

local function gray(
  module,
  path,
  width,
  height,
  page_width,
  first,
  last,
  known,
  offset
)
  local ok, bands, palette = pcall(function()
    return dofile(module)(
      path,
      width,
      height,
      page_width,
      first,
      last,
      known,
      offset
    )
  end)
  if ok and bands then
    return bands, palette
  end
  return "", ""
end

function M.start(entry, task, done)
  local fast = entry.page_width == entry.width
    and vim.fn.executable("img2sixel") == 1
  local function completed(bands, palette)
    if task.cancelled then
      return done()
    end
    if bands == "" then
      return command(entry, task, fast, done)
    end
    done({
      width = entry.width,
      height = entry.height,
      palette = palette,
      bands = vim.split(bands, "-", { plain = true }),
    }, false)
  end
  local worker = vim.uv.new_work(gray, vim.schedule_wrap(completed))
  local queued = worker
    and worker:queue(
      gray_module,
      entry.path,
      entry.width,
      entry.height,
      entry.page_width,
      task.first,
      task.last,
      entry.gray == true,
      entry.offset
    )
  if not queued then
    command(entry, task, fast, done)
  end
end

return M
