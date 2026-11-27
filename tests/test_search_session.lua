-- Tests for the search session and entry points (task S5), driven
-- headless through the session API on the S1 corpus with real ripgrep.
local helpers = require("helpers")
local proc = require("iara.core.proc")
local search = require("iara.features.search")
local session_module = require("iara.features.search.session")

local expect = MiniTest.expect
local eq = expect.equality

local fixture =
  dofile(helpers.iara_dir .. "/tests/fixtures/make_search_fixture.lua")

local WAIT_MS = 20000
local GREP_TAG = "search.grep"
local INVENTORY_TAG = "iara-search-inventory"
local UI_MODULE = "iara.features.search.ui"

-- Building the corpus takes a moment; share one read-only build.
local shared_manifest
local function manifest()
  shared_manifest = shared_manifest or fixture.build(helpers.temp_dir())
  return shared_manifest
end

local function root()
  local path = vim.fs.normalize(assert(vim.uv.fs_realpath(manifest().root)))
  return { path = path, provenance = "git", worktree_id = "git:" .. path }
end

-- The specs have no environment field, so the manifest environment (the
-- fixture HOME with its global ignore) is applied to this process.
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

local sessions = {}

local function new_session(request)
  local base = { case = "sensitive" }
  local session =
    session_module.new(vim.tbl_extend("force", base, request or {}), root())
  table.insert(sessions, session)
  return session
end

local function wait_until(predicate)
  eq(vim.wait(WAIT_MS, predicate, 5), true)
end

local function idle_processes(tag)
  wait_until(function()
    return proc.active_count(tag) == 0
  end)
end

---Wait until neither lane is loading; return the snapshot.
local function settle(session)
  local snapshot
  wait_until(function()
    snapshot = session:snapshot()
    local files, content = snapshot.files.lane, snapshot.content.lane
    return files.state ~= "loading" and content.state ~= "loading"
  end)
  return snapshot
end

local function all_occurrences(snapshot)
  local records = {}
  for _, group in ipairs(snapshot.content.groups) do
    vim.list_extend(records, group.records)
  end
  return records
end

---Occurrences in the manifest's form, sorted like the manifest.
local function locations(snapshot)
  local found = {}
  for _, record in ipairs(all_occurrences(snapshot)) do
    table.insert(found, {
      path = record.path,
      line = record.row + 1,
      byte_start = record.byte_start,
      byte_end = record.byte_end,
    })
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
  return found
end

local function file_paths(snapshot)
  return vim.tbl_map(function(record)
    return record.path
  end, snapshot.files.records)
end

local function group_of(snapshot, path)
  for _, group in ipairs(snapshot.content.groups) do
    if group.path == path then
      return group
    end
  end
end

local function needles(eligible)
  return fixture.expected_matches(manifest(), "needle", eligible)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for name, value in pairs(manifest().env) do
        set_env(name, value)
      end
    end,
    post_case = function()
      for _, session in ipairs(sessions) do
        session:close()
      end
      sessions = {}
      package.loaded[UI_MODULE] = nil
      proc.cancel_all()
      idle_processes()
      restore_env()
    end,
  },
})

T["lanes"] = MiniTest.new_set()

