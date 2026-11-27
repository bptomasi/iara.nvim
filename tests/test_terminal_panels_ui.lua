--- Terminal and agent panels seen through a real 120x35 UI (UX2, V7): a
--- child `nvim --embed` with a linegrid UI attached (the V2 color
--- gallery's, so every cell has its colors), Iara's options, status line,
--- tab line, and theme, a real `/bin/sh`, and a fake `claude` on a
--- private PATH. With IARA_UX2_SNAPSHOTS set to a directory, each screen
--- is also written there for the evidence.
local gallery = require("gallery")
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local WIDTH, HEIGHT = 120, 35

local child = nil
-- The project directory of the edited file, where shells start.
local project = nil

local FAKE_CLAUDE = [[#!/bin/sh
echo "Fake Claude Code (test double)"
printf '> '
while read -r line; do
  case "$line" in
    exit*) exit "${line#exit }" ;;
    *) printf 'got=%s\n> ' "$line" ;;
  esac
done
]]

local CHILD_SETUP = [[
local dir, bin = ...
vim.env.PATH = bin .. ":/usr/bin:/bin"
vim.env.PS1 = "$ "
vim.o.shell = "/bin/sh"
local config = { keymaps = {}, extras = { agents = {} },
  features = { terminal = { close_on_exit = false } } }
require("iara.core.options").setup(config)
require("iara.theme").setup({ ui = { terminal_background = false } })
require("iara.core.term_retention").setup({})
require("iara.features.terminal").setup(config)
require("iara.extras.agents").setup(config)
vim.fn.mkdir(dir .. "/.git", "p")
vim.fn.writefile({ "local M = {}", "", "return M" }, dir .. "/init.lua")
vim.cmd.edit(vim.fn.fnameescape(dir .. "/init.lua"))
]]

local function fake_bin()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/claude", FAKE_CLAUDE)
  vim.uv.fs_chmod(dir .. "/claude", tonumber("755", 8))
  return dir
end

---Screen rows as a list.
local function rows(screen)
  return vim.split(screen, "\n", { plain = true })
end

---The global status line: the row above the command line.
local function status_row(screen)
  return rows(screen)[HEIGHT - 1]
end

---Write the screen for the evidence when asked to.
local function snapshot(name, screen)
  local dir = vim.env.IARA_UX2_SNAPSHOTS
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(rows(screen), dir .. "/" .. name .. ".txt")
  end
end

local function wait_mode(expected)
  child:wait(function(c)
    return c:lua("return vim.api.nvim_get_mode().mode") == expected
  end)
end

---Wait until the screen has every text.
local function settled(texts)
  child:wait(function(c)
    local screen = c:screen()
    for _, text in ipairs(texts) do
      if not screen:find(text, 1, true) then
        return false
      end
    end
    return true
  end)
  return child:screen()
end

local function expect_has(screen, text)
  if not screen:find(text, 1, true) then
    error(("%q not in:\n%s"):format(text, screen), 2)
  end
end

---Role colors of the chocolate theme ("#rrggbb").
local function roles()
  return child:lua([[
    local theme = require("iara.theme")
    return require("iara.theme.roles").resolve(theme.palette("chocolate"))
  ]])
end

---Foreground and background of the cell where `text` starts.
local function colors_at(snap, text)
  local row, col = gallery.find(snap, text)
  if not row then
    error(("%q not on screen:\n%s"):format(text, gallery.text(snap)), 2)
  end
  local style = gallery.cell(snap, row, col).style
  return { fg = gallery.hex(style.fg), bg = gallery.hex(style.bg) }
end

---Row of the screen where `text` starts.
local function row_of(screen, text)
  for index, line in ipairs(rows(screen)) do
    if line:find(text, 1, true) then
      return index, line
    end
  end
  error(("%q not on screen:\n%s"):format(text, screen), 2)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = gallery.start(WIDTH, HEIGHT)
      project = helpers.temp_dir()
      child:lua(CHILD_SETUP, { project, fake_bin() })
    end,
    post_case = function()
      child:stop()
    end,
  },
})

---Show the main shell at the bottom and leave terminal input.
local function shell_in_normal_mode()
  child:input("<F7>")
  wait_mode("t")
  settled({ "$ ", "● running" })
  child:input([[<C-\><C-n>]])
  wait_mode("nt")
end

