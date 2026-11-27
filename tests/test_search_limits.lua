-- Tests for the M2 search limits (task M2-S): inventory walk limits and
-- incomplete labels, reuse of `E` across glob changes, the session-wide
-- cap of four search processes, and the byte limits on held and
-- retained results. Fake `rg` scripts produce inventories too large to
-- build on disk; the reuse cases log the real ripgrep's invocations.
local helpers = require("helpers")
local inventory = require("iara.features.search.inventory")
local proc = require("iara.core.proc")
local session_module = require("iara.features.search.session")
local slots = require("iara.features.search.slots")

local eq = MiniTest.expect.equality

local WAIT_MS = 20000
local INVENTORY_TAG = "iara-search-inventory"
local GREP_TAG = "search.grep"

local saved_path = vim.env.PATH
local saved_deadline = inventory.LIMITS.deadline_ms

local function wait_until(predicate, ms)
  eq(vim.wait(ms or WAIT_MS, predicate, 5), true)
end

local function wait_idle()
  wait_until(function()
    return slots.count() == 0 and proc.active_count() == 0
  end)
end

---Put a fake `rg` first on PATH. `e_walk` and `g_walk` are shell
---snippets for the plain walk and the glob walk; content searches find
---nothing. Returns a root directory for it.
local function fake_rg(e_walk, g_walk)
  local dir = helpers.temp_dir()
  local script = table.concat({
    "#!/bin/sh",
    'case " $* " in',
    '  *" --files "*"--glob="*) ' .. (g_walk or "exit 0") .. " ;;",
    '  *" --files "*) ' .. e_walk .. " ;;",
    "esac",
    "exit 1",
  }, "\n")
  helpers.write_file(dir .. "/bin/rg", script .. "\n")
  vim.fn.setfperm(dir .. "/bin/rg", "rwx------")
  vim.env.PATH = dir .. "/bin:" .. saved_path
  vim.fn.mkdir(dir .. "/root", "p")
  return dir .. "/root"
end

---Shell snippet printing `count` NUL-terminated paths `PREFIXn`.
local function many_paths(prefix, count)
  return ("seq -f '%s%%g' 1 %d | tr '\\n' '\\0'"):format(prefix, count)
end

local function build(root, fields)
  local spec = vim.tbl_extend("force", {
    root = root,
    scope = { kind = "root" },
    hidden = false,
    ignored = false,
    generation = 1,
  }, fields or {})
  local result
  inventory.build(spec, function(value)
    result = value
  end)
  wait_until(function()
    return result ~= nil
  end)
  return result
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      slots.cancel_all()
      wait_idle()
      vim.env.PATH = saved_path
      inventory.LIMITS.deadline_ms = saved_deadline
    end,
  },
})

T["inventory limits"] = MiniTest.new_set()
local limits = T["inventory limits"]

