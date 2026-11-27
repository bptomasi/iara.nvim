-- JSON extraction proofs of milestone M2 (task M2-D): the publication
-- watchdog and its suspension, the ARCH traversal and index caps at their
-- boundaries, and teardown of every owned timer and request without a
-- parse callback. Each case runs in a fresh child Neovim with the pinned
-- JSON parser; waits happen inside the child, on its own event loop.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local FIXTURES = helpers.iara_dir .. "/tests/fixtures/structured/"
local PARSER_DIR = helpers.iara_dir .. "/.tools/treesitter"
local HAS_PARSER = vim.uv.fs_stat(PARSER_DIR .. "/parser/json.so") ~= nil

local CHILD_HELPERS = [[
  local json = require("iara.features.structured.json")
  local path = require("iara.features.structured.path")
  _G.json = json
  _G.real_get_parser = vim.treesitter.get_parser
  _G.parse_calls = 0
  _G.results = {}

  -- Request a target and record each completion with its time.
  _G.request = function(row, col)
    local started = vim.uv.hrtime()
    return json.target_at(0, row or 0, col or 1, function(target, err)
      table.insert(_G.results, {
        code = err and err.code or "ok",
        message = err and err.message,
        path = target and path.render(target) or vim.NIL,
        ms = (vim.uv.hrtime() - started) / 1e6,
      })
    end)
  end

  _G.request_index = function()
    return json.index(0, function(result)
      table.insert(_G.results, {
        code = result.error and result.error.code or result.state,
      })
    end)
  end

  _G.await = function(count, ms)
    vim.wait(ms or 10000, function() return #_G.results >= count end, 5)
    return _G.results
  end

  _G.codes = function()
    return vim.tbl_map(function(r) return r.code end, _G.results)
  end

  -- Parsers whose behavior a case chooses: "silent" never calls back,
  -- "sync" completes inside parse(), "never_valid" also reports the
  -- tree as invalid (as after a paste in a highlighted buffer), "timeout"
  -- reports a Tree-sitter
  -- timeout inside parse(), "raise" throws.
  _G.use_parser = function(mode)
    _G.parse_callbacks = {}
    vim.treesitter.get_parser = function(bufnr, lang, opts)
      local real = _G.real_get_parser(bufnr, lang, opts)
      return {
        is_valid = function(_, ...)
          return mode ~= "never_valid" and real:is_valid(...)
        end,
        parse = function(_, range, callback)
          _G.parse_calls = _G.parse_calls + 1
          table.insert(_G.parse_callbacks, callback)
          if mode == "sync" or mode == "never_valid" then
            callback(nil, real:parse())
          elseif mode == "timeout" then
            callback("TIMEOUT", nil)
          elseif mode == "raise" then
            error("parser exploded")
          elseif mode == "real" then
            return real:parse(range, callback)
          end
        end,
      }
    end
  end

  -- Active libuv timers, to prove that teardown closes the watchdog.
  _G.active_timers = function()
    local count = 0
    vim.uv.walk(function(handle)
      if handle:get_type() == "timer" and handle:is_active() then
        count = count + 1
      end
    end)
    return count
  end
]]

local child = nil

local function start_child()
  if not HAS_PARSER then
    MiniTest.skip("JSON parser missing; run scripts/parsers.sh")
  end
  child = helpers.new_child()
  child.lua("vim.opt.runtimepath:prepend(...)", { PARSER_DIR })
  child.lua(CHILD_HELPERS)
end

local function stop_child()
  if child then
    child.stop()
    child = nil
  end
end

local function set_lines(lines)
  child.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  child.bo.filetype = "json"
end

local function status()
  return child.lua_get("json.status(0)")
end

local T = MiniTest.new_set({
  hooks = { pre_case = start_child, post_case = stop_child },
})

-- Watchdog -----------------------------------------------------------------

T["watchdog"] = MiniTest.new_set()

T["watchdog"]["abandons a silent parse and suspends the buffer"] = function()
  set_lines({ '{"a": [1]}' })
  child.lua("use_parser('silent')")
  local first = child.lua("request(); return await(1)[1]")
  eq(first.code, "watchdog")
  eq(first.ms >= 240, true)
  eq(first.message:find(":IaraStructuredRetry", 1, true) ~= nil, true)
  local held = status()
  eq({ held.parsing, held.watchdog, held.waiting }, { false, false, {} })
  eq(type(held.suspended), "string")
  -- Later automatic and index requests are refused without parsing and
  -- without waiting for another watchdog.
  local later = child.lua([[
    request(); request_index(); await(3)
    return { codes(), results[2].ms, parse_calls }
  ]])
  eq(later[1], { "watchdog", "watchdog", "watchdog" })
  eq(later[2] < 200, true)
  eq(later[3], 1)
end

T["watchdog"]["ignores the abandoned parse's late callback"] = function()
  set_lines({ '{"a": [1]}' })
  child.lua("use_parser('silent')")
  child.lua("request(); await(1)")
  local after = child.lua([[
    parse_callbacks[1](nil, real_get_parser(0, "json"):parse())
    vim.wait(300)
    return codes()
  ]])
  eq(after, { "watchdog" })
  eq(type(status().suspended), "string")
end

T["watchdog"]["explicit retry makes one bounded attempt"] = function()
  set_lines({ '{"a": [1]}' })
  child.lua("use_parser('silent')")
  child.lua("request(); await(1)")
  eq(child.lua_get("json.retry(0)"), true)
  eq(child.lua_get("json.retry(0)"), false)
  -- The retried parse is bounded by the watchdog too and suspends again.
  local retried = child.lua("request(); await(2); return results[2]")
  eq({ retried.code, retried.ms >= 240 }, { "watchdog", true })
  eq(child.lua_get("parse_calls"), 2)
  eq(type(status().suspended), "string")
  -- With a working parser the retry publishes the target.
  child.lua("use_parser('real'); json.retry(0)")
  local ok = child.lua("request(0, 7); await(3); return results[3]")
  eq({ ok.code, ok.path }, { "ok", 'doc[1]::$["a"][0]' })
  eq(status().suspended, nil)
end

T["watchdog"]["retry is a no-op on a buffer that is not suspended"] = function()
  set_lines({ "[1]" })
  eq(child.lua_get("json.retry(0)"), false)
end

T["watchdog"]["a synchronous callback publishes once, later"] = function()
  set_lines({ '{"a": [1]}' })
  child.lua("use_parser('sync')")
  local timers = child.lua_get("active_timers()")
  local run = child.lua([[
    request(0, 7)
    local during = #results
    await(1)
    vim.wait(400)
    return { during = during, codes = codes(), path = results[1].path }
  ]])
  eq(run, { during = 0, codes = { "ok" }, path = 'doc[1]::$["a"][0]' })
  local held = status()
  eq({ held.parsing, held.watchdog, held.suspended }, { false, false, nil })
  eq(child.lua_get("active_timers()") <= timers, true)
end

T["watchdog"]["a tree reported invalid still publishes once"] = function()
  set_lines({ '{"a": [1]}' })
  child.lua("use_parser('never_valid')")
  local run = child.lua([[
    request(0, 7); await(1); vim.wait(400)
    return { codes = codes(), path = results[1].path, calls = parse_calls }
  ]])
  eq(run, { codes = { "ok" }, path = 'doc[1]::$["a"][0]', calls = 1 })
end

T["watchdog"]["a synchronous Tree-sitter timeout suspends"] = function()
  set_lines({ "[1]" })
  child.lua("use_parser('timeout')")
  eq(child.lua("request(); return await(1)[1].code"), "watchdog")
  eq(type(status().suspended), "string")
  eq(status().watchdog, false)
end

T["watchdog"]["a raising parser fails once and releases"] = function()
  set_lines({ "[1]" })
  child.lua("use_parser('raise')")
  local codes = child.lua("request(); await(1); vim.wait(400); return codes()")
  eq(codes, { "no_parser" })
  local held = status()
  eq({ held.parsing, held.watchdog, held.suspended }, { false, false, nil })
end

-- Teardown -----------------------------------------------------------------

T["teardown"] = MiniTest.new_set()

---Leave a target and an index request waiting on a silent parse, run
---`trigger` in the child, and return what the requests and owner hold.
local function teardown_after(trigger)
  set_lines({ '{"a": [1]}' })
  child.lua("use_parser('silent')")
  local timers = child.lua_get("active_timers()")
  child.lua("_G.buf = vim.api.nvim_get_current_buf()")
  child.lua("request(); request_index()")
  eq(status().watchdog, true)
  child.lua(trigger)
  -- Past the watchdog: nothing else may complete or fire.
  child.lua("await(2, 2000); vim.wait(400)")
  return {
    codes = child.lua_get("codes()"),
    held = child.lua_get("json.status(_G.buf)"),
    timers = child.lua_get("active_timers()") <= timers,
  }
end

local RELEASED = { codes = { "stale", "stale" }, held = vim.NIL, timers = true }

T["teardown"]["unloading the buffer releases everything"] = function()
  eq(
    teardown_after([[
      vim.cmd("enew")
      vim.api.nvim_buf_delete(_G.buf, { unload = true, force = true })
    ]]),
    RELEASED
  )
end

T["teardown"]["wiping out the buffer releases everything"] = function()
  eq(
    teardown_after([[
      vim.cmd("enew")
      vim.api.nvim_buf_delete(_G.buf, { force = true })
    ]]),
    RELEASED
  )
end

T["teardown"]["changing the filetype releases everything"] = function()
  eq(teardown_after("vim.bo.filetype = 'text'"), RELEASED)
end

T["teardown"]["leaving the eligible state releases everything"] = function()
  local result = teardown_after([[
    local eligibility = require("iara.core.eligibility")
    eligibility.setup({})
    vim.api.nvim_buf_set_lines(0, 0, 0, true, { ("x"):rep(12000) })
    eligibility.recheck(0)
    vim.wait(2000, function()
      return eligibility.check(0).state ~= "eligible"
    end, 5)
  ]])
  eq(result, RELEASED)
end

T["teardown"]["cancelling every request releases the watchdog"] = function()
  set_lines({ "[1]" })
  child.lua("use_parser('silent')")
  local timers = child.lua_get("active_timers()")
  child.lua("request(); request_index()")
  child.lua("_G.h = request(); _G.i = request_index()")
  child.lua("h:cancel(); i:cancel(); vim.wait(400)")
  -- The first pair was superseded, the second cancelled; no watchdog
  -- fired and the buffer is not suspended.
  eq(child.lua_get("codes()"), { "stale", "cancelled", "stale", "cancelled" })
  local held = status()
  eq({ held.parsing, held.watchdog, held.suspended }, { false, false, nil })
  eq(child.lua_get("active_timers()") <= timers, true)
end

-- Caps ---------------------------------------------------------------------

T["caps"] = MiniTest.new_set()

---JSON key literal whose raw text, quotes included, is `bytes` long.
local function key(bytes, fill)
  return '"' .. (fill or "k"):rep(bytes - 2) .. '"'
end

local function probe(row, col)
  return child.lua(
    [[
    local row, col = ...
    local out
    json.target_at(0, row, col, function(target, err)
      out = err and { err = err.code } or {
        path = require("iara.features.structured.path").render(target)
          or vim.NIL,
        complete = target.certainty.complete,
        decoded = target.certainty.decoded,
        unique = target.certainty.unique,
        segments = #target.segments,
      }
    end)
    vim.wait(10000, function() return out ~= nil end, 5)
    return out
  ]],
    { row, col }
  )
end

local function index()
  return child.lua([[
    local out
    json.index(0, function(result) out = result end)
    vim.wait(30000, function() return out ~= nil end, 5)
    local max_segments, decoded = 0, true
    for _, target in ipairs(out.targets) do
      max_segments = math.max(max_segments, #target.segments)
      decoded = decoded and target.certainty.decoded
    end
    return {
      state = out.state,
      count = #out.targets,
      max_segments = max_segments,
      decoded = decoded,
      unique = out.targets[1] and out.targets[1].certainty.unique,
    }
  ]])
end

T["caps"]["raw keys over 4 KiB are source only"] = function()
  set_lines({
    "{",
    "  " .. key(4096) .. ": 1,",
    "  " .. key(4097) .. ": 2",
    "}",
  })
  local at_cap = probe(1, 2)
  eq({ at_cap.decoded, at_cap.complete }, { true, true })
  local over = probe(2, 2)
  eq({ over.decoded, over.path }, { false, vim.NIL })
  eq(index().decoded, false)
end

---One line per nested object whose keys decode to `total` bytes in all:
---keys of 4,094 bytes (raw 4,096, the raw cap), then the remainder.
---@return string[] lines, integer depth
local function nested_keys(total)
  local lines = {}
  while total > 0 do
    local bytes = math.min(total, 4094)
    total = total - bytes
    lines[#lines + 1] = "{" .. key(bytes + 2, string.char(97 + #lines)) .. ":"
  end
  return lines, #lines
end

---Nested objects whose path to the value 1 has `total` decoded bytes.
local function path_of_bytes(total)
  local lines, depth = nested_keys(total)
  lines[#lines + 1] = "1" .. ("}"):rep(depth)
  return lines, depth
end

T["caps"]["decoded paths over 16 KiB are incomplete"] = function()
  local lines, depth = path_of_bytes(16384)
  set_lines(lines)
  local at_cap = probe(depth, 0)
  eq({ at_cap.complete, at_cap.segments }, { true, depth })
  eq(type(at_cap.path), "string")
  lines, depth = path_of_bytes(16385)
  set_lines(lines)
  local over = probe(depth, 0)
  eq({ over.complete, over.path }, { false, vim.NIL })
  local indexed = index()
  eq({ indexed.state, indexed.count }, { "partial", 4 })
end

T["caps"]["index stops descending at 128 segments"] = function()
  child.cmd("edit " .. FIXTURES .. "deep_nesting.json")
  local result = index()
  eq(result.state, "partial")
  eq(result.max_segments <= 128, true)
  eq(result.unique, "unverified")
end

---Root object with `count` pairs; the cursor goes to the last key.
local function wide_object(count)
  local lines = { "{" }
  for i = 1, count do
    lines[#lines + 1] = ('"k%d": %d%s'):format(i, i, i < count and "," or "")
  end
  lines[#lines + 1] = "}"
  set_lines(lines)
  return probe(count, 1)
end

T["caps"]["key uniqueness is verified up to 2,048 sibling visits"] = function()
  -- 2,047 siblings plus the root's own identity: exactly 2,048 visits.
  local at_cap = wide_object(2047)
  eq({ at_cap.unique, at_cap.complete }, { "yes", true })
  -- Over the cap only uniqueness is unknown: the climb to the root is
  -- paid first, so the path stays exact and renders (with disclosure).
  local over = wide_object(2049)
  eq({ over.unique, over.complete }, { "unverified", true })
  eq(over.path, 'doc[1]::$["k2049"]')
end

T["caps"]["index retains at most 8 MiB of accounted payload"] = function()
  -- Each key below a 16,000-byte prefix costs about 16 KiB, so the
  -- payload cap is reached long before the 10,000 entry cap.
  local lines, depth = nested_keys(16000)
  lines[#lines] = lines[#lines] .. "{"
  for i = 1, 600 do
    lines[#lines + 1] = ('"p%d": %d,'):format(i, i)
  end
  lines[#lines + 1] = '"last": 0' .. ("}"):rep(depth + 1)
  set_lines(lines)
  local result = index()
  eq(result.state, "partial")
  eq(result.count > 400 and result.count < 600, true)
  eq(result.unique, "unverified")
end

T["caps"]["index keeps 10,000 entries, not one more"] = function()
  local function keys(count)
    local lines = { "{" }
    for i = 1, count do
      lines[#lines + 1] = ('"k%d": 0%s'):format(i, i < count and "," or "")
    end
    lines[#lines + 1] = "}"
    set_lines(lines)
    return index()
  end
  local at_cap = keys(10000)
  eq({ at_cap.state, at_cap.count }, { "complete", 10000 })
  local over = keys(10001)
  eq({ over.state, over.count }, { "partial", 10000 })
end

return T
