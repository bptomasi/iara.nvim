local fuzzy = require("iara.features.search.fuzzy")

local expect = MiniTest.expect
local eq = expect.equality

---Process events for `ms` milliseconds. A bare `vim.wait(ms)` can
---overrun: it subtracts whole elapsed milliseconds per loop iteration,
---so a stream of sub-millisecond batches never advances its timeout.
local function wait_ms(ms)
  local deadline = vim.uv.hrtime() + ms * 1e6
  vim.wait(ms + 1000, function()
    return vim.uv.hrtime() >= deadline
  end, 1)
end

---Run `match` to completion and return its single on_done report.
local function run_match(query, candidates, limit)
  local reports = {}
  fuzzy.match(query, candidates, {
    limit = limit,
    on_done = function(matches, complete)
      reports[#reports + 1] = { matches = matches, complete = complete }
    end,
  })
  vim.wait(5000, function()
    return #reports > 0
  end, 1)
  wait_ms(20) -- a second report would arrive here
  eq(#reports, 1)
  return reports[1].matches, reports[1].complete
end

local function paths_of(matches)
  return vim.tbl_map(function(item)
    return item.path
  end, matches)
end

---Expect `query` to score `better` strictly above `worse`.
local function expect_prefers(query, better, worse)
  local high, low = fuzzy.score(query, better), fuzzy.score(query, worse)
  if not (high and low and high > low) then
    error(
      ("%q: expected %q (%s) > %q (%s)"):format(
        query,
        better,
        tostring(high),
        worse,
        tostring(low)
      )
    )
  end
end

---Deterministic synthetic paths that mostly contain the letters "a".
local function synthetic_paths(count)
  local words = { "app", "data", "main", "panel", "base", "map", "tab" }
  local paths = {}
  for index = 1, count do
    local first = words[index % #words + 1]
    local second = words[(index * 7) % #words + 1]
    paths[index] = ("%s/%s_%d.lua"):format(first, second, index)
  end
  return paths
end

---A catalog large enough that matching takes many batches: one million
---entries reusing a few thousand strings, so it is cheap to build.
local function large_catalog()
  local unique = synthetic_paths(5000)
  local catalog = {}
  for index = 1, 1000000 do
    catalog[index] = unique[index % #unique + 1]
  end
  return catalog
end

local T = MiniTest.new_set()

local score = MiniTest.new_set()
T["score"] = score

score["requires query bytes in order"] = function()
  eq(type(fuzzy.score("fz", "fuzzy.lua")), "number")
  eq(fuzzy.score("zf", "fuzzy"), nil)
  eq(fuzzy.score("lua.x", "init.lua"), nil)
end

score["rejects paths over 4 KiB but accepts exactly 4 KiB"] = function()
  local at_limit = ("a"):rep(4095) .. "z"
  eq(type(fuzzy.score("z", at_limit)), "number")
  eq(fuzzy.score("z", "a" .. at_limit), nil)
end

score["matches every path with score 0 for an empty query"] = function()
  eq(fuzzy.score("", "any/path.lua"), 0)
  eq(fuzzy.score("", ""), 0)
end

score["uses smart case"] = function()
  eq(type(fuzzy.score("readme", "README.md")), "number")
  eq(type(fuzzy.score("README", "README.md")), "number")
  eq(fuzzy.score("README", "readme.md"), nil)
  eq(fuzzy.score("Readme", "README.md"), nil)
end

score["compares non-ASCII bytes exactly"] = function()
  eq(type(fuzzy.score("ação", "docs/ação.md")), "number")
  eq(fuzzy.score("AÇÃO", "docs/ação.md"), nil)
end

score["prefers consecutive matches over scattered ones"] = function()
  expect_prefers("abc", "xabcx", "axbxcx")
  expect_prefers("search", "lua/search.lua", "lua/s_e_a_r_c_h.lua")
end

score["prefers matches at word and path boundaries"] = function()
  expect_prefers("fb", "foo_bar.lua", "foobar.lua")
  expect_prefers("fb", "fooBar.lua", "foobar.lua")
  expect_prefers("ab", "a/b/z.txt", "axb/z.txt")
end

score["prefers matches inside the basename"] = function()
  expect_prefers("init", "lua/iara/init.lua", "init/lua/mod.lua")
  expect_prefers("fz", "lua/features/fuzzy.lua", "lua/fzf/other.lua")
end

score["prefers tighter windows over long gaps"] = function()
  expect_prefers("ml", "src/model.lua", "src/m_______________l.lua")
end

score["matches across directories when the basename cannot"] = function()
  local matches = run_match("sefz", { "lua/search/fuzzy.lua" })
  eq(matches[1].positions, { 4, 5, 11, 13 })
end

score["raises on non-string arguments"] = function()
  expect.error(function()
    fuzzy.score(nil, "path")
  end, "must be strings")
end

local match = MiniTest.new_set()
T["match"] = match

match["reports zero-based byte positions of the matched bytes"] = function()
  local matches = run_match("fz", { "src/fuzzy.lua" })
  eq(matches[1].positions, { 4, 6 })
  matches = run_match("çb", { "ação/çb.md" })
  eq(matches[1].positions, { 7, 8, 9 })
end

match["ranks by score and drops non-matching paths"] = function()
  local candidates = { "src/zzz.lua", "init/lua/mod.lua", "lua/init.lua" }
  local matches, complete = run_match("init", candidates)
  eq(complete, true)
  eq(paths_of(matches), { "lua/init.lua", "init/lua/mod.lua" })
  eq(matches[1].score, fuzzy.score("init", "lua/init.lua"))
end

match["breaks score ties by byte-wise path order"] = function()
  local candidates = { "b.lua", "a.lua", "B.lua", "_.lua", "é.lua" }
  local matches = run_match("", candidates)
  eq(paths_of(matches), { "B.lua", "_.lua", "a.lua", "b.lua", "é.lua" })
end

match["returns the same order regardless of candidate order"] = function()
  local candidates = synthetic_paths(600)
  local first = paths_of(run_match("ma", candidates, 50))
  local reversed = {}
  for index = #candidates, 1, -1 do
    reversed[#reversed + 1] = candidates[index]
  end
  eq(paths_of(run_match("ma", reversed, 50)), first)
end

match["keeps exactly the best limit matches of a large catalog"] = function()
  local candidates = synthetic_paths(3000)
  local expected = {}
  for _, path in ipairs(candidates) do
    local value = fuzzy.score("pa1", path)
    if value then
      expected[#expected + 1] = { path = path, score = value }
    end
  end
  table.sort(expected, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.path < b.path
  end)
  local matches = run_match("pa1", candidates, 25)
  eq(#matches, 25)
  eq(paths_of(matches), paths_of(vim.list_slice(expected, 1, 25)))
end

match["an empty query lists shallow paths first, ties by path"] = function()
  local candidates = { "src/b/x.lua", "z.lua", "src/a.lua", "a/b.lua", "y.md" }
  local matches = run_match("", candidates)
  eq(
    paths_of(matches),
    { "y.md", "z.lua", "a/b.lua", "src/a.lua", "src/b/x.lua" }
  )
  eq(matches[1].positions, {})
end

match["an empty query lists recent paths first, by rank"] = function()
  local candidates = { "a.lua", "deep/er/c.lua", "b.lua", "x/d.lua" }
  local reports = {}
  fuzzy.match("", candidates, {
    recent = { ["x/d.lua"] = 2, ["deep/er/c.lua"] = 1, ["gone.lua"] = 3 },
    on_done = function(matches)
      reports[#reports + 1] = paths_of(matches)
    end,
  })
  eq(
    vim.wait(5000, function()
      return #reports > 0
    end, 1),
    true
  )
  -- A recent path the candidates lack is never added.
  eq(reports[1], { "deep/er/c.lua", "x/d.lua", "a.lua", "b.lua" })
end

match["recent paths do not reorder a non-empty query"] = function()
  local reports = {}
  fuzzy.match("lib", { "l/i/b.txt", "lib.lua" }, {
    recent = { ["l/i/b.txt"] = 1 },
    on_done = function(matches)
      reports[#reports + 1] = paths_of(matches)
    end,
  })
  eq(
    vim.wait(5000, function()
      return #reports > 0
    end, 1),
    true
  )
  eq(reports[1], { "lib.lua", "l/i/b.txt" })
end

match["defaults to at most 200 matches"] = function()
  eq(#run_match("", synthetic_paths(1000)), 200)
end

match["completes an empty catalog"] = function()
  local matches, complete = run_match("x", {})
  eq(matches, {})
  eq(complete, true)
end

match["returns the whole match set only within the requested cap"] = function()
  for _, cap in ipairs({ 0, 2, 3 }) do
    local report
    fuzzy.match("a", { "z-a", "a", "skip", "a-last" }, {
      limit = 1,
      path_cap = cap,
      on_done = function(matches, complete, total, paths)
        report = { #matches, complete, total, paths }
      end,
    })
    eq(
      vim.wait(5000, function()
        return report ~= nil
      end, 1),
      true
    )
    local paths = cap == 3 and { "z-a", "a", "a-last" } or nil
    eq(report, { 1, true, 3, paths })
  end
end

match["never reports synchronously"] = function()
  local reported = false
  fuzzy.match("a", { "a" }, {
    on_done = function()
      reported = true
    end,
  })
  eq(reported, false)
  vim.wait(1000, function()
    return reported
  end, 1)
  eq(reported, true)
end

match["yields to the event loop between batches"] = function()
  local finished, observed_running = false, nil
  fuzzy.match("a", large_catalog(), {
    on_done = function()
      finished = true
    end,
  })
  vim.defer_fn(function()
    observed_running = not finished
  end, 5)
  vim.wait(10000, function()
    return finished
  end, 1)
  eq(observed_running, true)
end

match["cancels between batches and reports partial matches once"] = function()
  local reports = {}
  local handle = fuzzy.match("a", large_catalog(), {
    on_done = function(matches, complete)
      reports[#reports + 1] = { count = #matches, complete = complete }
    end,
  })
  wait_ms(5)
  eq(#reports, 0)
  handle:cancel()
  handle:cancel()
  vim.wait(1000, function()
    return #reports > 0
  end, 1)
  wait_ms(50)
  eq(#reports, 1)
  eq(reports[1].complete, false)
  -- Some batches ran before cancellation, so provisional matches exist.
  eq(reports[1].count > 0, true)
end

match["ignores cancel after completion"] = function()
  local calls = 0
  local handle = fuzzy.match("a", { "a" }, {
    on_done = function()
      calls = calls + 1
    end,
  })
  vim.wait(1000, function()
    return calls > 0
  end, 1)
  handle:cancel()
  wait_ms(20)
  eq(calls, 1)
end

match["runs only the latest pending query"] = function()
  local old, new = {}, {}
  fuzzy.match("a", large_catalog(), {
    on_done = function(_, complete)
      old[#old + 1] = complete
    end,
  })
  fuzzy.match("init", { "lua/init.lua" }, {
    on_done = function(matches, complete)
      new[#new + 1] = { matches = matches, complete = complete }
    end,
  })
  vim.wait(2000, function()
    return #old > 0 and #new > 0
  end, 1)
  wait_ms(50)
  eq(old, { false })
  eq(#new, 1)
  eq(new[1].complete, true)
  eq(paths_of(new[1].matches), { "lua/init.lua" })
end

match["raises on invalid arguments"] = function()
  expect.error(function()
    fuzzy.match("a", { "a" }, {})
  end, "on_done")
  expect.error(function()
    fuzzy.match("a", { "a" }, { limit = 0, on_done = function() end })
  end, "limit")
  expect.error(function()
    fuzzy.match(1, { "a" }, { on_done = function() end })
  end, "query")
  expect.error(function()
    fuzzy.match("", { "a" }, { recent = "a", on_done = function() end })
  end, "recent")
end

return T
