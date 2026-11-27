-- Structured UI (task D4) in a child Neovim with the pinned JSON parser
-- and snacks.nvim: breadcrumb, show and copy path, key search, and jumps
-- to recorded locations on the D2 fixtures.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local FIXTURES = helpers.iara_dir .. "/tests/fixtures/structured/"
local PARSER_DIR = helpers.iara_dir .. "/.tools/treesitter"
local HAS_PARSER = vim.uv.fs_stat(PARSER_DIR .. "/parser/json.so") ~= nil
local WAIT_MS = 20000

local snacks_path = nil

---Checkout of the locked snacks.nvim commit from the shared test mirror.
local function snacks_dir()
  if not snacks_path then
    local entry = lazy_fixture.release_entry("snacks.nvim")
    local mirror = lazy_fixture.url_format():format("folke/snacks.nvim")
    local dir = helpers.temp_dir() .. "/snacks.nvim"
    lazy_fixture.git({ "clone", "--quiet", mirror, dir })
    lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
    snacks_path = dir
  end
  return snacks_path
end

-- Helpers defined inside the child.
local CHILD_HELPERS = [[
_G.T = { notes = {}, prompts = {}, copied = {}, requests = 0 }
vim.g.mapleader = " "
vim.notify = function(message) table.insert(T.notes, message) end
vim.ui.select = function(items, opts, on_choice)
  table.insert(T.prompts, opts.prompt)
  on_choice(T.choose and items[1] or nil, T.choose and 1 or nil)
end
vim.g.clipboard = {
  name = "test",
  copy = { ["+"] = function(lines) T.copied["+"] = lines end,
           ["*"] = function(lines) T.copied["*"] = lines end },
  paste = { ["+"] = function() return T.copied["+"] or {} end,
            ["*"] = function() return T.copied["*"] or {} end },
}
local json = require("iara.features.structured.json")
local target_at = json.target_at
json.target_at = function(...)
  T.requests = T.requests + 1
  return target_at(...)
end
T.structured = require("iara.features.structured")
T.ui = require("iara.features.structured.ui")
T.structured.setup({
  features = { structured = _G.SETTINGS or {} },
  keymaps = {},
})

function T.cursor_to(needle, nth)
  local seen = 0
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, true)) do
    local from = 1
    while true do
      local col = line:find(needle, from, true)
      if not col then break end
      seen = seen + 1
      if seen == (nth or 1) then
        vim.api.nvim_win_set_cursor(0, { row, col - 1 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
        return
      end
      from = col + 1
    end
  end
  error("text not found: " .. needle)
end
function T.crumb()
  local shown = T.ui.breadcrumb()
  return shown and shown.text or vim.NIL
end
function T.picker()
  return _G.Snacks and Snacks.picker.get()[1] or nil
end
function T.items()
  local texts = {}
  for item in T.picker():iter() do
    table.insert(texts, item.text .. "  " .. T.ui.location_label(item.iara))
  end
  return texts
end
function T.list_lines()
  return vim.api.nvim_buf_get_lines(T.picker().list.win.buf, 0, -1, false)
end
function T.preview_lines()
  return vim.api.nvim_buf_get_lines(T.picker().preview.win.buf, 0, -1, false)
end
function T.go(text, nth)
  local seen = 0
  for item, index in T.picker():iter() do
    if item.text == text then
      seen = seen + 1
      if seen == (nth or 1) then return T.picker().list:view(index) end
    end
  end
  error("no row " .. text)
end
]]

local child = helpers.new_child()

local function wait_for(code, args)
  local ok = vim.wait(WAIT_MS, function()
    return child.lua_get(code, args) == true
  end, 20)
  if not ok then
    error("timed out waiting for: " .. code, 2)
  end
end

local function edit(name)
  child.cmd("edit " .. FIXTURES .. name)
end

local function cursor_to(needle, nth)
  child.lua("T.cursor_to(...)", { needle, nth or 1 })
end

local function crumb_is(text)
  wait_for("T.crumb() == ...", { text })
end

local function notes()
  return child.lua_get("T.notes")
end

local function wait_note(pattern)
  wait_for(
    [[(function(pattern)
    for _, note in ipairs(T.notes) do
      if note:find(pattern) then return true end
    end
    return false
  end)(...)]],
    { pattern }
  )
end

