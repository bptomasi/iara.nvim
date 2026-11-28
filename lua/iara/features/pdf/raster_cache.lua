--- Session cache for page one. A viewer links a cached raster into its own
--- directory so its drawing geometry and lifetime stay independent.
local graphics = require("iara.features.pdf.graphics")
local source = require("iara.features.pdf.source")
local uv = vim.uv

local M = {}
local entries = {}
local bytes = 0
local limit = 32 * 1024 * 1024

function M.identity(path, format)
  local stat = uv.fs_stat(path)
  if stat then
    return table.concat({
      path,
      format,
      stat.dev,
      stat.ino,
      stat.size,
      stat.mtime.sec,
      stat.mtime.nsec,
      stat.ctime.sec,
      stat.ctime.nsec,
    }, "\0")
  end
end

local function trim()
  local index = 1
  while (#entries > 8 or bytes > limit) and entries[index] do
    local entry = entries[index]
    if entry.refs == 0 then
      table.remove(entries, index)
      bytes = bytes - entry.bytes
      graphics.forget(entry.path)
      vim.fn.delete(entry.dir, "rf")
    else
      index = index + 1
    end
  end
end

function M.acquire(identity, size, minimum)
  if not identity then
    return
  end
  local best
  for i, entry in ipairs(entries) do
    if entry.key == identity and entry.size >= (minimum or size) then
      local distance = math.abs(entry.size - size)
      if not best or distance <= best.distance then
        best = { index = i, distance = distance }
      end
    end
  end
  if best then
    local entry = table.remove(entries, best.index)
    entries[#entries + 1] = entry
    entry.refs = entry.refs + 1
    return entry
  end
end

function M.release(entry)
  entry.refs = entry.refs - 1
  trim()
end

---Take ownership of an already rendered page directory.
function M.remember(identity, dir, path, size, length)
  local entry = {
    key = identity,
    dir = dir,
    path = path,
    size = size,
    bytes = length,
    refs = 1,
  }
  entries[#entries + 1] = entry
  bytes = bytes + length
  trim()
  return entry
end

function M.link(identity, path, size, minimum)
  local entry = M.acquire(identity, size, minimum)
  if entry then
    local linked = uv.fs_link(entry.path, path)
    M.release(entry)
    if linked then
      return entry.size, entry.bytes
    end
  end
end

function M.publish(identity, path, format, size, length)
  if not identity or length > limit then
    return
  end
  local existing = M.acquire(identity, size)
  if existing then
    return M.release(existing)
  end
  local dir = source.directory()
  if dir then
    local target = dir .. "/first." .. format
    if uv.fs_link(path, target) then
      M.release(M.remember(identity, dir, target, size, length))
    else
      vim.fn.delete(dir, "rf")
    end
  end
end

return M
