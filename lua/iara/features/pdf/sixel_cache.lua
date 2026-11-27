--- Encode each page at its drawing size once, off the editor thread.
--- The viewer owns the source raster and drops its matching encodings.
local proc = require("iara.core.proc")
local data = require("iara.features.pdf.sixel_data")
local source = debug.getinfo(1, "S").source:sub(2)
local gray_module = vim.fs.joinpath(vim.fs.dirname(source), "sixel_gray.lua")

local M = {}
local entries = {}
local staged = {}
local queue = {}
local history = {}
local history_bytes = 0
local history_limit = 8 * 1024 * 1024
local running = 0
local pump

local function fast_command(entry)
  local argv = { "img2sixel" }
  vim.list_extend(
    argv,
    { "-w", tostring(entry.width), "-h", tostring(entry.height) }
  )
  vim.list_extend(argv, { "-d", "none", "-p", "64" })
  return vim.list_extend(argv, { "-t", "rgb", "-E", "size", entry.path })
end

local function magick_command(entry)
  local converter = vim.fn.executable("magick") == 1 and "magick" or "convert"
  local size = ("%dx%d!"):format(entry.page_width, entry.height)
  local argv = { converter, "-limit", "thread", "2", entry.path }
  vim.list_extend(argv, { "-filter", "Lanczos", "-resize", size })
  if entry.width < entry.page_width then
    local offset = math.floor((entry.page_width - entry.width) / 2)
    local crop = ("%dx%d+%d+0"):format(entry.width, entry.height, offset)
    vim.list_extend(argv, { "-crop", crop, "+repage" })
  end
  return vim.list_extend(
    argv,
    { "-alpha", "off", "+dither", "-colors", "64", "sixel:-" }
  )
end

local function decode(entry, result)
  if result.code ~= 0 or result.status ~= "exited" then
    return
  end
  local output = result.stdout or ""
  local raster = data.decode(output)
  if
    raster
    and raster.width == entry.width
    and raster.height == entry.height
  then
    entry.raster, entry.bytes = raster, #output
  end
end

local function owns(entry)
  return entries[entry.path] == entry or staged[entry.path] == entry
end

local function finish(entry)
  if owns(entry) then
    entry.failed = not entry.raster
    entry.ready()
  end
  running = running - 1
  pump()
end

local function encode_with_command(entry, fast)
  local argv = fast and fast_command(entry) or magick_command(entry)
  entry.job = proc.spawn(argv, {
    cwd = vim.fs.dirname(entry.path),
    timeout_ms = 10000,
    stdout = { max_bytes = 8 * 1024 * 1024 },
    on_complete = function(result)
      entry.job = nil
      if owns(entry) then
        decode(entry, result)
        if not entry.raster and fast then
          return encode_with_command(entry, false)
        end
      end
      finish(entry)
    end,
  })
end

local function render_gray(module, path, width, height, page_width)
  local ok, bands, palette = pcall(function()
    return dofile(module)(path, width, height, page_width)
  end)
  if ok and bands then
    return bands, palette
  end
  return "", ""
end

local function encode(entry)
  local fast = entry.page_width == entry.width
    and vim.fn.executable("img2sixel") == 1
  local function completed(bands, palette)
    entry.working = false
    if owns(entry) then
      local bytes = #bands + #palette
      if bands == "" or bytes > history_limit then
        return encode_with_command(entry, fast)
      end
      entry.raster = {
        width = entry.width,
        height = entry.height,
        palette = palette,
        bands = vim.split(bands, "-", { plain = true }),
      }
      entry.bytes = bytes
    end
    finish(entry)
  end
  local worker = vim.uv.new_work(render_gray, vim.schedule_wrap(completed))
  entry.working = worker
    and worker:queue(
      gray_module,
      entry.path,
      entry.width,
      entry.height,
      entry.page_width
    )
  if not entry.working then
    encode_with_command(entry, fast)
  end
end

pump = function()
  while running < 2 and #queue > 0 do
    local entry = table.remove(queue, 1)
    if owns(entry) then
      running = running + 1
      encode(entry)
    end
  end
end

local function remove_history(index)
  local entry = table.remove(history, index)
  history_bytes = history_bytes - entry.bytes
  return entry
end

local function remember(entry)
  if not entry or not entry.raster or entry.bytes > history_limit then
    return
  end
  history[#history + 1] = entry
  history_bytes = history_bytes + entry.bytes
  while #history > 8 or history_bytes > history_limit do
    remove_history(1)
  end
end

local function matches(entry, path, width, height, page_width)
  return entry
    and entry.path == path
    and entry.width == width
    and entry.height == height
    and entry.page_width == (page_width or width)
end

local function take(path, width, height, page_width)
  for i, entry in ipairs(history) do
    if matches(entry, path, width, height, page_width) then
      return remove_history(i)
    end
  end
end

local function retire(entry)
  if entry and entry.job then
    entry.job:cancel("PDF image discarded")
  elseif entry and not entry.raster then
    for index, queued in ipairs(queue) do
      if queued == entry then
        table.remove(queue, index)
        break
      end
    end
  end
end

function M.forget(path)
  retire(entries[path])
  retire(staged[path])
  entries[path], staged[path] = nil, nil
  for index = #history, 1, -1 do
    if history[index].path == path then
      remove_history(index)
    end
  end
end

local function promote(entry)
  if not (entry.working or entry.job or entry.raster or entry.failed) then
    retire(entry)
    table.insert(queue, 1, entry)
    pump()
  end
end

function M.ready(path, width, height, page_width)
  local entry = entries[path]
  return matches(entry, path, width, height, page_width) and entry.raster ~= nil
end

function M.prepare(path, width, height, ready, visible, page_width)
  local active = entries[path]
  if matches(active, path, width, height, page_width) then
    if visible then
      active.ready = ready
      promote(active)
    end
    return active
  end
  retire(active)
  local cached = take(path, width, height, page_width)
  remember(active)
  if matches(staged[path], path, width, height, page_width) then
    cached, staged[path] = staged[path], nil
  end
  if cached then
    cached.ready = ready
    entries[path] = cached
    if visible then
      promote(cached)
    end
    return cached
  end
  local entry = {
    path = path,
    width = width,
    height = height,
    page_width = page_width or width,
    ready = ready,
  }
  entries[path] = entry
  table.insert(queue, visible and 1 or #queue + 1, entry)
  pump()
  return entry
end

function M.stage(path, width, height, page_width)
  if
    matches(entries[path], path, width, height, page_width)
    or matches(staged[path], path, width, height, page_width)
  then
    return
  end
  for _, entry in ipairs(history) do
    if matches(entry, path, width, height, page_width) then
      return
    end
  end
  local previous = staged[path]
  retire(previous)
  remember(previous)
  local entry = {
    path = path,
    width = width,
    height = height,
    page_width = page_width or width,
    ready = function() end,
  }
  staged[path] = entry
  queue[#queue + 1] = entry
  pump()
end

---Keep display-sized encodings when a higher-resolution source arrives.
function M.retain(old_path, new_path, max_size)
  local function reusable(entry)
    return entry
      and entry.raster
      and math.max(entry.page_width, entry.height) <= max_size
  end
  local active, pending = entries[old_path], staged[old_path]
  for _, entry in pairs({ active, pending }) do
    if reusable(entry) then
      entry.path = new_path
      remember(entry)
    end
  end
  for _, entry in ipairs(history) do
    if entry.path == old_path and reusable(entry) then
      entry.path = new_path
    end
  end
  M.forget(old_path)
end

return M
