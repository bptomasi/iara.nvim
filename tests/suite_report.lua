--- Machine-readable results of one test process: a mini.test reporter
--- wrapper that records each case's outcome and duration and writes them
--- as JSON, so scripts/test_runner.lua can aggregate parallel runs.
local M = {}

---@class SuiteReportCase
---@field file string Test file the case was collected from.
---@field id string Case description joined with " | ".
---@field ms number Wall time from the first to the last state change.
---@field fails string[]
---@field notes string[]

---Report entry of one executed case.
---@param case table mini.test case
---@param times { start: integer, finish: integer }|nil
---@return SuiteReportCase
local function case_entry(case, times)
  local exec = case.exec or { fails = {}, notes = {} }
  local ms = times and (times.finish - times.start) / 1e6 or 0
  return {
    file = case.desc[1],
    id = table.concat(case.desc, " | "),
    ms = math.floor(ms * 10 + 0.5) / 10,
    fails = exec.fails or {},
    notes = exec.notes or {},
  }
end

---Write the report of `cases` to `path`.
---@param path string
---@param cases table[] mini.test cases
---@param times table<integer, { start: integer, finish: integer }>
function M.write(path, cases, times)
  local entries = {}
  for num, case in ipairs(cases) do
    entries[num] = case_entry(case, times[num])
  end
  local file = assert(io.open(path, "wb"))
  file:write(vim.json.encode({ cases = entries }))
  file:close()
end

---Wrap `base` so that finishing first writes the report to `path`.
---@param base table mini.test reporter (start, update, finish)
---@param path string
---@return table reporter
function M.wrap(base, path)
  local all_cases, times = {}, {}
  return {
    start = function(cases)
      all_cases = cases
      base.start(cases)
    end,
    update = function(num)
      local now = vim.uv.hrtime()
      times[num] = times[num] or { start = now }
      times[num].finish = now
      base.update(num)
    end,
    finish = function()
      M.write(path, all_cases, times)
      base.finish()
    end,
  }
end

---Read a report written by M.write().
---@param path string
---@return { cases: SuiteReportCase[] }|nil report
---@return string|nil err
function M.read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil, "no report"
  end
  local text = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil, "unreadable report"
  end
  return decoded
end

return M
