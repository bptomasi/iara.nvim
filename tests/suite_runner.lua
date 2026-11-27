--- Parallel test runner behind scripts/test.sh. Each test file runs in
--- its own headless Neovim with its own temporary XDG directories, a
--- bounded number at a time; the per-file reports (suite_report.lua) are
--- aggregated into one summary and one exit status.
---
--- A test file can carry markers in its first lines:
---   -- iara-test: slow     started first, so it does not end the run
---   -- iara-test: serial   runs alone, after every parallel file
local suite_report = require("suite_report")

local M = {}

local MARKER_PATTERN = "^%-%- iara%-test: (%a+)%s*$"
local HEADER_LINES = 30
local OUTPUT_TAIL_LINES = 40
local SLOWEST_CASES = 10

---@class SuiteFile
---@field path string As given, or absolute when found by the glob.
---@field markers table<string, boolean>

---@class SuiteResult
---@field file SuiteFile
---@field code integer Exit code; 124 when the file timed out.
---@field signal integer
---@field output string Standard output followed by standard error.
---@field seconds number
---@field report { cases: SuiteReportCase[] }|nil
---@field error string|nil Why the file has no usable result.

---Markers in the first lines of `path`.
---@param path string
---@return table<string, boolean>
function M.read_markers(path)
  local markers = {}
  local file = io.open(path, "r")
  if not file then
    return markers
  end
  for _ = 1, HEADER_LINES do
    local line = file:read("*l")
    if not line then
      break
    end
    local marker = line:match(MARKER_PATTERN)
    if marker then
      markers[marker] = true
    end
  end
  file:close()
  return markers
end

---Test files to run: `args`, or every tests/**/test_*.lua, in the order
---they start: slow files first, serial files last, by name otherwise.
---@param iara_dir string
---@param args string[]
---@return SuiteFile[]
function M.list_files(iara_dir, args)
  local paths = args
  if #paths == 0 then
    paths = vim.fn.glob(iara_dir .. "/tests/**/test_*.lua", true, true)
  end
  local files = {}
  for _, path in ipairs(paths) do
    table.insert(files, { path = path, markers = M.read_markers(path) })
  end
  local function rank(file)
    return file.markers.serial and 2 or file.markers.slow and 0 or 1
  end
  table.sort(files, function(a, b)
    if rank(a) ~= rank(b) then
      return rank(a) < rank(b)
    end
    return a.path < b.path
  end)
  return files
end

---Environment of the process running file number `index`.
---@param root string Temporary root of the whole run.
---@param index integer
---@return table<string, string>
local function file_env(root, index)
  local home = ("%s/%d"):format(root, index)
  vim.fn.mkdir(home, "p")
  return {
    IARA_TEST_TMP = home,
    IARA_TEST_SHARED = root .. "/shared",
    IARA_TEST_REPORT = home .. "/report.json",
    NVIM_APPNAME = "iara-test",
    XDG_CONFIG_HOME = home .. "/config",
    XDG_DATA_HOME = home .. "/data",
    XDG_STATE_HOME = home .. "/state",
    XDG_CACHE_HOME = home .. "/cache",
  }
end

---@class SuiteContext
---@field iara_dir string
---@field root string
---@field jobs integer
---@field timeout_ms integer

---Start the process of file number `index`; `on_exit` receives its
---result (without the report) in a fast event context.
---@param ctx SuiteContext
---@param index integer
---@param file SuiteFile
---@param on_exit fun(result: SuiteResult)
local function start_file(ctx, index, file, on_exit)
  local env = file_env(ctx.root, index)
  local argv = {
    vim.v.progpath,
    "--headless",
    "-u",
    ctx.iara_dir .. "/tests/minit.lua",
    "-c",
    "lua require('helpers').run_suite()",
    "--",
    file.path,
  }
  local started = vim.uv.hrtime()
  vim.system(argv, {
    env = env,
    text = true,
    timeout = ctx.timeout_ms,
  }, function(out)
    on_exit({
      file = file,
      code = out.code,
      signal = out.signal,
      output = (out.stdout or "") .. (out.stderr or ""),
      seconds = (vim.uv.hrtime() - started) / 1e9,
      report_path = env.IARA_TEST_REPORT,
    })
  end)
