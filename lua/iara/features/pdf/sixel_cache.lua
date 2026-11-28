--- Retain only encoded bands at each scale. Foreground requests describe
--- what each window can see and may supersede speculative work.
local encoder = require("iara.features.pdf.sixel_encode")
local M = {}

local entries, staged, pending, inflight = {}, {}, {}, {}
local sources = {}
local history = {}
local history_bytes = 0
local limit = 8 * 1024 * 1024
local margin = 24
local sequence = 0
local scheduled = false
local pump

local function shape_key(shape)
  return ("%d:%d:%d:%d"):format(
    shape.width,
    shape.height,
    shape.page_width,
    shape.offset or 0
  )
end

local function owns(entry)
  local variants = entries[entry.path]
  return (variants and variants[entry.key] == entry)
    or staged[entry.path] == entry
end

local function schedule(entry)
  pending[entry] = true
  if not scheduled then
    scheduled = true
    vim.schedule(function()
      scheduled = false
      pump()
    end)
  end
end

local function cancel(entry)
  local task = entry.task
  if task then
    entry.task, task.cancelled = nil, true
    if task.job then
      task.job:cancel("PDF bands superseded")
    end
  end
end

local function retire(entry)
  if entry then
    pending[entry] = nil
    cancel(entry)
  end
end

local function missing(entry, first, last)
  local bands = entry.raster and entry.raster.bands or {}
  while first <= last and bands[first] do
    first = first + 1
  end
  if first > last then
    return
  end
  local finish = first
  while finish < last and not bands[finish + 1] do
    finish = finish + 1
  end
  return first, finish
end

local function request(entry, first, last, priority, stamp)
  local start, finish = missing(entry, first, last)
  if start then
    return {
      entry = entry,
      first = start,
      last = finish,
      priority = priority,
      stamp = stamp,
    }
  end
end

local function better(task, current)
  return task
    and (
      not current
      or task.priority > current.priority
      or (task.priority == current.priority and task.stamp > current.stamp)
    )
end

local function visible_task(entry)
  local next_task
  for _, span in pairs(entry.visible) do
    local task =
      request(entry, span.first, span.last, span.priority, span.stamp)
    if better(task, next_task) then
      next_task = task
    end
  end
  return next_task
end

local function ahead(entry, span)
  -- Warm up to a third of a viewport in the direction of movement.
  local distance =
    math.min(96, math.max(margin, math.ceil((span.last - span.first + 1) / 3)))
  local before = span.backward and distance or margin
  local after = span.backward and margin or distance
  local lower = request(
    entry,
    span.last + 1,
    math.min(entry.count, span.last + after),
    0,
    span.stamp
  )
  local upper = request(
    entry,
    math.max(1, span.first - before),
    span.first - 1,
    0,
    span.stamp
  )
  if span.backward then
    return upper or lower
  end
  return lower or upper
end

local function background_task(entry)
  if not entry.no_margin then
    for _, span in pairs(entry.visible) do
      local task = ahead(entry, span)
      if task then
        return task
      end
    end
  end
  if entry.hint then
    return request(entry, entry.hint.first, entry.hint.last, 0, entry.stamp)
  end
end

local function candidate()
  local next_task
  for entry in pairs(pending) do
    if not owns(entry) or entry.failed or entry.task then
      pending[entry] = nil
    else
      local task = visible_task(entry) or background_task(entry)
      if not task then
        pending[entry] = nil
      elseif better(task, next_task) then
        next_task = task
      end
    end
  end
  return next_task
end

local function available(next_task)
  local total, background, obsolete = 0, false, false
  for task in pairs(inflight) do
    total = total + 1
    background = background or task.priority == 0
    obsolete = obsolete or task.cancelled
  end
  if next_task.priority == 0 then
    return total < 2 and not background
  end
  -- At most one extra interactive encode can pass retired workers still
  -- draining from libuv. Speculation never uses the reserved capacity.
  return total < 2 or (total == 2 and obsolete)
end

local function intersects(task, span)
  return task.first <= span.last and span.first <= task.last
end

local function discard_obsolete(entry)
  if not entry.task then
    return
  end
  for _, span in pairs(entry.visible) do
    if intersects(entry.task, span) then
      local missing_first = missing(entry, span.first, span.last)
      if missing_first then
        entry.task.priority = math.max(entry.task.priority, span.priority)
      end
      return
    end
  end
  cancel(entry)
end

local function protected(entry, band)
  for _, span in pairs(entry.visible) do
    if band >= span.first and band <= span.last then
      return true
    end
  end
  return false
end

local function bound(entry)
  if entry.bytes > limit then
    entry.no_margin, entry.hint = true, nil
    for band, bytes in pairs(entry.raster.bands) do
      if not protected(entry, band) then
        entry.bytes = entry.bytes - #bytes
        entry.raster.bands[band] = nil
      end
    end
  end
end

local function store(entry, task, result, full)
  if full or not entry.raster then
    entry.raster = {
      width = result.width,
      height = result.height,
      palette = result.palette,
      bands = {},
    }
    entry.bytes = #result.palette
  end
  for i, band in ipairs(result.bands) do
    local index = task.first + i - 1
    local bands = entry.raster.bands
    local old = bands[index]
    bands[index] = band
    entry.bytes = entry.bytes + #band - (old and #old or 0)
  end
  bound(entry)
end