T["shell at the bottom and Claude at the right, clean status"] = function()
  shell_in_normal_mode()
  child:lua("vim.cmd.wincmd('p'); vim.cmd('IaraAgent claude')")
  local screen = settled({ "Fake Claude Code", "$ ", " Claude Code " })
  snapshot("shell-bottom-agent-right", screen)
  eq(screen:find("term://", 1, true), nil)
  local status = status_row(screen)
  expect_has(status, " Claude Code  running")
  expect_has(status, "(git)")
  -- The agent panel spans the full height at the right (40%): its
  -- header on the first row, the session below it.
  local lines = rows(screen)
  eq(vim.fn.strcharpart(lines[1], WIDTH - 48, 1), "▎")
  eq(vim.fn.strcharpart(lines[2], WIDTH - 48, 16), "Fake Claude Code")
end

T["the shell status line names the terminal"] = function()
  child:input("<F7>")
  wait_mode("t")
  local screen = settled({ "$ ", "Terminal · sh  running" })
  snapshot("shell-status", screen)
  eq(screen:find("term://", 1, true), nil)
  eq(screen:find("[-]", 1, true), nil)
  expect_has(status_row(screen), " Terminal · sh  running")
end

T["Claude in a centered float with a straight titled border"] = function()
  child:lua("vim.cmd('IaraAgent claude float')")
  local screen = settled({ "Fake Claude Code", "┌" })
  snapshot("agent-float", screen)
  local top, line = row_of(screen, "┌")
  expect_has(line, "┌─ ")
  expect_has(line, " Claude Code ")
  expect_has(line, " ● running ─┐")
  local _, bottom = row_of(screen, "└")
  expect_has(bottom, "␣at hide · ␣ap move · ^\\^n normal")
  -- The editor stays visible around the float.
  eq(top > 1, true)
  expect_has(rows(screen)[1], "local M = {}")
  eq(screen:find("term://", 1, true), nil)
end

T["a shell at the top spans the width above the editor"] = function()
  child:lua("vim.cmd('IaraTermPosition top')")
  child:input("<F7>")
  wait_mode("t")
  local screen = settled({ "$ ", "Terminal · sh" })
  snapshot("shell-top", screen)
  local lines = rows(screen)
  -- A third of the lines for the shell (header, then the shell), then
  -- the editor below it.
  local editor_row = math.floor(HEIGHT / 3) + 1
  expect_has(lines[editor_row + 1], "local M = {}")
  eq(vim.fn.strcharpart(lines[1], 0, 1), "▎")
  eq(lines[2]:sub(1, 2), "$ ")
  eq(screen:find("term://", 1, true), nil)
end

T["the tab line names a terminal tab cleanly"] = function()
  shell_in_normal_mode()
  -- The first tab's current window is the shell panel.
  child:lua("vim.cmd.tabnew()")
  local screen = settled({ "[No Name]", "Terminal · sh" })
  snapshot("tabline", screen)
  local first = rows(screen)[1]
  expect_has(first, " Terminal · sh ")
  expect_has(first, " [No Name] ")
  eq(
    first:find("Terminal · sh", 1, true) < first:find("[No Name]", 1, true),
    true
  )
  eq(screen:find("term://", 1, true), nil)
end

T["a docked shell has a header with name, directory, state, keys"] = function()
  child:input("<F7>")
  wait_mode("t")
  local screen = settled({ "▎", "● running", "F7 hide" })
  snapshot("shell-header", screen)
  local row, line = row_of(screen, "▎")
  -- The header is the panel's first row, above the prompt.
  eq(row, HEIGHT - 1 - math.floor(HEIGHT / 3))
  expect_has(line, " Terminal · sh  ")
  expect_has(line, "  ● running")
  expect_has(line, "  " .. vim.fn.fnamemodify(project, ":~") .. "  ")
  -- Hints sit at the right edge, keys as typed with Space shown as ␣.
  eq(vim.endswith(line, "F7 hide  ␣tn new  ^\\^n normal "), true)
end

T["panels sit on the mantle surface, the editor on base"] = function()
  shell_in_normal_mode()
  local snap = gallery.capture(child, "$ ")
  local role = roles()
  eq(colors_at(snap, "$ ").bg, role.mantle)
  eq(colors_at(snap, "local M").bg, role.base)
  eq(colors_at(snap, "Terminal · sh").fg, role.fg_strong)
  eq(colors_at(snap, "Terminal · sh").bg, role.mantle)
  eq(colors_at(snap, "● running").fg, role.tide)
  eq(colors_at(snap, "F7").fg, role.accent)
  eq(colors_at(snap, " hide").fg, role.muted)
  eq(child:lua("return vim.g.terminal_color_0"), role.mantle)
