local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["passes"] = function()
  eq(true, true)
end

T["fails"] = function()
  eq("observed", "expected")
end

T["notes"] = function()
  MiniTest.add_note("remember this")
end

return T
