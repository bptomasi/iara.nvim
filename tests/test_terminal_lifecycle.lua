--- Terminal lifecycle proofs of gate G3 (T2 M2 scope, task M2-T):
--- aborted and actual quit, manual buffer deletion, exits while hidden,
--- and output from a hidden job. Every case runs real PTY jobs in a
--- headless child Neovim; waits poll instead of sleeping.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

local CHILD_HELPERS = [[
vim.o.shell = "/bin/sh"
vim.g.mapleader = " "
_G.messages = {}
vim.notify = function(message) table.insert(_G.messages, message) end
require("iara.core.term_retention").setup({})
terminal = require("iara.features.terminal")
registry = require("iara.features.terminal.registry")
root_mod = require("iara.core.root")
terminal.setup({ features = { terminal = _G.terminal_options } })

_G.events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "IaraTerminalChanged",
  callback = function(args) table.insert(_G.events, args.data) end,
})

function _G.edit(dir)
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/file.txt"))
  return root_mod.resolve(0)
end

function _G.text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function _G.wait_for(predicate)
  return vim.wait(10000, predicate, 20)
end

function _G.wait_text(bufnr, pattern)
  wait_for(function() return text(bufnr):find(pattern) ~= nil end)
  return text(bufnr)
end

---Process id of a running job, or nil.
function _G.pid(job)
  local ok, value = pcall(vim.fn.jobpid, job)
  return ok and value or nil
end

function _G.panel_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    for _, record in ipairs(registry.list()) do
      if record.bufnr == bufnr then count = count + 1 end
    end
  end
  return count
end

---Start the main terminal, hide it, and wait for its prompt.
function _G.hidden_main()
  terminal.toggle_main()
  terminal.toggle_main()
  local main = registry.main_for(root_mod.resolve(0))
  wait_text(main.bufnr, "%$")
  return main
end
]]

local function run(code, ...)
  if not child.lua_get("_G.terminal ~= nil") then
    child.lua(CHILD_HELPERS)
  end
  return child.lua(code, { ... })
end

local function start_with_options(options)
  child.lua("_G.terminal_options = ...", { options })
end

---Whether a process exists, seen from the test process.
local function process_alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

local function wait_process_gone(pid)
  vim.wait(10000, function()
    return not process_alive(pid)
  end, 20)
  return process_alive(pid)
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

T["aborted quit keeps shells, transcripts, and edits"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local main = hidden_main()
    terminal.new()
    vim.cmd.stopinsert()
    local shell = registry.list({ role = "shell" })[1]
    vim.fn.chansend(main.job, "echo BEFORE-$((20+22))\n")
    wait_text(main.bufnr, "BEFORE%-42")
    vim.cmd.wincmd("p")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved edit" })
    local ok, err = pcall(vim.cmd, "qa")
    return { ok = ok, err = err, main = main, shell = shell }
  ]])
  eq(state.ok, false)
  match(state.err, "E37")
  local after = run(
    [[
    local main, shell = ...
    vim.fn.chansend(main.job, "echo AFTER-$((1+1))\n")
    return { main = registry.get(main.id), shell = registry.get(shell.id),
      text = wait_text(main.bufnr, "AFTER%-2"), panels = panel_count(),
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
      modified = vim.bo.modified, events = _G.events }
  ]],
    state.main,
    state.shell
  )
  eq(after.main.status, "running")
  eq(after.shell.status, "running")
  eq(after.main.job, state.main.job)
  match(after.text, "BEFORE%-42")
  match(after.text, "AFTER%-2")
  eq(after.panels, 1)
  eq(after.lines, { "unsaved edit" })
  eq(after.modified, true)
  for _, event in ipairs(after.events) do
    eq(event.status == "stopping" or event.status == "disposed", false)
  end
end

