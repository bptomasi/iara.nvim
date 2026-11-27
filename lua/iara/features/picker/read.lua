--- Bounded disk reads for previews, and a small cache of their results
--- (task M2-S). See contracts.md, section 9.6.
---
--- A preview needs the lines around one location, not the start of the
--- file. `window` reads at most READ_BYTES around the line `row`: when
--- the row starts within the first quarter of the file's first chunk,
--- that chunk is the window; otherwise chunks are scanned, counting
--- lines, up to SCAN_BYTES, and one window starting a quarter before the
--- row is read. A NUL in any byte read marks the file as binary.
---
--- Windows are cached by path and row range, up to CACHE_BYTES and
--- CACHE_ENTRIES (least recently used first out). A cached window is a
--- disk snapshot: callers check it with `fresh` (an asynchronous stat of
--- size, modification time, and inode) before showing it.
local M = {}

local uv = vim.uv
local find, sub = string.find, string.sub

M.READ_BYTES = 256 * 1024
M.SCAN_BYTES = 64 * 1024 * 1024
M.LINE_BYTES = 1000
M.CACHE_BYTES = 16 * 1024 * 1024
M.CACHE_ENTRIES = 32
---Accounted cost of one cached line beyond its bytes.
local LINE_OVERHEAD = 40

---@class IaraPreviewWindow
---@field path string
---@field stat { size: integer, sec: integer, nsec: integer, ino: integer }
---@field first_row integer Zero-based line of `lines[1]`.
---@field lines string[] Lines, each cut at LINE_BYTES.
---@field cut boolean Some content was cut (line ends or window end).
---@field binary boolean? A NUL byte was read; `lines` is empty.
---@field beyond boolean? The row lies past the end or the scan limit.
---@field bytes integer Accounted size in the cache.

-- Reading ---------------------------------------------------------------

---Position of the `count`-th newline in `data` (0 when `count` is 0),
---or nil and the number of newlines found.
local function skip_lines(data, count)
  local index, found = 0, 0
  while found < count do
    local newline = find(data, "\n", index + 1, true)
    if not newline then
      return nil, found
    end
    index, found = newline, found + 1
  end
  return index, found
end

local function stat_key(stat)
  return {
    size = stat.size,
    sec = stat.mtime.sec,
    nsec = stat.mtime.nsec,
    ino = stat.ino,
  }
end

local function split(data, whole)
  local lines, cut = vim.split(data, "\n", { plain = true }), false
  if not whole then
    -- The last line is partial; when it is the only one (a minified
    -- file), keep its start, cut at LINE_BYTES below (S11).
    if #lines > 1 then
      table.remove(lines)
    end
    cut = true
  end
  for index, line in ipairs(lines) do
    if #line > M.LINE_BYTES then
      lines[index], cut = sub(line, 1, M.LINE_BYTES), true
    end
  end
  return lines, cut
end

local function new_window(job, fields)
  local window = vim.tbl_extend("force", {
    path = job.path,
    stat = job.stat,
    first_row = 0,
    lines = {},
    cut = false,
  }, fields)
  window.bytes = 0
  for _, line in ipairs(window.lines) do
    window.bytes = window.bytes + #line + LINE_OVERHEAD
  end
  return window
end

---Window from `data` read at byte offset `start`, where line `job.row`
---starts at offset `row_start`. A partial first line is dropped: the
---bytes before `row_start` end with the newline that ends line row - 1.
local function window_from(job, data, start, row_start)
  if find(data, "\0", 1, true) then
    return new_window(job, { binary = true })
  end
  local whole = #data < M.READ_BYTES or start + #data >= job.stat.size
  local first_row = job.row
  if start < row_start then
    local before = sub(data, 1, row_start - start)
    local _, count = skip_lines(before, math.huge)
    first_row = job.row - count
    if start > 0 then
      local first_newline = find(before, "\n", 1, true)
      data, first_row = sub(data, first_newline + 1), first_row + 1
    end
  end
  local lines, cut = split(data, whole)
  return new_window(job, { first_row = first_row, lines = lines, cut = cut })
end

local function finish(job, err, window)
  uv.fs_close(job.fd)
  job.on_done(err, window)
end

