-- Tests for the search eligibility inventory (task S2), against the S1
-- corpus and the real ripgrep.
local helpers = require("helpers")
local inventory = require("iara.features.search.inventory")
local proc = require("iara.core.proc")

local expect = MiniTest.expect
local eq = expect.equality

local generator = helpers.iara_dir .. "/tests/fixtures/make_search_fixture.lua"
local fixture = dofile(generator)

-- Building the corpus takes a moment; share one read-only build.
local shared_manifest
local function manifest()
  shared_manifest = shared_manifest or fixture.build(helpers.temp_dir())
  return shared_manifest
end

-- Ripgrep inherits the editor environment, so the manifest environment
-- (fixture HOME with its global ignore) is applied to this process for
-- each case and restored afterwards.
local saved_env = {}

local function apply_env(env)
  for key, value in pairs(env) do
    if saved_env[key] == nil then
      saved_env[key] = vim.env[key] or false
    end
    vim.env[key] = value
  end
end

local function restore_env()
  for key, value in pairs(saved_env) do
    vim.env[key] = value or nil
  end
  saved_env = {}
end

local function spec(fields)
  local m = manifest()
  return vim.tbl_extend("force", {
    root = m.root,
    scope = { kind = "root" },
    hidden = false,
    ignored = false,
    generation = 1,
  }, fields or {})
end

---Start a build; record every on_done call and every progress report.
local function start(fields)
  local calls = { progress = {} }
  local handle = inventory.build(spec(fields), function(result)
    table.insert(calls, result)
  end, function(paths)
    table.insert(calls.progress, { paths = paths, after_done = #calls > 0 })
  end)
  return handle, calls
end

local function sorted(paths)
  local copy = vim.list_slice(paths)
  table.sort(copy)
  return copy
end

---First result, with its paths sorted (the walk order is unspecified).
local function wait_for(calls)
  local finished = vim.wait(15000, function()
    return #calls > 0
  end, 5)
  eq(finished, true)
  local result = vim.deepcopy(calls[1])
  result.paths = sorted(result.paths)
  return result
end

---Every path reported as progress, sorted, after the build finished.
local function progress_paths(calls)
  local paths = {}
  for _, report in ipairs(calls.progress) do
    eq(report.after_done, false)
    vim.list_extend(paths, report.paths)
  end
  return sorted(paths)
end

local function build(fields)
  local _, calls = start(fields)
  return wait_for(calls)
end

local function wait_for_idle()
  eq(
    vim.wait(15000, function()
      return proc.active_count() == 0
    end, 5),
    true
  )
end

local function under(paths, prefix)
  return vim.tbl_filter(function(path)
    return vim.startswith(path, prefix)
  end, paths)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      apply_env(manifest().env)
    end,
    post_case = function()
      proc.cancel_all()
      restore_env()
    end,
  },
})

local eligible_set = MiniTest.new_set()
T["eligible set"] = eligible_set

