-- Tests for the content search runner (task S3) against the S1 corpus.
-- The runner receives explicit eligible files; here they come from the
-- manifest, as S2 will provide them later.
local helpers = require("helpers")
local grep = require("iara.features.search.grep")
local proc = require("iara.core.proc")

local expect = MiniTest.expect
local eq = expect.equality

local fixture =
  dofile(helpers.iara_dir .. "/tests/fixtures/make_search_fixture.lua")

local TAG = "search.grep"
local WAIT_MS = 20000

-- Building the corpus takes a moment; share one build across tests.
local shared_manifest
local function manifest()
  shared_manifest = shared_manifest or fixture.build(helpers.temp_dir())
  return shared_manifest
end

---Variables set for one case, restored in post_case.
local saved_env = {}
local function set_env(name, value)
  if saved_env[name] == nil then
    saved_env[name] = { value = vim.env[name] }
  end
  vim.env[name] = value
end

local function restore_env()
  for name, saved in pairs(saved_env) do
    vim.env[name] = saved.value
  end
  saved_env = {}
end

local function wait_until(predicate)
  return vim.wait(WAIT_MS, predicate, 10)
end

---Start a run; `calls` records every callback in order.
local function start(spec)
  local m = manifest()
  spec = vim.tbl_extend("keep", spec, {
    root = m.root,
    files = fixture.eligible(m, true, true),
    regex = false,
    case = "sensitive",
    generation = 1,
  })
  local calls = { files = {}, done = {}, order = {} }
  local handle = grep.run(spec, {
    on_file = function(path, items)
      table.insert(calls.files, { path = path, items = items })
      table.insert(calls.order, "file")
      if calls.after_file then
        calls.after_file()
      end
    end,
    on_done = function(result)
      table.insert(calls.done, result)
      table.insert(calls.order, "done")
    end,
  })
  return handle, calls
end

local function finished(calls)
  wait_until(function()
    return #calls.done > 0
  end)
  return calls.done[1]
end

---Run to completion; return the result and occurrences sorted like the
---manifest, as { path, line, byte_start, byte_end }.
local function search(spec)
  local _, calls = start(spec)
  local result = finished(calls)
  local found = {}
  for _, file in ipairs(calls.files) do
    for _, item in ipairs(file.items) do
      eq(item.path, file.path)
      table.insert(found, {
        path = item.path,
        line = item.row + 1,
        byte_start = item.byte_start,
        byte_end = item.byte_end,
      })
    end
  end
  table.sort(found, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.byte_start < b.byte_start
  end)
  return result, found, calls
end

local function items_of(calls, path)
  for _, file in ipairs(calls.files) do
    if file.path == path then
      return file.items
    end
  end
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for name, value in pairs(manifest().env) do
        set_env(name, value)
      end
    end,
    post_case = function()
      proc.cancel_all(TAG)
      wait_until(function()
        return proc.active_count(TAG) == 0
      end)
      restore_env()
    end,
  },
})

T["matches"] = MiniTest.new_set()

