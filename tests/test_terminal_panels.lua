-- Terminal and agent panels (UX2): positions, two independent panels,
-- and clean status and tab lines. Shells are real `/bin/sh` jobs; the
-- agents are fake `claude` and `codex` executables on a private PATH, so
-- the real CLIs are never started.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

local FAKE_AGENT = [[#!/bin/sh
echo READY
while read -r line; do
  case "$line" in
    exit*) exit "${line#exit }" ;;
    *) printf 'got=%s\n' "$line" ;;
  esac
done
]]

local CHILD_HELPERS = [[
local fake_bin, config = ...
vim.env.PATH = fake_bin .. ":/usr/bin:/bin"
vim.o.shell = "/bin/sh"
vim.g.mapleader = " "
-- As in the full editor: one status line for the whole screen.
vim.o.laststatus = 3
_G.messages = {}
vim.notify = function(message) table.insert(_G.messages, message) end
require("iara.core.term_retention").setup({})
terminal = require("iara.features.terminal")
terminal.setup(config)
agents = require("iara.extras.agents")
agents.setup(config)
registry = require("iara.features.terminal.registry")
panel = require("iara.features.terminal.panel")
statusline = require("iara.core.statusline")

function _G.edit(dir)
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/file.txt"))
  return require("iara.core.root").resolve(0)
end

---Size, layout, and float configuration of a panel in this tab.
function _G.panel_state(which)
  local win = panel[which]:window()
  if not win then return nil end
  local config = vim.api.nvim_win_get_config(win)
  return { win = win, bufnr = vim.api.nvim_win_get_buf(win),
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
    relative = config.relative, row = config.row, col = config.col,
    border = config.border, title = config.title,
    layout = vim.fn.winlayout(), columns = vim.o.columns,
    lines = vim.o.lines }
end

---The status line of `win` as drawn, without highlights.
function _G.status_text(win)
  vim.g.statusline_winid = win
  local text = statusline.render()
  vim.g.statusline_winid = nil
  return vim.api.nvim_eval_statusline(text, { winid = win }).str
end

function _G.tab_text()
  return vim.api.nvim_eval_statusline(statusline.tabline(),
    { use_tabline = true }).str
end

function _G.alive(record)
  return vim.fn.jobwait({ record.job }, 0)[1] == -1
end
]]

local CONFIG = { keymaps = {}, extras = { agents = {} } }

local function fake_bin()
  local dir = helpers.temp_dir()
  for _, name in ipairs({ "claude", "codex" }) do
    helpers.write_file(dir .. "/" .. name, FAKE_AGENT)
    vim.uv.fs_chmod(dir .. "/" .. name, tonumber("755", 8))
  end
  return dir
end

local function start(config)
  child.lua(CHILD_HELPERS, { fake_bin(), config or CONFIG })
  return child.lua("return edit(...)", { helpers.temp_dir() })
end

local function run(code, ...)
  return child.lua(code, { ... })
end

local function wait_mode(expected)
  vim.wait(10000, function()
    return child.api.nvim_get_mode().mode == expected
  end, 20)
  return child.api.nvim_get_mode().mode
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

-- Status and tab lines ----------------------------------------------------

T["a shell window's status line has a clean name, no term://"] = function()
  local project = start()
  local text = run([[
    terminal.toggle_main()
    return status_text(vim.api.nvim_get_current_win())
  ]])
  eq(text:find("term://", 1, true), nil)
  eq(text:find("[-]", 1, true), nil)
  match(text, "^  Terminal · sh  running")
  match(text, vim.pesc(project.label) .. " $")
  match(run("return statusline.render()"), "IaraStatusTerminal")
end

T["an agent window's status line names the agent"] = function()
  local project = start()
  local text = run([[
    agents.launch("claude")
    return status_text(vim.api.nvim_get_current_win())
  ]])
  eq(text:find("term://", 1, true), nil)
  match(text, "^  Claude Code  running")
  match(text, vim.pesc(project.label))
  match(run("return statusline.render()"), "IaraStatusAgent")
end

