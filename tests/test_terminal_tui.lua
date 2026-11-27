--- Full-screen programs in an Iara terminal, seen through a real UI: a
--- child `nvim --embed` with a linegrid UI attached runs `less` in the
--- terminal panel (gate G3, T3 acceptance, M2).
local helpers = require("helpers")
local ui_child = require("ui_child")

local eq = MiniTest.expect.equality

local WIDTH, HEIGHT = 100, 30

local child = nil

local CHILD_SETUP = [[
local dir = ...
vim.o.shell = "/bin/sh"
vim.env.PS1 = "TUI$ "
vim.g.mapleader = " "
require("iara.core.term_retention").setup({})
require("iara.features.terminal").setup({})
vim.fn.mkdir(dir .. "/.git", "p")
local rows = {}
for index = 1, 300 do
  rows[index] = ("row %03d"):format(index)
end
vim.fn.writefile(rows, dir .. "/big.txt")
vim.cmd.edit(vim.fn.fnameescape(dir .. "/file.txt"))
]]

---Rows of the screen that show lines of big.txt, with the column where
---the first one starts (zero-based screen cell).
local function less_rows(screen)
  local count, column = 0, nil
  for line in screen:gmatch("[^\n]*") do
    local start = line:find("row %d%d%d")
    if start then
      count = count + 1
      column = column or vim.fn.strdisplaywidth(line:sub(1, start - 1))
    end
  end
  return count, column
end

---Wait until less shows `count` rows of the file; return the screen.
local function wait_rows(count)
  child:wait(function(c)
    return (less_rows(c:screen())) == count
  end)
  return child:screen()
end

local function mode()
  return child:lua("return vim.api.nvim_get_mode().mode")
end

local function wait_mode(expected)
  child:wait(function()
    return mode() == expected
  end)
  return mode()
end

local function panel_size()
  return child:lua([[
    local win = require("iara.features.terminal.panel").shell:window()
    -- The text height leaves out the panel's winbar header (V7).
    return win and { vim.api.nvim_win_get_width(win),
      vim.api.nvim_win_get_height(win),
      vim.fn.getwininfo(win)[1].height } or vim.NIL
  ]])
end

---Show the main terminal with F7 and start `less big.txt` after a marker
---that only the command's output (not its echo) contains.
local function start_less()
  child:input("<F7>")
  child:wait_screen("TUI$ ")
  eq(wait_mode("t"), "t")
  child:input("echo BEFORE-$((1+1)); less big.txt<CR>")
  child:wait_screen("row 001")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = ui_child.start(WIDTH, HEIGHT)
      child:lua(CHILD_SETUP, { helpers.temp_dir() })
    end,
    post_case = function()
      child:stop()
    end,
  },
})

T["less fills the bottom panel and gets plain keys and Space"] = function()
  start_less()
  local size = panel_size()
  eq({ size[1], size[2] }, { WIDTH, math.floor(HEIGHT / 3) })
  eq(size[3], size[2] - 1)
  -- One row less than the text: less keeps its prompt on the last row.
  local count, column = less_rows(wait_rows(size[3] - 1))
  eq({ count, column }, { size[3] - 1, 0 })
  child:input("G")
  eq(child:wait_screen("row 300"):find("row 300", 1, true) ~= nil, true)
  -- Space pages forward in less: terminal input has no leader mapping.
  child:input("g<Space>")
  local screen = child:wait_screen("row 018")
  eq(screen:find("row 001", 1, true), nil)
  child:input("/row 150<CR>")
  eq(child:wait_screen("row 158"):find("row 150", 1, true) ~= nil, true)
  eq(mode(), "t")
end

T["less leaves the alternate screen and the shell output returns"] = function()
  start_less()
  local during = child:screen()
  eq(during:find("BEFORE-2", 1, true), nil)
  child:input("q")
  local after = child:wait_screen("BEFORE-2")
  eq(after:find("BEFORE-2", 1, true) ~= nil, true)
  eq((less_rows(after)), 0)
  local transcript = child:lua([[
    local panel = require("iara.features.terminal.panel")
    local lines = vim.api.nvim_buf_get_lines(panel.shell:buffer(), 0, -1, false)
    return table.concat(lines, "\n")
  ]])
  eq(transcript:find("row 001", 1, true), nil)
end

T["less redraws when the panel moves to the right"] = function()
  start_less()
  wait_rows(math.floor(HEIGHT / 3) - 2)
  child:input([[<C-\><C-n>]])
  eq(wait_mode("nt"), "nt")
  child:input("<Space>tv")
  child:wait(function()
    local size = panel_size()
    return size ~= vim.NIL and size[1] < WIDTH
  end)
  local size = panel_size()
  eq(size[1], math.floor(WIDTH * 0.4))
  local count, column = less_rows(wait_rows(size[3] - 1))
  eq(count, size[3] - 1)
  -- The panel is the right part of the screen, after the separator.
  eq(column, WIDTH - size[1])
end

T["less follows a resize made while the panel was hidden"] = function()
  start_less()
  child:input("<F7>")
  child:wait(function()
    return panel_size() == vim.NIL
  end)
  eq(wait_mode("n"), "n")
  child:resize(WIDTH + 20, HEIGHT + 10)
  child:input("<F7>")
  child:wait(function()
    return panel_size() ~= vim.NIL
  end)
  local size = panel_size()
  eq(size[1], WIDTH + 20)
  -- The remembered height stays; less draws for the window it is in.
  eq(size[2], math.floor(HEIGHT / 3))
  eq((less_rows(wait_rows(size[3] - 1))), size[3] - 1)
  eq(wait_mode("t"), "t")
  child:input("q")
  child:wait_screen("BEFORE-2")
  eq(child:lua("return vim.fn.mode()"), "t")
end

return T
