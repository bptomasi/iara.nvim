-- Run test files in parallel and aggregate their results; started by
-- scripts/test.sh, which sets up the temporary root and isolation.
--
--   nvim --clean -l scripts/test_runner.lua [TEST_FILE...]
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local iara_dir = vim.fn.fnamemodify(source, ":p:h:h")
package.path = iara_dir .. "/tests/?.lua;" .. package.path

local runner = require("suite_runner")
os.exit(runner.main(iara_dir, arg))