end

T["the background toggle recolors existing shells and new agents"] = function()
  shell_in_normal_mode()
  child:lua("vim.cmd.IaraToggleBackground()")
  local snap = gallery.capture(child, "$ ")
  local base = colors_at(snap, "local M").bg
  eq(colors_at(snap, "$ ").bg, base)
  eq(colors_at(snap, "Terminal · sh").bg, base)
  child:lua("vim.cmd('IaraAgent claude float')")
  local agent = gallery.capture(child, "Fake Claude Code")
  eq(colors_at(agent, "Fake Claude Code").bg, base)
  eq(colors_at(agent, "┌").bg, base)
  child:input([[<C-\><C-n>]])
  wait_mode("nt")
  child:lua("vim.cmd.IaraToggleBackground()")
  local restored = gallery.capture(child, "Fake Claude Code")
  eq(colors_at(restored, "Fake Claude Code").bg, roles().mantle)
end

T["the focused panel's bar is accent, others tide or hint"] = function()
  child:input("<F7>")
  wait_mode("t")
  local role = roles()
  eq(colors_at(gallery.capture(child, "▎"), "▎").fg, role.accent)
  child:input([[<C-\><C-n><C-w>p]])
  wait_mode("n")
  eq(colors_at(gallery.capture(child, "▎"), "▎").fg, role.tide)
  child:lua("vim.cmd('IaraAgent claude')")
  settled({ "Fake Claude Code" })
  child:input([[<C-\><C-n><C-w>p]])
  wait_mode("n")
  local snap = gallery.capture(child, "Fake Claude Code")
  local row, col = gallery.find(snap, "▎ " .. "\u{f06a9}")
  eq(row, 1)
  eq(gallery.hex(gallery.cell(snap, row, col).style.fg), role.hint)
end

T["a nonzero exit shows as error in the header"] = function()
  child:input("<F7>")
  wait_mode("t")
  settled({ "$ " })
  child:input("exit 3<CR>")
  -- The header follows the job's state change.
  child:wait(function(c)
    local _, header = row_of(c:screen(), "▎")
    return header:find("exited 3", 1, true) ~= nil
  end)
  local screen = child:screen()
  snapshot("shell-exited", screen)
  local _, line = row_of(screen, "▎")
  expect_has(line, "  exited 3")
  eq(line:find("running", 1, true), nil)
  local snap = gallery.capture(child, "exited 3")
  eq(colors_at(snap, "exited 3").fg, roles().error)
end

T["a float has a title, a state chip, and footer hints"] = function()
  child:lua("vim.cmd('IaraTermPosition float')")
  child:input("<F7>")
  wait_mode("t")
  local snap = gallery.capture(child, "● running ─┐")
  local role = roles()
  -- Focus is the border color; the title is accent text on the frame.
  local title = colors_at(snap, "Terminal · sh ")
  eq(title, { fg = role.accent, bg = role.mantle })
  eq(colors_at(snap, "─┐").fg, role.border_focus)
  eq(colors_at(snap, "F7").fg, role.accent)
  -- Docked headers are winbars; a float has none.
  eq(child:lua("return vim.wo.winbar"), "")
  child:input([[<C-\><C-n><C-w>p]])
  wait_mode("n")
  snap = gallery.capture(child, "local M")
  title = colors_at(snap, "Terminal · sh ")
  eq(title, { fg = role.muted, bg = role.mantle })
  -- Unfocused, the frame is the quiet `border` role.
  eq(colors_at(snap, "─┐").fg, role.border)
  local config = child:lua([[
    local win = require("iara.features.terminal.panel").shell:window()
    return vim.api.nvim_win_get_config(win)
  ]])
  eq(config.border, { "┌", "─", "┐", "│", "┘", "─", "└", "│" })
end

T["hiding, showing, and moving keep the header"] = function()
  child:input("<F7>")
  wait_mode("t")
  settled({ "F7 hide" })
  child:input("<F7>")
  wait_mode("n")
  eq(child:screen():find("▎", 1, true), nil)
  child:input("<F7>")
  wait_mode("t")
  local screen = settled({ "▎", "F7 hide" })
  expect_has(screen, "● running")
  child:lua("vim.cmd('IaraTermPosition float')")
  screen = settled({ "● running ─┐" })
  eq(child:lua("return vim.wo.winbar"), "")
  child:lua("vim.cmd('IaraTermPosition right')")
  screen = settled({ "▎" })
  eq(screen:find("─┐", 1, true), nil)
  eq(child:lua("return vim.api.nvim_win_get_config(0).title == nil"), true)
