-- Appearance (tasks UX3 and V4): status line segments and width tiers
-- that follow editor state, the tab line's buffer bar, window chrome,
-- the theme groups of every palette, and the start screen's startup
-- conditions, headless and without plugins.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = helpers.new_child()

local SETUP = [[
local config = { options = ... }
require("iara.core.options").setup(config)
require("iara.theme").load("chocolate")
require("iara.core.root").setup(config)
require("iara.core.eligibility").setup(config)
require("iara.core.reconcile").setup(config)
]]

local function setup(options)
  child.lua(SETUP, { options or {} })
end

---Status line as drawn (highlight markers removed).
local function status_text()
  return child.lua([[
    local text = require("iara.core.statusline").render()
    return vim.api.nvim_eval_statusline(text, {}).str
  ]])
end

local function status_raw()
  return child.lua_get("require('iara.core.statusline').render()")
end

local function tab_text()
  return child.lua([[
    local text = require("iara.core.statusline").tabline()
    return vim.api.nvim_eval_statusline(text, { use_tabline = true }).str
  ]])
end

local function edit(name, content)
  local path = helpers.temp_dir() .. "/" .. name
  helpers.write_file(path, content or "local x = 1\n")
  child.cmd("edit " .. vim.fn.fnameescape(path))
  return path
end

---Let scheduled callbacks (cache refreshes) run.
local function settle()
  child.lua("vim.wait(50)")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

-- Status line ---------------------------------------------------------------

local MARK = "\u{223f}"

T["the mode block follows the mode"] = function()
  setup()
  edit("init.lua")
  match(status_text(), "^ NORMAL  ")
  match(status_raw(), "^%%#IaraStatusModeNormal# NORMAL %%%*")
  child.type_keys("i")
  match(status_text(), "^ INSERT ")
  match(status_raw(), "IaraStatusModeInsert#")
  child.type_keys("<Esc>", "v")
  match(status_text(), "^ VISUAL ")
end

T["segments are flat, no caps or arrows; the mode is a block"] = function()
  setup()
  edit("init.lua")
  local text = status_text()
  for _, glyph in ipairs({ "\u{e0b6}", "\u{e0b4}", "\u{e0b0}", "\u{e0b2}" }) do
    eq(text:find(glyph, 1, true), nil)
  end
  match(text, " 1:1 $")
  -- Every segment but the mode sits on the bar's own background.
  local flat = child.lua([[
    local bar = vim.api.nvim_get_hl(0, { name = "StatusLine" }).bg
    local wrong = {}
    for _, name in ipairs({ "IaraStatusFile", "IaraStatusRoot",
      "IaraStatusPosition", "IaraStatusModified", "IaraStatusMark" }) do
      if vim.api.nvim_get_hl(0, { name = name, link = false }).bg ~= bar then
        table.insert(wrong, name)
      end
    end
    local mode = vim.api.nvim_get_hl(0, { name = "IaraStatusModeNormal" })
    return { wrong = wrong, block = mode.bg ~= bar }
  ]])
  eq(flat, { wrong = {}, block = true })
end

T["the file shows its name, then a dot while modified"] = function()
  setup()
  edit("init.lua")
  local dot = "\u{25cf}"
  match(status_text(), " init%.lua ")
  eq(status_text():find(dot, 1, true), nil)
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 0, true, { '-- edit' })")
  eq(status_text():find("init.lua " .. dot, 1, true) ~= nil, true)
  child.cmd("write")
  eq(status_text():find(dot, 1, true), nil)
  -- A rename shows at once although the file segment is cached.
  child.cmd("file renamed.lua")
  match(status_text(), " renamed%.lua ")
end

T["git branch and nonzero counts come from Gitsigns"] = function()
  setup()
  edit("init.lua")
  child.o.columns = 120
  eq(status_text():find("main", 1, true), nil)
  child.lua([[
    vim.b.gitsigns_status_dict =
      { head = "main", added = 3, changed = 0, removed = 2 }
  ]])
  local text = status_text()
  match(text, "main")
  match(text, " 3")
  match(text, " 2")
  eq(text:find(" 0", 1, true), nil)
  match(status_raw(), "IaraStatusGitAdded")
  eq(status_raw():find("IaraStatusGitChanged", 1, true), nil)
