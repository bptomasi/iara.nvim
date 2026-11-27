local probe = require("fixtures.runner.probe")

local T = MiniTest.new_set()

T["overlaps parallel_a"] = function()
  MiniTest.expect.equality(probe.overlap("parallel_b", "parallel_a"), true)
end

return T