end

---Run `files` with at most `ctx.jobs` at a time (serial files alone).
---`progress` is called once per finished file.
---@param files SuiteFile[]
---@param ctx SuiteContext
---@param progress fun()|nil
---@return SuiteResult[] results In the order of `files`.
function M.run_files(files, ctx, progress)
  local results, running, next_index, finished = {}, 0, 1, 0
  local function on_exit(index)
    return function(result)
      results[index] = result
      running = running - 1
    end
  end
  while next_index <= #files or running > 0 do
    local file = files[next_index]
    local limit = file and file.markers.serial and 1 or ctx.jobs
    if file and running < limit then
      running = running + 1
      start_file(ctx, next_index, file, on_exit(next_index))
      next_index = next_index + 1
    else
      vim.wait(1000, function()
        return vim.tbl_count(results) > finished
      end, 20)
    end
    for _ = finished + 1, vim.tbl_count(results) do
      finished = finished + 1
      if progress then
        progress()
      end
    end
  end
  return results
end

---Attach the report of `result` and explain a missing or broken result.
---@param result SuiteResult
---@param timeout_ms integer
function M.attach_report(result, timeout_ms)
  local report, err = suite_report.read(result.report_path)
  result.report = report
  if result.code == 124 then
    result.error = ("timed out after %ds"):format(timeout_ms / 1000)
  elseif not report then
    result.error = ("exited with code %d and %s"):format(result.code, err)
  elseif result.code ~= 0 and M.count(result).fails == 0 then
    result.error = ("exited with code %d"):format(result.code)
  end
end

