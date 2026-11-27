-- Idle garbage collection after a search (FU-V12-PERF), in a child.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local SETUP = [[
_G.collect = require("iara.features.search.collect")
-- A live heap and a few MiB of garbage, like a closed Find files.
_G.live = {}
for i = 1, 50000 do
  _G.live[i] = { ("dir/%d/file.lua"):format(i) }
end
function _G.make_garbage()
  local garbage = {}
  for i = 1, 50000 do
    garbage[i] = { ("other/%d/name.lua"):format(i) }
  end
end
]]

local function wait_stopped()
  local stopped = vim.wait(5000, function()
    return child.lua_get("collect.running()") == false
  end, 10)
  eq(stopped, true)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.lua(SETUP)
    end,
    post_once = child.stop,
  },
})

T["steps run until a collection cycle ends and free the garbage"] = function()
  -- The garbage is made with the collector stopped, so only the steps
  -- can free it.
  child.lua([[
    collectgarbage("stop")
    make_garbage()
    _G.before = collectgarbage("count")
    collectgarbage("restart")
    collect.start()
  ]])
  eq(child.lua_get("collect.running()"), true)
  wait_stopped()
  local freed = child.lua_get("_G.before - collectgarbage('count')")
  eq(freed > 1024, true)
end

T["each step stays short"] = function()
  child.lua([[
    _G.longest = 0
    local step = collectgarbage
    _G.collectgarbage = function(what, ...)
      local t = vim.uv.hrtime()
      local result = step(what, ...)
      _G.longest = math.max(_G.longest, (vim.uv.hrtime() - t) / 1e6)
      return result
    end
    make_garbage()
    collect.start()
  ]])
  wait_stopped()
  eq(child.lua_get("_G.longest") < 5, true)
end

T["starting again while running keeps one run"] = function()
  child.lua("collect.start() collect.start()")
  wait_stopped()
  eq(child.lua_get("collect.running()"), false)
end

T["stop ends the steps at once"] = function()
  child.lua("collect.start() collect.stop()")
  eq(child.lua_get("collect.running()"), false)
end

T["steps are bounded on a heap that never finishes a cycle"] = function()
  child.lua([[
    collect.MAX_STEPS = 3
    _G.steps = 0
    local step = collectgarbage
    _G.collectgarbage = function(what, ...)
      if what == "step" then
        _G.steps = _G.steps + 1
        return false
      end
      return step(what, ...)
    end
    collect.start()
  ]])
  wait_stopped()
  eq(child.lua_get("_G.steps"), 3)
end

return T
