local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

local MIB = 1048576

---Start the module in the child and record every change event.
local function start_module()
  child.lua([[
    _G.events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "IaraEligibilityChanged",
      callback = function(args) table.insert(_G.events, args.data) end,
    })
    require("iara.core.eligibility").setup({})
  ]])
end

local function check(bufnr)
  return child.lua("return require('iara.core.eligibility').check(...)", {
    bufnr or 0,
  })
end

local function statusline()
  return child.lua("return require('iara.core.eligibility').statusline()")
end

---Write a file of `line_count` lines of `width` bytes each and edit it.
local function edit_file(line_count, width)
  local path = helpers.temp_dir() .. "/fixture.txt"
  local line = ("x"):rep(width)
  local lines = {}
  for i = 1, line_count do
    lines[i] = line
  end
  helpers.write_file(path, table.concat(lines, "\n") .. "\n")
  child.cmd("edit " .. path)
  return path
end

---Wait in the child until an event reaches `state`; return that event.
local function wait_for_event(state)
  return child.lua(
    [[
    local state = ...
    local found = nil
    vim.wait(5000, function()
      for _, event in ipairs(_G.events) do
        if event.state == state then found = event end
      end
      return found ~= nil
    end)
    return found
  ]],
    { state }
  )
end

local function clear_events()
  child.lua("_G.events = {}")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
      start_module()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local thresholds = MiniTest.new_set()
T["thresholds"] = thresholds

thresholds["a small file is eligible with an empty statusline"] = function()
  edit_file(100, 80)
  local result = check()
  eq(result.state, "eligible")
  eq(result.reason, nil)
  eq(result.bytes, 8100)
  eq(statusline(), "")
end

thresholds["a file above 1 MiB is conservative by size"] = function()
  edit_file(32 * 1024 + 1, 63)
  local result = check()
  eq(result.state, "conservative")
  eq(result.reason, "size")
  eq(result.bytes, 2 * MIB + 64)
  eq(result.message, "large file (2.0 MiB > 1 MiB)")
  match(statusline(), "^conservative: large file")
end

thresholds["exactly 1 MiB of text stays eligible"] = function()
  -- 16,384 lines of 63 bytes plus a newline each.
  edit_file(16 * 1024, 63)
  local result = check()
  eq(result.bytes, MIB)
  eq(result.state, "eligible")
end

thresholds["a minified one-line file is conservative"] = function()
  edit_file(1, 200000)
  local result = check()
  eq(result.state, "conservative")
  eq(result.reason, "long_line")
  eq(result.message, "long line 1 (200000 >= 10000 bytes)")
end

thresholds["a line of 10,000 bytes is long and 9,999 is not"] = function()
  edit_file(3, 9999)
  eq(check().state, "eligible")
  child.lua("vim.api.nvim_buf_set_lines(0, 1, 2, true, { ('y'):rep(10000) })")
  local result = check()
  eq(result.state, "conservative")
  eq(result.message, "long line 2 (10000 >= 10000 bytes)")
end

thresholds["an invalid buffer is unknown and suspended"] = function()
  local result = check(9999)
  eq(result.state, "unknown")
  eq(result.reason, "invalid")
  local eligible = child.lua([[
    return require("iara.core.eligibility").is_eligible(9999)
  ]])
  eq(eligible, false)
end

thresholds["a non-numeric buffer handle is a programmer error"] = function()
  local result = child.lua([[
    local ok, problem =
      pcall(require("iara.core.eligibility").check, "current")
    return { ok = ok, problem = problem }
  ]])
  eq(result.ok, false)
  match(result.problem, "bufnr must be an integer")
end

local budget = MiniTest.new_set()
T["budgeted checks"] = budget

budget["many lines are unknown until the budgeted scan finishes"] = function()
  edit_file(500000, 1)
  local first = child.lua([[
    local eligibility = require("iara.core.eligibility")
    eligibility.recheck(0)
    _G.events = {}
    return {
      result = eligibility.check(0),
      eligible = eligibility.is_eligible(0),
      statusline = eligibility.statusline(0),
    }
  ]])
  eq(first.result.state, "unknown")
  eq(first.result.reason, "pending")
  eq(first.eligible, false)
  eq(first.statusline, "suspended: checking line lengths")
  local event = wait_for_event("eligible")
  eq(event.previous, "unknown")
  eq(check().state, "eligible")