end

T["diagnostic counts appear and disappear with diagnostics"] = function()
  setup()
  edit("init.lua")
  local error_icon = "\u{f057}"
  eq(status_text():find(error_icon, 1, true), nil)
  child.lua([[
    local ns = vim.api.nvim_create_namespace("test")
    _G.ns = ns
    local E, W = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
    vim.diagnostic.set(ns, 0, {
      { lnum = 0, col = 0, message = "a", severity = E },
      { lnum = 0, col = 0, message = "b", severity = E },
      { lnum = 0, col = 0, message = "c", severity = W },
    })
  ]])
  settle()
  local text = status_text()
  eq(text:find(error_icon .. " 2", 1, true) ~= nil, true)
  eq(text:find("\u{f071} 1", 1, true) ~= nil, true)
  child.lua("vim.diagnostic.reset(_G.ns, 0)")
  settle()
  eq(status_text():find(error_icon, 1, true), nil)
end

T["the LSP client name shows while a client is attached"] = function()
  setup()
  edit("init.lua")
  local fake = helpers.iara_dir .. "/tests/fixtures/baseline/fake_lsp.lua"
  local log = helpers.temp_dir() .. "/lsp.log"
  eq(status_text():find("fake_ls", 1, true), nil)
  child.o.columns = 120
  child.lua(
    [[
    local fake, log = ...
    _G.client = vim.lsp.start({
      name = "fake_ls",
      cmd = { vim.v.progpath, "-l", fake, log },
      root_dir = vim.fn.getcwd(),
    })
    vim.wait(5000, function()
      return #vim.lsp.get_clients({ bufnr = 0 }) > 0
    end)
  ]],
    { fake, log }
  )
  settle()
  match(status_text(), "fake_ls")
  child.lua([[
    vim.lsp.buf_detach_client(0, _G.client)
    vim.wait(5000, function()
      return #vim.lsp.get_clients({ bufnr = 0 }) == 0
    end)
  ]])
  settle()
  eq(status_text():find("fake_ls", 1, true), nil)
end

---Which segments the status line shows at `columns`.
local function segments(columns)
  child.o.columns = columns
  local text = status_text()
  local function has(fragment)
    return text:find(fragment, 1, true) ~= nil
  end
  return {
    mode = has(" NORMAL "),
    file = has(" init.lua "),
    branch = has("main"),
    counts = has(" 3"),
    lsp = has("fake_ls"),
    progress = has("indexing"),
    root = has("(git)") or has("(startup)"),
    position = has(" 1:1 "),
  }
end

T["narrow screens drop LSP, Git counts, then the root"] = function()
  setup()
  edit("init.lua")
  child.lua([[
    vim.b.gitsigns_status_dict = { head = "main", added = 3 }
    vim.lsp.get_clients = function()
      return { { name = "fake_ls" } }
    end
    -- A stand-in for V5's segment, which has width tiers of its own.
    package.loaded["iara.core.progress"] = {
      statusline = function()
        return vim.o.columns >= 100 and "indexing" or ""
      end,
    }
  ]])
  local all = {
    mode = true,
    file = true,
    branch = true,
    counts = true,
    lsp = true,
    progress = true,
    root = true,
    position = true,
  }
  eq(segments(120), all)
  eq(segments(100), all)
  local at80 = vim.tbl_extend("force", all, { lsp = false, progress = false })
  eq(segments(80), at80)
  local at60 = vim.tbl_extend("force", at80, { counts = false, root = false })
  eq(segments(60), at60)
end

T["a failing progress segment shows a question mark"] = function()
  setup()
  edit("init.lua")
  child.lua([[
    package.loaded["iara.core.progress"] = {
      statusline = function()
        error("boom")
      end,
    }
  ]])
  match(status_text(), " %? ")
end

