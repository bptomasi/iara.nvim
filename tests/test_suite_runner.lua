-- scripts/test.sh: parallel files, aggregated results and exit status,
-- serial files, shared fixtures, and timeouts. The fixture files in
-- tests/fixtures/runner/ log what they do to RUNNER_LOG.
local helpers = require("helpers")
local runner = require("suite_runner")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local FIXTURES = helpers.iara_dir .. "/tests/fixtures/runner/"

local function read_lines(path)
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local text = file:read("*a")
  file:close()
  return vim.split(vim.trim(text), "\n", { plain = true })
end

---Run test.sh on fixture files `names` with two jobs and `env`.
---@return HelpersRunResult|{ log: string[] }
local function run(names, env)
  local dir = helpers.temp_dir()
  local argv = { helpers.iara_dir .. "/scripts/test.sh" }
  for _, name in ipairs(names) do
    table.insert(argv, FIXTURES .. name .. ".lua")
  end
  local log = dir .. "/log"
  env = vim.tbl_extend("force", {
    TMPDIR = dir,
    RUNNER_LOG = log,
    IARA_TEST_JOBS = "2",
  }, env or {})
  local result = helpers.run(argv, { env = env })
  return vim.tbl_extend("force", result, { log = read_lines(log) })
end

---Expect test.sh to have exited with `code`; show its output if not.
local function expect_code(result, code)
  if result.code ~= code then
    error(
      ("exit code %d, expected %d; output:\n%s%s"):format(
        result.code,
        code,
        result.stdout,
        result.stderr
      ),
      2
    )
  end
end

local T = MiniTest.new_set()

T["summary"] = MiniTest.new_set()

T["summary"]["passes with the case count of every file"] = function()
  local result = run({ "pass" })
  expect_code(result, 0)
  match(result.stdout, "Running 1 test files, 2 at a time")
  match(result.stdout, "\nPASS +[%d.]+s  [^\n]*/pass%.lua  %(2 cases%)\n")
  match(result.stdout, "Total number of cases: 2\n")
  match(result.stdout, "Fails %(0%) and Notes %(0%)")
end

T["summary"]["aggregates failures and notes and exits nonzero"] = function()
  local result = run({ "pass", "fail" })
  expect_code(result, 1)
  local fail_line = "\nFAIL +[%d.]+s  [^\n]*/fail%.lua  %(3 cases, 1 failed%)"
  match(result.stdout, fail_line)
  match(result.stdout, "\nPASS +[%d.]+s  [^\n]*/pass%.lua")
  -- Files are listed by name, whichever finished first.
  local fail_at = result.stdout:find("/fail%.lua  %(")
  local pass_at = result.stdout:find("/pass%.lua  %(")
  eq(fail_at < pass_at, true)
  match(result.stdout, "Total number of cases: 5\n")
  match(result.stdout, "Fails %(1%) and Notes %(1%)")
  match(result.stdout, "FAIL in [^\n]*fail%.lua | fails: \n[^\n]*equality")
  match(result.stdout, 'Left:  "observed"')
  match(result.stdout, "NOTE in [^\n]*fail%.lua | notes: remember this")
end

T["summary"]["reports a file that exits without a report"] = function()
  local result = run({ "crash", "pass" })
  expect_code(result, 1)
  match(result.stdout, "\nERROR +[%d.]+s  [^\n]*/crash%.lua  %(0 cases%)")
  match(result.stdout, "\nPASS +[%d.]+s  [^\n]*/pass%.lua")
  match(result.stdout, "ERROR in [^\n]*/crash%.lua: exited with code 3")
  match(result.stdout, "  | crash fixture exiting")
  match(result.stdout, "Total number of cases: 2\n")
end

T["summary"]["stops a file that exceeds its timeout"] = function()
  local result = run({ "hang" }, { IARA_TEST_FILE_TIMEOUT = "1" })
  expect_code(result, 1)
  match(result.stdout, "ERROR in [^\n]*/hang%.lua: timed out after 1s")
end

T["scheduling"] = MiniTest.new_set()

T["scheduling"]["runs files at the same time up to the job limit"] = function()
  local result = run({ "parallel_a", "parallel_b" })
  expect_code(result, 0)
  table.sort(result.log)
  eq(result.log, { "start parallel_a", "start parallel_b" })
end

T["scheduling"]["runs serial files alone after the others"] = function()
  local result = run({ "serial_b", "pass", "serial_a" }, {
    IARA_TEST_JOBS = "4",
  })
  expect_code(result, 0)
  eq(result.log, {
    "pass",
    "start serial_a",
    "end serial_a",
    "start serial_b",
    "end serial_b",
  })
end

T["scheduling"]["starts slow files first, serial files last"] = function()
  local dir = helpers.temp_dir()
  local function file(name, header)
    helpers.write_file(dir .. "/" .. name, header .. "return {}\n")
    return dir .. "/" .. name
  end
  local paths = {
    file("a.lua", "-- iara-test: serial\n"),
    file("b.lua", ""),
    file("c.lua", "-- A slow file.\n-- iara-test: slow\n"),
    file("d.lua", ""),
  }
  local order = vim.tbl_map(function(item)
    return vim.fs.basename(item.path)
  end, runner.list_files(helpers.iara_dir, paths))
  eq(order, { "c.lua", "b.lua", "d.lua", "a.lua" })
end

T["shared fixtures"] = MiniTest.new_set()

T["shared fixtures"]["are built once for concurrent files"] = function()
  local result = run({ "shared_a", "shared_b" })
  expect_code(result, 0)
  eq(#result.log, 3)
  eq(result.log[1], "build")
  match(result.log[2], "^saw %d+$")
  eq(result.log[3], result.log[2])
end

T["shared fixtures"]["report a failed build to every caller"] = function()
  local saved = vim.env.IARA_TEST_SHARED
  vim.env.IARA_TEST_SHARED = helpers.temp_dir()
  local builds = 0
  local function build()
    builds = builds + 1
    error("no network")
  end
  local first = { pcall(helpers.shared, "broken", build) }
  local second = { pcall(helpers.shared, "broken", build) }
  vim.env.IARA_TEST_SHARED = saved
  eq({ first[1], second[1], builds }, { false, false, 1 })
  match(first[2], "shared fixture broken failed: .*no network")
  eq(second[2], first[2])
end

return T
