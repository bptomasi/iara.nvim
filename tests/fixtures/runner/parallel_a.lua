local probe = require("fixtures.runner.probe")

local T = MiniTest.new_set()

T["overlaps parallel_b"] = function()
  MiniTest.expect.equality(probe.overlap("parallel_a", "parallel_b"), true)
end

return T
