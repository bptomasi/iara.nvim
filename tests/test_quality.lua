local helpers = require("helpers")

local expect = MiniTest.expect
local eq = expect.equality

local script = helpers.iara_dir .. "/scripts/quality.lua"
local fixtures = helpers.iara_dir .. "/tests/fixtures/quality/"

---Run the checker and return its exit code and diagnostic lines.
local function check(paths, cwd)
  local argv = { vim.v.progpath, "-l", script }
  vim.list_extend(argv, paths)
  local result = helpers.run(argv, { cwd = cwd or fixtures })
  local lines = vim.split(result.stdout, "\n", { trimempty = true })
  local summary = table.remove(lines)
  return result.code, lines, summary
end

---Diagnostics whose message contains `fragment`.
local function matching(lines, fragment)
  return vim.tbl_filter(function(line)
    return line:find(fragment, 1, true) ~= nil
  end, lines)
end

local T = MiniTest.new_set()

local length = MiniTest.new_set()
T["function length"] = length

length["reports functions over 40 lines only"] = function()
  local code, lines = check({ "function_length.lua" })
  eq(code, 1)
  eq(matching(lines, "lines (max"), {
    "function_length.lua:46: function 'forty_one' has 41 lines (max 40)",
    "function_length.lua:90: function 'long_field' has 41 lines (max 40)",
  })
end

local complexity = MiniTest.new_set()
T["cognitive complexity"] = complexity

complexity["adds nesting increments for nested structures"] = function()
  local _, lines = check({ "complexity_nesting.lua" })
  eq(matching(lines, "complexity"), {
    "complexity_nesting.lua:2: function 'nested_loops' has cognitive"
      .. " complexity 16 (max 15)",
  })
end

complexity["counts each sequence of like boolean operators"] = function()
  local _, lines = check({ "complexity_boolean.lua" })
  eq(matching(lines, "complexity"), {
    "complexity_boolean.lua:2: function 'classify' has cognitive"
      .. " complexity 18 (max 15)",
  })
end

complexity["counts recursion, goto, and nested functions"] = function()
  local _, lines = check({ "complexity_misc.lua" })
  eq(matching(lines, "complexity"), {
    "complexity_misc.lua:31: function 'over_limit' has cognitive"
      .. " complexity 16 (max 15)",
    "complexity_misc.lua:61: function 'M:walk' has cognitive"
      .. " complexity 17 (max 15)",
  })
end

local lines_set = MiniTest.new_set()
T["line length"] = lines_set

lines_set["counts characters, not bytes, up to 80"] = function()
  local code, lines = check({ "line_length.md" })
  eq(code, 1)
  eq(lines, { "line_length.md:5: line has 81 characters (max 80)" })
end

local syntax = MiniTest.new_set()
T["syntax errors"] = syntax

syntax["reports unparsable Lua instead of passing it"] = function()
  local code, lines = check({ "syntax_error.lua" })
  eq(code, 1)
  eq(lines, { "syntax_error.lua:1: syntax error" })
end

local directories = MiniTest.new_set()
T["directories"] = directories

local function make_tree()
  local root = helpers.temp_dir()
  local long = string.rep("x", 81) .. "\n"
  helpers.write_file(root .. "/lazy-lock.json", long)
  helpers.write_file(root .. "/tests/fixtures/quality/bad.lua", long)
  helpers.write_file(root .. "/notes.bin", long)
  helpers.write_file(root .. "/bin/tool", "#!/bin/sh\n# " .. long)
  helpers.write_file(root .. "/ok.lua", "return 1\n")
  return root
end

directories["checks scripts and skips documented exclusions"] = function()
  local root = make_tree()
  local code, lines, summary = check({ "." }, root)
  eq(code, 1)
  eq(lines, { "bin/tool:2: line has 83 characters (max 80)" })
  eq(summary, "quality: 2 files checked, 1 problems")
end

directories["exits zero when every rule holds"] = function()
  local root = helpers.temp_dir()
  helpers.write_file(root .. "/ok.lua", "local function f()\n  return 1\nend\n")
  local code, lines, summary = check({ "." }, root)
  eq(code, 0)
  eq(lines, {})
  eq(summary, "quality: 1 files checked, 0 problems")
end

directories["a source archive skips enclosing Git ignore rules"] = function()
  local parent = helpers.temp_dir()
  local result = helpers.run({ "git", "init", "--quiet" }, { cwd = parent })
  eq(result.code, 0)
  helpers.write_file(parent .. "/.gitignore", "/source/\n")
  local dir = parent .. "/source"
  local checker = dir .. "/scripts/quality.lua"
  vim.fn.mkdir(vim.fs.dirname(checker), "p")
  assert(vim.uv.fs_copyfile(script, checker))
  helpers.write_file(dir .. "/long.md", string.rep("x", 81) .. "\n")
  helpers.write_file(dir .. "/.tools/local.md", string.rep("x", 81) .. "\n")
  local argv = { vim.v.progpath, "--clean", "-l", checker, "." }
  local report = helpers.run(argv, { cwd = dir })
  eq(report.code, 1)
  local lines = vim.split(report.stdout, "\n", { trimempty = true })
  eq(lines, {
    "long.md:1: line has 81 characters (max 80)",
    "quality: 2 files checked, 1 problems",
  })
end

return T