end

budget["a long line at the end of many lines is found"] = function()
  edit_file(400000, 1)
  child.lua([[
    vim.api.nvim_buf_set_lines(0, -1, -1, true, { ("z"):rep(12000) })
  ]])
  local event = wait_for_event("conservative")
  eq(event.reason, "long_line")
  eq(check().message, "long line 400001 (12000 >= 10000 bytes)")
end

local changes = MiniTest.new_set()
T["changes"] = changes

changes["growing past 1 MiB turns conservative and notifies"] = function()
  edit_file(1000, 99)
  eq(check().state, "eligible")
  clear_events()
  child.lua([[
    local lines = {}
    for i = 1, 11000 do lines[i] = ("g"):rep(99) end
    vim.api.nvim_buf_set_lines(0, -1, -1, true, lines)
  ]])
  local event = wait_for_event("conservative")
  eq(event.previous, "eligible")
  eq(event.reason, "size")
  eq(event.bufnr, child.lua("return vim.api.nvim_get_current_buf()"))
end

changes["pasting a long line turns conservative"] = function()
  edit_file(50, 40)
  eq(check().state, "eligible")
  clear_events()
  child.lua([[
    vim.fn.setreg("a", ("p"):rep(15000), "l")
    vim.cmd('normal! 10G"ap')
  ]])
  local event = wait_for_event("conservative")
  eq(event.reason, "long_line")
  eq(check().message, "long line 11 (15000 >= 10000 bytes)")
end

changes["removing the long line makes the buffer eligible again"] = function()
  edit_file(1, 30000)
  eq(check().state, "conservative")
  clear_events()
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 1, true, { 'short' })")
  local event = wait_for_event("eligible")
  eq(event.previous, "conservative")
  eq(statusline(), "")
end

changes["reloading a file that grew on disk rechecks it"] = function()
  local path = edit_file(10, 10)
  eq(check().state, "eligible")
  clear_events()
  helpers.write_file(path, ("r"):rep(2 * MIB) .. "\n")
  child.cmd("edit!")
  local event = wait_for_event("conservative")
  eq(event.reason, "size")
end

changes["listeners see the new state when the event fires"] = function()
  edit_file(5, 5)
  check()
  local seen = child.lua([[
    local seen = nil
    vim.api.nvim_create_autocmd("User", {
      pattern = "IaraEligibilityChanged",
      once = true,
      callback = function(args)
        seen = require("iara.core.eligibility").check(args.data.bufnr).state
      end,
    })
    vim.api.nvim_buf_set_lines(0, 0, 1, true, { ("q"):rep(20000) })
    vim.wait(5000, function() return seen ~= nil end)
    return seen
  ]])
  eq(seen, "conservative")
end

---Start Tree-sitter highlighting (a real subscriber) and a minimal
---feature that follows the contract: it suspends on every event whose
---buffer is not eligible and records each decision.
local function start_consumers()
  child.lua([[
    vim.cmd("filetype on")
    require("iara.core.treesitter").setup()
    _G.decisions = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "IaraEligibilityChanged",
      callback = function(args)
        local eligibility = require("iara.core.eligibility")
        local bufnr = args.data.bufnr
        -- Tree-sitter's handler was registered first and has run.
        table.insert(_G.decisions, {
          state = args.data.state,
          running = eligibility.is_eligible(bufnr),
          highlighted = vim.treesitter.highlighter.active[bufnr] ~= nil,
        })
      end,
    })
  ]])
end

---Edit a Lua file of `line_count` short lines.
local function edit_lua(line_count)
  local path = helpers.temp_dir() .. "/fixture.lua"
  local lines = {}
  for i = 1, line_count do
    lines[i] = ("local value_%d = %d"):format(i, i)
  end
  helpers.write_file(path, table.concat(lines, "\n") .. "\n")
  child.cmd("edit " .. path)
  return path
end

local IS_HIGHLIGHTED = [[
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.treesitter.highlighter.active[bufnr] ~= nil
]]

local function highlighted()
  return child.lua(IS_HIGHLIGHTED)
