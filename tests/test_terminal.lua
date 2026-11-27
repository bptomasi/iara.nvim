local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

---Child-side helpers. Terminals are real PTY jobs; the default shell is
---/bin/sh and `vim.notify` messages are collected for assertions.
local CHILD_HELPERS = [[
vim.o.shell = "/bin/sh"
vim.g.mapleader = " "
_G.messages = {}
_G.native_notify = vim.notify
vim.notify = function(message) table.insert(_G.messages, message) end
require("iara.core.term_retention").setup({})
terminal = require("iara.features.terminal")
registry = require("iara.features.terminal.registry")
root_mod = require("iara.core.root")
terminal.setup({ keymaps = _G.user_keymaps or {},
  features = { terminal = _G.terminal_options } })

---Edit `name` inside project `dir`, which gets a `.git` marker.
function _G.edit(dir, name)
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. (name or "file.txt")))
  return root_mod.resolve(0)
end

---Windows of the current tab that show an Iara terminal record.
function _G.panel_windows()
  local result = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    for _, record in ipairs(registry.list()) do
      if record.bufnr == bufnr then
        table.insert(result, { win = win, id = record.id,
          project = record.project, role = record.role })
      end
    end
  end
  return result
end

function _G.main_of(project_root)
  return registry.main_for(project_root)
end

function _G.alive(record)
  return vim.fn.jobwait({ record.job }, 0)[1] == -1
end

function _G.text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function _G.wait_text(bufnr, pattern)
  vim.wait(10000, function() return text(bufnr):find(pattern) ~= nil end, 20)
  return text(bufnr)
end
]]

local function run(code, ...)
  if not child.lua_get("_G.terminal ~= nil") then
    child.lua(CHILD_HELPERS)
  end
  return child.lua(code, { ... })
end

---Load the helpers with these personal keymaps before the first action.
local function start_with_keymaps(keymaps)
  child.lua("_G.user_keymaps = ...", { keymaps })
end

---Load the helpers with these `features.terminal` options.
local function start_with_options(options)
  child.lua("_G.terminal_options = ...", { options })
end

local function mode()
  return child.api.nvim_get_mode().mode
end

---Wait for the child to reach `expected` mode; mode changes requested
---by an action happen when the child processes its input queue.
local function wait_mode(expected)
  vim.wait(10000, function()
    return mode() == expected
  end, 20)
  return mode()
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