limits["stops at 100,000 retained paths"] = function()
  local root = fake_rg(many_paths("f", 100005))
  local result = build(root)
  eq({ result.state, result.reason }, { "incomplete", "paths" })
  eq(#result.paths, 100000)
  eq(result.base, nil) -- an incomplete `E` is never reused
end

limits["an oversized root completes a small scope"] = function()
  local walk = many_paths("big/f", 100005) .. "; printf 'small/a\\0small/b\\0'"
  local root = fake_rg(walk)
  local scope = { kind = "directory", path = root .. "/small" }
  local result = build(root, { scope = scope })
  eq({ result.state, result.paths }, { "complete", { "small/a", "small/b" } })
end

limits["stops at 16 MiB of retained path bytes"] = function()
  local walk = table.concat({
    "x=$(head -c 4000 /dev/zero | tr '\\0' x)",
    "i=0",
    "while [ $i -lt 4300 ]; do",
    "  printf '%s%05d\\0' \"$x\" $i; i=$((i + 1))",
    "done",
  }, "\n")
  local result = build(fake_rg(walk))
  eq({ result.state, result.reason }, { "incomplete", "bytes" })
  eq(#result.paths, math.floor(16 * 1024 * 1024 / 4005))
end

limits["stops at a retained path above 4 KiB, not an outside one"] = function()
  local walk = table.concat({
    "long=$(head -c 4100 /dev/zero | tr '\\0' x)",
    'printf \'out/%s\\0in/ok\\0in/%s\\0in/later\\0\' "$long" "$long"',
  }, "\n")
  local root = fake_rg(walk)
  local scope = { kind = "directory", path = root .. "/in" }
  local result = build(root, { scope = scope })
  eq({ result.state, result.reason }, { "incomplete", "path_length" })
  eq(result.paths, { "in/ok" })
end

limits["a deadline stops both walks, even for a small scope"] = function()
  inventory.LIMITS.deadline_ms = 300
  local root = fake_rg("printf 'small/a\\0'; exec sleep 10", "exec sleep 10")
  local scope = { kind = "directory", path = root .. "/small" }
  local started = vim.uv.now()
  local result = build(root, { scope = scope, glob = "*" })
  eq({ result.state, result.reason }, { "incomplete", "deadline" })
  eq(result.paths, {}) -- `G` never listed small/a
  -- Both walks are terminated well before their sleep would end.
  wait_until(function()
    return proc.active_count(INVENTORY_TAG) == 0
  end, 3000)
  eq(vim.uv.now() - started < 5000, true)
end

limits["an incomplete inventory withholds content"] = function()
  local root = fake_rg(many_paths("f", 100005))
  local session = session_module.new({ query = "f1" }, { path = root })
  local snapshot
  wait_until(function()
    snapshot = session:snapshot()
    return snapshot.files.lane.state ~= "loading"
      and snapshot.content.lane.state ~= "loading"
  end)
  session:close()
  eq(snapshot.files.lane.state, "incomplete")
  helpers.expect_match(snapshot.files.lane.error.message, "paths")
  eq(snapshot.files.lane.count, 200)
  eq(snapshot.content.lane.state, "incomplete")
  helpers.expect_match(snapshot.content.lane.error.message, "withheld")
  eq(proc.active_count(GREP_TAG), 0)
end

T["reuse"] = MiniTest.new_set()

---A tree for the real ripgrep, and a wrapper that logs each call.
local function logged_tree()
  local dir = helpers.temp_dir()
  for _, name in ipairs({ "a.lua", "b.txt", "sub/c.lua", ".hidden/d.lua" }) do
    helpers.write_file(dir .. "/root/" .. name, "x\n")
  end
  local log = dir .. "/rg.log"
  local script = table
    .concat({
      "#!/bin/sh",
      "printf '%%s\\n' \"$*\" >> '%s'",
      "exec '%s' \"$@\"",
      "",
    }, "\n")
    :format(log, vim.fn.exepath("rg"))
  helpers.write_file(dir .. "/bin/rg", script)
  vim.fn.setfperm(dir .. "/bin/rg", "rwx------")
  vim.env.PATH = dir .. "/bin:" .. saved_path
  return dir .. "/root",
    function()
      return vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
    end
end

local function sorted(list)
  local copy = vim.list_slice(list)
  table.sort(copy)
  return copy
end

T["reuse"]["a glob change walks only G over the earlier E"] = function()
  local root, calls = logged_tree()
  local plain = build(root)
  eq(sorted(plain.paths), { "a.lua", "b.txt", "sub/c.lua" })
  local globbed = build(root, { glob = "*.lua", base = plain.base })
  eq(sorted(globbed.paths), { "a.lua", "sub/c.lua" })
  eq(#calls(), 2)
  helpers.expect_match(calls()[2], "%-%-glob=%*%.lua")
  -- The glob build carries the same `E`, so a second glob change reuses
  -- it again, and no glob at all needs no walk.
  local cleared = build(root, { base = globbed.base })
  eq(sorted(cleared.paths), { "a.lua", "b.txt", "sub/c.lua" })
  eq(#calls(), 2)
end

T["reuse"]["a base of other switches is not reused"] = function()
  local root, calls = logged_tree()
  local plain = build(root)
  local hidden = build(root, { hidden = true, glob = "*", base = plain.base })
  eq(sorted(hidden.paths), { ".hidden/d.lua", "a.lua", "b.txt", "sub/c.lua" })
  eq(#calls(), 3)
end

T["reuse"]["a session reruns only G when the glob changes"] = function()
  local root, calls = logged_tree()
  local session = session_module.new({ mode = "files" }, { path = root })
  wait_until(function()
    return session:snapshot().files.lane.state == "complete"
  end)
  eq(#calls(), 1)
  session:update({ glob = "*.lua", query = "c" })
  local snapshot
  wait_until(function()
    snapshot = session:snapshot()
    return snapshot.files.lane.state == "complete"
  end)
  session:close()
  eq(snapshot.files.records[1].path, "sub/c.lua")
  eq(#calls(), 2)
  helpers.expect_match(calls()[2], "%-%-glob")
end

T["processes"] = MiniTest.new_set()

local function sleeper(log, seconds)
  local completions = log
  return slots.spawn({ "sleep", tostring(seconds) }, {
    cwd = "/",
    timeout_ms = 10000,
    tag = GREP_TAG,
    on_complete = function(result)
      table.insert(completions, result.status)
    end,
  })
end

T["processes"]["at most four search processes live at once"] = function()
  local completions = {}
  local handles = {}
  for index = 1, 6 do
    handles[index] = sleeper(completions, 0.2)
  end
  eq(proc.active_count(GREP_TAG), 4)
  eq({ slots.count() }, { 4, 2 })
  -- The same cap holds in iara.core.proc's "search" admission group.
  eq(proc.admits({ group = "search", max = 4 }), false)
  handles[6]:cancel()
  wait_until(function()
    return #completions == 6
  end)
  -- The cancelled start never spawned; the fifth waited for a slot.
  eq(
    sorted(completions),
    { "cancelled", "exited", "exited", "exited", "exited", "exited" }
  )
  eq({ slots.count() }, { 0, 0 })
end

T["processes"]["retiring processes keep their slots"] = function()
  local completions = {}
  local first = sleeper(completions, 5)
  for _ = 1, 3 do
    sleeper(completions, 5)
  end
  local waiting = sleeper(completions, 0)
  first:cancel()
  -- Until the cancelled process is reaped, the waiting one cannot start.
  eq({ slots.count() }, { 4, 1 })
  wait_until(function()
    return vim.tbl_contains(completions, "exited")
  end)
  eq(completions[1], "cancelled")
  waiting:cancel()
end

T["held and retained bytes"] = MiniTest.new_set()

T["held and retained bytes"]["grep stops above 2 MiB held"] = function()
  local dir = helpers.temp_dir()
  local line = "needle" .. ("x"):rep(250)
  local lines = {}
  for index = 1, 8000 do
    lines[index] = line
  end
  -- 8,000 occurrences (below the 10,000 per file) of 256-byte lines
  -- hold more than 2 MiB before the file's `end` frame.
  helpers.write_file(dir .. "/big.txt", table.concat(lines, "\n") .. "\n")
  local done
  local published = 0
  require("iara.features.search.grep").run({
    root = dir,
    files = { "big.txt" },
    query = "needle",
    regex = false,
    case = "sensitive",
    generation = 1,
  }, {
    on_file = function()
      published = published + 1
    end,
    on_done = function(result)
      done = result
    end,
  })
  wait_until(function()
    return done ~= nil
  end)
  eq({ done.state, done.error.code, published }, { "partial", "overflow", 0 })
  helpers.expect_match(done.error.message, "held occurrences")
end

---A root-relative path of 4,005 bytes: deep directories of 199-byte
---names, so the absolute path stays within Linux's 4,096 bytes.
local function deep_path()
  local parts = {}
  for index = 1, 20 do
    parts[index] = ("%02d"):format(index) .. ("d"):rep(197)
  end
  return table.concat(parts, "/") .. "/f.txt"
end

T["held and retained bytes"]["content stops at 8 MiB retained"] = function()
  local dir = helpers.temp_dir()
  local path = deep_path()
  local line = "needle" .. ("x"):rep(250)
  local lines = {}
  for index = 1, 1010 do
    lines[index] = line
  end
  helpers.write_file(dir .. "/" .. path, table.concat(lines, "\n") .. "\n")
  local session = session_module.new({ query = "needle" }, { path = dir })
  local snapshot
  wait_until(function()
    snapshot = session:snapshot()
    return snapshot.content.lane.state ~= "loading"
  end)
  session:close()
  local lane = snapshot.content.lane
  eq({ lane.state, lane.error and lane.error.code }, { "truncated", "memory" })
  -- About 8.5 KiB per record: the byte limit, not the 1,000 quota, hit.
  eq(lane.count > 900 and lane.count < 1000, true)
end

return T