end

T["a file opened in a panel window loses the panel look"] = function()
  shell_in_normal_mode()
  local state = child:lua([[
    vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd() .. "/init.lua"))
    return { winbar = vim.wo.winbar, winhighlight = vim.wo.winhighlight }
  ]])
  eq(state, { winbar = "", winhighlight = "" })
end

T["terminal output and typing never rebuild headers"] = function()
  shell_in_normal_mode()
  child:lua([[
    local header = require("iara.features.terminal.header")
    local decorate = header.decorate
    _G.decorated = 0
    header.decorate = function(...)
      _G.decorated = _G.decorated + 1
      return decorate(...)
    end
  ]])
  child:input("i")
  wait_mode("t")
  child:input("i=0; while [ $i -lt 300 ]; do echo line$i; i=$((i+1)); done<CR>")
  settled({ "line299" })
  local before = child:lua("return _G.decorated")
  child:input([[<C-\><C-n><C-w>p]])
  wait_mode("n")
  local after_focus = child:lua("return _G.decorated")
  child:input("Oabcdefghijklmnopqrstuvwxyz<Esc>")
  settled({ "abcdefghijklmnopqrstuvwxyz" })
  eq(before, 0)
  -- Leaving the panel redraws its bar once per panel, and typing in
  -- the editor adds nothing.
  eq(after_focus, 1)
  eq(child:lua("return _G.decorated"), after_focus)
end

T["narrow headers drop the directory, then hints from the end"] = function()
  shell_in_normal_mode()
  local texts = child:lua([[
    local header = require("iara.features.terminal.header")
    local panel = require("iara.features.terminal.panel")
    local description = require("iara.features.terminal.title").describe(
      panel.shell:buffer())
    description.cwd = "/srv/project"
    local function text(chunks)
      return table.concat(vim.tbl_map(function(c) return c[1] end, chunks))
    end
    local result = {}
    for _, width in ipairs({ 120, 60, 40, 24 }) do
      local left, right = header.docked_chunks(description, width, false)
      table.insert(result, { text(left), text(right) })
    end
    return result
  ]])
  local wide, mid, narrow, tiny = unpack(texts)
  expect_has(wide[1], "  /srv/project  ● running")
  eq(wide[2], "F7 hide  ␣tn new  ^\\^n normal ")
  eq(mid[1]:find("/srv/project", 1, true), nil)
  eq(mid[2], "F7 hide  ␣tn new  ^\\^n normal ")
  eq(narrow[2], "F7 hide ")
  expect_has(tiny[1], "● running")
  eq(tiny[2], "")
end

T["panel and terminal status texts are readable in every theme"] = function()
  local low = child:lua([[
    local theme = require("iara.theme")
    local hl = require("iara.theme.highlights")
    local texts = { "IaraPanel", "IaraPanelTitle", "IaraPanelCwd",
      "IaraPanelRunning", "IaraPanelStopping", "IaraPanelExited",
      "IaraPanelDone", "IaraPanelKey", "IaraPanelHint",
      "IaraStatusTerminal", "IaraStatusAgent", "IaraStatusRunning",
      "IaraStatusExited" }
    local bars = { "IaraPanelBarShell", "IaraPanelBarAgent",
      "IaraPanelBarFocus" }
    local low = {}
    local function check(groups, name, group, ratio)
      local spec = groups[group]
      local value = hl.contrast(spec.fg, spec.bg)
      if value < ratio then
        table.insert(low, ("%s %s %.2f"):format(name, group, value))
      end
    end
    for _, name in ipairs(theme.THEMES) do
      local groups = hl.resolve(theme.palette(name))
      for _, group in ipairs(texts) do check(groups, name, group, 4.5) end
      for _, group in ipairs(bars) do check(groups, name, group, 3) end
    end
    return low
  ]])
  eq(low, {})
end

T["panel groups link to neutral groups under a foreign scheme"] = function()
  shell_in_normal_mode()
  local links = child:lua([[
    vim.cmd.colorscheme("default")
    local function link(name)
      return vim.api.nvim_get_hl(0, { name = name }).link
    end
    return { link("IaraPanel"), link("IaraPanelKey") }
  ]])
  eq(links, { "NormalFloat", "Special" })
end

return T