---Number of cases, failed cases, and notes of `result`.
---@param result SuiteResult
---@return { cases: integer, fails: integer, notes: integer }
function M.count(result)
  local counts = { cases = 0, fails = 0, notes = 0 }
  for _, case in ipairs(result.report and result.report.cases or {}) do
    counts.cases = counts.cases + 1
    counts.fails = counts.fails + (#case.fails > 0 and 1 or 0)
    counts.notes = counts.notes + #case.notes
  end
  return counts
end

---Status word of `result`: PASS, FAIL, or ERROR.
---@param result SuiteResult
---@return string
function M.status(result)
  if result.error then
    return "ERROR"
  end
  return M.count(result).fails > 0 and "FAIL" or "PASS"
end

---One summary line per file, in name order.
---@param results SuiteResult[]
---@return string[]
function M.file_lines(results)
  local sorted = vim.list_slice(results)
  table.sort(sorted, function(a, b)
    return a.file.path < b.file.path
  end)
  local lines = {}
  for _, result in ipairs(sorted) do
    local counts = M.count(result)
    local detail = ("%d cases"):format(counts.cases)
    if counts.fails > 0 then
      detail = detail .. (", %d failed"):format(counts.fails)
    end
    local line = ("%-5s %6.1fs  %s  (%s)"):format(
      M.status(result),
      result.seconds,
      result.file.path,
      detail
    )
    table.insert(lines, line)
  end
  return lines
end

---The slowest cases of the run, slowest first.
---@param results SuiteResult[]
---@param limit integer
---@return string[]
function M.slowest_lines(results, limit)
  local cases = {}
  for _, result in ipairs(results) do
    vim.list_extend(cases, result.report and result.report.cases or {})
  end
  table.sort(cases, function(a, b)
    return a.ms > b.ms
  end)
  local lines = {}
  for index = 1, math.min(limit, #cases) do
    local case = cases[index]
    table.insert(lines, ("%7.1fs  %s"):format(case.ms / 1000, case.id))
  end
  return lines
end

---Append each message after a blank line, prefixed like mini.test does.
---@param lines string[]
---@param prefix string
---@param messages string[]
local function append_messages(lines, prefix, messages)
  for _, message in ipairs(messages) do
    table.insert(lines, "")
    vim.list_extend(lines, vim.split(prefix .. message, "\n", { plain = true }))
  end
end

---Lines explaining a file without a usable result, with the end of its
---output.
---@param result SuiteResult
---@return string[]
local function error_lines(result)
  local lines = {}
  local message = ("%s: %s; output ends with:"):format(
    result.file.path,
    result.error
  )
  append_messages(lines, "ERROR in ", { message })
  local output = vim.split(result.output, "\n", { plain = true })
  for _, line in ipairs(vim.list_slice(output, -OUTPUT_TAIL_LINES)) do
    table.insert(lines, "  | " .. line)
  end
  return lines
end

---Failures and notes of every case, mini.test style, then each file
---without a usable result.
---@param results SuiteResult[]
---@return string[] lines
---@return { fails: integer, notes: integer, errors: integer } totals
function M.detail_lines(results)
  local fails, notes, errors = {}, {}, {}
  local totals = { fails = 0, notes = 0, errors = 0 }
  for _, result in ipairs(results) do
    for _, case in ipairs(result.report and result.report.cases or {}) do
      totals.fails = totals.fails + #case.fails
      totals.notes = totals.notes + #case.notes
      append_messages(fails, ("FAIL in %s: "):format(case.id), case.fails)
      append_messages(notes, ("NOTE in %s: "):format(case.id), case.notes)
    end
    if result.error then
      totals.errors = totals.errors + 1
      vim.list_extend(errors, error_lines(result))
    end
  end
  local lines = {
    ("Fails (%d) and Notes (%d)"):format(totals.fails, totals.notes),
  }
  vim.list_extend(lines, fails)
  vim.list_extend(lines, notes)
  vim.list_extend(lines, errors)
  return lines, totals
end

---Summary of a finished run and whether it passed.
---@param results SuiteResult[]
---@param seconds number Wall time of the run.
---@return string[] lines
---@return boolean passed
function M.summary(results, seconds)
  local lines = M.file_lines(results)
  local cases = 0
  for _, result in ipairs(results) do
    cases = cases + M.count(result).cases
  end
  table.insert(lines, "")
  table.insert(lines, "Slowest cases:")
  vim.list_extend(lines, M.slowest_lines(results, SLOWEST_CASES))
  table.insert(lines, "")
  table.insert(lines, ("Total number of cases: %d"):format(cases))
  table.insert(lines, ("Total number of files: %d"):format(#results))
  table.insert(lines, ("Wall time: %.1fs"):format(seconds))
  table.insert(lines, "")
  local details, totals = M.detail_lines(results)
  vim.list_extend(lines, details)
  return lines, totals.fails == 0 and totals.errors == 0
end

---Number of parallel jobs: IARA_TEST_JOBS, or the CPU count.
---@return integer
function M.job_count()
  local jobs = tonumber(vim.env.IARA_TEST_JOBS or "")
  if jobs and jobs >= 1 then
    return math.floor(jobs)
  end
  return vim.uv.available_parallelism()
end

---Time limit of one file: IARA_TEST_FILE_TIMEOUT seconds, or 600.
---@return integer
function M.file_timeout_ms()
  local seconds = tonumber(vim.env.IARA_TEST_FILE_TIMEOUT or "")
  return math.floor((seconds or 600) * 1000)
end

---Run the suite and return the process exit status.
---@param iara_dir string
---@param args string[] Test files; empty runs every file.
---@return integer status
function M.main(iara_dir, args)
  local ctx = {
    iara_dir = iara_dir,
    root = assert(vim.env.IARA_TEST_TMP, "IARA_TEST_TMP is not set"),
    jobs = M.job_count(),
    timeout_ms = M.file_timeout_ms(),
  }
  local files = M.list_files(iara_dir, args)
  io.stdout:write(
    ("Running %d test files, %d at a time\n"):format(#files, ctx.jobs)
  )
  local started = vim.uv.hrtime()
  local results = M.run_files(files, ctx, function()
    io.stdout:write(".")
    io.stdout:flush()
  end)
  for _, result in ipairs(results) do
    M.attach_report(result, ctx.timeout_ms)
  end
  local seconds = (vim.uv.hrtime() - started) / 1e9
  local lines, passed = M.summary(results, seconds)
  io.stdout:write("\n\n" .. table.concat(lines, "\n") .. "\n")
  return passed and 0 or 1
end

return M