T["matches"]["reports documented occurrences, drops binary files"] = function()
  local m = manifest()
  local query = fixture.query(m, "needle")
  local files = fixture.eligible(m, true, true)
  local result, found, calls = search({ query = query.query, files = files })
  eq(result.state, "complete")
  eq(result.generation, 1)
  eq(result.binary_files, #query.binary_paths)
  eq(found, fixture.expected_matches(m, "needle", files))
  local seen = {}
  for _, file in ipairs(calls.files) do
    eq({ file.path, seen[file.path] }, { file.path, nil })
    seen[file.path] = true
  end
  eq(seen[m.special.binary.path], nil)
end

T["matches"]["a NUL in a binary match line keeps later files"] = function()
  local m = manifest()
  local binary = m.special.binary.path
  local files = { binary, "src/main.lua" }
  local result, found = search({ query = "needle", files = files })
  eq(result.state, "complete")
  eq(result.binary_files, 1)
  eq(found, fixture.expected_matches(m, "needle", { "src/main.lua" }))
end

T["matches"]["searches only the files it is given"] = function()
  local m = manifest()
  local files = fixture.eligible(m, false, false)
  local _, found = search({ query = "needle", files = files })
  eq(found, fixture.expected_matches(m, "needle", files))
  local paths = vim.tbl_map(function(item)
    return item.path
  end, found)
  eq(vim.list_contains(paths, ".env"), false)
  eq(vim.list_contains(paths, "ignored-content.txt"), false)
end

T["matches"]["searches alpha -- beta verbatim"] = function()
  local m = manifest()
  local result, found, calls = search({ query = "alpha -- beta" })
  eq(result.state, "complete")
  eq(found, fixture.query(m, "alpha_dashes").matches)
  eq(items_of(calls, "dashes.txt")[1].text, "alpha -- beta")
end

T["matches"]["separates literal and regex interpretation"] = function()
  local m = manifest()
  local ids = { "regex_optional", "literal_optional", "literal_paren" }
  for _, id in ipairs(ids) do
    local query = fixture.query(m, id)
    local result, found = search({ query = query.query, regex = query.regex })
    eq({ id, result.state }, { id, "complete" })
    eq({ id, found }, { id, query.matches })
  end
end

T["matches"]["applies the case mode"] = function()
  local function count(query, case)
    local result, found = search({ query = query, case = case })
    return result.state, #found
  end
  eq({ count("NEEDLE", "insensitive") }, { "complete", 13 })
  eq({ count("NEEDLE", "sensitive") }, { "no_match", 0 })
  eq({ count("needle", "smart") }, { "complete", 13 })
  eq({ count("Needle", "smart") }, { "no_match", 0 })
end

T["matches"]["splits zero-width regex matches into occurrences"] = function()
  local result, found = search({
    query = "^",
    regex = true,
    files = { "dashes.txt" },
  })
  eq(result.state, "complete")
  eq(found, {
    { path = "dashes.txt", line = 1, byte_start = 0, byte_end = 0 },
    { path = "dashes.txt", line = 2, byte_start = 0, byte_end = 0 },
    { path = "dashes.txt", line = 3, byte_start = 0, byte_end = 0 },
  })
end

T["matches"]["reports no_match when nothing matches"] = function()
  local result, found = search({ query = "absent-from-every-file" })
  eq(result.state, "no_match")
  eq(result.error, nil)
  eq(found, {})
end

T["bytes"] = MiniTest.new_set()

T["bytes"]["keeps disk byte ranges for Unicode, CRLF, and BOM"] = function()
  local m = manifest()
  local files = { m.special.unicode_content, m.special.crlf, m.special.bom }
  local _, found, calls = search({ query = "needle", files = files })
  eq(found, fixture.expected_matches(m, "needle", files))
  eq(items_of(calls, m.special.unicode_content)[1].text, "ação needle")
  eq(items_of(calls, m.special.crlf)[1].text, "second needle")
  local bom = items_of(calls, m.special.bom)[1]
  eq({ bom.byte_start, bom.byte_end }, { 3, 9 })
end

T["bytes"]["passes special file names as operands, not options"] = function()
  local m = manifest()
  local names = vim.tbl_values(m.special.names)
  table.sort(names)
  local result, found = search({ query = "special file name", files = names })
  eq(result.state, "complete")
  local paths = vim.tbl_map(function(item)
    return item.path
  end, found)
  eq(paths, names)
end

T["bytes"]["bounds the display text of a line"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/wide.txt", ("é"):rep(400) .. " needle\n")
  local _, calls = start({ root = dir, files = { "wide.txt" }, query = "é" })
  eq(finished(calls).state, "complete")
  local item = calls.files[1].items[1]
  eq(#item.text <= 256, true)
  eq(item.text, ("é"):rep(128))
end

T["errors"] = MiniTest.new_set()

T["errors"]["reports an invalid regex as an error state"] = function()
  local m = manifest()
  local query = fixture.query(m, "invalid_regex")
  local result, found = search({ query = query.query, regex = true })
  eq(result.state, "error")
  eq(result.error.code, "regex")
  helpers.expect_match(result.error.message, "regex")
  eq(found, {})
end

T["errors"]["validates the regex without eligible files"] = function()
  local invalid = search({ query = "(unclosed", regex = true, files = {} })
  eq({ invalid.state, invalid.error.code }, { "error", "regex" })
  local valid = search({ query = "colou?r", regex = true, files = {} })
  eq({ valid.state, valid.error }, { "no_match", nil })
end

T["errors"]["runs no process for a literal query without files"] = function()
  local _, calls = start({ query = "needle", files = {} })
  eq(proc.active_count(TAG), 0)
  eq(#calls.done, 0)
  eq(finished(calls).state, "no_match")
end

T["errors"]["keeps an error after partial results"] = function()
  local result, found = search({
    query = "needle",
    files = { "content-only.txt", "missing-file.txt" },
  })
  eq(result.state, "error")
  eq(result.error.code, "rg")
  helpers.expect_match(result.error.message, "missing%-file%.txt")
  eq(#found, 1)
end

T["errors"]["reports a missing ripgrep executable"] = function()
  set_env("PATH", helpers.temp_dir())
  local result = search({ query = "needle" })
  eq({ result.state, result.error.code }, { "error", "not_found" })
end

T["errors"]["stops at an oversized JSON frame as partial"] = function()
  local m = manifest()
  local long = m.special.long_line.path
  local result, found = search({
    query = "longlinemarker",
    files = { long },
  })
  eq(result.state, "partial")
  eq(result.error.code, "overflow")
  eq(found, {})
end

T["errors"]["raises on an empty query or NUL"] = function()
  expect.error(function()
    grep.run({
      root = "/",
      files = {},
      query = "",
      regex = false,
      case = "smart",
      generation = 1,
    }, { on_file = function() end, on_done = function() end })
  end, "non%-empty")
  expect.error(function()
    start({ query = "a\0b" })
  end, "NUL")
end

T["batches"] = MiniTest.new_set()

---Directory with `count` files whose operands are about 600 bytes each.
local function long_path_tree(count)
  local dir = helpers.temp_dir()
  local deep =
    table.concat({ ("a"):rep(200), ("b"):rep(200), ("c"):rep(200) }, "/")
  local files = {}
  for index = 1, count do
    local path = ("%s/f%03d.txt"):format(deep, index)
    helpers.write_file(dir .. "/" .. path, "needle\n")
    table.insert(files, path)
  end
  return dir, files
end

local function arg_max()
  local result = helpers.run({ "getconf", "ARG_MAX" })
  return tonumber(vim.trim(result.stdout))
end

---Fill the environment so a spawn of `rg` with about `free` bytes of
---extra arguments still fits under ARG_MAX, and no more.
local function leave_arg_space(free)
  local used = 0
  for name, value in pairs(vim.fn.environ()) do
    used = used + #name + #value + 2 + 8
  end
  local pad = arg_max() - used - free - 512
  local index = 0
  while pad > 0 do
    index = index + 1
    local size = math.min(pad, 100 * 1024)
    set_env(("IARA_TEST_PAD_%d"):format(index), ("x"):rep(size))
    pad = pad - size - #"IARA_TEST_PAD_00=" - 8
  end
end

T["batches"]["halves a batch that fails with E2BIG"] = function()
  local dir, files = long_path_tree(300)
  leave_arg_space(96 * 1024)
  local _, calls = start({ root = dir, files = files, query = "needle" })
  local result = finished(calls)
  eq({ result.state, result.error }, { "complete", nil })
  eq(#calls.files, #files)
end

T["batches"]["reports E2BIG when one operand cannot fit"] = function()
  local dir, files = long_path_tree(1)
  leave_arg_space(256)
  local _, calls = start({ root = dir, files = files, query = "needle" })
  local result = finished(calls)
  eq(result.state, "error")
  eq({ result.error.code, result.error.uv_error }, { "spawn", "E2BIG" })
end

---Wait for the run's result while sampling how many batches are live.
local function finished_with_peak(calls)
  local peak = 0
  wait_until(function()
    peak = math.max(peak, proc.active_count(TAG))
    return #calls.done > 0
  end)
  return calls.done[1], peak
end

T["batches"]["splits a large list into two concurrent batches"] = function()
  local dir, files = long_path_tree(300)
  local _, calls = start({ root = dir, files = files, query = "needle" })
  eq(proc.active_count(TAG), 2)
  local result = finished(calls)
  eq({ result.state, result.error }, { "complete", nil })
  eq(#calls.files, #files)
end

T["batches"]["runs at most two batches at once"] = function()
  local dir, files = long_path_tree(300)
  -- Little argv space: E2BIG halving leaves many small batches.
  leave_arg_space(48 * 1024)
  local _, calls = start({ root = dir, files = files, query = "needle" })
  local result, peak = finished_with_peak(calls)
  eq({ result.state, result.error }, { "complete", nil })
  eq(#calls.files, #files)
  eq(peak <= 2, true)
end

T["cancel"] = MiniTest.new_set()

T["cancel"]["publishes nothing after an immediate cancel"] = function()
  local handle, calls = start({ query = "bulkmark" })
  handle:cancel()
  eq(finished(calls).state, "cancelled")
  wait_until(function()
    return proc.active_count(TAG) == 0
  end)
  vim.wait(100)
  eq(calls.files, {})
  eq(calls.order, { "done" })
end

T["cancel"]["stops publishing after a cancel during the run"] = function()
  local handle, calls = start({ query = "bulkmark" })
  local published
  calls.after_file = function()
    if not published then
      handle:cancel()
      published = #calls.files
    end
  end
  wait_until(function()
    return proc.active_count(TAG) == 0
  end)
  vim.wait(100)
  eq(#calls.files, published)
  eq(calls.order[#calls.order], "done")
  eq(#calls.done, 1)
  eq(calls.done[1].state, "cancelled")
end

T["cancel"]["completes the bulk query when not cancelled"] = function()
  local m = manifest()
  local query = fixture.query(m, "bulk")
  local result, found, calls = search({ query = query.query })
  eq(result.state, "complete")
  eq(#found, query.occurrence_count)
  eq(#calls.files, query.file_count)
end

return T