eligible_set["equals the manifest for every switch and glob case"] = function()
  local m = manifest()
  eq(#m.eligible, 16)
  for index, case in ipairs(m.eligible) do
    local result = build({
      hidden = case.hidden,
      ignored = case.ignored,
      glob = m.globs[case.glob],
      generation = index,
    })
    local label = ("hidden=%s ignored=%s glob=%s"):format(
      case.hidden,
      case.ignored,
      case.glob
    )
    eq({ label, result.state, result.generation, result.paths }, {
      label,
      "complete",
      index,
      case.paths,
    })
  end
end

eligible_set["drops whitelisted hidden paths when hidden is off"] = function()
  local m = manifest()
  local result = build({ glob = "*" })
  for _, path in ipairs(m.special.whitelisted_hidden) do
    eq(vim.list_contains(result.paths, path), false)
  end
end

eligible_set["excludes worktree administration paths"] = function()
  local root = helpers.temp_dir()
  helpers.write_file(root .. "/a.txt", "a\n")
  local result = helpers.run({
    "git",
    "init",
    "-q",
    "--separate-git-dir=" .. root .. "/gitstore",
    root,
  }, { env = manifest().env })
  eq(result.code, 0)
  eq(vim.fn.filereadable(root .. "/gitstore/HEAD"), 1)
  local inv = build({ root = root, hidden = true, ignored = true })
  eq(inv.paths, { "a.txt" })
end

T["scope"] = MiniTest.new_set()

T["scope"]["narrows a directory scope after root eligibility"] = function()
  local m = manifest()
  local result =
    build({ scope = { kind = "directory", path = m.root .. "/src" } })
  local expected = under(fixture.eligible(m, false, false), "src/")
  eq(#expected > 0, true)
  eq(result.paths, expected)
end

T["scope"]["cannot make an ignored directory eligible"] = function()
  local m = manifest()
  local scope = { kind = "directory", path = m.root .. "/build" }
  eq(build({ scope = scope }).paths, {})
  local ignored = build({ scope = scope, ignored = true })
  eq(ignored.paths, under(fixture.eligible(m, false, true), "build/"))
  eq(#ignored.paths > 0, true)
end

T["scope"]["admits a hidden ignored file only with both switches"] = function()
  local m = manifest()
  local scope = { kind = "file", path = m.root .. "/.env" }
  eq(build({ scope = scope }).paths, {})
  eq(build({ scope = scope, hidden = true }).paths, {})
  eq(build({ scope = scope, hidden = true, ignored = true }).paths, { ".env" })
end

T["scope"]["yields nothing for a scope outside the root"] = function()
  local m = manifest()
  local outside = vim.fs.dirname(m.root) .. "/outside"
  local result = build({ scope = { kind = "directory", path = outside } })
  eq({ result.state, result.paths }, { "complete", {} })
end

T["errors"] = MiniTest.new_set()

T["errors"]["reports an invalid glob as a filter error"] = function()
  local result = build({ glob = "src/[", hidden = true })
  eq({ result.state, result.error.code, result.paths }, { "error", "glob", {} })
  helpers.expect_match(result.error.message, "glob")
end

T["errors"]["rejects an oversized glob before spawning"] = function()
  wait_for_idle() -- earlier cases may still be retiring their walks
  local handle, calls = start({ glob = string.rep("a", 1025) })
  eq(#calls, 0) -- never synchronous
  eq(proc.active_count(), 0)
  local result = wait_for(calls)
  eq({ result.state, result.error.code }, { "error", "glob" })
  handle:cancel()
  vim.wait(20)
  eq(#calls, 1)
end

T["errors"]["reports a missing ripgrep as not_found"] = function()
  apply_env({ PATH = helpers.temp_dir() })
  local result = build()
  eq({ result.state, result.error.code }, { "error", "not_found" })
end

T["errors"]["raises for a malformed spec"] = function()
  local done = function() end
  expect.error(function()
    inventory.build(spec({ root = "relative" }), done)
  end, "absolute")
  expect.error(function()
    inventory.build(spec({ scope = { kind = "file" } }), done)
  end, "scope.path")
  expect.error(function()
    inventory.build(spec())
  end, "on_done")
end

local progress = MiniTest.new_set()
T["progress"] = progress

progress["reports every eligible path once while walking"] = function()
  local m = manifest()
  for index, case in ipairs(m.eligible) do
    local _, calls = start({
      hidden = case.hidden,
      ignored = case.ignored,
      glob = m.globs[case.glob],
      generation = index,
    })
    local result = wait_for(calls)
    vim.wait(50)
    -- With a glob, a path is reported only once both walks have it, so
    -- no path outside E ∩ G is ever shown early.
    eq({ case.glob, progress_paths(calls) }, { case.glob, result.paths })
  end
end

progress["reports nothing after a cancel"] = function()
  local handle, calls = start({ hidden = true, ignored = true })
  handle:cancel()
  wait_for_idle()
  vim.wait(50)
  eq(calls.progress, {})
end

progress["keeps scope and .git exclusion in early reports"] = function()
  local m = manifest()
  local scope = { kind = "directory", path = m.root .. "/src" }
  local _, calls = start({ hidden = true, ignored = true, scope = scope })
  local result = wait_for(calls)
  vim.wait(50)
  eq(progress_paths(calls), result.paths)
  for _, path in ipairs(progress_paths(calls)) do
    eq({ path, vim.startswith(path, "src/") }, { path, true })
  end
  local _, all = start({ hidden = true, ignored = true, generation = 2 })
  wait_for(all)
  for _, path in ipairs(progress_paths(all)) do
    eq({ path, ("/" .. path .. "/"):find("/.git/", 1, true) }, { path, nil })
  end
end

local generations = MiniTest.new_set()
T["generations"] = generations

generations["a cancelled build reports once without paths"] = function()
  local handle, calls = start({ hidden = true, ignored = true, glob = "*" })
  handle:cancel()
  handle:cancel()
  wait_for_idle()
  vim.wait(50)
  eq(#calls, 1)
  eq(calls[1], { generation = 1, state = "cancelled", paths = {} })
end

generations["a superseded walk leaves the newer one intact"] = function()
  local m = manifest()
  local old, old_calls = start({ generation = 1, hidden = true })
  local _, new_calls = start({ generation = 2, ignored = true })
  old:cancel()
  local result = wait_for(new_calls)
  wait_for_idle()
  vim.wait(50)
  eq({ result.generation, result.state }, { 2, "complete" })
  eq(result.paths, fixture.eligible(m, false, true))
  eq(#old_calls, 1)
  eq({ old_calls[1].state, old_calls[1].paths }, { "cancelled", {} })
end

generations["an external process cancel still reports once"] = function()
  local _, calls = start({ hidden = true, ignored = true, glob = "*" })
  proc.cancel_all()
  local result = wait_for(calls)
  wait_for_idle()
  vim.wait(50)
  eq(#calls, 1)
  eq({ result.state, result.paths }, { "cancelled", {} })
end

generations["cancel after completion changes nothing"] = function()
  local handle, calls = start({ generation = 7 })
  local result = wait_for(calls)
  handle:cancel()
  vim.wait(50)
  eq(#calls, 1)
  eq({ result.generation, result.state }, { 7, "complete" })
end

return T
