local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = nil

local FIXTURES = helpers.iara_dir .. "/tests/fixtures/structured/"
local PARSER_DIR = helpers.iara_dir .. "/.tools/treesitter"
local HAS_PARSER = vim.uv.fs_stat(PARSER_DIR .. "/parser/json.so") ~= nil

-- Child-side helpers: every wait happens inside the child, so callbacks
-- run on its main loop exactly as in the editor.
local CHILD_HELPERS = [[
  local json = require("iara.features.structured.json")
  local path = require("iara.features.structured.path")

  _G.find = function(needle, nth)
    local seen = 0
    for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, true)) do
      local from = 1
      while true do
        local col = line:find(needle, from, true)
        if not col then break end
        seen = seen + 1
        if seen == (nth or 1) then return row - 1, col - 1 end
        from = col + 1
      end
    end
    error("text not found: " .. needle)
  end

  _G.await_target = function(row, col)
    local results = {}
    json.target_at(0, row, col, function(target, err)
      results[#results + 1] = { target = target, err = err }
    end)
    vim.wait(10000, function() return #results > 0 end, 5)
    return results[1]
  end

  _G.probe = function(needle, nth, offset)
    local row, col = _G.find(needle, nth)
    local result = _G.await_target(row, col + (offset or 0))
    if not result.target then return { err = result.err.code } end
    local rendered, refusal = path.render(result.target)
    return {
      path = rendered,
      refusal = refusal and refusal.code,
      target = result.target,
      breadcrumb = path.breadcrumb(result.target),
    }
  end

  _G.await_index = function()
    local results = {}
    json.index(0, function(result) results[#results + 1] = result end)
    vim.wait(20000, function() return #results > 0 end, 5)
    local result = results[1]
    local rendered = {}
    for _, target in ipairs(result.targets) do
      rendered[#rendered + 1] = path.render(target) or false
    end
    return {
      state = result.state,
      count = #result.targets,
      paths = rendered,
      unique = vim.tbl_map(function(t) return t.certainty.unique end,
        result.targets),
      error = result.error and result.error.code,
    }
  end
]]

local function start_child(with_parser)
  child = helpers.new_child()
  if with_parser then
    child.lua("vim.opt.runtimepath:prepend(...)", { PARSER_DIR })
  end
  child.lua(CHILD_HELPERS)
end

local function edit(name)
  child.cmd("edit " .. FIXTURES .. name)
end

---Render the path under the first character of the `nth` `needle`.
local function path_at(needle, nth, offset)
  return child.lua("return _G.probe(...)", { needle, nth or 1, offset or 0 })
end

local function expect_path(needle, expected, nth)
  local result = path_at(needle, nth)
  eq(result.err, nil)
  eq(result.path, expected)
  return result
end

local function expect_refusal(needle, code, nth)
  local result = path_at(needle, nth)
  eq(result.err, nil)
  eq(result.path, nil)
  eq(result.refusal, code)
  return result
end

local function index()
  return child.lua("return _G.await_index()")
end

local function stop_child()
  if child then
    child.stop()
    child = nil
  end
end

---Hooks for cases that need the pinned JSON parser.
local PARSED = {
  hooks = {
    pre_case = function()
      if not HAS_PARSER then
        MiniTest.skip("JSON parser missing; run scripts/parsers.sh")
      end
      start_child(true)
    end,
    post_case = stop_child,
  },
}

local T = MiniTest.new_set()

-- Fixture paths --------------------------------------------------------------

local fixtures = MiniTest.new_set(PARSED)
T["fixture paths"] = fixtures

fixtures["root object distinguishes indexes from numeric keys"] = function()
  edit("root_object.json")
  expect_path('"tenth"', 'doc[1]::$["list"][10]["tenth"]')
  expect_path("9,", 'doc[1]::$["list"][9]')
  expect_path("0,", 'doc[1]::$["list"][0]')
  expect_path('"0"', 'doc[1]::$["0"]')
  expect_path('"deep"', 'doc[1]::$["nested"][0][0]["deep"]')
  expect_path("8080", 'doc[1]::$["server"]["port"]')
  expect_path("{}", 'doc[1]::$["empty_object"]')
end

fixtures["records exact key and value byte ranges"] = function()
  edit("root_object.json")
  local target = path_at('"port"').target
  eq(target.key_range, { 3, 4, 3, 10 })
  eq(target.value_range, { 3, 12, 3, 16 })
  eq(target.document, 1)
  eq(target.bufnr, child.api.nvim_get_current_buf())
  eq(target.changedtick, child.api.nvim_buf_get_changedtick(0))
end

fixtures["root array paths start with an index"] = function()
  edit("root_array.json")
  expect_path('"b"', 'doc[1]::$[1]["tags"][1]')
  expect_path("10", "doc[1]::$[2][0]")
  expect_path('"scalar element"', "doc[1]::$[3]")
  expect_path('"name"', 'doc[1]::$[0]["name"]')
end

fixtures["root scalar has the root path"] = function()
  edit("root_scalar.json")
  local result = expect_path("42", "doc[1]::$")
  eq(result.target.segments, {})
end

fixtures["literal keys keep dots, brackets, quotes, and escapes"] = function()
  edit("literal_keys.json")
  expect_path('"server.port"', 'doc[1]::$["server.port"]')
  expect_path('"port"', 'doc[1]::$["server"]["port"]')
  expect_path('"[0]"', 'doc[1]::$["[0]"]')
  expect_path('"a[1].b"', 'doc[1]::$["a[1].b"]')
  expect_path('"": "empty key"', 'doc[1]::$[""]')
  expect_path('"say', 'doc[1]::$["say \\"hi\\""]')
  expect_path('"back', 'doc[1]::$["back\\\\slash"]')
  expect_path('"slash', 'doc[1]::$["slash/escaped"]')
  expect_path('"tab', 'doc[1]::$["tab\\there"]')
  expect_path('"nul', 'doc[1]::$["nul\\u0000byte"]')
  expect_path('"surrogate pair"', 'doc[1]::$["😀"]')
  expect_path('"escaped e-acute"', 'doc[1]::$["café"]')
  expect_path('"empty keys at', 'doc[1]::$["nested"][""][""]')
end

fixtures["byte columns stay exact after a multibyte prefix"] = function()
  edit("literal_keys.json")
  local needle = '"multibyte prefix'
  local result = path_at(needle)
  local row, col = unpack(child.lua("return { _G.find(...) }", { needle }))
  local line = child.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
  local key_start = line:find('{"', 1, true)
  eq(result.target.value_range[1], row)
  eq(result.target.value_range[2], col)
  eq(result.target.key_range, { row, key_start, row, col - 2 })
  eq(#result.target.segments, 2)
end

fixtures["undecodable keys are source only"] = function()
  edit("invalid_strings.json")
  expect_refusal('"lone \\ud83d', "source_only")
  expect_refusal('"lone \\ude00', "source_only")
  expect_refusal('"bad', "source_only")
  expect_refusal('"raw', "source_only")
  expect_refusal('"short', "source_only")
  local valid = expect_path('"valid"', 'doc[1]::$["valid"]')
  eq(valid.target.certainty.decoded, true)
end

fixtures["duplicate keys and their descendants are ambiguous"] = function()
  edit("duplicates.json")
  expect_refusal('"name"', "ambiguous", 1)
  expect_refusal('"name"', "ambiguous", 2)
  expect_refusal('"b"', "ambiguous", 1)
  expect_refusal('"b"', "ambiguous", 2)
  local unique = expect_path('"b"', 'doc[1]::$["unique"]["a"]["b"]', 3)
  eq(unique.target.certainty.unique, "yes")
  expect_refusal('"café"', "ambiguous", 1)
  expect_refusal('"café"', "ambiguous", 2)
  -- "e" followed by U+0301: never normalized to the precomposed form.
  expect_path('"decomposed', 'doc[1]::$["e\204\129"]')
end

fixtures["several top-level values get recovery roots"] = function()
  edit("multiple_values.json")
  expect_path('"a"', 'doc[1]/root[1]::$["a"]', 1)
  expect_path('"a"', 'doc[1]/root[2]::$["a"]', 2)
  expect_path("3", "doc[1]/root[3]::$[0]")
end

fixtures["empty recovery roots stay distinct"] = function()
  edit("empty_multiple_values.json")
  expect_path("{}", "doc[1]/root[1]::$", 1)
  expect_path("{}", "doc[1]/root[2]::$", 2)
end

fixtures["comments never count as elements"] = function()
  edit("comments.json")
  expect_path('"second"', 'doc[1]::$["items"][1]')
  expect_path("/* comment between", 'doc[1]::$["items"]')
  expect_path("true", 'doc[1]::$["after"]')
end

fixtures["intact entries survive incomplete edits"] = function()
  edit("incomplete_unterminated.json")
  expect_path('"x"', 'doc[1]::$["intact"]["x"]')
  edit("incomplete_missing_value.json")
  expect_path("2]", 'doc[1]::$["intact"][1]')
  expect_refusal('"missing"', "incomplete")
  edit("error_elsewhere.json")
  expect_path('"to"', 'doc[1]::$["good"]["path"]["to"]')
  expect_path('"k"', 'doc[1]::$["also_good"]["k"]')
  expect_refusal("3", "incomplete")
end

fixtures["a broken key never decodes"] = function()
  edit("incomplete_key.json")
  expect_path('"child"', 'doc[1]::$["ok"]["child"]', 1)
  local broken = path_at('"child"', 2)
  eq(broken.path, nil)
  eq(broken.target.certainty.complete, false)
  eq(broken.target.certainty.decoded, false)
end

fixtures["unclosed containers never invent paths"] = function()
  edit("incomplete_unclosed.json")
  for _, needle in ipairs({ '"inner"', "2," }) do
    local result = path_at(needle)
    if result.target then
      eq(result.path, nil)
      eq(result.refusal, "incomplete")
      eq(result.target.certainty.complete, false)
    else
      eq(result.err, "no_target")
    end
  end
end

fixtures["paths over the segment cap are incomplete"] = function()
  edit("deep_nesting.json")
  local result = expect_refusal('"bottom"', "incomplete")
  eq(result.target.document, nil)
  eq(#result.target.segments, 128)
  eq(result.target.segments[128], { kind = "index", value = 0 })
end

fixtures["indexes past the sibling cap are never guessed"] = function()
  edit("wide_array.json")
  expect_path("2047,", "doc[1]::$[2047]")
  local last = expect_refusal("2099", "incomplete")
  eq(last.target.segments, {})
  eq(last.target.value_range, { 2100, 2, 2100, 6 })
end

fixtures["positions outside any value have no target"] = function()
  edit("comments.json")
  eq(path_at("// Line comment").err, "no_target")
end

fixtures["extraction reads unsaved edits"] = function()
  edit("root_object.json")
  child.api.nvim_buf_set_lines(0, 1, 1, true, { '  "added": {"k.1": 1},' })
  eq(child.bo.modified, true)
  expect_path('"k.1"', 'doc[1]::$["added"]["k.1"]')
  expect_path("8080", 'doc[1]::$["server"]["port"]')
  child.api.nvim_buf_set_lines(0, 1, 2, true, { '  "added": 1, "added": 2,' })
  expect_refusal('"added"', "ambiguous")
end

fixtures["works in an unnamed buffer"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, true, { '{"a": [true]}' })
  expect_path("true", 'doc[1]::$["a"][0]')
end

-- Lifecycle ------------------------------------------------------------------

local lifecycle = MiniTest.new_set(PARSED)
T["lifecycle"] = lifecycle

lifecycle["never completes synchronously"] = function()
  edit("root_object.json")
  local result = child.lua([[
    local calls, sync = 0, true
    require("iara.features.structured.json").target_at(0, 1, 3, function()
      calls = calls + 1
    end)
    local during = calls
    vim.wait(5000, function() return calls > 0 end, 5)
    vim.wait(50)
    return { during = during, calls = calls }
  ]])
  eq(result, { during = 0, calls = 1 })
end

lifecycle["an edit before publication completes as stale"] = function()
  edit("root_object.json")
  local code = child.lua([[
    local result
    require("iara.features.structured.json").target_at(0, 1, 3,
      function(target, err) result = { target = target, err = err } end)
    vim.api.nvim_buf_set_lines(0, 0, 0, true, { "" })
    vim.wait(5000, function() return result ~= nil end, 5)
    return { result.target == nil, result.err.code }
  ]])
  eq(code, { true, "stale" })
end

lifecycle["only the latest intent is published"] = function()
  edit("root_object.json")
  local results = child.lua([[
    local json = require("iara.features.structured.json")
    local results = {}
    for i, row in ipairs({ 2, 3 }) do
      json.target_at(0, row, 6, function(target, err)
        results[i] = target and #target.segments or err.code
      end)
    end
    vim.wait(5000, function() return results[1] and results[2] end, 5)
    return results
  ]])
  eq(results, { "stale", 2 })
end

lifecycle["cancel completes once as stale"] = function()
  edit("root_object.json")
  local results = child.lua([[
    local results = {}
    local handle = require("iara.features.structured.json").target_at(
      0, 1, 3, function(_, err) results[#results + 1] = err.code end)
    handle:cancel()
    handle:cancel()
    vim.wait(300)
    return results
  ]])
  eq(results, { "stale" })
end

---Replace the parser factory with one whose parse never calls back.
local function install_silent_parser()
  child.lua([[
    _G.parse_callbacks = {}
    vim.treesitter.get_parser = function()
      return {
        parse = function(_, _, callback)
          table.insert(_G.parse_callbacks, callback)
        end,
        is_valid = function() return true end,
      }
    end
  ]])
end

lifecycle["watchdog abandons a parse that never completes"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, true, { "[1]" })
  install_silent_parser()
  local result = child.lua([[
    local results = {}
    local started = vim.uv.hrtime()
    local elapsed
    require("iara.features.structured.json").target_at(0, 0, 1,
      function(_, err)
        elapsed = (vim.uv.hrtime() - started) / 1e6
        results[#results + 1] = err.code
      end)
    vim.wait(10000, function() return #results > 0 end, 5)
    _G.parse_callbacks[1](nil, {})
    vim.wait(100)
    return { results = results, elapsed = elapsed }
  ]])
  eq(result.results, { "watchdog" })
  eq(result.elapsed >= 240, true)
end

lifecycle["wiping the buffer releases a pending parse"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, true, { "[1]" })
  install_silent_parser()
  local results = child.lua([[
    local results = {}
    local bufnr = vim.api.nvim_get_current_buf()
    require("iara.features.structured.json").target_at(0, 0, 1,
      function(_, err) results[#results + 1] = err.code end)
    vim.cmd("enew")
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.wait(600)
    return results
  ]])
  eq(results, { "stale" })
end

lifecycle["changing the filetype releases a pending parse"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, true, { "[1]" })
  install_silent_parser()
  local results = child.lua([[
    local results = {}
    require("iara.features.structured.json").target_at(0, 0, 1,
      function(_, err) results[#results + 1] = err.code end)
    vim.bo.filetype = "text"
    vim.wait(600)
    return results
  ]])
  eq(results, { "stale" })
end

lifecycle["large buffers are refused before parsing"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, true, {
    '{"a": "' .. ("x"):rep(10000) .. '"}',
  })
  eq(path_at('"a"').err, "ineligible")
end

lifecycle["rejects invalid arguments"] = function()
  local ok = child.lua([[
    local json = require("iara.features.structured.json")
    local function raises(fn, ...)
      return not pcall(fn, ...)
    end
    return {
      raises(json.target_at, 9999, 0, 0, function() end),
      raises(json.target_at, 0, -1, 0, function() end),
      raises(json.index, 0, nil),
    }
  ]])
  eq(ok, { true, true, true })
end

-- Index ----------------------------------------------------------------------

local index_set = MiniTest.new_set(PARSED)
T["index"] = index_set

index_set["lists every key target in source order"] = function()
  edit("root_object.json")
  local result = index()
  eq(result.state, "complete")
  eq(result.paths, {
    'doc[1]::$["server"]',
    'doc[1]::$["server"]["host"]',
    'doc[1]::$["server"]["port"]',
    'doc[1]::$["list"]',
    'doc[1]::$["list"][10]["tenth"]',
    'doc[1]::$["0"]',
    'doc[1]::$["empty_object"]',
    'doc[1]::$["empty_array"]',
    'doc[1]::$["nested"]',
    'doc[1]::$["nested"][0][0]["deep"]',
  })
end

index_set["marks duplicated ancestors ambiguous"] = function()
  edit("duplicates.json")
  local result = index()
  eq(result.state, "complete")
  eq(result.unique, {
    "no",
    "no",
    "no",
    "no",
    "no",
    "no",
    "yes",
    "yes",
    "yes",
    "no",
    "no",
    "yes",
  })
  eq(result.paths[9], 'doc[1]::$["unique"]["a"]["b"]')
end

index_set["keeps recovery roots apart"] = function()
  edit("multiple_values.json")
  eq(index().paths, { 'doc[1]/root[1]::$["a"]', 'doc[1]/root[2]::$["a"]' })
end

index_set["skips comments and keeps intact entries"] = function()
  edit("error_elsewhere.json")
  local result = index()
  eq(result.paths, {
    'doc[1]::$["good"]',
    'doc[1]::$["good"]["path"]',
    'doc[1]::$["good"]["path"]["to"]',
    'doc[1]::$["bad"]',
    'doc[1]::$["also_good"]',
    'doc[1]::$["also_good"]["k"]',
  })
end

index_set["stops at the entry cap with unverified uniqueness"] = function()
  local lines = { "{" }
  for i = 1, 10050 do
    lines[#lines + 1] = ('  "k%d": %d,'):format(i, i)
  end
  lines[#lines + 1] = '  "last": 0'
  lines[#lines + 1] = "}"
  child.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  local result = index()
  eq(result.state, "partial")
  eq(result.count, 10000)
  eq(result.paths[1], 'doc[1]::$["k1"]')
  eq(result.unique[1], "unverified")
end

index_set["an edit during indexing reports stale"] = function()
  edit("root_object.json")
  local result = child.lua([[
    local result
    require("iara.features.structured.json").index(0, function(r)
      result = r
    end)
    vim.api.nvim_buf_set_lines(0, 0, 0, true, { "" })
    vim.wait(5000, function() return result ~= nil end, 5)
    return { result.state, result.error.code }
  ]])
  eq(result, { "error", "stale" })
end

index_set["a newer index cancels the previous one"] = function()
  edit("root_object.json")
  local states = child.lua([[
    local json = require("iara.features.structured.json")
    local states = {}
    for i = 1, 2 do
      json.index(0, function(r) states[i] = r.state end)
    end
    vim.wait(5000, function() return states[1] and states[2] end, 5)
    return states
  ]])
  eq(states, { "cancelled", "complete" })
end

-- Missing parser -------------------------------------------------------------

T["without a JSON parser"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      start_child(false)
    end,
    post_case = stop_child,
  },
})

T["without a JSON parser"]["returns no_parser without raising"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, true, { '{"a": 1}' })
  eq(path_at('"a"').err, "no_parser")
  eq(index().error, "no_parser")
end

return T
