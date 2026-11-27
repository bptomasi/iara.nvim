-- Editor chrome (task V8): diagnostics show virtual text on the cursor's
-- line only while signs and error numbers stay on every line, the
-- diagnostic float has a title, glyphs, and muted details, and line
-- numbers, signs, and diagnostics read on every palette.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local theme = require("iara.theme")
local roles = require("iara.theme.roles")
local hl = require("iara.theme.highlights")

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.lua([[
        require("iara.core.options").setup({})
        require("iara.core.lsp").setup()
      ]])
    end,
    post_once = child.stop,
  },
})

---Put five lines in the buffer and an error on line 2 and a warning on
---line 4 (1-based), both from the source "demo".
local function with_diagnostics(extra)
  child.lua(
    [[
    vim.api.nvim_buf_set_lines(0, 0, -1, true,
      { "one", "two", "three", "four", "five" })
    _G.ns = vim.api.nvim_create_namespace("test.chrome")
    local S = vim.diagnostic.severity
    local list = {
      { lnum = 1, col = 0, message = "broken", severity = S.ERROR,
        source = "demo", code = "E1" },
      { lnum = 3, col = 0, message = "shaky", severity = S.WARN,
        source = "demo" },
    }
    vim.list_extend(list, ... or {})
    vim.diagnostic.set(_G.ns, 0, list)
  ]],
    { extra }
  )
end

---Extmarks of the diagnostic namespaces: rows with virtual text, with
---a sign, and the number highlight of each sign row.
local function marks()
  return child.lua_get([[(function()
    local result = { virtual = {}, signs = {}, numhl = {} }
    local all = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1,
      { details = true })
    for _, mark in ipairs(all) do
      local row, details = mark[2] + 1, mark[4]
      if details.virt_text then
        table.insert(result.virtual, row)
      end
      if details.sign_text then
        table.insert(result.signs, row)
        result.numhl[row] = details.number_hl_group or "none"
      end
    end
    table.sort(result.signs)
    return result
  end)()]])
end

T["virtual text follows the cursor line"] = function()
  with_diagnostics()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys("0")
  eq(marks().virtual, { 2 })
  child.type_keys("jj")
  eq(marks().virtual, { 4 })
  child.type_keys("j")
  eq(marks().virtual, {})
end

T["signs stay on every line and only errors color the number"] = function()
  with_diagnostics()
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.type_keys("0")
  local result = marks()
  eq(result.signs, { 2, 4 })
  eq(result.numhl[2], "DiagnosticError")
  eq(result.numhl[4], "none")
end

---Lines, title, and highlights of a diagnostic float on line 2.
local function float_on_line_two()
  return child.lua_get([[(function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local buf, win = vim.diagnostic.open_float()
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1,
      { details = true })
    local groups = {}
    for _, mark in ipairs(marks) do
      table.insert(groups, mark[4].hl_group)
    end
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true),
      title = vim.api.nvim_win_get_config(win).title,
      groups = groups,
    }
  end)()]])
end

T["the diagnostic float has a title, a glyph, and the code"] = function()
  with_diagnostics()
  local float = float_on_line_two()
  local glyph = child.lua_get("require('iara.core.icons').DIAGNOSTICS.ERROR")
  -- No "Diagnostics:" header line: the title names the float.
  eq(float.lines, { glyph .. " broken  E1" })
  match(vim.inspect(float.title), "Diagnostics")
  match(vim.inspect(float.title), "FloatTitle")
  match(table.concat(float.groups, " "), "DiagnosticError")
  match(table.concat(float.groups, " "), "IaraMuted")
end

T["the float names the source only when there are several"] = function()
  local S = vim.diagnostic.severity
  with_diagnostics({
    {
      lnum = 1,
      col = 1,
      message = "style",
      severity = S.HINT,
      source = "lint",
    },
  })
  local lines = float_on_line_two().lines
  match(lines[1], "broken  E1 · demo$")
  match(lines[2], "style  lint$")
end

T["line numbers and signs read on every palette"] = function()
  local failures = {}
  local function check(label, color, surface, ratio)
    if hl.contrast(color, surface) < ratio then
      table.insert(
        failures,
        ("%s %.2f"):format(label, hl.contrast(color, surface))
      )
    end
  end
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, r = hl.resolve(palette), roles.resolve(palette)
    -- Line numbers are text: 4.5:1 on the editor and its cursor line.
    check(name .. " LineNr", groups.LineNr.fg, r.base, 4.5)
    check(name .. " LineNr cursorline", groups.LineNr.fg, r.cursorline, 4.5)
    check(name .. " CursorLineNr", groups.CursorLineNr.fg, r.base, 4.5)
    for _, state in ipairs({ "Error", "Warn", "Info", "Hint", "Ok" }) do
      local text = groups["DiagnosticVirtualText" .. state]
      check(name .. " virtual " .. state, text.fg, text.bg, 4.5)
      check(
        name .. " sign " .. state,
        groups["Diagnostic" .. state].fg,
        r.base,
        4.5
      )
    end
    for _, sign in ipairs({ "GitSignsAdd", "GitSignsChange" }) do
      check(name .. " " .. sign, groups[sign].fg, r.base, 3)
    end
  end
  eq(failures, {})
end

T["the cursor number is the accent and changes are blue"] = function()
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, r = hl.resolve(palette), roles.resolve(palette)
    eq(
      { name, groups.CursorLineNr.fg, groups.CursorLineNr.bold },
      { name, r.accent, true }
    )
    eq({ name, groups.GitSignsChange.fg }, { name, r.info })
    eq({ name, groups.GitSignsAdd.fg }, { name, r.ok })
    eq(
      { name, groups.DiagnosticInfo.fg ~= groups.DiagnosticOk.fg },
      { name, true }
    )
  end
end

return T