T["F7 shows the project's main terminal with input focus"] = function()
  local project = run("return edit(...)", helpers.temp_dir())
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  local state = run([[
    local main = main_of(root_mod.resolve(vim.fn.bufnr("file.txt")))
    return { main = main, panels = panel_windows(),
      current = vim.api.nvim_get_current_win(),
      height = vim.api.nvim_win_get_height(0), lines = vim.o.lines }
  ]])
  eq(state.main.project, project.worktree_id)
  eq(state.main.cwd, project.path)
  eq(state.main.status, "running")
  eq(#state.panels, 1)
  eq(state.panels[1].win, state.current)
  eq(state.height, math.floor(state.lines / 3))
end

T["F7 in terminal input hides the panel and keeps the job"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  child.type_keys("<F7>")
  eq(wait_mode("n"), "n")
  local state = run([[
    local main = main_of(root_mod.resolve(0))
    return { panels = #panel_windows(), alive = alive(main),
      status = main.status, current = vim.api.nvim_get_current_win() }
  ]])
  eq(state.panels, 0)
  eq(state.alive, true)
  eq(state.status, "running")
  eq(state.current, editor)
end

local navigation = MiniTest.new_set({
  parametrize = {
    { "right", "<C-h>" },
    { "top", "<C-j>" },
    { "bottom", "<C-k>" },
    { "left", "<C-l>" },
  },
})
T["window navigation"] = navigation

navigation["moves focus directly from terminal input"] = function(position, key)
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  run("terminal.set_position(...); terminal.toggle_main()", position)
  eq(wait_mode("t"), "t")
  local panels = run("return panel_windows()")
  child.type_keys(key)
  eq(wait_mode("n"), "n")
  eq(run("return vim.api.nvim_get_current_win()"), editor)
  eq(run("return panel_windows()"), panels)
  eq(run("return alive(registry.list()[1])"), true)
end

T["toggle hides a visible panel from another window"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  child.type_keys([[<C-\><C-n>]])
  eq(wait_mode("nt"), "nt")
  run("vim.api.nvim_set_current_win(...)", editor)
  child.type_keys("<F7>")
  eq(run("return #panel_windows()"), 0)
  eq(run("return vim.api.nvim_get_current_win()"), editor)
  eq(mode(), "n")
end

T["showing again reuses the same buffer and process"] = function()
  run("edit(...)", helpers.temp_dir())
  local first = run([[
    terminal.toggle_main()
    local main = main_of(root_mod.resolve(0))
    terminal.toggle_main()
    return main
  ]])
  local second = run([[
    terminal.toggle_main()
    return main_of(root_mod.resolve(0))
  ]])
  eq(second.id, first.id)
  eq(second.bufnr, first.bufnr)
  eq(second.job, first.job)
  eq(second.generation, 1)
  eq(run("return #registry.list()"), 1)
end

T["F7 from another project switches the panel to its terminal"] = function()
  local a = run("return edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  run("terminal.toggle_main()")
  run("vim.api.nvim_set_current_win(...)", editor)
  local b = run("return edit(...)", helpers.temp_dir())
  run("terminal.toggle_main()")
  local state = run(
    [[
    local a, b = ...
    return { panels = panel_windows(), a = main_of(a), b = main_of(b) }
  ]],
    a,
    b
  )
  eq(#state.panels, 1)
  eq(state.panels[1].project, b.worktree_id)
  eq(state.a.project, a.worktree_id)
  eq(state.b.project, b.worktree_id)
  eq(run("return alive(...)", state.a), true)
  -- From project B's buffer the next toggle hides B's terminal.
  run("vim.api.nvim_set_current_win(...)", editor)
  run("terminal.toggle_main()")
  eq(run("return #panel_windows()"), 0)
end

T["one panel moves between tabs"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local file = vim.api.nvim_buf_get_name(0)
    terminal.toggle_main()
    vim.cmd.tabnew(vim.fn.fnameescape(file))
    terminal.toggle_main()
    local main = registry.list()[1]
    local second_tab = panel_windows()
    vim.cmd.tabfirst()
    return { main = main, second_tab = second_tab,
      first_tab = #panel_windows(), records = #registry.list(),
      windows = #vim.fn.win_findbuf(main.bufnr) }
  ]])
  eq(#state.second_tab, 1)
  eq(state.second_tab[1].id, state.main.id)
  eq(state.first_tab, 0)
  eq(state.windows, 1)
  eq(state.records, 1)
end

T["focus is idempotent and never hides"] = function()
  run("edit(...)", helpers.temp_dir())
  run("terminal.focus_main()")
  eq(wait_mode("t"), "t")
  local first = run("return panel_windows()")
  run("terminal.focus_main()")
  eq(wait_mode("t"), "t")
  local editor_state = run([[
    vim.cmd.stopinsert()
    return panel_windows()
  ]])
  eq(editor_state, first)
  -- From the editing window, focus goes back to the same panel.
  run("vim.cmd.wincmd('p'); terminal.focus_main()")
  eq(run("return panel_windows()"), first)
  eq(run("return vim.api.nvim_get_current_win()"), first[1].win)
  eq(#run("return registry.list()"), 1)
end

T["Esc and Ctrl+c reach the program; Ctrl+\\ Ctrl+n leaves input"] = function()
  local dir = helpers.temp_dir()
  local script = dir .. "/keys.sh"
  helpers.write_file(
    script,
    table.concat({
      "#!/bin/sh",
      "trap 'echo GOT_INT' INT",
      "stty -icanon -echo min 1",
      "echo READY",
      "while :; do od -An -tx1 -N1; done",
      "",
    }, "\n")
  )
  vim.uv.fs_chmod(script, 493)
  run("local shell, dir = ...; vim.o.shell = shell; edit(dir)", script, dir)
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  local bufnr = run("return vim.api.nvim_get_current_buf()")
  run("wait_text(..., 'READY')", bufnr)
  child.type_keys("<Esc>")
  match(run("return wait_text(..., ' 1b')", bufnr), " 1b")
  eq(mode(), "t")
  child.type_keys("<C-c>")
  match(run("return wait_text(..., 'GOT_INT')", bufnr), "GOT_INT")
  eq(mode(), "t")
  child.type_keys("<C-l>")
  match(run("return wait_text(..., ' 0c')", bufnr), " 0c")
  eq(mode(), "t")
  child.type_keys([[<C-\><C-n>]])
  eq(wait_mode("nt"), "nt")
  eq(run("return alive(registry.list()[1])"), true)
end

T[":IaraTermExit leaves terminal input from a mapping"] = function()
  run("edit(...)", helpers.temp_dir())
  run([[
    vim.keymap.set("t", "<F8>", "<Cmd>IaraTermExit<CR>")
    terminal.toggle_main()
  ]])
  eq(wait_mode("t"), "t")
  child.type_keys("<F8>")
  eq(wait_mode("nt"), "nt")
  eq(run("return #panel_windows()"), 1)
end

T["terminal input has no leader mappings"] = function()
  run("edit(...)", helpers.temp_dir())
  run("terminal.toggle_main()")
  local maps = run([[
    local lhs = {}
    local bufnr = vim.api.nvim_get_current_buf()
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "t")) do
      table.insert(lhs, map.lhs:lower())
    end
    for _, map in ipairs(vim.api.nvim_get_keymap("t")) do
      table.insert(lhs, map.lhs:lower())
    end
    table.sort(lhs)
    return lhs
  ]])
  eq(maps, { "<c-h>", "<c-j>", "<c-k>", "<c-l>", "<f7>" })
end

T["entering a hidden terminal buffer does not start input"] = function()
  run("edit(...)", helpers.temp_dir())
  run("terminal.toggle_main(); terminal.toggle_main()")
  eq(wait_mode("n"), "n")
  run("vim.cmd.buffer(registry.list()[1].bufnr)")
  eq(mode(), "nt")
end

T["unowned terminals keep native F7"] = function()
  run("edit(...)", helpers.temp_dir())
  local maps = run([[
    vim.cmd.terminal()
    return vim.api.nvim_buf_get_keymap(0, "t")
  ]])
  eq(maps, {})
end

T["Space tn and Space tl create and select terminals"] = function()
  local a = run("return edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys(" tn")
  eq(wait_mode("t"), "t")
  run("vim.cmd.stopinsert(); vim.api.nvim_set_current_win(...)", editor)
  local b = run("return edit(...)", helpers.temp_dir())
  run("terminal.toggle_main(); vim.cmd.stopinsert()")
  local items = run([[
    _G.offered = nil
    vim.ui.select = function(items, opts, on_choice)
      _G.offered = vim.tbl_map(opts.format_item, items)
      on_choice(items[1])
    end
    terminal.select()
    vim.wait(1000, function() return panel_windows()[1].role == "shell" end)
    return _G.offered
  ]])
  eq(#items, 2)
  match(items[1], vim.pesc(a.label) .. " shell 1")
  match(items[2], vim.pesc(b.label) .. " main")
  local shown = run("return panel_windows()")
  eq(shown[1].project, a.worktree_id)
  eq(shown[1].role, "shell")
end

T["a cancelled selection changes nothing"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    terminal.toggle_main(); terminal.toggle_main()
    local before = vim.api.nvim_get_current_win()
    vim.ui.select = function(_, _, on_choice) on_choice(nil) end
    terminal.select()
    vim.wait(50)
    return { before = before, after = vim.api.nvim_get_current_win(),
      panels = #panel_windows() }
  ]])
  eq(state.after, state.before)
  eq(state.panels, 0)
end

T["Space t. starts in the file directory"] = function()
  local dir = helpers.temp_dir()
  vim.fn.mkdir(dir .. "/sub", "p")
  local project = run("return edit(..., 'sub/x.txt')", dir)
  run("vim.cmd('normal! ix'); terminal.new_here()")
  local record = run("return registry.list()[1]")
  eq(record.cwd, project.path .. "/sub")
  eq(record.project, project.worktree_id)
  eq(record.role, "shell")
end

T["Space t. refuses a buffer without a file"] = function()
  local state = run([[
    vim.cmd.enew()
    terminal.new_here()
    return { records = #registry.list(), messages = _G.messages }
  ]])
  eq(state.records, 0)
  match(state.messages[1], "not a file")
end

T["exited main terminal is shown, not restarted, when kept"] = function()
  start_with_options({ close_on_exit = false })
  run("edit(...)", helpers.temp_dir())
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  local before = run([[
    local main = main_of(root_mod.resolve(0))
    vim.fn.chansend(main.job, "exit 4\n")
    vim.wait(10000, function()
      return registry.get(main.id).status == "exited"
    end)
    return main
  ]])
  child.type_keys([[<C-\><C-n>]], "<C-w>p", "<F7>")
  eq(run("return #panel_windows()"), 0)
  child.type_keys("<F7>")
  local state = run(
    [[
    return { after = registry.get(...), panels = panel_windows(),
      current = vim.api.nvim_get_current_buf() }
  ]],
    before.id
  )
  eq(state.after.status, "exited")
  eq(state.after.exit_code, 4)
  eq(state.after.generation, 1)
  eq(state.current, before.bufnr)
  eq(state.panels[1].id, before.id)
  eq(wait_mode("nt"), "nt")
end

T["refused creation reports the registry error"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    registry.LIMITS.running = 0
    terminal.toggle_main()
    return { panels = #panel_windows(), messages = _G.messages }
  ]])
  eq(state.panels, 0)
  match(state.messages[1], "^Iara: 0 terminals are running")
end

T["hiding the only window keeps the tab and the job"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    terminal.toggle_main()
    vim.cmd.only()
    terminal.toggle_main()
    local main = registry.list()[1]
    return { wins = #vim.api.nvim_tabpage_list_wins(0),
      buftype = vim.bo.buftype, alive = alive(main) }
  ]])
  eq(state.wins, 1)
  eq(state.buftype, "")
  eq(state.alive, true)
end

T["personal keymaps replace or remove the defaults"] = function()
  start_with_keymaps({
    ["n <F7>"] = false,
    ["t <F7>"] = false,
    ["t <C-h>"] = false,
  })
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    terminal.toggle_main()
    return {
      normal = vim.fn.maparg("<F7>", "n"),
      leader = vim.fn.maparg("<leader>tt", "n", false, true).desc,
      f7 = vim.fn.maparg("<F7>", "t"),
      left = vim.fn.maparg("<C-h>", "t"),
    }
  ]])
  eq(state.normal, "")
  eq(state.leader, "Toggle main terminal")
  eq(state.f7, "")
  eq(state.left, "")
