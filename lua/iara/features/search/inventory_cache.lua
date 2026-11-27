--- Reuse one bounded, complete root inventory across picker sessions.
--- A libuv worker validates its filesystem dependencies before reuse.
--- Every miss uses the normal ripgrep walk and the same admission limits.
local inventory = require("iara.features.search.inventory")

local M = {}
local uv = vim.uv
local source = debug.getinfo(1, "S").source:sub(2)
local stamp_module =
  vim.fs.joinpath(vim.fs.dirname(source), "inventory_stamp.lua")

local MAX_PATHS = 30000
local MAX_BYTES = 2 * 1024 * 1024
local WAIT_MS = 50
local cached
local busy = false
local epoch = 0

---Forget the shared inventory and any capture started before a refresh.
function M.invalidate()
  cached = nil
  epoch = epoch + 1
end

local function fits(paths)
  if #paths > MAX_PATHS then
    return false
  end
  local bytes = 0
  for _, path in ipairs(paths) do
    bytes = bytes + #path
    if bytes > MAX_BYTES then
      return false
    end
  end
  return true
end

local function identity(spec)
  return table.concat({
    spec.root,
    tostring(spec.hidden),
    tostring(spec.ignored),
  }, "\0")
end

local function check_in_worker(module, root, hidden, ignored, rg, token)
  local ok, hit, stamp = pcall(function()
    return dofile(module).check(root, hidden, ignored, rg, token)
  end)
  return ok and hit or false, ok and stamp or nil
end

local function start_walk(request, hit, stamp)
  local spec = request.spec
  local previous = request.previous
  if request.epoch ~= epoch then
    hit, stamp = false, nil
  end
  if hit and previous then
    spec = vim.tbl_extend("force", spec, { base = previous.base })
  end
  request.walk = inventory.build(spec, function(result)
    if
      not request.cancelled
      and request.epoch == epoch
      and stamp
      and result.base
      and (hit or fits(result.paths))
    then
      cached = { key = request.key, base = result.base, stamp = stamp }
    end
    request.done(result)
  end, request.progress)
end

local function stop_deadline(request)
  local timer = request.deadline
  if timer then
    request.deadline = nil
    timer:stop()
    timer:close()
  end
end

local function begin_if_pending(request, hit, stamp)
  stop_deadline(request)
  if not request.cancelled and not request.walk then
    start_walk(request, hit, stamp)
  end
end

local function check(request, rg)
  busy = true
  local worker = uv.new_work(
    check_in_worker,
    vim.schedule_wrap(function(hit, stamp)
      busy = false
      begin_if_pending(request, hit, stamp)
    end)
  )
  local spec, previous = request.spec, request.previous
  local queued = worker
    and worker:queue(
      stamp_module,
      spec.root,
      spec.hidden == true,
      spec.ignored == true,
      rg,
      previous and previous.stamp or ""
    )
  if not queued then
    busy = false
    return start_walk(request)
  end
  -- Slow storage can stall a single stat past the worker's budget.
  request.deadline = uv.new_timer()
  if not request.deadline then
    return start_walk(request)
  end
  request.deadline:start(
    WAIT_MS,
    0,
    vim.schedule_wrap(function()
      begin_if_pending(request)
    end)
  )
end

---Build like inventory.build, with shared reuse for plain root requests.
---@param spec IaraInventorySpec
---@param on_done fun(result: IaraInventory)
---@param on_progress fun(paths: string[])
---@return { cancel: fun(self) }
function M.build(spec, on_done, on_progress)
  if busy or spec.scope.kind ~= "root" or spec.glob or spec.base then
    return inventory.build(spec, on_done, on_progress)
  end
  local rg = vim.fn.exepath("rg")
  if rg == "" then
    return inventory.build(spec, on_done, on_progress)
  end
  local key = identity(spec)
  local request = {
    spec = spec,
    done = on_done,
    progress = on_progress,
    key = key,
    epoch = epoch,
    previous = cached and cached.key == key and cached or nil,
  }
  check(request, rg)
  return {
    cancel = function()
      if request.cancelled then
        return
      end
      request.cancelled = true
      stop_deadline(request)
      if request.walk then
        request.walk:cancel()
      else
        vim.schedule(function()
          on_done({
            state = "cancelled",
            generation = spec.generation,
            paths = {},
          })
        end)
      end
    end,
  }
end

return M