---Start an in-process server that reports "Indexing 42%" through the
---native `LspProgress` event.
local function report_progress()
  child.lua([[
    local function server(dispatchers)
      _G.dispatchers = dispatchers
      return {
        request = function(method, _, callback)
          local result = method == "initialize" and { capabilities = {} }
          vim.schedule(function() callback(nil, result or nil) end)
          return true, 1
        end,
        notify = function() return true end,
        is_closing = function() return false end,
        terminate = function() end,
      }
    end
    local id = vim.lsp.start({ name = "busy_ls", cmd = server })
    vim.wait(5000, function()
      local client = vim.lsp.get_client_by_id(id)
      return client ~= nil and client.initialized
    end)
    _G.dispatchers.notification("$/progress", {
      token = "t",
      value = { kind = "begin", title = "Indexing", percentage = 42 },
    })
    vim.wait(500, function()
      return require("iara.core.progress").state() ~= nil
    end)
  ]])
end

T["LSP progress shows between the sides and redraws on change"] = function()
  setup()
  edit("init.lua")
  child.o.columns = 120
  local events = child.lua([[
    return #vim.api.nvim_get_autocmds({
      group = "IaraStatusline",
      event = "User",
      pattern = "IaraProgressChanged",
    })
  ]])
  eq(events, 1)
  report_progress()
  local text = status_text()
  local file = text:find("init.lua", 1, true)
  local busy = text:find("busy_ls", 1, true)
  local position = text:find("1:1", 1, true)
  eq(busy ~= nil and file < busy and busy < position, true)
  match(text, "Indexing")
  match(text, "42%%")
end

T["root and position close the status line"] = function()
  setup()
  edit("init.lua")
  local label = child.lua_get("require('iara.core.root').statusline()")
  local text = status_text()
  eq(text:find(label, 1, true) ~= nil, true)
  match(text, " 1:1 $")
  match(status_raw(), "IaraStatusRootIcon")
  match(status_raw(), "IaraStatusPosition#")
  eq(text:find(MARK, 1, true), nil)
end

T["a trusted project's root carries the Iara mark"] = function()
  local project = helpers.temp_dir()
  helpers.write_file(project .. "/.git/HEAD", "ref: refs/heads/main\n")
  local personal = helpers.temp_dir() .. "/user.lua"
  helpers.write_file(
    personal,
    ("return { trusted_projects = { %q } }"):format(project)
  )
  child.lua(
    "require('iara.config').load({ personal_path = ..., project_dir = '/' })",
    { personal }
  )
  setup()
  child.cmd("edit " .. project .. "/init.lua")
  match(status_text(), MARK .. " ")
  match(status_raw(), "IaraStatusMark#")
  eq(status_raw():find("IaraStatusRootIcon", 1, true), nil)
  -- A file of another project has the folder icon instead.
  edit("other.lua")
  eq(status_text():find(MARK, 1, true), nil)
  match(status_raw(), "IaraStatusRootIcon")
end

T["safe mode shows its chip only in safe mode"] = function()
  setup()
  edit("init.lua")
  eq(status_text():find("[safe]", 1, true), nil)
  child.g.iara_mode = "safe"
  match(status_text(), "%[safe%]")
end

T["typing does no new status, tab, or winbar work"] = function()
  setup()
  edit("one.lua")
  child.cmd("vsplit " .. helpers.temp_dir() .. "/two.lua")
  -- The first change marks the buffer modified: its one redraw of the
  -- file segment, tab line, and winbars happens here, before counting.
  child.type_keys("i", "x")
  settle()
  child.lua([[
    _G.calls = {}
    local function count(key, module, name)
      local original = module[name]
      module[name] = function(...)
        _G.calls[key] = (_G.calls[key] or 0) + 1
        return original(...)
      end
    end
    count("status", require("iara.core.statusline"), "render")
    count("icon", require("iara.core.icons"), "file")
    count("root", require("iara.core.root"), "resolve")
    count("diagnostics", vim.diagnostic, "count")
    count("tab", require("iara.core.tabline"), "render")
    count("winbar", require("iara.core.winbar"), "text")
  ]])
  for _ = 1, 50 do
    child.type_keys("x")
  end
  settle()
  local calls = child.lua_get("_G.calls")
  -- The status line was drawn for every key, from its caches only.
  eq(calls.status >= 50, true)
  calls.status = nil
  eq(calls, {})
end

-- Tab line ------------------------------------------------------------------

