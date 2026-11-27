local probe = require("fixtures.runner.probe")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["adds"] = function()
  probe.log("pass")
  eq(1 + 1, 2)
end

T["concatenates"] = function()
  eq("a" .. "b", "ab")
end

return T
