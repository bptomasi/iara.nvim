-- Split winbars and inactive windows (task V4): the winbar appears with
-- two or more normal windows and goes with the split, never on
-- terminals, scratch windows, floats, short windows, or a winbar set by
-- another owner; 'cursorline' belongs to the current normal window.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = helpers.new_child()

local BAR = "\u{258e}"

local function setup(options)
  child.lua(
    [[
    require("iara.config").compose({ options = ... })
    require("iara.core.options").setup({ options = ... })
    require("iara.theme").load("chocolate")
  ]],
    { options or {} }
  )
end

local function edit(name)
  local path = helpers.temp_dir() .. "/" .. name
  helpers.write_file(path, "local x = 1\n")
  child.cmd("edit " .. vim.fn.fnameescape(path))
  return path
end

---Let the scheduled winbar update run.
local function settle()
  child.lua("vim.wait(50)")
end

---Raw winbar option of window `win` (0: current).
local function winbar(win)
  return child.lua_get(("vim.wo[%d].winbar"):format(win or 0))
end

---Winbar of `win` as drawn (highlight markers removed).
local function drawn(win)
  return child.lua(
    [[
    local win = ...
    win = win == 0 and vim.api.nvim_get_current_win() or win
    return vim.api.nvim_eval_statusline(vim.wo[win].winbar,
      { winid = win, use_winbar = true }).str
  ]],
    { win or 0 }
  )
end

local function windows()
  return child.lua_get("vim.api.nvim_tabpage_list_wins(0)")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.o.lines, child.o.columns = 30, 100
    end,
    post_once = child.stop,
  },
})

T["one window has no winbar; a split gives both one"] = function()
  setup()
  edit("one.lua")
  settle()
  eq(winbar(), "")
  child.cmd("vsplit")
  edit("two.lua")
  settle()
  for _, win in ipairs(windows()) do
    match(winbar(win), "^%%#IaraWinbar")
  end
  child.cmd("only")
  settle()
  eq(winbar(), "")
end

T["the current window leads with an accent bar and name"] = function()
  setup()
  local first = edit("one.lua")
  child.cmd("vsplit")
  edit("two.lua")
  settle()
  local current = child.lua_get("vim.api.nvim_get_current_win()")
  local other = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  match(drawn(current), "^" .. BAR .. ".*/two%.lua$")
  match(winbar(current), "IaraWinbarName#two%.lua")
  eq(drawn(other):find(BAR, 1, true), nil)
  match(winbar(other), "^%%#IaraWinbarInactive#")
  -- The path is relative to the working directory.
  child.cmd("cd " .. vim.fn.fnamemodify(first, ":h:h"))
  settle()
  local dir = vim.fn.fnamemodify(first, ":h:t")
  eq(vim.endswith(drawn(other), " " .. dir .. "/one.lua"), true)
  child.cmd("wincmd p")
  settle()
  match(drawn(other), "^" .. BAR)
  eq(drawn(current):find(BAR, 1, true), nil)
end

T["a modified file shows a dot in its winbar"] = function()
  setup()
  edit("one.lua")
  child.cmd("vsplit")
  settle()
  eq(drawn():find("\u{25cf}", 1, true), nil)
  child.type_keys("ix<Esc>")
  settle()
  match(drawn(), "one%.lua \u{25cf}$")
end

T["terminals, scratch windows, and floats do not count"] = function()
  setup()
  edit("one.lua")
  child.cmd("botright split | terminal")
  settle()
  -- One normal window beside a terminal: no winbar anywhere.
  for _, win in ipairs(windows()) do
    eq(winbar(win), "")
  end
  child.cmd("wincmd p | vnew | setlocal buftype=nofile")
  settle()
  for _, win in ipairs(windows()) do
    eq(winbar(win), "")
  end
  child.lua([[
    vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), true,
      { relative = "editor", row = 1, col = 1, width = 20, height = 8 })
  ]])
  settle()
  for _, win in ipairs(windows()) do
    eq(winbar(win), "")
  end
end

T["a terminal split never gets a winbar"] = function()
  setup()
  edit("one.lua")
  child.cmd("vsplit")
  edit("two.lua")
  child.cmd("split | terminal")
  settle()
  local term = child.lua_get("vim.api.nvim_get_current_win()")
  for _, win in ipairs(windows()) do
    if win == term then
      eq(winbar(win), "")
    else
      match(winbar(win), "^%%#IaraWinbarInactive#")
    end
  end
end

T["windows shorter than six rows get no winbar"] = function()
  setup()
  edit("one.lua")
  child.cmd("split")
  settle()
  match(winbar(), "^%%#IaraWinbar")
  child.cmd("resize 3")
  settle()
  eq(winbar(), "")
  child.cmd("resize 10")
  settle()
  match(winbar(), "^%%#IaraWinbar")
end

T["a winbar set by another owner is left alone"] = function()
  setup()
  edit("one.lua")
  child.cmd("vsplit")
  child.wo.winbar = "Disk version"
  settle()
  eq(winbar(), "Disk version")
  child.cmd("only")
  settle()
  eq(winbar(), "Disk version")
end

T["a configured winbar option turns split winbars off"] = function()
  setup({ winbar = "%f" })
  edit("one.lua")
  child.cmd("vsplit")
  settle()
  for _, win in ipairs(windows()) do
    eq(winbar(win), "%f")
  end
end

T["only the current normal window keeps its cursor line"] = function()
  setup()
  edit("one.lua")
  child.cmd("vsplit")
  edit("two.lua")
  local current = child.lua_get("vim.api.nvim_get_current_win()")
  local other = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  local function cursorline(win)
    return child.lua_get(("vim.wo[%d].cursorline"):format(win))
  end
  eq({ cursorline(current), cursorline(other) }, { true, false })
  child.cmd("wincmd p")
  eq({ cursorline(current), cursorline(other) }, { false, true })
  -- Entering a float keeps the editor's cursor line.
  child.lua([[
    vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
      { relative = "editor", row = 1, col = 1, width = 20, height = 4 })
  ]])
  eq(cursorline(other), true)
end

T["a window without a cursor line keeps it off"] = function()
  setup()
  edit("one.lua")
  child.cmd("vsplit")
  child.wo.cursorline = false
  local plain = child.lua_get("vim.api.nvim_get_current_win()")
  child.cmd("wincmd p")
  child.cmd("wincmd p")
  eq(child.lua_get(("vim.wo[%d].cursorline"):format(plain)), false)
end

return T
