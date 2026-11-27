--- Shared test helpers. Tests run through scripts/test.sh, which sets
--- NVIM_APPNAME=iara-test and temporary XDG directories.
local helpers = {}

local source = debug.getinfo(1, "S").source:gsub("^@", "")

---Absolute path of the Iara checkout.
helpers.iara_dir = vim.fn.fnamemodify(source, ":p:h:h")

---Init file for child Neovim processes.
helpers.minimal_init = helpers.iara_dir .. "/tests/minit.lua"

---Refuse to run unless the environment is isolated from real user data.
local function assert_isolated()
  local root = vim.env.IARA_TEST_TMP
  local config_home = vim.env.XDG_CONFIG_HOME or ""
  local isolated = vim.env.NVIM_APPNAME == "iara-test"
    and root ~= nil
    and root ~= ""
    and vim.startswith(config_home, root)
  if not isolated then
    error("tests must run through scripts/test.sh (isolation)", 0)
  end
end

---Create a new empty directory inside the test run's temporary root.
---@return string path
function helpers.temp_dir()
  local root = vim.env.IARA_TEST_TMP or vim.fn.stdpath("run")
  return assert(vim.uv.fs_mkdtemp(root .. "/work-XXXXXX"))
end

---Build the shared fixture `dir`, then leave a marker that says whether
---the build succeeded (`dir.ready`) or failed (`dir.failed`, the error).
local function build_shared(dir, build)
  vim.fn.mkdir(dir, "p")
  local ok, err = pcall(build, dir)
  local marker = io.open(dir .. (ok and ".ready" or ".failed"), "wb")
  if marker then
    marker:write(ok and "" or tostring(err))
    marker:close()
  end
end

---Wait for the marker of the shared fixture `dir` named `name`.
local function wait_shared(name, dir, timeout_ms)
  local ready, failed = dir .. ".ready", dir .. ".failed"
  local done = vim.wait(timeout_ms, function()
    return vim.uv.fs_stat(ready) ~= nil or vim.uv.fs_stat(failed) ~= nil
  end, 50)
  local file = io.open(failed, "rb")
  if file then
    local err = file:read("*a")
    file:close()
    error(("shared fixture %s failed: %s"):format(name, err), 0)
  end
  if not done then
    error(("timed out waiting for shared fixture %s"):format(name), 0)
  end
end

---Directory of a fixture shared by every test file of one run: the first
---process that asks for `name` builds it with `build(dir)`, concurrent
---and later callers wait for that build and reuse it. A failed build
---fails every caller with its error. Callers must not modify it.
---@param name string
---@param build fun(dir: string)
---@param timeout_ms integer|nil How long to wait for another build.
---@return string dir
function helpers.shared(name, build, timeout_ms)
  local root = vim.env.IARA_TEST_SHARED
  if root == nil or root == "" then
    root = (vim.env.IARA_TEST_TMP or vim.fn.stdpath("run")) .. "/shared"
  end
  -- Concurrent callers may create the root at the same time.
  pcall(vim.fn.mkdir, root, "p")
  local dir = root .. "/" .. name
  -- mkdir is atomic: exactly one process wins the right to build.
  if vim.uv.fs_mkdir(dir .. ".lock", tonumber("700", 8)) then
    build_shared(dir, build)
  end
  wait_shared(name, dir, timeout_ms or 600000)
  return dir
end

---Write `content` to `path`, creating parent directories.
---@param path string
---@param content string
function helpers.write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

---Environment for a Neovim subprocess with fresh XDG directories.
---@param extra table<string, string>|nil Additional variables.
---@return table<string, string>
function helpers.isolated_env(extra)
  local home = helpers.temp_dir()
  local env = {
    NVIM_APPNAME = "iara-test",
    XDG_CONFIG_HOME = home .. "/config",
    XDG_DATA_HOME = home .. "/data",
    XDG_STATE_HOME = home .. "/state",
    XDG_CACHE_HOME = home .. "/cache",
  }
  return vim.tbl_extend("force", env, extra or {})
end

---@class HelpersRunResult
---@field code integer
---@field stdout string
---@field stderr string

---Run a command synchronously, failing the test on timeout.
---@param argv string[]
---@param opts { cwd: string|nil, env: table|nil }|nil
---@return HelpersRunResult
function helpers.run(argv, opts)
  opts = opts or {}
  local process = vim.system(argv, {
    cwd = opts.cwd,
    env = opts.env,
    text = true,
  })
  local result = process:wait(20000)
  if result.signal ~= 0 then
    error(("command timed out or was killed: %s"):format(argv[1]), 2)
  end
  return { code = result.code, stdout = result.stdout, stderr = result.stderr }
end

---Expect `text` to match the Lua pattern `pattern`.
helpers.expect_match = MiniTest.new_expectation(
  "string matching",
  function(text, pattern)
    return type(text) == "string" and text:find(pattern) ~= nil
  end,
  function(text, pattern)
    return ("Pattern: %s\nObserved: %s"):format(pattern, vim.inspect(text))
  end
)

---Start a child Neovim with the minimal init. Stop it in post_case.
---@return table child MiniTest child process.
function helpers.new_child()
  local child = MiniTest.new_child_neovim()
  child.start({ "-u", helpers.minimal_init })
  return child
end

---Run the test files given as arguments (or every tests/test_*.lua) and
---quit with a nonzero status on failure.
function helpers.run_suite()
  assert_isolated()
  local files = vim.fn.argv()
  if #files == 0 then
    local pattern = helpers.iara_dir .. "/tests/**/test_*.lua"
    files = vim.fn.glob(pattern, true, true)
  end
  local execute = {}
  local report_path = vim.env.IARA_TEST_REPORT
  if report_path and report_path ~= "" then
    local base = MiniTest.gen_reporter.stdout()
    execute.reporter = require("suite_report").wrap(base, report_path)
  end
  MiniTest.run({
    collect = {
      find_files = function()
        return files
      end,
    },
    execute = execute,
  })
end

return helpers