---Copy the path under `needle` and return the "+" register contents.
local function copy_at(needle, nth)
  cursor_to(needle, nth)
  child.lua("T.copied['+'] = nil; T.notes = {}; T.structured.copy_path()")
  wait_for("T.copied['+'] ~= nil or #T.notes > 0")
  local copied = child.lua_get("T.copied['+']")
  return copied ~= vim.NIL and copied[1] or nil
end

local function open_search()
  child.lua("T.structured.search_keys()")
  wait_for("T.picker() ~= nil and #T.items() > 0")
end

local function cursor()
  return child.api.nvim_win_get_cursor(0)
end

-- Times a breadcrumb text appears on screen.
local function on_screen(text)
  child.cmd("redraw")
  local screen = tostring(child.get_screenshot())
  local count = 0
  for _ in screen:gmatch(vim.pesc(text)) do
    count = count + 1
  end
  return count
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not HAS_PARSER then
        MiniTest.skip("JSON parser missing; run scripts/parsers.sh")
      end
      child.restart({ "-u", helpers.minimal_init })
      child.o.columns, child.o.lines = 140, 40
      child.lua("vim.opt.runtimepath:prepend(...)", { PARSER_DIR })
      child.lua("vim.opt.runtimepath:prepend(...)", { snacks_dir() })
      child.lua(CHILD_HELPERS)
    end,
    post_once = child.stop,
  },
})

-- Breadcrumb ---------------------------------------------------------------

T["breadcrumb"] = MiniTest.new_set()

