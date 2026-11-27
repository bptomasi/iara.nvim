--- Helpers of the runner fixtures: they log what they do to the file
--- named by RUNNER_LOG so tests/test_suite_runner.lua can check how
--- scripts/test.sh scheduled them.
local helpers = require("helpers")

local probe = {}

---Append `line` to the log.
---@param line string
function probe.log(line)
  local file = assert(io.open(assert(vim.env.RUNNER_LOG), "a"))
  file:write(line .. "\n")
  file:close()
end

---Lines of the log so far.
---@return string[]
function probe.lines()
  local file = io.open(assert(vim.env.RUNNER_LOG), "r")
  if not file then
    return {}
  end
  local text = file:read("*a")
  file:close()
  return vim.split(vim.trim(text), "\n", { plain = true })
end

---Log the start of `name`, hold for a moment, and log its end.
---@param name string
function probe.window(name)
  probe.log("start " .. name)
  vim.wait(300)
  probe.log("end " .. name)
end

---Log the start of `name` and wait until `other` has started too.
---@param name string
---@param other string
---@return boolean overlapped
function probe.overlap(name, other)
  probe.log("start " .. name)
  return vim.wait(10000, function()
    return vim.tbl_contains(probe.lines(), "start " .. other)
  end, 20)
end

---Read the shared "probe" fixture, building it (slowly) if needed.
---@return string value
function probe.shared_value()
  local dir = helpers.shared("probe", function(path)
    probe.log("build")
    vim.wait(300)
    helpers.write_file(path .. "/value", tostring(vim.uv.os_getpid()))
  end)
  local file = assert(io.open(dir .. "/value", "r"))
  local value = file:read("*a")
  file:close()
  return value
end

return probe