T["lanes"]["one query drives file names and content"] = function()
  local m = manifest()
  local snapshot = settle(new_session({ query = "needle" }))
  eq(snapshot.files.lane.state, "complete")
  eq(snapshot.content.lane.state, "complete")
  local names = file_paths(snapshot)
  eq(vim.list_contains(names, m.special.name_only), true)
  eq(vim.list_contains(names, m.special.name_and_content), true)
  eq(locations(snapshot), needles(fixture.eligible(m, false, false)))
  eq(snapshot.content.lane.count, #all_occurrences(snapshot))
  for _, record in ipairs(snapshot.files.records) do
    eq({ record.kind, record.row, record.byte_start }, { "file" })
  end
end

T["lanes"]["keeps both kinds when a file matches both"] = function()
  local m = manifest()
  local snapshot = settle(new_session({ query = "needle" }))
  local both = m.special.name_and_content
  eq(vim.list_contains(file_paths(snapshot), both), true)
  eq(#group_of(snapshot, both).records, 1)
end

T["lanes"]["keeps every location of a file sorted"] = function()
  local snapshot = settle(new_session({ query = "needle" }))
  local group = group_of(snapshot, manifest().special.repeated_same_line)
  local spans = vim.tbl_map(function(record)
    return { record.row, record.byte_start, record.byte_end }
  end, group.records)
  eq(spans, { { 0, 0, 6 }, { 0, 7, 13 }, { 0, 14, 20 }, { 2, 0, 6 } })
  local ids = {}
  for _, record in ipairs(group.records) do
    eq(ids[record.id], nil)
    ids[record.id] = true
  end
end

T["lanes"]["path glob narrows both lanes"] = function()
  local m = manifest()
  local eligible = fixture.eligible(m, false, false, "exclusion")
  local snapshot = settle(new_session({ query = "needle", glob = "!*.txt" }))
  local files, content = snapshot.files.lane, snapshot.content.lane
  eq({ files.state, files.error, content.state, content.error }, {
    "complete",
    nil,
    "complete",
    nil,
  })
  eq(locations(snapshot), needles(eligible))
  eq(#snapshot.content.groups > 0, true)
  for _, path in ipairs(file_paths(snapshot)) do
    eq(vim.list_contains(eligible, path), true)
  end
  eq(vim.list_contains(file_paths(snapshot), m.special.name_only), false)
end

T["lanes"]["visibility switches keep the query"] = function()
  local m = manifest()
  local session = new_session({ query = "needle" })
  settle(session)
  session:update({ hidden = true, ignored = true })
  local snapshot = settle(session)
  eq(snapshot.request.query, "needle")
  eq(locations(snapshot), needles(fixture.eligible(m, true, true)))
  eq(group_of(snapshot, m.special.ignored_hidden) ~= nil, true)
end

T["empty query"] = MiniTest.new_set()

T["empty query"]["with a glob lists its files, no content"] = function()
  local m = manifest()
  local session = new_session({ glob = "!*.txt" })
  local snapshot = settle(session)
  vim.wait(150) -- past the content debounce
  eq(proc.active_count(GREP_TAG), 0)
  snapshot = session:snapshot()
  eq(snapshot.files.lane.state, "complete")
  eq(file_paths(snapshot), fixture.eligible(m, false, false, "exclusion"))
  eq({ snapshot.content.lane.state, #snapshot.content.groups }, { "idle", 0 })
end

---Paths in the listing order of an empty query without recent buffers:
---fewer path components first, ties by byte-wise path order.
local function listing_order(paths)
  local sorted = vim.list_slice(paths)
  local function depth(path)
    return select(2, path:gsub("/", ""))
  end
  table.sort(sorted, function(a, b)
    if depth(a) ~= depth(b) then
      return depth(a) < depth(b)
    end
    return a < b
  end)
  return sorted
end

T["empty query"]["Find files lists every eligible file"] = function()
  local eligible = fixture.eligible(manifest(), false, false)
  local session = new_session({ mode = "files" })
  local snapshot = settle(session)
  vim.wait(150) -- past the content debounce
  eq(proc.active_count(GREP_TAG), 0)
  snapshot = session:snapshot()
  -- More files than the quota: the best 200 in listing order, and the
  -- total counts them all.
  eq(#eligible > 200, true)
  eq(snapshot.files.lane.state, "truncated")
  eq(snapshot.files.lane.total, #eligible)
  eq(file_paths(snapshot), vim.list_slice(listing_order(eligible), 1, 200))
  eq(snapshot.content.lane.state, "idle")
end

T["empty query"]["Find files lists recent buffers first"] = function()
  local base = root().path
  local edited = {}
  for _, name in ipairs({ "bulk/bulk-200.txt", "src/main.lua" }) do
    vim.cmd.edit(vim.fn.fnameescape(base .. "/" .. name))
    table.insert(edited, vim.api.nvim_get_current_buf())
  end
  -- Listed but never shown, outside the inventory, and outside the root.
  for _, path in ipairs({ "unicode.txt", "no-such-file.txt" }) do
    table.insert(edited, vim.fn.bufadd(base .. "/" .. path))
    vim.bo[edited[#edited]].buflisted = true
  end
  table.insert(edited, vim.fn.bufadd(helpers.temp_dir() .. "/elsewhere.txt"))
  vim.bo[edited[#edited]].buflisted = true
  local snapshot = settle(new_session({ mode = "files" }))
  for _, bufnr in ipairs(edited) do
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  -- Recently used first, the current buffer last of them; the others
  -- keep the listing order and the total is unchanged.
  local paths = file_paths(snapshot)
  eq(
    vim.list_slice(paths, 1, 3),
    { "bulk/bulk-200.txt", "unicode.txt", "src/main.lua" }
  )
  eq(vim.tbl_contains(paths, "no-such-file.txt"), false)
  local eligible = fixture.eligible(manifest(), false, false)
  eq(snapshot.files.lane.total, #eligible)
  eq(paths[4], listing_order(eligible)[1])
end

T["empty query"]["typing narrows the listing"] = function()
  local session = new_session({ mode = "files" })
  settle(session)
  session:update({ query = "needle" })
  local snapshot = settle(session)
  eq(file_paths(snapshot), { "needle-both.txt", "needle-name-only.txt" })
  eq(snapshot.files.lane.total, 2)
end

T["empty query"]["Find in files runs nothing"] = function()
  local session = new_session({ mode = "content" })
  vim.wait(150) -- past the content debounce
  eq(proc.active_count(GREP_TAG), 0)
  local snapshot = session:snapshot()
  eq(snapshot.content.lane.state, "idle")
  eq(snapshot.files.lane.state, "idle")
  eq(#snapshot.content.groups, 0)
end

T["empty query"]["combined search without a glob shows nothing"] = function()
  local session = new_session({ query = "needle" })
  settle(session)
  session:update({ query = "" })
  vim.wait(150) -- past the content debounce
  eq(proc.active_count(GREP_TAG), 0)
  local snapshot = session:snapshot()
  eq(snapshot.files.lane.state, "idle")
  eq(snapshot.content.lane.state, "idle")
  eq({ #snapshot.files.records, #snapshot.content.groups }, { 0, 0 })
end

T["modes"] = MiniTest.new_set()

T["modes"]["file names alone never run content search"] = function()
  local session = new_session({ mode = "files", query = "needle" })
  local snapshot = settle(session)
  vim.wait(150) -- past the content debounce
  eq(proc.active_count(GREP_TAG), 0)
  eq(file_paths(snapshot), { "needle-both.txt", "needle-name-only.txt" })
  eq(snapshot.files.lane.total, 2)
  eq(snapshot.content.lane.state, "idle")
  eq(#snapshot.files.records[1].positions, 6)
end

T["modes"]["content alone never ranks file names"] = function()
  local session = new_session({ mode = "content", query = "needle" })
  local snapshot = settle(session)
  eq(snapshot.files.lane.state, "idle")
  eq(#snapshot.files.records, 0)
  local eligible = fixture.eligible(manifest(), false, false)
  eq(locations(snapshot), needles(eligible))
end

T["modes"]["counts every match beyond the file name quota"] = function()
  local m = manifest()
  local snapshot = settle(new_session({ mode = "files", query = "bulk" }))
  eq(snapshot.files.lane.state, "truncated")
  eq(snapshot.files.lane.total, m.special.bulk.file_count)
end

local fuzzy = require("iara.features.search.fuzzy")
local match_paths = fuzzy.match
local visits
T["refinements"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      visits = 0
      fuzzy.match = function(query, paths, opts)
        visits = visits + #paths
        return match_paths(query, paths, opts)
      end
    end,
    post_case = function()
      fuzzy.match = match_paths
    end,
  },
})

T["refinements"]["reranks matches beyond the visible quota"] = function()
  local session = new_session({ mode = "files", query = "bulk" })
  local before = settle(session)
  local total = before.files.lane.total
  local tail = ("bulk-%03d.txt"):format(manifest().special.bulk.file_count)
  local path = "bulk/" .. tail
  eq(before.files.lane.state, "truncated")
  eq(vim.list_contains(file_paths(before), path), false)
  visits = 0
  session:update({ query = tail })
  eq(file_paths(settle(session)), { path })
  eq(visits, total)
  visits = 0
  session:update({ query = "bulk" })
  eq(settle(session).files.lane.total, total)
  eq(visits > total, true)
end

T["refinements"]["widening the path restriction ranks outside it"] = function()
  local session = new_session({
    mode = "files",
    query = "need",
    within = { "needle-both.txt" },
  })
  eq(file_paths(settle(session)), { "needle-both.txt" })
  session:update({ query = "needle", within = false })
  eq(file_paths(settle(session)), { "needle-both.txt", "needle-name-only.txt" })
end

T["refinements"]["a refresh admits new files before an append"] = function()
  local dir = helpers.temp_dir()
  assert(vim.fn.writefile({}, dir .. "/app-one.lua") == 0)
  local search_root = { path = dir, provenance = "startup" }
  local session =
    session_module.new({ mode = "files", query = "ap" }, search_root)
  table.insert(sessions, session)
  eq(file_paths(settle(session)), { "app-one.lua" })
  assert(vim.fn.writefile({}, dir .. "/app-two.lua") == 0)
  session:refresh()
  session:update({ query = "app" })
  eq(file_paths(settle(session)), { "app-one.lua", "app-two.lua" })
end

T["within"] = MiniTest.new_set()

T["within"]["narrows both lanes to the listed paths"] = function()
  local within = { "repeated.txt", "unicode.txt", "no-such-file.txt" }
  local snapshot = settle(new_session({ query = "needle", within = within }))
  local groups = vim.tbl_map(function(group)
    return group.path
  end, snapshot.content.groups)
  table.sort(groups)
  eq(groups, { "repeated.txt", "unicode.txt" })
  eq(snapshot.files.records, {})
  -- An empty query lists every listed path that is eligible.
  local session = new_session({ mode = "files", within = within })
  local listed = file_paths(settle(session))
  table.sort(listed)
  eq(listed, { "repeated.txt", "unicode.txt" })
end

T["within"]["never widens eligibility"] = function()
  local within = { ".env", "repeated.txt", ".git/HEAD" }
  local session = new_session({ query = "needle", within = within })
  local snapshot = settle(session)
  eq(
    vim.tbl_map(function(group)
      return group.path
    end, snapshot.content.groups),
    { "repeated.txt" }
  )
  -- Only both switches make the ignored hidden `.env` eligible.
  session:update({ hidden = true, ignored = true })
  snapshot = settle(session)
  local paths = vim.tbl_map(function(group)
    return group.path
  end, snapshot.content.groups)
  table.sort(paths)
  eq(paths, { ".env", "repeated.txt" })
end

T["within"]["false clears the list"] = function()
  local session = new_session({
    mode = "files",
    query = "needle",
    within = { "repeated.txt" },
  })
  eq(file_paths(settle(session)), {})
  session:update({ within = false })
  local snapshot = settle(session)
  eq(snapshot.request.within, nil)
  eq(file_paths(snapshot), { "needle-both.txt", "needle-name-only.txt" })
end

T["within"]["rejects a list with a non-string path"] = function()
  expect.error(function()
    new_session({ within = { "a", 1 } })
  end, "within%[2%] must be a string")
  expect.error(function()
    new_session({ mode = "names" })
  end, "mode must be files or content")
end

T["quotas"] = MiniTest.new_set()

T["quotas"]["each lane stops at its own quota"] = function()
  local snapshot = settle(new_session({ query = "bulk" }))
  local files, content = snapshot.files.lane, snapshot.content.lane
  eq({ files.state, files.count, files.limit }, { "truncated", 200, 200 })
  eq(#snapshot.files.records, 200)
  eq(
    { content.state, content.count, content.limit },
    { "truncated", 1000, 1000 }
  )
  eq(#all_occurrences(snapshot), 1000)
  idle_processes(GREP_TAG) -- the full quota stopped ripgrep
end

T["generations"] = MiniTest.new_set()

T["generations"]["debounces content and keeps the walk"] = function()
  local session = new_session({ query = "needle" })
  settle(session)
  idle_processes()
  local content_at
  session:on_change(function(snapshot)
    local lane = snapshot.content.lane
    if not content_at and (lane.count > 0 or lane.state ~= "loading") then
      content_at = vim.uv.hrtime()
    end
  end)
  local typed_at = vim.uv.hrtime()
  for _, query in ipairs({ "c", "co", "col", "colo", "color" }) do
    session:update({ query = query })
  end
  eq(proc.active_count(INVENTORY_TAG), 0) -- keystrokes keep the walk
  local snapshot = settle(session)
  wait_until(function()
    return content_at ~= nil
  end)
  -- A lower bound only: load can delay results, never advance them.
  -- Timers count from the cached loop time, hence the margin.
  eq((content_at - typed_at) / 1e6 >= 40, true)
  local paths = vim.tbl_map(function(group)
    return group.path
  end, snapshot.content.groups)
  eq(paths, { "regex.txt" })
end

T["generations"]["rejects results of a superseded query"] = function()
  local session = new_session({ query = "bulkmark" })
  wait_until(function()
    return session:snapshot().content.lane.count > 0
  end)
  local seen = {}
  session:on_change(function(snapshot)
    table.insert(seen, snapshot)
  end)
  session:update({ query = "needle" })
  local generation = session:snapshot().generation
  local final = settle(session)
  vim.wait(50)
  eq(#seen > 0, true)
  for _, snapshot in ipairs(seen) do
    eq(snapshot.generation, generation)
    for _, record in ipairs(all_occurrences(snapshot)) do
      eq({ record.generation, vim.startswith(record.path, "bulk/") }, {
        generation,
        false,
      })
    end
  end
  eq(locations(final), needles(fixture.eligible(manifest(), false, false)))
end

T["generations"]["reuses the inventory of a known identity"] = function()
  local session = new_session({ query = "needle" })
  settle(session)
  idle_processes()
  session:update({ hidden = true })
  eq(proc.active_count(INVENTORY_TAG) > 0, true)
  settle(session)
  idle_processes()
  session:update({ hidden = false })
  eq(proc.active_count(INVENTORY_TAG), 0)
  local snapshot = settle(session)
  eq(locations(snapshot), needles(fixture.eligible(manifest(), false, false)))
end

T["generations"]["close cancels work and stops notifying"] = function()
  local session = new_session({ query = "bulkmark" })
  local calls = 0
  session:on_change(function()
    calls = calls + 1
  end)
  session:close()
  idle_processes()
  vim.wait(100)
  eq(calls, 0)
  local snapshot = session:snapshot()
  eq({ snapshot.files.lane.state, snapshot.content.lane.state }, {
    "cancelled",
    "cancelled",
  })
end

T["progressive"] = MiniTest.new_set()

---A fake `rg` on PATH: the walk prints `early`, waits until `gate`
---exists, prints `late`, and exits with `code`; content search finds
---nothing. Returns a root for it and the gate path.
local function gated_walk(early, late, code)
  local dir = helpers.temp_dir()
  local gate = dir .. "/gate"
  local script = table.concat({
    "#!/bin/sh",
    'case " $* " in',
    '  *" --files "*)',
    ("    printf '%s\\0'"):format(early),
    ("    while [ ! -e '%s' ]; do sleep 0.01; done"):format(gate),
    ("    printf '%s\\0'"):format(late),
    ("    exit %d ;;"):format(code),
    "esac",
    "exit 1",
  }, "\n")
  helpers.write_file(dir .. "/bin/rg", script .. "\n")
  vim.fn.setfperm(dir .. "/bin/rg", "rwx------")
  set_env("PATH", dir .. "/bin:" .. vim.env.PATH)
  local path = dir .. "/root"
  vim.fn.mkdir(path, "p")
  return { path = path, provenance = "marker" }, gate
end

local function open_gate(gate)
  helpers.write_file(gate, "")
end

T["progressive"]["ranks file names before the inventory completes"] = function()
  local walk_root, gate = gated_walk("needle-early.txt", "needle-a.txt", 0)
  local session = session_module.new({ query = "needle" }, walk_root)
  table.insert(sessions, session)
  wait_until(function()
    return #session:snapshot().files.records == 1
  end)
  local early = session:snapshot()
  eq(file_paths(early), { "needle-early.txt" })
  -- Provisional: the lane keeps loading, and content waits for the
  -- complete inventory.
  eq(early.files.lane.state, "loading")
  eq(early.content.lane.state, "loading")
  eq(proc.active_count(GREP_TAG), 0)
  open_gate(gate)
  local final = settle(session)
  eq(final.files.lane.state, "complete")
  -- A later, better-ranked path goes before the provisional one.
  eq(file_paths(final), { "needle-a.txt", "needle-early.txt" })
  eq(final.content.lane.state, "complete")
end

T["progressive"]["Find files lists before the walk completes"] = function()
  local walk_root, gate = gated_walk("deep/early.txt", "top.txt", 0)
  local session = session_module.new({ mode = "files" }, walk_root)
  table.insert(sessions, session)
  wait_until(function()
    return #session:snapshot().files.records == 1
  end)
  local early = session:snapshot()
  eq(file_paths(early), { "deep/early.txt" })
  eq(early.files.lane.state, "loading")
  eq(early.files.lane.total, 1)
  open_gate(gate)
  local final = settle(session)
  eq(final.files.lane.state, "complete")
  eq(file_paths(final), { "top.txt", "deep/early.txt" })
  eq(final.files.lane.total, 2)
end

T["progressive"]["a failed walk withdraws provisional names"] = function()
  local walk_root, gate = gated_walk("needle-early.txt", "needle-late.txt", 2)
  local session = session_module.new({ query = "needle" }, walk_root)
  table.insert(sessions, session)
  wait_until(function()
    return #session:snapshot().files.records == 1
  end)
  open_gate(gate)
  local final = settle(session)
  eq(final.files.lane.state, "error")
  eq(final.files.records, {})
  eq(final.files.lane.count, 0)
  eq(final.content.lane.state, "error")
end

T["progressive"]["a keystroke reranks the paths walked so far"] = function()
  local walk_root, gate = gated_walk("alpha-one.txt", "alpha-two.txt", 0)
  local session = session_module.new({ query = "one" }, walk_root)
  table.insert(sessions, session)
  wait_until(function()
    return #session:snapshot().files.records == 1
  end)
  eq(proc.active_count(INVENTORY_TAG), 1)
  session:update({ query = "alpha" })
  wait_until(function()
    return #session:snapshot().files.records == 1
  end)
  eq(file_paths(session:snapshot()), { "alpha-one.txt" })
  eq(proc.active_count(INVENTORY_TAG), 1) -- the walk kept running
  open_gate(gate)
  eq(file_paths(settle(session)), { "alpha-one.txt", "alpha-two.txt" })
end

T["errors"] = MiniTest.new_set()

T["errors"]["invalid regex fails content only"] = function()
  local snapshot = settle(new_session({ query = "(unclosed", regex = true }))
  eq(snapshot.content.lane.state, "error")
  eq(snapshot.content.lane.error.code, "regex")
  eq(snapshot.files.lane.state, "complete")
end

T["errors"]["an oversized frame leaves content incomplete"] = function()
  local snapshot = settle(new_session({ query = "longlinemarker" }))
  eq(snapshot.content.lane.state, "incomplete")
  eq(snapshot.content.lane.error.code, "overflow")
  helpers.expect_match(snapshot.content.lane.error.message, "stopped early")
  eq(snapshot.files.lane.state, "complete")
end

T["errors"]["rejects an oversized query before any work"] = function()
  local snapshot = settle(new_session({ query = ("q"):rep(257) }))
  eq(snapshot.files.lane.error.code, "query")
  eq(snapshot.content.lane.error.code, "query")
  vim.wait(100)
  eq(proc.active_count(GREP_TAG), 0)
end

T["errors"]["an invalid glob fails both lanes as a filter"] = function()
  local snapshot = settle(new_session({ query = "needle", glob = "src/[" }))
  eq({ snapshot.files.lane.state, snapshot.files.lane.error.code }, {
    "error",
    "glob",
  })
  eq(snapshot.content.lane.error.code, "glob")
end

T["errors"]["a missing ripgrep is reported per lane"] = function()
  set_env("PATH", helpers.temp_dir())
  local snapshot = settle(new_session({ query = "needle" }))
  eq(snapshot.files.lane.error.code, "not_found")
  eq(snapshot.content.lane.error.code, "not_found")
end

T["errors"]["raises for a malformed request"] = function()
  expect.error(function()
    session_module.new({ pattern = "x" }, root())
  end, "unknown request field")
  expect.error(function()
    session_module.new({ hidden = "yes" }, root())
  end, "boolean")
  expect.error(function()
    session_module.new({ scope = { kind = "directory" } }, root())
  end, "absolute")
end

T["quickfix"] = MiniTest.new_set()

local function quickfix_items(id)
  local list = vim.fn.getqflist({ id = id, items = 1, title = 1 })
  local items = {}
  for _, item in ipairs(list.items) do
    table.insert(items, {
      name = vim.api.nvim_buf_get_name(item.bufnr),
      lnum = item.lnum,
      col = item.col,
      end_col = item.end_col,
    })
  end
  return list.title, items
end

T["quickfix"]["exports byte ranges as one-based positions"] = function()
  local m = manifest()
  local session = new_session({ query = "needle" })
  local snapshot = settle(session)
  local records = {}
  for _, path in ipairs({ "unicode.txt", "crlf.txt", "bom.txt" }) do
    vim.list_extend(records, group_of(snapshot, path).records)
  end
  for _, record in ipairs(snapshot.files.records) do
    if record.path == m.special.name_only then
      table.insert(records, record)
    end
  end
  local title, items = quickfix_items(session:to_quickfix(records, "Needle"))
  local base = root().path .. "/"
  eq(title, "Needle")
  eq(items, {
    { name = base .. "unicode.txt", lnum = 1, col = 8, end_col = 14 },
    { name = base .. "crlf.txt", lnum = 2, col = 8, end_col = 14 },
    -- Neovim strips the BOM that ripgrep counts.
    { name = base .. "bom.txt", lnum = 1, col = 1, end_col = 7 },
    { name = base .. m.special.name_only, lnum = 0, col = 0, end_col = 0 },
  })
end

---Text under the cursor, as long as `word`, after a quickfix jump.
local function word_at_cursor(word)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  return line:sub(cursor[2] + 1, cursor[2] + #word)
end

T["quickfix"]["jumps land on matches in BOM, CRLF, Unicode files"] = function()
  local session = new_session({ query = "needle" })
  local snapshot = settle(session)
  local records = {}
  for _, path in ipairs({ "bom.txt", "crlf.txt", "unicode.txt" }) do
    vim.list_extend(records, group_of(snapshot, path).records)
  end
  session:to_quickfix(records, "Needle")
  local landed = {}
  vim.cmd("silent cfirst")
  for index = 1, #records do
    if index > 1 then
      vim.cmd("silent cnext")
    end
    local name = vim.fs.basename(vim.api.nvim_buf_get_name(0))
    table.insert(landed, name .. ":" .. word_at_cursor("needle"))
  end
  vim.cmd("silent! %bwipeout!")
  eq(landed, { "bom.txt:needle", "crlf.txt:needle", "unicode.txt:needle" })
end

T["quickfix"]["follows loaded buffers with and without the BOM"] = function()
  local session = new_session({ query = "needle" })
  local records = group_of(settle(session), "bom.txt").records
  local path = vim.fn.fnameescape(root().path .. "/bom.txt")
  local landed = {}
  -- `++bin` keeps the BOM in the text; 'nobomb' after a normal read
  -- leaves it stripped.
  for _, command in ipairs({ "edit ++bin ", "edit ++nobin " }) do
    vim.cmd(command .. path)
    vim.bo.bomb = false
    session:to_quickfix(records, "Needle")
    vim.cmd("silent cfirst")
    table.insert(landed, word_at_cursor("needle"))
    vim.cmd("silent! %bwipeout!")
  end
  eq(landed, { "needle", "needle" })
end

T["quickfix"]["keeps paths with spaces and Unicode intact"] = function()
  local names = manifest().special.names
  local session = new_session({ query = "special file name" })
  local snapshot = settle(session)
  local records = {}
  for _, path in ipairs({ names.spaces, names.unicode }) do
    vim.list_extend(records, group_of(snapshot, path).records)
  end
  local _, items = quickfix_items(session:to_quickfix(records, "Special"))
  local base = root().path .. "/"
  eq(items, {
    { name = base .. names.spaces, lnum = 1, col = 1, end_col = 18 },
    { name = base .. names.unicode, lnum = 1, col = 1, end_col = 18 },
  })
end

T["entry"] = MiniTest.new_set()

local function stub_ui()
  local opened = {}
  package.loaded[UI_MODULE] = {
    open = function(session)
      table.insert(sessions, session)
      table.insert(opened, session)
    end,
  }
  return opened
end

---Open a search from a buffer editing a fixture file.
local function open_from_fixture(request)
  vim.cmd.edit(vim.fn.fnameescape(manifest().root .. "/content-only.txt"))
  local bufnr = vim.api.nvim_get_current_buf()
  local session = search.open(request)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return session
end

T["entry"]["open snapshots the root of the invoking buffer"] = function()
  local opened = stub_ui()
  local session = open_from_fixture({ query = "needle", focus = "content" })
  eq(opened, { session })
  local snapshot = session:snapshot()
  eq(snapshot.root.path, root().path)
  eq(snapshot.request.focus, "content")
end

T["entry"]["resume restores the controls and reruns"] = function()
  stub_ui()
  local first = open_from_fixture({ query = "needle", glob = "!*.txt" })
  first:update({ hidden = true, regex = true })
  settle(first)
  local resumed = search.resume()
  eq(resumed ~= first, true)
  local fresh = resumed:snapshot()
  eq(#fresh.files.records + #fresh.content.groups, 0) -- nothing reused
  local request = fresh.request
  eq(
    { request.query, request.glob, request.hidden, request.regex },
    { "needle", "!*.txt", true, true }
  )
  eq(fresh.root.path, first:snapshot().root.path)
  local snapshot = settle(resumed)
  local eligible = fixture.eligible(manifest(), true, false, "exclusion")
  eq(locations(snapshot), needles(eligible))
  eq(snapshot.generation, 1)
end

-- Directory step source (S9) -------------------------------------------

T["tree"] = MiniTest.new_set()

---Count inventory walks started from now on.
local function count_walks()
  local inventory = require("iara.features.search.inventory")
  local build, counter = inventory.build, { walks = 0 }
  inventory.build = function(...)
    counter.walks = counter.walks + 1
    return build(...)
  end
  counter.restore = function()
    inventory.build = build
  end
  return counter
end

local function tree_of(session)
  local result, synchronous = nil, true
  session:tree(function(found)
    eq(synchronous, false)
    result = found
  end)
  synchronous = false
  wait_until(function()
    return result ~= nil
  end)
  return result
end

local function sorted(paths)
  local copy = vim.list_slice(paths)
  table.sort(copy)
  return copy
end

T["tree"]["lists the whole root under the switches, never .git"] = function()
  local m = manifest()
  local src = root().path .. "/src"
  local session = new_session({
    mode = "files",
    scope = { kind = "directory", path = src },
  })
  local result = tree_of(session)
  eq(result.state, "complete")
  eq(sorted(result.paths), fixture.eligible(m, false, false))
  session:update({ hidden = true, ignored = true })
  result = tree_of(session)
  local paths = sorted(result.paths)
  eq(paths, fixture.eligible(m, true, true))
  for _, path in ipairs(paths) do
    eq(fixture.is_git_metadata(path), false)
  end
end

T["tree"]["reuses the root inventory instead of walking again"] = function()
  local counter = count_walks()
  local ok, err = pcall(function()
    local session = new_session({ mode = "files", glob = "*.txt" })
    settle(session)
    local before = counter.walks
    -- The complete `E` behind the glob serves the tree.
    tree_of(session)
    eq(counter.walks, before)
    local scoped = new_session({
      mode = "files",
      scope = { kind = "directory", path = root().path .. "/src" },
    })
    settle(scoped)
    before = counter.walks
    tree_of(scoped)
    eq(counter.walks, before + 1)
    tree_of(scoped)
    -- Back to the root scope: the tree's walk is the inventory.
    scoped:update({ scope = { kind = "root" } })
    settle(scoped)
    eq(counter.walks, before + 1)
  end)
  counter.restore()
  assert(ok, err)
end

T["tree"]["is not delivered after cancel or close"] = function()
  local session = new_session({ mode = "files" })
  local called = false
  local handle = session:tree(function()
    called = true
  end)
  handle:cancel()
  session:tree(function()
    called = true
  end)
  session:close()
  vim.wait(200)
  eq(called, false)
end

return T
