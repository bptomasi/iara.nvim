-- iara-test: serial
local probe = require("fixtures.runner.probe")

local T = MiniTest.new_set()

T["holds a window"] = function()
  probe.window("serial_a")
end

return T
