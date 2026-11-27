local helpers = require("helpers")
local cache = require("mirror_cache")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["reuses a completed mirror until its inputs change"] = function()
  local root = helpers.temp_dir()
  local calls = 0
  local function build(dir)
    calls = calls + 1
    helpers.write_file(dir .. "/pin", tostring(calls))
  end
  local first = cache.get(root, "first", build)
  eq(cache.get(root, "first", build), first)
  eq(calls, 1)
  local second = cache.get(root, "second", build)
  eq(vim.fn.readfile(second .. "/pin"), { "2" })
  eq(vim.fn.readfile(first .. "/pin"), { "1" })
end

T["a failed build publishes nothing and can be retried"] = function()
  local root = helpers.temp_dir()
  local ok = pcall(cache.get, root, "key", function(dir)
    helpers.write_file(dir .. "/partial", "unfinished")
    error("fetch failed")
  end)
  eq(ok, false)
  eq(vim.fs.dir(root)(), nil)
  local result = cache.get(root, "key", function(dir)
    helpers.write_file(dir .. "/pin", "complete")
  end)
  eq(vim.fn.readfile(result .. "/pin"), { "complete" })
end

return T
