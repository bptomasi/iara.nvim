--- Garbage of a closed search, collected while the editor is idle
--- (FU-V12-PERF).
---
--- A Find files session on a large root allocates a few MiB (the path
--- inventory, rows, chunks). LuaJIT's incremental collector pays for that
--- garbage while later code allocates, so a full cycle of 10-20 ms used to
--- land inside the first result of every second or third search. After a
--- picker closes, small collector steps run on a timer until the cycle
--- ends; a key typed meanwhile waits for one step at most (under 1 ms on
--- a 20 MiB heap), and the next search starts without that debt.
local M = {}

---Collector work per step, in KiB of allocation it stands for.
M.STEP_KB = 64
---Time between steps.
M.INTERVAL_MS = 1
---Upper bound of steps per close, so a busy heap cannot keep it running.
M.MAX_STEPS = 1000

---@type uv.uv_timer_t|nil
local timer = nil

---Stop collecting; the collector goes back to its own pace.
function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

---Whether steps are still running.
---@return boolean
function M.running()
  return timer ~= nil
end

---Run collector steps while idle until one garbage collection cycle ends.
---Starting again while running keeps the current run.
function M.start()
  if timer then
    return
  end
  local steps = 0
  timer = assert(vim.uv.new_timer())
  timer:start(M.INTERVAL_MS, M.INTERVAL_MS, function()
    steps = steps + 1
    if collectgarbage("step", M.STEP_KB) or steps >= M.MAX_STEPS then
      M.stop()
    end
  end)
end

return M