T["aborted quit keeps an exited transcript"] = function()
  start_with_options({ close_on_exit = false })
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local main = hidden_main()
    vim.fn.chansend(main.job, "echo LAST-$((3*3)); exit 2\n")
    wait_for(function() return registry.get(main.id).status == "exited" end)
    vim.bo.modified = true
    local ok = pcall(vim.cmd, "qa")
    return { ok = ok, main = registry.get(main.id), text = text(main.bufnr) }
  ]])
  eq(state.ok, false)
  eq(state.main.status, "exited")
  eq(state.main.exit_code, 2)
  match(state.text, "LAST%-9")
end

T["quitting stops every shell without waiting"] = function()
  run("edit(...)", helpers.temp_dir())
  local pids = run([[
    local main = hidden_main()
    terminal.new()
    local shell = registry.list({ role = "shell" })[1]
    return { pid(main.job), pid(shell.job) }
  ]])
  eq(process_alive(pids[1]) and process_alive(pids[2]), true)
  child.api.nvim_input("<C-\\><C-n>:qa<CR>")
  eq(wait_process_gone(pids[1]), false)
  eq(wait_process_gone(pids[2]), false)
end

T["refused :bdelete keeps a running terminal"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local main = hidden_main()
    local ok, err = pcall(vim.cmd.bdelete, main.bufnr)
    return { ok = ok, err = err, main = registry.get(main.id),
      alive = pid(main.job) ~= nil }
  ]])
  eq(state.ok, false)
  match(state.err, "E89")
  eq(state.main.status, "running")
  eq(state.alive, true)
end

T[":bdelete! of the shown terminal stops and disposes its job"] = function()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  local state = run([[
    terminal.toggle_main()
    vim.cmd.stopinsert()
    local main = registry.list()[1]
    local process = pid(main.job)
    vim.cmd("bdelete! " .. main.bufnr)
    return { main = main, pid = process }
  ]])
  eq(wait_process_gone(state.pid), false)
  local after = run(
    [[
    local main = ...
    wait_for(function() return registry.get(main.id) == nil end)
    return { record = registry.get(main.id), panels = panel_count(),
      valid = vim.api.nvim_buf_is_valid(main.bufnr),
      current = vim.api.nvim_get_current_win(),
      last = _G.events[#_G.events] }
  ]],
    state.main
  )
  eq(after.record, nil)
  eq(after.panels, 0)
  eq(after.valid, false)
  eq(after.current, editor)
  eq(after.last.status, "disposed")
  -- F7 starts a fresh main terminal instead of a stale record.
  local fresh = run("terminal.toggle_main(); return registry.list()")
  eq(#fresh, 1)
  eq(fresh[1].status, "running")
end

T[":bdelete! of a hidden terminal removes its old transcripts"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local main = hidden_main()
    local restarted = registry.restart(main.id)
    local process = pid(restarted.job)
    vim.cmd("bdelete! " .. restarted.bufnr)
    wait_for(function()
      return not vim.api.nvim_buf_is_valid(main.bufnr)
    end)
    return { pid = process, record = registry.get(main.id),
      old = vim.api.nvim_buf_is_valid(main.bufnr),
      new = vim.api.nvim_buf_is_valid(restarted.bufnr) }
  ]])
  eq(wait_process_gone(state.pid), false)
  eq({ state.record, state.old, state.new }, { nil, false, false })
  -- The disposed record no longer counts toward the caps.
  eq(run("return #registry.list()"), 0)
end

T["a nonzero exit while hidden disposes and leaves windows alone"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local main = hidden_main()
    local layout = vim.fn.winlayout()
    local current = vim.api.nvim_get_current_win()
    vim.fn.chansend(main.job, "exit 3\n")
    wait_for(function() return registry.get(main.id) == nil end)
    vim.wait(100)
    return { layout = layout, after = vim.fn.winlayout(), current = current,
      now = vim.api.nvim_get_current_win(), main = main,
      valid = vim.api.nvim_buf_is_valid(main.bufnr), events = _G.events }
  ]])
  eq(state.after, state.layout)
  eq(state.now, state.current)
  eq(state.valid, false)
  local exited = vim.tbl_filter(function(event)
    return event.status == "exited"
  end, state.events)
  eq(#exited, 1)
  eq(run("return vim.api.nvim_get_mode().mode"), "n")
end

T["an exit with the panel in another tab closes it there"] = function()
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    terminal.toggle_main()
    vim.cmd.stopinsert()
    local main = registry.list()[1]
    wait_text(main.bufnr, "%$")
    vim.cmd.tabnew()
    local tab = vim.api.nvim_get_current_tabpage()
    vim.fn.chansend(main.job, "exit 0\n")
    wait_for(function() return registry.get(main.id) == nil end)
    vim.cmd.tabfirst()
    return { panels = panel_count(), tab = tab,
      wins = #vim.api.nvim_list_wins(), buftype = vim.bo.buftype }
  ]])
  eq(state.panels, 0)
  eq(state.wins, 2)
  eq(state.buftype, "")
