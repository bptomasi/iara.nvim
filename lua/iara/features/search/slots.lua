--- Session-wide admission of search processes (task M2-S).
---
--- ARCH allows at most four live search-related processes: walks,
--- validation, grep batches, and children still retiring after a
--- cancel. Every search process starts here, in the admission group
--- "search" of `iara.core.proc` (contracts.md, section 5), which counts
--- retiring handles until they are reaped. A start refused for the cap
--- waits in arrival order and retries when a search process completes;
--- a waiting start that is cancelled never spawns and completes as
--- "cancelled". Any other refusal (a search process whose cleanup
--- failed) is not queued: the start completes at once as "refused".
local proc = require("iara.core.proc")

local M = {}

M.MAX_LIVE = 4
M.ADMISSION = { group = "search", max = M.MAX_LIVE }
---Process tags of the search modules, for `iara.core.proc` queries.
M.TAGS = { "iara-search-inventory", "search.grep" }

local live = 0
---@type table[] Starts waiting for a slot, oldest first.
local waiting = {}

local start

---Whether a start must wait: only a full group is worth waiting for.
local function must_wait()
  local admitted, refusal = proc.admits(M.ADMISSION)
  return not admitted and refusal.code == "cap"
end

local function release()
  live = live - 1
  while #waiting > 0 and not must_wait() do
    start(table.remove(waiting, 1))
  end
end

---@param pending table { argv, opts, handle }
start = function(pending)
  live = live + 1
  local on_complete = pending.opts.on_complete
  local opts = vim.tbl_extend("force", pending.opts, {
    admission = M.ADMISSION,
    on_complete = function(result)
      release()
      on_complete(result)
    end,
  })
  local ok, job = pcall(proc.spawn, pending.argv, opts)
  if not ok then
    live = live - 1
    error(job, 0)
  end
  pending.job = job
end

local function cancel_waiting(pending, reason)
  for index, other in ipairs(waiting) do
    if other == pending then
      table.remove(waiting, index)
      vim.schedule(function()
        pending.opts.on_complete({ status = "cancelled", reason = reason })
      end)
      return
    end
  end
end

local function cancel(pending, reason)
  if pending.job then
    return pending.job:cancel(reason)
  end
  cancel_waiting(pending, reason)
end

---Spawn `argv` like `iara.core.proc.spawn`, or queue it while four
---search processes are live. The handle cancels either way; a queued
---start reports `{ status = "cancelled" }` through `on_complete`,
---asynchronously.
---@param argv string[]
---@param opts IaraProcOpts
---@return { cancel: fun(self, reason: string?) } handle
function M.spawn(argv, opts)
  local pending = { argv = argv, opts = opts }
  local handle = {
    cancel = function(_, reason)
      cancel(pending, reason)
    end,
  }
  if must_wait() then
    table.insert(waiting, pending)
  else
    start(pending)
  end
  return handle
end

---Cancel every waiting start (each reports "cancelled") and every live
---search process.
function M.cancel_all()
  for _, pending in ipairs(vim.list_slice(waiting)) do
    cancel_waiting(pending, "cancelled")
  end
  for _, tag in ipairs(M.TAGS) do
    proc.cancel_all(tag)
  end
end

---Search processes started here and not yet completed (refused ones
---complete on a later iteration), and starts waiting for a slot.
---@return integer live
---@return integer waiting
function M.count()
  return live, #waiting
end

return M