T["the status line shows an exit and file buffers keep theirs"] = function()
  start({ keymaps = {}, features = { terminal = { close_on_exit = false } } })
  local state = run([[
    local editor = vim.api.nvim_get_current_win()
    terminal.toggle_main()
    local main = registry.list()[1]
    vim.fn.chansend(main.job, "exit 3\n")
    vim.wait(10000, function()
      return registry.get(main.id).status == "exited"
    end, 20)
    return { terminal = status_text(panel.shell:window()),
      file = status_text(editor) }
  ]])
  match(state.terminal, " Terminal · sh  exited 3 ")
  match(state.file, "file%.txt")
  match(state.file, "%d+:%d+ $")
end

T["extra shells and native terminals are named cleanly"] = function()
  start()
  local state = run([[
    terminal.new()
    local shell = status_text(vim.api.nvim_get_current_win())
    vim.cmd.wincmd("p")
    vim.cmd.terminal()
    return { shell = shell, native = status_text(0) }
  ]])
  match(state.shell, "^  Terminal 2 · sh  running")
  match(state.native, "^  Terminal · sh  running")
  eq(state.native:find("term://", 1, true), nil)
end

T["the tab line names terminal tabs without term://"] = function()
  start()
  local text = run([[
    vim.cmd.tabnew()
    terminal.toggle_main()
    vim.cmd.only()
    return tab_text()
  ]])
  eq(text:find("term://", 1, true), nil)
  -- One label per tab (UX3 adds the file or terminal icon).
  match(text, "^ %S+ file%.txt  %S+ Terminal · sh $")
end

T["the theme colors terminal and agent labels"] = function()
  start()
  local colors = run([[
    local theme = require("iara.theme")
    theme.load("chocolate")
    local palette = theme.palette("chocolate").base_30
    local function bg(name)
      return ("#%06x"):format(vim.api.nvim_get_hl(0, { name = name }).bg)
    end
    return { terminal = bg("IaraStatusTerminal"), green = palette.green,
      agent = bg("IaraStatusAgent"), purple = palette.purple }
  ]])
  eq(colors.terminal, colors.green)
  eq(colors.agent, colors.purple)
end

-- Positions ---------------------------------------------------------------

T["top and left panels span the tab with their default size"] = function()
  start()
  local editor = run("return vim.api.nvim_get_current_win()")
  local top = run([[
    terminal.set_position("top")
    terminal.toggle_main()
    return panel_state("shell")
  ]])
  eq(top.layout, { "col", { { "leaf", top.win }, { "leaf", editor } } })
  eq(top.height, math.floor(top.lines / 3))
  local left = run([[
    terminal.set_position("left")
    return panel_state("shell")
  ]])
  eq(left.layout, { "row", { { "leaf", left.win }, { "leaf", editor } } })
  eq(left.width, math.floor(left.columns * 0.4))
end

T["a float is centered, straight, titled, and hides cleanly"] = function()
  start()
  local editor = run("return vim.api.nvim_get_current_win()")
  local state = run([[
    vim.cmd("IaraTermPosition float")
    terminal.toggle_main()
    return panel_state("shell")
  ]])
  eq(state.relative, "editor")
  eq(state.border, { "┌", "─", "┐", "│", "┘", "─", "└", "│" })
  -- The title names the terminal (V7 owns its look).
  local chunks = vim.tbl_map(function(c)
    return c[1]
  end, state.title)
  match(table.concat(chunks), " Terminal · sh ")
  eq(state.width, math.floor(state.columns * 0.8))
  local area = state.lines - 2
  eq(state.height, math.floor(area * 0.8))
  eq(state.row, math.floor((area - state.height - 2) / 2))
  eq(state.col, math.floor((state.columns - state.width - 2) / 2))
  eq(state.layout, { "leaf", editor })
  local after = run([[
    terminal.toggle_main()
    local main = registry.list()[1]
    return { wins = #vim.api.nvim_list_wins(), alive = alive(main),
      current = vim.api.nvim_get_current_win(),
      valid = vim.api.nvim_buf_is_valid(main.bufnr) }
  ]])
  eq(after, { wins = 1, alive = true, current = editor, valid = true })
end