T["breadcrumb"]["shows the path at the cursor line"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
  eq(child.lua_get("T.ui.breadcrumb().row"), 3)
  eq(on_screen("→ server.port"), 1)
  cursor_to('"tenth"')
  crumb_is("  → list[10].tenth")
  eq(on_screen("→ server.port"), 0)
end

T["breadcrumb"]["is drawn in the active window only"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
  -- The same buffer in two windows: only the current one shows it.
  child.cmd("split")
  crumb_is("  → server.port")
  eq(child.lua_get("T.ui.breadcrumb().win"), child.api.nvim_get_current_win())
  eq(on_screen("→ server.port"), 1)
end

T["breadcrumb"]["is cleared and replaced on focus change"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
  -- Cleared at once, before the new window's request is answered: one
  -- request, so the child cannot handle the answer in between.
  local cleared = child.lua(
    "vim.cmd.vsplit(...); return T.crumb()",
    { FIXTURES .. "root_array.json" }
  )
  eq(cleared, vim.NIL)
  cursor_to('"tags"')
  crumb_is("  → [1].tags")
  eq(on_screen("→ server.port"), 0)
  child.cmd("wincmd p")
  crumb_is("  → server.port")
  eq(on_screen("→ [1].tags"), 0)
  child.cmd("enew")
  eq(child.lua_get("T.crumb()"), vim.NIL)
end

T["breadcrumb"]["coalesces cursor moves into one request"] = function()
  edit("root_object.json")
  crumb_is("  → $")
  child.lua("T.requests = 0")
  -- Every move happens before the 25 ms timer can fire.
  child.lua([[
    for _, needle in ipairs({ '"host"', '"port"', '"list"', '"tenth"' }) do
      T.cursor_to(needle)
    end
  ]])
  crumb_is("  → list[10].tenth")
  eq(child.lua_get("T.requests"), 1)
  -- An unchanged cursor and text requests nothing.
  child.lua("vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })")
  vim.wait(100)
  eq(child.lua_get("T.requests"), 1)
end

T["breadcrumb"]["follows unsaved edits"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
  child.api.nvim_buf_set_lines(0, 3, 4, true, { '    "a.b": 8080' })
  child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })")
  crumb_is('  → server."a.b"')
end

---Restart the child with `settings` as `features.structured`.
local function restart_with(settings)
  child.restart({ "-u", helpers.minimal_init })
  child.lua("vim.opt.runtimepath:prepend(...)", { PARSER_DIR })
  child.lua("_G.SETTINGS = ...", { settings })
  child.lua(CHILD_HELPERS)
end

T["breadcrumb"]["can be disabled in the configuration"] = function()
  restart_with({ breadcrumb = false })
  edit("root_object.json")
  cursor_to('"port"')
  vim.wait(100)
  eq(child.lua_get("T.crumb()"), vim.NIL)
  child.lua("T.structured.toggle_breadcrumb()")
  crumb_is("  → server.port")
end

T["breadcrumb"]["reports an invalid setting and keeps the default"] = function()
  restart_with({ breadcrumb = "yes" })
  eq(notes(), {
    "Iara: features.structured.breadcrumb must be a boolean; using true",
  })
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
end

T["breadcrumb"]["can be toggled off and on"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
  child.lua("T.structured.toggle_breadcrumb()")
  eq(child.lua_get("T.crumb()"), vim.NIL)
  cursor_to('"host"')
  vim.wait(100)
  eq(child.lua_get("T.crumb()"), vim.NIL)
  eq(on_screen("→ server"), 0)
  child.lua("T.structured.toggle_breadcrumb()")
  crumb_is("  → server.host")
  eq(notes(), { "Iara: JSON breadcrumb off", "Iara: JSON breadcrumb on" })
end

T["breadcrumb"]["shows nothing in a conservative buffer"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  crumb_is("  → server.port")
  child.lua([[
    local long = '"' .. ("x"):rep(12000) .. '"'
    vim.api.nvim_buf_set_lines(0, 1, 1, true, { '  "long": ' .. long .. "," })
    require("iara.core.eligibility").recheck(0)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
  ]])
  wait_for("T.crumb() == vim.NIL")
  cursor_to('"host"')
  vim.wait(100)
  eq(child.lua_get("T.crumb()"), vim.NIL)
end

-- Show and copy ------------------------------------------------------------

T["copy"] = MiniTest.new_set()

T["copy"]["copies keys with dots, brackets, quotes, empty names"] = function()
  edit("literal_keys.json")
  eq(copy_at('"server.port"'), 'doc[1]::$["server.port"]')
  eq(copy_at('"port"'), 'doc[1]::$["server"]["port"]')
  eq(copy_at('"[0]"'), 'doc[1]::$["[0]"]')
  eq(copy_at('"a[1].b"'), 'doc[1]::$["a[1].b"]')
  eq(copy_at('"": "empty key"'), 'doc[1]::$[""]')
  eq(copy_at('"say'), 'doc[1]::$["say \\"hi\\""]')
  eq(copy_at('"back'), 'doc[1]::$["back\\\\slash"]')
  eq(copy_at('"empty keys at'), 'doc[1]::$["nested"][""][""]')
  eq(copy_at('"surrogate pair"'), 'doc[1]::$["😀"]')
  eq(notes(), { 'Iara: copied doc[1]::$["😀"] to register +' })
end

T["copy"]["copies array indexes"] = function()
  edit("root_array.json")
  eq(copy_at('"b"'), 'doc[1]::$[1]["tags"][1]')
  eq(copy_at("10"), "doc[1]::$[2][0]")
  eq(copy_at('"scalar element"'), "doc[1]::$[3]")
end

T["copy"]["uses the unnamed register without a clipboard"] = function()
  child.lua("vim.g.clipboard = nil; vim.g.loaded_clipboard_provider = 1")
  edit("root_object.json")
  cursor_to('"port"')
  child.lua("T.structured.copy_path()")
  wait_note("copied")
  eq(child.fn.getreg('"'), 'doc[1]::$["server"]["port"]')
end

T["copy"]["refuses an ambiguous duplicate and offers the source"] = function()
  edit("duplicates.json")
  child.lua("T.choose = true")
  eq(copy_at('"name"', 2), FIXTURES .. "duplicates.json:3:3")
  match(notes()[1], "^Iara: cannot copy path: Duplicate keys make this")
  match(child.lua_get("T.prompts")[1], "%(ambiguous%)")
  -- Descendants of a duplicated ancestor are ambiguous too.
  eq(copy_at('"b"', 1), FIXTURES .. "duplicates.json:4:9")
end

T["copy"]["refuses an incomplete path; declining copies nothing"] = function()
  edit("incomplete_missing_value.json")
  cursor_to('"missing"')
  child.lua("T.structured.copy_path()")
  wait_note("cannot copy path")
  match(notes()[1], "Path is incomplete")
  match(child.lua_get("T.prompts")[1], "%(incomplete%)")
  eq(child.lua_get("T.copied['+']"), vim.NIL)
end

T["copy"]["refuses in a conservative buffer with the reason"] = function()
  edit("root_object.json")
  child.lua([[
    local long = '"' .. ("x"):rep(12000) .. '"'
    vim.api.nvim_buf_set_lines(0, 1, 1, true, { '  "long": ' .. long .. "," })
    require("iara.core.eligibility").recheck(0)
  ]])
  wait_for("require('iara.core.eligibility').check(0).state == 'conservative'")
  cursor_to('"port"')
  child.lua("T.structured.copy_path()")
  wait_note("cannot copy the path")
  match(notes()[1], "^Iara: cannot copy the path: .*line")
  child.lua("T.structured.search_keys()")
  wait_note("cannot search keys")
  eq(child.lua_get("T.copied['+']"), vim.NIL)
end

T["copy"]["show path names the path or why it has none"] = function()
  edit("duplicates.json")
  cursor_to('"b": 3')
  child.lua("T.structured.show_path()")
  wait_note("unique")
  eq(notes()[1], 'Iara: unique.a.b  doc[1]::$["unique"]["a"]["b"]')
  cursor_to('"name"', 1)
  child.lua("T.structured.show_path()")
  wait_for("#T.notes == 2")
  local text = "Iara: name (ambiguous)  no canonical path: Duplicate keys "
    .. "make this path ambiguous; source "
    .. FIXTURES
    .. "duplicates.json:2:3"
  eq(notes()[2], text)
end

T["copy"]["refuses buffers that are neither JSON nor YAML"] = function()
  child.cmd("enew")
  child.lua("T.structured.copy_path(); T.structured.search_keys()")
  eq(notes(), {
    "Iara: cannot copy the path: not a JSON or YAML buffer",
    "Iara: cannot search keys: not a JSON or YAML buffer",
  })
end

-- Key search ---------------------------------------------------------------

T["search"] = MiniTest.new_set()

T["search"]["lists keys with locations; duplicates labeled"] = function()
  edit("duplicates.json")
  open_search()
  eq(child.lua_get("T.items()"), {
    "name (ambiguous)  2:3",
    "name (ambiguous)  3:3",
    "a (ambiguous)  4:3",
    "a.b (ambiguous)  4:9",
    "a (ambiguous)  5:3",
    "a.b (ambiguous)  5:9",
    "unique  6:3",
    "unique.a  6:14",
    "unique.a.b  6:20",
    "café (ambiguous)  7:3",
    "café (ambiguous)  8:3",
    -- Decomposed e and combining acute: a different key.
    "e\204\129  9:3",
  })
  local lines = child.lua_get("T.list_lines()")
  match(table.concat(lines, "\n"), "name %(ambiguous%)  3:3  duplicate key")
end

T["search"]["jumps to the recorded byte location"] = function()
  edit("literal_keys.json")
  open_search()
  child.lua("T.go(...)", { "日本語.キー" })
  child.type_keys("<CR>")
  wait_for("T.picker() == nil")
  -- Byte column after the multibyte prefix, not a character count.
  local line = child.api.nvim_get_current_line()
  eq(cursor()[2], line:find('"キー"', 1, true) - 1)
  eq(cursor()[1], 14)
end

T["search"]["indexes unsaved edits and jumps to them"] = function()
  edit("root_object.json")
  child.api.nvim_buf_set_lines(0, 1, 1, true, { '  "added.key": {"x": 1},' })
  open_search()
  child.lua("T.go(...)", { '"added.key".x' })
  child.type_keys("<CR>")
  wait_for("T.picker() == nil")
  eq(cursor(), { 2, 16 })
  eq(child.bo.modified, true)
end

T["search"]["refuses a jump after the buffer changed"] = function()
  edit("root_object.json")
  open_search()
  child.lua("T.go(...)", { "server.port" })
  child.lua([[
    local item = T.picker():current()
    vim.api.nvim_buf_set_lines(item.iara.bufnr, 0, 0, true, { "" })
  ]])
  child.type_keys("<CR>")
  wait_for("T.picker() == nil")
  wait_note("cannot jump")
  match(notes()[1], "changed after this location was recorded")
  -- Still where it was (one line down after the insertion above it).
  eq(cursor(), { 2, 0 })
end

T["search"]["previews at most 20 lines with the key marked"] = function()
  edit("deep_nesting.json")
  child.lua([[
    local lines = {}
    for index = 1, 60 do
      lines[index] = ('  "k%d": "%s",'):format(index, ("v"):rep(500))
    end
    lines[61] = '  "last": 1'
    vim.api.nvim_buf_set_lines(0, 0, -1, true,
      vim.list_extend({ "{" }, vim.list_extend(lines, { "}" })))
  ]])
  open_search()
  child.lua("T.go(...)", { "k30" })
  wait_for("(T.preview_lines()[6] or ''):find('k30') ~= nil")
  local lines = child.lua_get("T.preview_lines()")
  eq(#lines, 20)
  local bytes = #table.concat(lines, "\n")
  eq(bytes <= 8 * 1024, true)
  eq(lines[6]:sub(1, 7), '  "k30"')
  local marked = child.lua_get([[(function()
    local buf = T.picker().preview.win.buf
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1,
      { details = true })) do
      if mark[4].hl_group == "IaraSearchPreviewMatch" then
        return { mark[2], mark[3], mark[4].end_col }
      end
    end
  end)()]])
  eq(marked, { 5, 2, 7 })
end

T["search"]["discloses unverified uniqueness of a partial index"] = function()
  child.cmd("enew")
  child.bo.filetype = "json"
  child.lua([[
    local lines = { "{" }
    for index = 1, 10001 do
      lines[#lines + 1] = ('"k%d": 1,'):format(index)
    end
    lines[#lines + 1] = '"end": 1}'
    vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  ]])
  open_search()
  match(
    child.lua_get("T.picker().title"),
    "partial index: uniqueness unverified"
  )
  local lines = child.lua_get("T.list_lines()")
  match(lines[1], "k1  2:1  uniqueness unverified")
end

T["search"]["routes YAML buffers to yaml-revealer's key search"] = function()
  child.lua([[
    T.yaml_calls = {}
    package.loaded["iara.features.structured.yaml_legacy"] = {
      search_keys = function(bufnr) table.insert(T.yaml_calls, bufnr) end,
      status = function() return { state = "active" } end,
    }
  ]])
  edit("duplicates.yaml")
  child.lua("T.structured.search_keys()")
  eq(child.lua_get("T.yaml_calls"), { child.api.nvim_get_current_buf() })
  child.lua("T.structured.copy_path()")
  match(notes()[1], "YAML adapter")
  eq(child.lua_get("T.picker()"), vim.NIL)
  eq(child.lua_get("T.requests"), 0)
end

T["search"]["maps the Space y actions"] = function()
  edit("root_object.json")
  cursor_to('"port"')
  child.type_keys(" yp")
  wait_note("server.port")
  child.type_keys(" yc")
  wait_for("T.copied['+'] ~= nil")
  child.type_keys(" ys")
  wait_for("T.picker() ~= nil")
  eq(
    child.lua_get("vim.fn.maparg(' yt', 'n', false, true).desc"),
    "Toggle structured breadcrumb"
  )
end

-- Watchdog and retry ---------------------------------------------------------

---Make every JSON parse silent: it never calls back. Counts parses.
local function silence_parser()
  child.lua([[
    T.parses = 0
    T.real_get_parser = T.real_get_parser or vim.treesitter.get_parser
    vim.treesitter.get_parser = function(bufnr, lang, opts)
      local real = T.real_get_parser(bufnr, lang, opts)
      return {
        is_valid = function(_, ...) return real:is_valid(...) end,
        parse = function() T.parses = T.parses + 1 end,
      }
    end
  ]])
end

local function restore_parser()
  child.lua("vim.treesitter.get_parser = T.real_get_parser")
end

T["watchdog"] = MiniTest.new_set()

T["watchdog"]["pauses the breadcrumb until an explicit retry"] = function()
  edit("root_object.json")
  silence_parser()
  cursor_to('"port"')
  wait_note("breadcrumb paused")
  match(notes()[1], "250 ms.*:IaraStructuredRetry")
  eq(
    child.lua_get("T.ui.breadcrumb_paused(vim.api.nvim_get_current_buf())"),
    true
  )
  -- No automatic parse while paused, whatever the cursor does.
  cursor_to('"host"')
  child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })")
  vim.wait(200)
  eq(child.lua_get("T.parses"), 1)
  -- Explicit actions refuse with the reason instead of parsing again.
  child.lua("T.notes = {}; T.structured.copy_path()")
  wait_note("cannot copy the path")
  match(notes()[1], ":IaraStructuredRetry")
  child.lua("T.structured.search_keys()")
  wait_note("cannot search keys")
  eq(child.lua_get("T.parses"), 1)
  eq(child.lua_get("T.copied['+']"), vim.NIL)
  -- The retry makes one attempt with a working parser and resumes.
  restore_parser()
  child.lua("T.notes = {}")
  child.cmd("IaraStructuredRetry")
  wait_note("server.host")
  crumb_is("  → server.host")
end

T["watchdog"]["a failed retry suspends again after one attempt"] = function()
  edit("root_object.json")
  silence_parser()
  cursor_to('"port"')
  wait_note("breadcrumb paused")
  child.lua("T.notes = {}")
  child.cmd("IaraStructuredRetry")
  wait_note("cannot retry")
  match(notes()[1], "250 ms")
  vim.wait(300)
  eq(child.lua_get("T.parses"), 2)
  child.cmd("IaraStructuredRetry")
  wait_note("cannot retry")
  eq(child.lua_get("T.parses"), 3)
end

T["watchdog"]["retry without a suspension says so"] = function()
  edit("root_object.json")
  child.cmd("IaraStructuredRetry")
  eq(notes(), {
    "Iara: nothing to retry: JSON parsing is not suspended here",
  })
end

T["watchdog"]["turning the breadcrumb off releases its parse"] = function()
  edit("root_object.json")
  silence_parser()
  cursor_to('"port"')
  wait_for("T.parses == 1")
  child.lua("T.structured.toggle_breadcrumb()")
  local held =
    child.lua_get("require('iara.features.structured.json')" .. ".status(0)")
  eq({ held.parsing, held.watchdog, held.waiting }, { false, false, {} })
  -- Past the watchdog: the buffer was not suspended.
  vim.wait(400)
  eq(
    child.lua_get(
      "require('iara.features.structured.json').status(0)" .. ".suspended"
    ),
    vim.NIL
  )
end

-- Key search modes and layout (UX4) ----------------------------------------

local function mode()
  return child.api.nvim_get_mode().mode
end

local function current_item()
  return child.lua_get([[(function()
    local item = T.picker():current({ resolve = false })
    return item.text .. "  " .. T.ui.location_label(item.iara)
  end)()]])
end

local function footer()
  return child.lua_get([[(function()
    local list = T.picker().list.win.win
    local parts = {}
    for _, chunk in ipairs(vim.api.nvim_win_get_config(list).footer) do
      table.insert(parts, chunk[1])
    end
    return table.concat(parts)
  end)()]])
end

local function mode_chip()
  return child.lua_get([[(function()
    local buf = T.picker().input.win.buf
    local ns = vim.api.nvim_create_namespace("iara.picker.mode")
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, 1,
      { details = true })
    return mark[3] and mark[3].virt_text[1][1] or ""
  end)()]])
end

T["search"]["Normal mode moves, returns to Insert mode, and opens"] = function()
  edit("root_object.json")
  open_search()
  local items = child.lua_get("T.items()")
  eq(mode(), "i")
  match(footer(), "^ ⏎ open · C%-v vsplit ")
  child.type_keys("<Esc>")
  wait_for("vim.api.nvim_get_mode().mode == 'n'")
  eq(child.lua_get("T.picker() ~= nil"), true)
  eq(mode_chip(), " NORMAL ")
  match(child.wo.statuscolumn, "❮")
  match(footer(), "^ j/k move · i insert · ⏎ open · q close ")
  child.type_keys("j")
  eq(current_item(), items[2])
  child.type_keys("G")
  eq(current_item(), items[#items])
  child.type_keys("gg")
  eq(current_item(), items[1])
  child.type_keys("A")
  eq(mode(), "i")
  eq(mode_chip(), "")
  child.type_keys("port")
  wait_for("T.items()[1] == 'server.port  4:5'")
  child.type_keys("<Esc>", "o")
  wait_for("T.picker() == nil")
  eq(cursor(), { 4, 4 })
end

T["search"]["q closes; list and preview are equal panes"] = function()
  edit("root_object.json")
  for _, columns in ipairs({ 120, 121 }) do
    child.o.columns = columns
    open_search()
    local frames = child.lua_get([[(function()
      local picker = T.picker()
      local function results_frame(picker)
      local input = vim.api.nvim_win_get_config(picker.input.win.win)
      local list = vim.api.nvim_win_get_config(picker.list.win.win)
      return {
        row = input.row, col = input.col, width = input.width,
        height = input.height + 1 + list.height,
      }
    end
      local list = results_frame(picker)
      local preview = vim.api.nvim_win_get_config(picker.preview.win.win)
      return { list, preview }
    end)()]])
    eq(frames[1].width, frames[2].width)
    eq(frames[1].height, frames[2].height)
    eq(frames[1].row, frames[2].row)
    child.type_keys("<Esc>")
    wait_for("vim.api.nvim_get_mode().mode == 'n'")
    child.type_keys("q")
    wait_for("T.picker() == nil")
  end
  child.o.columns = 140
end
return T
