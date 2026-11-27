-- Chained search filters (task UX1): which files a step hands to the
-- next one, what it discloses, refusals, and going back.
local helpers = require("helpers")
local chain = require("iara.features.search.chain")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local function request(fields)
  return vim.tbl_extend("force", {
    query = "",
    hidden = false,
    ignored = false,
    regex = false,
    case = "smart",
    scope = { kind = "root" },
  }, fields)
end

local function lane(state, count, total)
  return { state = state, count = count or 0, total = total or count or 0 }
end

---Snapshot of a file name step whose records are `paths`.
local function files_snapshot(fields, paths, state, total)
  local records = {}
  for _, path in ipairs(paths) do
    table.insert(records, { kind = "file", path = path })
  end
  return {
    request = request(vim.tbl_extend("force", { mode = "files" }, fields)),
    files = {
      lane = lane(state or "complete", #paths, total),
      records = records,
    },
    content = { lane = lane("idle"), groups = {} },
  }
end

local function content_snapshot(query, paths, state)
  local groups = {}
  for _, path in ipairs(paths) do
    table.insert(groups, { path = path, records = { {}, {} } })
  end
  return {
    request = request({ mode = "content", query = query }),
    files = { lane = lane("idle"), records = {} },
    content = { lane = lane(state or "complete", 2 * #paths), groups = groups },
  }
end

local T = MiniTest.new_set()

T["file names hand every collected record to a content step"] = function()
  local paths = {}
  for index = 1, 150 do
    paths[index] = ("src/file-%03d.ts"):format(index)
  end
  local hand_off = chain.hand_off(files_snapshot({ query = "file" }, paths))
  eq(hand_off.request.mode, "content")
  eq(hand_off.request.query, "")
  eq(hand_off.request.within, paths)
  eq(hand_off.handed, 150)
  eq(hand_off.notice, nil)
end

T["a truncated file list is handed over with a disclosure"] = function()
  local paths = {}
  for index = 1, 200 do
    paths[index] = ("bulk/%03d.txt"):format(index)
  end
  local snapshot = files_snapshot({ query = "bulk" }, paths, "truncated", 1234)
  local hand_off = chain.hand_off(snapshot)
  eq(#hand_off.request.within, 200)
  match(hand_off.notice, "best 200 of 1,234 files by name")
end

T["a glob without a query hands over the glob, not the listing"] = function()
  local snapshot = files_snapshot(
    { glob = "*.lua" },
    { "a.lua", "b.lua" },
    "truncated",
    900
  )
  local hand_off = chain.hand_off(snapshot)
  eq(hand_off.request.glob, "*.lua")
  eq(hand_off.request.within, nil)
  eq(hand_off.handed, 900)
  eq(hand_off.notice, nil)
end

T["an empty listing hands the whole eligible set, not its rows"] = function()
  local rows = {}
  for index = 1, 200 do
    rows[index] = ("src/%03d.ts"):format(index)
  end
  local snapshot = files_snapshot({}, rows, "truncated", 1284)
  local hand_off = chain.hand_off(snapshot)
  eq(hand_off.request.mode, "content")
  -- No path list: the next step searches every eligible file.
  eq(hand_off.request.within, nil)
  eq(hand_off.request.glob, nil)
  eq(hand_off.handed, 1284)
  eq(hand_off.notice, nil)
  local steps = chain.new(snapshot.request)
  chain.push(steps, snapshot.request, hand_off)
  eq(chain.crumbs(steps, "x"), { "Files (1,284)", "Contains: x" })
  -- A listing inside an earlier step keeps that step's paths.
  local within = { "a.ts", "b.ts" }
  local narrowed = files_snapshot({ within = within }, within)
  eq(chain.hand_off(narrowed).request.within, within)
end

T["content hands the files with matches to a file name step"] = function()
  local snapshot = content_snapshot("useEffect", { "a.ts", "b.ts" })
  snapshot.request.within = { "a.ts", "b.ts", "c.ts" }
  local hand_off = chain.hand_off(snapshot)
  eq(hand_off.request.mode, "files")
  eq(hand_off.request.query, "")
  eq(hand_off.request.within, { "a.ts", "b.ts" })
  local truncated = content_snapshot("x", { "a.ts" }, "truncated")
  match(chain.hand_off(truncated).notice, "first 1,000 matches")
end

T["refuses to chain from loading, failed, or empty results"] = function()
  local _, loading =
    chain.hand_off(files_snapshot({ query = "a" }, {}, "loading"))
  match(loading, "still loading")
  local failed = content_snapshot("(", {}, "error")
  failed.content.lane.error = { message = "invalid regex" }
  local _, reason = chain.hand_off(failed)
  match(reason, "invalid regex")
  local _, none = chain.hand_off(files_snapshot({ query = "zzz" }, {}))
  match(none, "No files")
  local _, empty = chain.hand_off(content_snapshot("", {}, "idle"))
  match(empty, "Type the text")
end

T["push keeps the current query and pop restores it"] = function()
  local first = request({ mode = "files", query = "" })
  local steps = chain.new(first)
  local snapshot = files_snapshot({ query = "test" }, { "a.test.ts" })
  chain.push(steps, snapshot.request, chain.hand_off(snapshot))
  eq(chain.depth(steps), 2)
  eq(chain.crumbs(steps, "useEffect"), {
    "Files: test (1)",
    "Contains: useEffect",
  })
  local restored = chain.pop(steps)
  eq(restored.query, "test")
  eq(restored.mode, "files")
  eq(chain.depth(steps), 1)
  eq(chain.pop(steps), nil)
end

T["changes clear the glob and the path list a step does not set"] = function()
  local changes = chain.changes(request({ mode = "files" }))
  eq(changes.glob, "")
  eq(changes.within, false)
  local kept = chain.changes(request({ glob = "*.ts", within = { "a" } }))
  eq(kept.glob, "*.ts")
  eq(kept.within, { "a" })
end

T["crumbs name globs and escape control characters"] = function()
  local steps = chain.new(request({ mode = "files", glob = "*.lua" }))
  eq(chain.crumbs(steps, "a\tb"), { "Files: *.lua a^Ib" })
  eq(chain.count_text(1234567), "1,234,567")
  eq(chain.count_text(12), "12")
end

return T