T["a float stays in its tab and moves to another one"] = function()
  start()
  local state = run([[
    terminal.set_position("float")
    terminal.toggle_main()
    vim.cmd.stopinsert()
    local first = vim.api.nvim_get_current_tabpage()
    vim.cmd.wincmd("p")
    vim.cmd.tabnew(vim.fn.fnameescape(vim.api.nvim_buf_get_name(0)))
    local away = panel_state("shell")
    vim.api.nvim_set_current_tabpage(first)
    local back = panel_state("shell")
    vim.cmd.tabnext()
    terminal.toggle_main()
    local moved = panel_state("shell")
    vim.api.nvim_set_current_tabpage(first)
    return { away = away, back = back, moved = moved,
      left = panel_state("shell"),
      records = #registry.list(),
      windows = #vim.fn.win_findbuf(registry.list()[1].bufnr) }
  ]])
  eq(state.away, nil)
  eq(state.back.relative, "editor")
  eq(state.moved.relative, "editor")
  eq(state.left, nil)
  eq({ state.records, state.windows }, { 1, 1 })
end

T["each position remembers its own size"] = function()
  start()
  local state = run([[
    terminal.set_position("top")
    terminal.toggle_main()
    vim.api.nvim_win_set_height(0, 5)
    terminal.set_position("bottom")
    local bottom = panel_state("shell").height
    terminal.set_position("float")
    vim.api.nvim_win_set_config(0, { width = 40, height = 9 })
    terminal.set_position("top")
    local top = panel_state("shell").height
    terminal.set_position("float")
    local float = panel_state("shell")
    return { bottom = bottom, top = top,
      float = { float.width, float.height }, lines = vim.o.lines }
  ]])
  eq(state.bottom, math.floor(state.lines / 3))
  eq(state.top, 5)
  eq(state.float, { 40, 9 })
end

-- Two panels --------------------------------------------------------------

T["a shell at the bottom and an agent at the right coexist"] = function()
  start()
  local editor = run("return vim.api.nvim_get_current_win()")
  local state = run([[
    terminal.toggle_main()
    vim.cmd.stopinsert()
    agents.launch("claude")
    vim.cmd.stopinsert()
    return { shell = panel_state("shell"), agent = panel_state("agent") }
  ]])
  local shell, agent = state.shell, state.agent
  eq(shell.layout, {
    "row",
    {
      { "col", { { "leaf", editor }, { "leaf", shell.win } } },
      { "leaf", agent.win },
    },
  })
  eq(agent.width, math.floor(agent.columns * 0.4))
  eq(shell.height, math.floor(shell.lines / 3))
  eq(run("return registry.get(1).role"), "main")
  eq(run("return registry.get(2).role"), "agent")
end

T["F7 and Space at toggle their own panel only"] = function()
  start()
  local editor = run("return vim.api.nvim_get_current_win()")
  run("agents.launch('codex'); vim.cmd.stopinsert()")
  run("vim.api.nvim_set_current_win(...)", editor)
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  child.type_keys("<F7>")
  eq(wait_mode("n"), "n")
  local after_f7 = run([[
    return { shell = panel_state("shell") ~= nil,
      agent = panel_state("agent") ~= nil }
  ]])
  eq(after_f7, { shell = false, agent = true })
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  child.type_keys([[<C-\><C-n>]], "<C-w>p", " at")
  local after_at = run([[
    return { shell = panel_state("shell") ~= nil,
      agent = panel_state("agent") ~= nil,
      alive = alive(registry.list({ role = "agent" })[1]) }
  ]])
  eq(after_at, { shell = true, agent = false, alive = true })
  child.type_keys(" at")
  eq(wait_mode("t"), "t")
  eq(run("return panel.agent:buffer() == registry.get(1).bufnr"), true)
end

T["F7 in a focused agent panel hides only that panel"] = function()
  start()
  run("terminal.toggle_main(); vim.cmd.stopinsert()")
  run("vim.cmd.wincmd('p'); agents.launch('claude')")
  eq(wait_mode("t"), "t")
  child.type_keys("<F7>")
  eq(wait_mode("n"), "n")
  eq(run("return panel_state('agent')"), vim.NIL)
  eq(run("return panel_state('shell') ~= nil"), true)
end

T["Space ap cycles the agent panel and keeps the session"] = function()
  start()
  local editor = run("return vim.api.nvim_get_current_win()")
  local before = run([[
    agents.launch("claude")
    return panel_state("agent")
  ]])
  eq(wait_mode("t"), "t")
  child.type_keys([[<C-\><C-n>]], " ap")
  local top = run("return panel_state('agent')")
  eq(top.layout, { "col", { { "leaf", top.win }, { "leaf", editor } } })
  eq({ top.win, top.bufnr }, { before.win, before.bufnr })
  local record = run("return registry.list()[1]")
  eq({ record.generation, record.status }, { 1, "running" })
  eq(run("return alive(...)", record), true)
  child.type_keys(" ap", " ap")
  eq(run("return panel_state('agent').relative"), "editor")
  local title = run("return panel_state('agent').title")
  local text = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, title))
  match(text, " Claude Code ")