local function read_at(job, offset, on_data)
  uv.fs_read(job.fd, M.READ_BYTES, offset, function(err, data)
    if err or not data then
      return finish(job, err or "read failed")
    end
    on_data(data)
  end)
end

---Read the window once line `job.row` is known to start at `row_start`.
local function read_window(job, first_chunk, row_start)
  local start = math.max(0, row_start - math.floor(M.READ_BYTES / 4))
  if start == 0 then
    return finish(job, nil, window_from(job, first_chunk, 0, row_start))
  end
  read_at(job, start, function(data)
    finish(job, nil, window_from(job, data, start, row_start))
  end)
end

---Count lines chunk by chunk until line `job.row` starts.
local function scan(job, offset, rows_before, first_chunk)
  read_at(job, offset, function(data)
    first_chunk = first_chunk or data
    if find(data, "\0", 1, true) then
      return finish(job, nil, new_window(job, { binary = true }))
    end
    local position, found = skip_lines(data, job.row - rows_before)
    if position then
      return read_window(job, first_chunk, offset + position)
    end
    local next_offset = offset + #data
    if #data < M.READ_BYTES or next_offset >= M.SCAN_BYTES then
      return finish(job, nil, new_window(job, { beyond = true }))
    end
    scan(job, next_offset, rows_before + found, first_chunk)
  end)
end

---Read the window around zero-based line `row` (0 when nil) of `path`
---asynchronously. `on_done(err, window)` runs in a libuv callback.
---@param path string
---@param row integer?
---@param on_done fun(err: string?, window: IaraPreviewWindow?)
function M.window(path, row, on_done)
  uv.fs_open(path, "r", 0, function(open_err, fd)
    if not fd then
      return on_done(open_err)
    end
    uv.fs_fstat(fd, function(stat_err, stat)
      local job = { fd = fd, path = path, row = row or 0, on_done = on_done }
      if not stat then
        return finish(job, stat_err)
      end
      job.stat = stat_key(stat)
      scan(job, 0, 0)
    end)
  end)
end

-- Cache -----------------------------------------------------------------

---@type IaraPreviewWindow[] Most recently used last.
local cache = {}
local cached_bytes = 0

local function covers(window, row)
  if window.binary then
    return true
  end
  if window.beyond then
    return false
  end
  local last = window.first_row + #window.lines - 1
  return row >= window.first_row and row <= last
end

local function evict(index)
  local window = table.remove(cache, index)
  cached_bytes = cached_bytes - window.bytes
end

---A cached window of `path` holding line `row` (0 when nil), or nil.
---@param path string
---@param row integer?
---@return IaraPreviewWindow?
function M.cached(path, row)
  for index, window in ipairs(cache) do
    if window.path == path and covers(window, row or 0) then
      table.remove(cache, index)
      table.insert(cache, window)
      return window
    end
  end
end

---Keep `window`, evicting the least recently used windows to stay
---within the cache limits. Windows larger than the cache are not kept.
---@param window IaraPreviewWindow
function M.store(window)
  if window.beyond or window.bytes > M.CACHE_BYTES then
    return
  end
  for index = #cache, 1, -1 do
    if cache[index].path == window.path then
      evict(index)
    end
  end
  while
    #cache >= M.CACHE_ENTRIES or cached_bytes + window.bytes > M.CACHE_BYTES
  do
    evict(1)
  end
  table.insert(cache, window)
  cached_bytes = cached_bytes + window.bytes
end

---Check asynchronously that `window` still matches its file on disk;
---a stale window is evicted. `on_done(fresh)` runs in a libuv callback.
---@param window IaraPreviewWindow
---@param on_done fun(fresh: boolean)
function M.fresh(window, on_done)
  uv.fs_stat(window.path, function(_, stat)
    local fresh = stat ~= nil and vim.deep_equal(stat_key(stat), window.stat)
    on_done(fresh)
  end)
end

---Drop `path` (every cached window when nil).
---@param path string?
function M.forget(path)
  for index = #cache, 1, -1 do
    if path == nil or cache[index].path == path then
      evict(index)
    end
  end
end

---Cached windows and their accounted bytes.
---@return integer count
---@return integer bytes
function M.usage()
  return #cache, cached_bytes
end

return M
