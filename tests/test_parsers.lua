-- scripts/parsers.sh: pinned grammars built with the local C compiler.
local helpers = require("helpers")
local fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local parsers = require("iara.core.parsers")

---Run parsers.sh of `iara_dir` against the local grammar mirror.
local function build(dest, iara_dir)
  local script = (iara_dir or helpers.iara_dir) .. "/scripts/parsers.sh"
  return helpers.run({ "sh", script, dest }, {
    env = { IARA_GIT_URL_FORMAT = fixture.url_format() },
  })
end

---Pinned commit of `lang` in the release's parser lock.
local function pinned(lang)
  for _, pin in ipairs(assert(parsers.read_lock())) do
    if pin.lang == lang then
      return pin.commit
    end
  end
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local T = MiniTest.new_set()

T["builds every pinned parser with its stamp"] = function()
  local dest = helpers.temp_dir()
  local result = build(dest)
  eq(result.code, 0)
  for _, pin in ipairs(assert(parsers.read_lock())) do
    eq(parsers.installed_commit(dest, pin.lang), pin.commit)
  end
  -- Block scalars come from the YAML grammar's external scanner.
  vim.treesitter.language.add("iara_test_yaml", {
    path = parsers.parser_path(dest, "yaml"),
    symbol_name = "yaml",
  })
  local tree = vim.treesitter
    .get_string_parser("a: |\n  text\n", "iara_test_yaml")
    :parse()[1]
  match(tree:root():sexpr(), "block_scalar")
end

T["keeps parsers already built from the pinned commit"] = function()
  local dest = helpers.temp_dir()
  eq(build(dest).code, 0)
  local before = vim.uv.fs_stat(parsers.parser_path(dest, "yaml"))
  local again = build(dest)
  eq(again.code, 0)
  match(again.stdout, "yaml parser %x+ already built")
  local after = vim.uv.fs_stat(parsers.parser_path(dest, "yaml"))
  eq(after.ino, before.ino)
  eq(after.mtime, before.mtime)
end

T["rebuilds a parser whose stamp names another commit"] = function()
  local dest = helpers.temp_dir()
  eq(build(dest).code, 0)
  helpers.write_file(dest .. "/stamps/json", ("1"):rep(40) .. "\n")
  local result = build(dest)
  eq(result.code, 0)
  match(result.stdout, "built json parser")
  eq(read(dest .. "/stamps/json"), pinned("json"))
end

T["rejects an unknown key in the parser lock"] = function()
  local checkout = fixture.checkout()
  local lock = checkout .. "/parsers-lock.txt"
  helpers.write_file(lock, read(lock) .. "\nbranch main\n")
  local dest = helpers.temp_dir()
  local result = build(dest, checkout)
  eq(result.code, 1)
  match(result.stderr, "unknown key 'branch'")
end

T["pins the baseline parsers and rejects malformed locks"] = function()
  -- core/treesitter.lua highlights json and yaml beyond Neovim's bundle.
  eq(type(pinned("json")), "string")
  eq(type(pinned("yaml")), "string")
  local path = helpers.temp_dir() .. "/lock.txt"
  helpers.write_file(path, "parser yaml\nrepo a/b\ncommit 85c7ff3\n")
  local _, short = parsers.read_lock(path)
  eq(short.code, "lock_invalid")
  match(short.message, "full 40%-character commit")
  helpers.write_file(path, "repo a/b\n")
  local _, orphan = parsers.read_lock(path)
  match(orphan.message, "unexpected line: repo a/b")
  local _, missing = parsers.read_lock(path .. ".absent")
  eq(missing.code, "lock_missing")
end

return T