end

---Wait in the child until highlighting is `active`; return whether it is.
local function wait_highlighted(active)
  return child.lua(
    [[
    local active, probe = ...
    local is_highlighted = loadstring(probe)
    vim.wait(5000, function()
      return is_highlighted() == active
    end)
    return is_highlighted()
  ]],
    { active, IS_HIGHLIGHTED }
  )
end

---The consumer's latest decision on an event in `state`, after waiting
---for one.
local function wait_decision(state)
  return child.lua(
    [[
    local state = ...
    local found = nil
    vim.wait(5000, function()
      for _, decision in ipairs(_G.decisions) do
        if decision.state == state then found = decision end
      end
      return found ~= nil
    end)
    return found
  ]],
    { state }
  )
end

local suspension = MiniTest.new_set({
  hooks = {
    pre_case = start_consumers,
  },
})
T["feature suspension"] = suspension

suspension["growing past 1 MiB suspends highlighting"] = function()
  edit_lua(200)
  eq(highlighted(), true)
  child.lua([[
    local lines = {}
    for i = 1, 11000 do lines[i] = ("-- grown "):rep(11) end
    vim.api.nvim_buf_set_lines(0, -1, -1, true, lines)
  ]])
  eq(
    wait_decision("conservative"),
    { state = "conservative", running = false, highlighted = false }
  )
  eq(wait_highlighted(false), false)
  match(statusline(), "^conservative: large file")
end

suspension["undoing the growth makes the buffer eligible again"] = function()
  edit_lua(200)
  child.lua([[
    local lines = {}
    for i = 1, 11000 do lines[i] = ("-- grown "):rep(11) end
    vim.api.nvim_buf_set_lines(0, -1, -1, true, lines)
  ]])
  wait_decision("conservative")
  child.cmd("silent undo")
  eq(
    wait_decision("eligible"),
    { state = "eligible", running = true, highlighted = true }
  )
  eq(wait_highlighted(true), true)
  eq(statusline(), "")
end

suspension["a bracketed paste of a long line suspends"] = function()
  edit_lua(20)
  eq(highlighted(), true)
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.paste({ "", ("p"):rep(12000) }, -1)
  ]])
  eq(wait_decision("conservative").running, false)
  eq(check().reason, "long_line")
  eq(wait_highlighted(false), false)
end

suspension["a register paste past 1 MiB suspends"] = function()
  edit_lua(20)
  child.lua([[
    local lines = {}
    for i = 1, 12000 do lines[i] = ("r"):rep(99) end
    vim.fn.setreg("a", lines, "l")
    vim.cmd('normal! 3G"ap')
  ]])
  eq(wait_decision("conservative").running, false)
  eq(check().reason, "size")
  eq(wait_highlighted(false), false)
end

suspension["a file reloaded by checktime is rechecked"] = function()
  local path = edit_lua(20)
  eq(highlighted(), true)
  child.lua("vim.o.autoread = true")
  -- A different size and mtime make checktime see the external change.
  helpers.write_file(path, ("-- minified "):rep(2000) .. "\n")
  vim.uv.fs_utime(path, os.time() + 5, os.time() + 5)
  child.cmd("checktime")
  eq(wait_decision("conservative").running, false)
  eq(check().reason, "long_line")
  eq(wait_highlighted(false), false)
end

suspension["unknown eligibility suspends until proven eligible"] = function()
  edit_lua(20)
  eq(highlighted(), true)
  -- A million empty lines stay below 1 MiB but need four budgeted
  -- slices, so the state is still unknown when the event is handled.
  local during = child.lua([[
    local lines = {}
    for i = 1, 1000000 do lines[i] = "" end
    vim.api.nvim_buf_set_lines(0, -1, -1, true, lines)
    local eligibility = require("iara.core.eligibility")
    return {
      state = eligibility.check(0).state,
      eligible = eligibility.is_eligible(0),
    }
  ]])
  eq(during, { state = "unknown", eligible = false })
  eq(
    wait_decision("unknown"),
    { state = "unknown", running = false, highlighted = false }
  )
  eq(
    wait_decision("eligible"),
    { state = "eligible", running = true, highlighted = true }
  )
end

return T