T["the tab line lists open files and appears with two"] = function()
  setup()
  edit("one.lua")
  eq(child.o.showtabline, 1)
  edit("two.lua")
  settle()
  eq(child.o.showtabline, 2)
  local text = tab_text()
  match(text, "one%.lua .* two%.lua")
  local raw = child.lua_get("require('iara.core.statusline').tabline()")
  match(raw, "IaraTabInactive#[^%%]*one%.lua")
  match(raw, "IaraTabActive#[^%%]*two%.lua")
  child.cmd("bdelete")
  settle()
  eq(child.o.showtabline, 1)
end

T["the tab line checks visibility once after each buffer batch"] = function()
  setup()
  edit("one.lua")
  settle()
  local states = child.lua([[
    local tabline = require("iara.core.tabline")
    local wanted = tabline.wanted_showtabline
    local checks = 0
    tabline.wanted_showtabline = function()
      checks = checks + 1
      return wanted()
    end
    local buffers = {}
    for index = 1, 80 do
      local name = ("batch-%d.lua"):format(index)
      vim.cmd.badd(name)
      buffers[index] = vim.fn.bufnr(name)
    end
    vim.wait(50)
    local added = { checks, vim.o.showtabline }
    checks = 0
    for _, bufnr in ipairs(buffers) do
      vim.api.nvim_buf_delete(bufnr, {})
    end
    vim.wait(50)
    return { added, { checks, vim.o.showtabline } }
  ]])
  eq(states, { { 1, 2 }, { 1, 1 } })
end

T["the current label leads with an accent bar"] = function()
  setup()
  edit("one.lua")
  edit("two.lua")
  local bar = "\u{258e}"
  local text = tab_text()
  eq(select(2, text:gsub(bar, "")), 1)
  match(text, bar .. "%S+ two%.lua")
  local raw = child.lua_get("require('iara.core.statusline').tabline()")
  match(raw, "IaraTabActiveBar#" .. bar)
end

T["the tab line marks modified files by label"] = function()
  setup()
  edit("one.lua")
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 0, true, { '-- edit' })")
  child.cmd("set hidden")
  edit("two.lua")
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 0, true, { '-- edit' })")
  local dot = "\u{25cf}"
  eq(tab_text():find("two.lua " .. dot, 1, true) ~= nil, true)
  eq(tab_text():find("one.lua " .. dot, 1, true) ~= nil, true)
  local raw = child.lua_get("require('iara.core.statusline').tabline()")
  -- The accent on the current label, the warning color on the others.
  match(raw, "one%.lua %%#IaraTabModifiedInactive#")
  match(raw, "two%.lua %%#IaraTabModified#")
end

T["a configured showtabline is left alone"] = function()
  setup({ showtabline = 0 })
  edit("one.lua")
  edit("two.lua")
  settle()
  eq(child.o.showtabline, 0)
end

T["the tab line keeps the current file visible when narrow"] = function()
  local fit = [[
    local items = {}
    for i = 1, 10 do
      items[i] = { text = "<" .. i .. ">", width = 10 }
    end
    return require("iara.core.tabline").fit(items, ...)
  ]]
  eq(child.lua(fit, { 9, 30 }), "<8><9><10>")
  eq(child.lua(fit, { 1, 25 }), "<1><2>")
  eq(child.lua(fit, { 5, 100 }), "<1><2><3><4><5><6><7><8><9><10>")
end

T["label widths match what the tab line draws"] = function()
  setup()
  for index = 1, 6 do
    edit(("file_%d.lua"):format(index))
  end
  -- Labels fit exactly when the measured widths are right: the drawn
  -- text never exceeds the screen and keeps the current label.
  child.o.columns = 60
  local text = tab_text()
  eq(vim.api.nvim_strwidth(text) <= 60, true)
  match(text, "file_6%.lua")
end

-- Window chrome -------------------------------------------------------------

T["floats get straight borders and the end of buffer is blank"] = function()
  setup()
  eq(child.o.winborder, "single")
  match(child.o.fillchars, "eob: ")
  eq(child.o.signcolumn, "yes")
end

-- Theme groups --------------------------------------------------------------