end

-- T4: side panel and close on exit.

---Layout of the current tab with the panel's size and record.
local PANEL_STATE = [[
  local panel = panel_windows()[1]
  local win = panel and panel.win
  return { layout = vim.fn.winlayout(), win = win,
    id = panel and panel.id,
    bufnr = win and vim.api.nvim_win_get_buf(win),
    width = win and vim.api.nvim_win_get_width(win),
    height = win and vim.api.nvim_win_get_height(win),
    columns = vim.o.columns, lines = vim.o.lines,
    current = vim.api.nvim_get_current_win() }
]]

---Whether the layout is the editor beside (row) or above (col) the panel.
local function expect_layout(state, kind, editor)
  eq(state.layout, { kind, { { "leaf", editor }, { "leaf", state.win } } })
end

---Wait until no record is left and return what remains of the panel.
local function wait_disposed()
  return run([[
    vim.wait(10000, function() return #registry.list() == 0 end, 20)
    return { records = #registry.list(), panels = #panel_windows(),
      current = vim.api.nvim_get_current_win(),
      buftype = vim.bo.buftype }
  ]])
end

T["Space ts shows the main terminal at the right"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys(" ts")
  eq(wait_mode("t"), "t")
  local state = run(PANEL_STATE)
  expect_layout(state, "row", editor)
  eq(state.current, state.win)
  eq(state.width, math.floor(state.columns * 0.4))
  eq(run("return registry.get(...).role", state.id), "main")
end

-- UX2: Space tv cycles bottom, right, top, left, float (it used to swap
-- bottom and right only), so this case walks the whole cycle.
T["Space tv cycles the panel and keeps its job and buffer"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  local bottom = run(PANEL_STATE)
  local job = run("return registry.list()[1].job")
  child.type_keys([[<C-\><C-n>]], " tv")
  local right = run(PANEL_STATE)
  expect_layout(right, "row", editor)
  eq({ right.win, right.bufnr }, { bottom.win, bottom.bufnr })
  eq(right.width, math.floor(right.columns * 0.4))
  -- A width set by the user is remembered for the next visit.
  run("vim.api.nvim_win_set_width(0, 30)")
  child.type_keys(" tv")
  local top = run(PANEL_STATE)
  eq(top.layout, { "col", { { "leaf", top.win }, { "leaf", editor } } })
  eq(top.height, bottom.height)
  child.type_keys(" tv")
  local left = run(PANEL_STATE)
  eq(left.layout, { "row", { { "leaf", left.win }, { "leaf", editor } } })
  child.type_keys(" tv")
  eq(run("return vim.api.nvim_win_get_config(0).relative"), "editor")
  child.type_keys(" tv")
  expect_layout(run(PANEL_STATE), "col", editor)
  child.type_keys(" tv")
  local again = run(PANEL_STATE)
  eq({ again.win, again.width }, { bottom.win, 30 })
  local record = run("return registry.list()[1]")
  eq({ record.job, record.generation, record.status }, { job, 1, "running" })
  eq(#run("return registry.list()"), 1)
end

T["Space tv on a hidden panel shows it at the other side"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys(" tv")
  eq(wait_mode("t"), "t")
  expect_layout(run(PANEL_STATE), "row", editor)
end

T[":IaraTermPosition moves the panel and leaves focus alone"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run([[
    local editor = vim.api.nvim_get_current_win()
    terminal.toggle_main()
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(editor)
    vim.cmd("IaraTermPosition right")
    return editor
  ]])
  local state = run(PANEL_STATE)
  expect_layout(state, "row", editor)
  eq(state.current, editor)
  run("vim.cmd('IaraTermPosition middle')")
  match(run("return _G.messages[1]"), 'unknown terminal position "middle"')
  expect_layout(run(PANEL_STATE), "row", editor)
end

T["position setting opens the panel at the right"] = function()
  start_with_options({ position = "right" })
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  run("terminal.toggle_main()")
  expect_layout(run(PANEL_STATE), "row", editor)
end

T["a shown panel moves to the configured side in a new tab"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local file = vim.api.nvim_buf_get_name(0)
    terminal.toggle_main()
    terminal.set_position("right")
    vim.cmd.tabnew(vim.fn.fnameescape(file))
    local editor = vim.api.nvim_get_current_win()
    terminal.toggle_main()
    local second = panel_windows()
    vim.cmd.tabfirst()
    return { editor = editor, second = second, first = #panel_windows(),
      layout = (function() vim.cmd.tablast(); return vim.fn.winlayout() end)() }
  ]])
  eq(state.first, 0)
  eq(#state.second, 1)
  eq(state.layout, {
    "row",
    { { "leaf", state.editor }, { "leaf", state.second[1].win } },
  })
end

local eof = MiniTest.new_set({ parametrize = { { false }, { true } } })
T["shell EOF"] = eof

eof["Ctrl+D closes the panel and disposes it"] = function(switch_windows)
  run("edit(...)", helpers.temp_dir())
  run([[
    require("iara.core.keymaps").setup({})
    terminal.set_position("right")
  ]])
  local editor = run("return vim.api.nvim_get_current_win()")
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  local bufnr = run("return vim.api.nvim_get_current_buf()")
  run("wait_text(..., '%$')", bufnr)
  if switch_windows then
    child.type_keys("<C-h>")
    eq(wait_mode("n"), "n")
    eq(run("return vim.api.nvim_get_current_win()"), editor)
    child.type_keys("<C-l><C-d>")
  else
    child.type_keys("<C-d>")
  end
  local state = wait_disposed()
  eq(state, { records = 0, panels = 0, current = editor, buftype = "" })
  eq(wait_mode("n"), "n")
  eq(run("return vim.api.nvim_buf_is_valid(...)", bufnr), false)
  -- F7 afterwards starts a fresh main terminal.
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  eq(run("return registry.list()[1].status"), "running")
end

T["a nonzero exit such as 130 also closes the panel"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run([[
    local editor = vim.api.nvim_get_current_win()
    terminal.toggle_main()
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(editor)
    vim.fn.chansend(registry.list()[1].job, "exit 130\n")
    return editor
  ]])
  local state = wait_disposed()
  eq(state, { records = 0, panels = 0, current = editor, buftype = "" })
end

T["a shell exiting while hidden is disposed without a window"] = function()
  run("edit(...)", helpers.temp_dir())
  run([[
    terminal.toggle_main(); terminal.toggle_main()
    _G.wins = #vim.api.nvim_list_wins()
    vim.fn.chansend(registry.list()[1].job, "exit 0\n")
  ]])
  local state = wait_disposed()
  eq(state.records, 0)
  eq(run("return #vim.api.nvim_list_wins() == _G.wins"), true)
end

T["close_on_exit = false keeps the transcript of an exit"] = function()
  start_with_options({ close_on_exit = false })
  run("edit(...)", helpers.temp_dir())
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  local state = run([[
    local main = registry.list()[1]
    vim.fn.chansend(main.job, "echo KEPT; exit 0\n")
    vim.wait(10000, function()
      return registry.get(main.id).status == "exited"
    end, 20)
    -- Give a wrongly scheduled close the chance to run.
    vim.wait(100)
    return { record = registry.get(main.id), panels = panel_windows(),
      text = text(main.bufnr) }
  ]])
  eq(state.record.exit_code, 0)
  eq(state.panels[1].id, state.record.id)
  match(state.text, "KEPT")
end

T["an invalid close_on_exit is reported and closes"] = function()
  start_with_options({ close_on_exit = "yes", position = "sideways" })
  run("edit(...)", helpers.temp_dir())
  local messages = table.concat(run("return _G.messages"), "\n")
  match(messages, "close_on_exit must be a boolean")
  match(messages, 'unknown terminal position "sideways"')
  run([[
    terminal.toggle_main()
    vim.fn.chansend(registry.list()[1].job, "exit 1\n")
  ]])
  eq(wait_disposed().records, 0)
end

---Text of the command line, the last screen row.
local function command_line()
  local screenshot = child.get_screenshot()
  return table.concat(screenshot.text[#screenshot.text])
end

T["the 'no terminals yet' message does not outlive F7"] = function()
  run("edit(...)", helpers.temp_dir())
  -- As in the full editor: real messages and no mode message.
  run("vim.notify = _G.native_notify; vim.o.showmode = false")
  child.type_keys(" tl")
  match(command_line(), "no terminals yet")
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  eq(vim.trim(command_line()), "")
end

return T
