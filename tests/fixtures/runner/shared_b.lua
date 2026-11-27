local probe = require("fixtures.runner.probe")

local T = MiniTest.new_set()

T["reads the shared fixture"] = function()
  probe.log("saw " .. probe.shared_value())
end

return T