-- Status, tab, and winbar text (4.5:1 on its own background) and glyphs
-- (3:1), checked in every palette. `IaraStatusSafe` is a warning chip
-- since V12 (U1's black on orange was 3.0:1 in gruvbox_light).
local TEXT_GROUPS = {
  "StatusLine",
  "IaraStatusSafe",
  "IaraStatusMuted",
  "IaraStatusLsp",
  "IaraStatusWarn",
  "IaraStatusConflict",
  "IaraStatusGitAdded",
  "IaraStatusGitChanged",
  "IaraStatusGitRemoved",
  "IaraStatusDiagError",
  "IaraStatusDiagWarn",
  "IaraStatusDiagInfo",
  "IaraStatusDiagHint",
  "IaraStatusFile",
  "IaraStatusRoot",
  "IaraStatusPosition",
  "TabLine",
  "TabLineSel",
  "IaraTabActive",
  "IaraTabInactive",
  "WinBar",
  "WinBarNC",
  "IaraWinbarPath",
  "IaraWinbarName",
  "IaraWinbarInactive",
}
local GLYPH_GROUPS = {
  "IaraStatusModified",
  "IaraStatusRootIcon",
  "IaraStatusMark",
  "IaraTabActiveBar",
  "IaraTabModified",
  "IaraTabModifiedInactive",
  "IaraWinbarBar",
  "IaraWinbarIcon",
  "IaraWinbarModified",
}
local MODES = {
  "Normal",
  "Insert",
  "Visual",
  "Replace",
  "Command",
  "Select",
  "Terminal",
  "Confirm",
}

local AUDIT = [[
local text, glyphs, modes = ...
local theme = require("iara.theme")
local hl = require("iara.theme.highlights")
local low = {}
local function check(name, groups, group, ratio)
  local spec = groups[group]
  local value = hl.contrast(spec.fg, spec.bg)
  if value < ratio then
    table.insert(low, ("%s %s %.2f"):format(name, group, value))
  end
end
for _, name in ipairs(theme.THEMES) do
  local groups = hl.resolve(theme.palette(name))
  for _, group in ipairs(text) do
    check(name, groups, group, 4.5)
  end
  for _, mode in ipairs(modes) do
    check(name, groups, "IaraStatusMode" .. mode, 4.5)
  end
  for _, group in ipairs(glyphs) do
    check(name, groups, group, 3)
  end
end
return low
]]

T["status, tab, and winbar text is readable in every palette"] = function()
  eq(child.lua(AUDIT, { TEXT_GROUPS, GLYPH_GROUPS, MODES }), {})
end

T["every palette defines the appearance groups"] = function()
  local missing = child.lua([[
    local theme = require("iara.theme")
    local hl = require("iara.theme.highlights")
    local missing = {}
    for _, name in ipairs(theme.THEMES) do
      local groups, problems = hl.resolve(theme.palette(name))
      vim.list_extend(missing, problems)
      for group in pairs(theme.FALLBACK_LINKS) do
        local spec = groups[group]
        if not spec or not (spec.fg or spec.bg or spec.link) then
          table.insert(missing, name .. ": " .. group)
        end
      end
    end
    return missing
  ]])
  eq(missing, {})
end

T["blended colors mix two palette slots"] = function()
  local blend = "return require('iara.theme.highlights').blend(...)"
  eq(child.lua(blend, { "#ffffff", "#000000", 50 }), "#808080")
  eq(child.lua(blend, { "#ff0000", "#0000ff", 100 }), "#ff0000")
  eq(child.lua(blend, { "#ff0000", "#0000ff", 0 }), "#0000ff")
end

-- Start screen and safe mode ------------------------------------------------

T["the start screen stays away without a UI"] = function()
  child.lua("require('iara.core.start').setup({})")
  eq(child.lua_get("require('iara.core.start').wanted()"), false)
  eq(child.lua_get("vim.fn.exists(':IaraRecent')"), 2)
end

T["safe mode draws status and tab lines without plugins"] = function()
  local status = child.lua([[
    local status = require("iara").setup({ safe = true })
    vim.cmd.edit(vim.fn.tempname() .. ".lua")
    local states = {}
    for _, step in ipairs(status.steps) do
      states[step.name] = step.state
    end
    return { mode = status.mode, start = states["iara.core.start"] }
  ]])
  eq(status, { mode = "safe", start = "skipped" })
  match(status_text(), "^ NORMAL ")
  match(status_text(), "%[safe%]")
  match(tab_text(), "%.lua")
  eq(child.cmd_capture("messages"):find("E%d+"), nil)
end

return T