end

T["Space at with no session offers the agent picker"] = function()
  start()
  local offered = run([[
    vim.ui.select = function(items, opts, on_choice)
      _G.offered = vim.tbl_map(opts.format_item, items)
      on_choice(nil)
    end
    agents.toggle()
    return _G.offered
  ]])
  match(offered[1], "^New Claude Code session")
  eq(run("return #registry.list()"), 0)
end

-- Agent positions ---------------------------------------------------------

T["per-agent positions override the agents' default"] = function()
  start({
    keymaps = {},
    extras = { agents = { position = "float", codex = { position = "top" } } },
  })
  local editor = run("return vim.api.nvim_get_current_win()")
  local claude = run("agents.launch('claude'); return panel_state('agent')")
  eq(claude.relative, "editor")
  local codex = run(
    [[
    vim.api.nvim_set_current_win(...)
    agents.launch("codex")
    return panel_state("agent")
  ]],
    editor
  )
  eq(codex.layout, { "col", { { "leaf", codex.win }, { "leaf", editor } } })
  eq(codex.win, claude.win)
  eq(run("return #vim.api.nvim_list_wins()"), 2)
end

T["invalid agent positions are reported and the default used"] = function()
  start({
    keymaps = {},
    extras = { agents = { position = "middle", claude = { position = 3 } } },
  })
  local messages = table.concat(run("return _G.messages"), "\n")
  match(messages, 'unknown agent position "middle"')
  match(messages, "extras.agents.claude position must be one of")
  local editor = run("return vim.api.nvim_get_current_win()")
  local state = run("agents.launch('claude'); return panel_state('agent')")
  eq(state.layout, { "row", { { "leaf", editor }, { "leaf", state.win } } })
end

T[":IaraAgent opens an agent at a chosen position"] = function()
  start()
  local editor = run("return vim.api.nvim_get_current_win()")
  local left =
    run("vim.cmd('IaraAgent claude left'); return panel_state('agent')")
  eq(left.layout, { "row", { { "leaf", left.win }, { "leaf", editor } } })
  -- The choice sticks to claude; codex keeps the default (right).
  local codex = run(
    [[
    vim.api.nvim_set_current_win(...)
    vim.cmd("IaraAgent codex")
    return panel_state("agent")
  ]],
    editor
  )
  eq(codex.layout, { "row", { { "leaf", editor }, { "leaf", codex.win } } })
  local again = run(
    [[
    vim.api.nvim_set_current_win(...)
    vim.cmd("IaraAgent claude")
    return panel_state("agent")
  ]],
    editor
  )
  eq(again.layout, { "row", { { "leaf", again.win }, { "leaf", editor } } })
  run("vim.cmd('IaraAgent claude nowhere')")
  match(table.concat(run("return _G.messages"), "\n"), '"nowhere"')
  eq(run("return #registry.list()"), 2)
end

T[":IaraAgentPosition moves the panel for every agent"] = function()
  start({
    keymaps = {},
    extras = { agents = { codex = { position = "left" } } },
  })
  local editor = run("return vim.api.nvim_get_current_win()")
  local state = run(
    [[
    local editor = ...
    agents.launch("claude")
    vim.cmd("IaraAgentPosition bottom")
    local claude = panel_state("agent")
    vim.api.nvim_set_current_win(editor)
    agents.launch("codex")
    return { claude = claude, codex = panel_state("agent") }
  ]],
    editor
  )
  for _, shown in pairs(state) do
    eq(shown.layout, { "col", { { "leaf", editor }, { "leaf", shown.win } } })
  end
  run("vim.cmd('IaraAgentPosition up')")
  match(table.concat(run("return _G.messages"), "\n"), 'position "up"')
end

return T