local function start(task)
  local entry = task.entry
  pending[entry], entry.task, inflight[task] = nil, task, true
  local source = sources[entry.path] or {}
  sources[entry.path] = source
  entry.gray = source.gray
  -- The source can be forgotten while its worker finishes. The captured
  -- table is detached then, so it cannot classify a replacement raster.
  local function classify(gray)
    source.gray = gray
  end
  encoder.start(entry, task, function(result, full)
    inflight[task] = nil
    if not task.cancelled and owns(entry) then
      entry.task = nil
      if result then
        store(entry, task, result, full)
      else
        entry.failed = true
      end
      if task.priority > 0 or entry.hint or entry.failed then
        entry.ready()
      end
    end
    schedule(entry)
  end, classify)
end

pump = function()
  local task = candidate()
  while task and available(task) do
    start(task)
    task = candidate()
  end
end

local function remove_history(index)
  local entry = table.remove(history, index)
  history_bytes = history_bytes - entry.bytes
  return entry
end

local function remember(entry)
  if not entry or not entry.raster or entry.bytes > limit then
    return
  end
  history[#history + 1] = entry
  history_bytes = history_bytes + entry.bytes
  while #history > 8 or history_bytes > limit do
    remove_history(1)
  end
end

local function matches(entry, path, shape)
  return entry
    and entry.path == path
    and entry.width == shape.width
    and entry.height == shape.height
    and entry.page_width == shape.page_width
    and entry.offset == (shape.offset or 0)
end

local function take(path, shape)
  for i, entry in ipairs(history) do
    if matches(entry, path, shape) then
      return remove_history(i)
    end
  end
end

local function new_entry(path, shape, ready)
  sequence = sequence + 1
  return {
    path = path,
    key = shape_key(shape),
    references = 0,
    width = shape.width,
    page_width = shape.page_width,
    offset = shape.offset or 0,
    height = shape.height,
    count = shape.height / 6,
    stamp = sequence,
    ready = ready,
    visible = {},
  }
end

function M.forget(path)
  sources[path] = nil
  for _, entry in pairs(entries[path] or {}) do
    retire(entry)
  end
  retire(staged[path])
  entries[path], staged[path] = nil, nil
  for index = #history, 1, -1 do
    if history[index].path == path then
      remove_history(index)
    end
  end
end

function M.ready(path, shape)
  local variants = entries[path]
  local entry = variants and variants[shape_key(shape)]
  return entry and entry.raster ~= nil and not visible_task(entry)
end

function M.prepare(path, shape, ready)
  local key = shape_key(shape)
  local variants = entries[path] or {}
  entries[path] = variants
  local active = variants[key]
  if active then
    active.ready = ready or active.ready
    return active
  end
  local cached = take(path, shape)
  if matches(staged[path], path, shape) then
    if cached then
      retire(staged[path])
    else
      cached = staged[path]
    end
    staged[path] = nil
  end
  local entry = cached or new_entry(path, shape, ready)
  entry.ready = ready or entry.ready
  entry.failed = nil
  variants[key] = entry
  return entry
end

function M.hold(entry)
  entry.references = entry.references + 1
end

function M.release(entry)
  entry.references = entry.references - 1
  local variants = entries[entry.path]
  if entry.references == 0 and variants and variants[entry.key] == entry then
    retire(entry)
    variants[entry.key] = nil
    if not next(variants) then
      entries[entry.path] = nil
    end
    entry.visible, entry.hint = {}, nil
    remember(entry)
  end
end

function M.want(entry, key, first, last, focused)
  local priority = focused and 2 or 1
  local old = entry.visible[key]
  if
    old
    and old.first == first
    and old.last == last
    and old.priority == priority
  then
    return
  end
  sequence = sequence + 1
  local backward = old
    and (first < old.first or (first == old.first and old.backward))
  entry.visible[key] = {
    first = first,
    last = last,
    priority = priority,
    stamp = sequence,
    backward = backward,
  }
  entry.hint = nil
  discard_obsolete(entry)
  schedule(entry)
end

function M.drop(entry, key)
  if entry.visible[key] then
    entry.visible[key] = nil
    discard_obsolete(entry)
    schedule(entry)
  end
end

function M.stage(path, shape, first, last, ready)
  local variants = entries[path]
  local active = variants and variants[shape_key(shape)]
  if active then
    return active
  end
  if matches(staged[path], path, shape) then
    return staged[path]
  end
  for _, entry in ipairs(history) do
    if matches(entry, path, shape) then
      return entry
    end
  end
  local previous = staged[path]
  retire(previous)
  remember(previous)
  local entry = new_entry(path, shape, ready or function() end)
  entry.hint = { first = first, last = last }
  staged[path] = entry
  schedule(entry)
  return entry
end

function M.warm(path, shape, count, ready)
  return M.stage(path, shape, 1, math.min(shape.height / 6, count), ready)
end

---Keep display-sized encodings when a higher-resolution source arrives.
function M.retain(old_path, new_path, max_size)
  local function reusable(entry)
    return entry
      and entry.raster
      and math.max(entry.page_width, entry.height) <= max_size
  end
  local active = entries[old_path] or {}
  local predicted = staged[old_path]
  for _, entry in ipairs(history) do
    if entry.path == old_path and reusable(entry) then
      entry.path = new_path
      entry.gray = nil
    end
  end
  M.forget(old_path)
  local function preserve(entry)
    if reusable(entry) then
      local copy = new_entry(new_path, entry, entry.ready)
      copy.raster, copy.bytes = entry.raster, entry.bytes
      remember(copy)
    end
  end
  for _, entry in pairs(active) do
    preserve(entry)
  end
  preserve(predicted)
end

return M