end

T["with close_on_exit false a hidden exit keeps the transcript"] = function()
  start_with_options({ close_on_exit = false })
  run("edit(...)", helpers.temp_dir())
  local state = run([[
    local main = hidden_main()
    local wins = #vim.api.nvim_list_wins()
    vim.fn.chansend(main.job, "echo GONE-$((5+5)); exit 5\n")
    wait_for(function() return registry.get(main.id).status == "exited" end)
    vim.wait(100)
    return { main = registry.get(main.id), wins = wins,
      now = #vim.api.nvim_list_wins(), text = text(main.bufnr) }
  ]])
  eq(state.main.exit_code, 5)
  eq(state.now, state.wins)
  match(state.text, "GONE%-10")
  -- F7 shows the transcript without restarting it.
  local shown = run([[
    terminal.toggle_main()
    return { main = registry.list()[1], panels = panel_count(),
      current = vim.api.nvim_get_current_buf() }
  ]])
  eq(shown.main.generation, 1)
  eq(shown.main.status, "exited")
  eq(shown.current, state.main.bufnr)
  eq(shown.panels, 1)
end

---Start a hidden main terminal running a loop that prints nonstop and
---wait until its output passes the 10,000-line scrollback.
local function noisy_hidden_main()
  return run([[
    local main = hidden_main()
    vim.fn.chansend(main.job,
      "i=0; while :; do i=$((i+1)); echo noise $i; done\n")
    -- Well past the 10,000-line scrollback.
    wait_for(function()
      return vim.api.nvim_buf_line_count(main.bufnr) >= 10000
    end)
    return main
  ]])
end

T["a noisy hidden job keeps scrollback bounded; editing works"] = function()
  run("edit(...)", helpers.temp_dir())
  local main = noisy_hidden_main()
  child.type_keys("i", "typed while noisy", "<Esc>")
  local state = run(
    [[
    local main = ...
    local count = vim.api.nvim_buf_line_count(main.bufnr)
    return { line = vim.api.nvim_get_current_line(), count = count,
      scrollback = vim.bo[main.bufnr].scrollback,
      record = registry.get(main.id), panels = panel_count(),
      last = vim.api.nvim_buf_get_lines(main.bufnr, -3, -1, false) }
  ]],
    main
  )
  eq(state.line, "typed while noisy")
  eq(state.record.status, "running")
  eq(state.panels, 0)
  eq(state.scrollback, 10000)
  -- Scrollback plus at most one screen of lines.
  eq(state.count <= 10000 + 100, true)
  match(table.concat(state.last, "\n"), "noise %d+")
  -- Ctrl+c reaches the loop once the terminal is shown again.
  run("terminal.toggle_main()")
  child.type_keys("<C-c>")
  local stopped = run(
    [[
    local main = ...
    vim.fn.chansend(main.job, "echo QUIET-$((6*7))\n")
    return wait_text(main.bufnr, "QUIET%-42")
  ]],
    main
  )
  match(stopped, "QUIET%-42")
end

return T
