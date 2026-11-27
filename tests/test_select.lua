-- The vim.ui.select presenter (task V10): a numbered float with the
-- prompt as its title on a straight frame in the focus color, Vim
-- keys, digits, and a cancel that reports nil exactly once. Children
-- run without Snacks, as in safe mode.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.o.columns, child.o.lines = 120, 35
      child.lua([[
        _G.calls = {}
        require("iara.core.select").setup()
      ]])
    end,
    post_once = child.stop,
  },
})

---Open vim.ui.select with `items` (strings) and `opts`, recording each
---call of on_choice in `_G.calls`.
local function open(items, opts)
  child.lua(
    [[
    local items, opts = ...
    vim.ui.select(items, opts, function(item, index)
      local call = { item = item or vim.NIL, index = index or vim.NIL }
      table.insert(_G.calls, call)
    end)
  ]],
    { items, opts or vim.empty_dict() }
  )
end

local function calls()
  return child.lua_get("_G.calls")
end

---Text and configuration of the open float.
local function float()
  return child.lua([[
    local win = vim.api.nvim_get_current_win()
    local config = vim.api.nvim_win_get_config(win)
    local function text(chunks)
      local parts = {}
      for _, chunk in ipairs(chunks or {}) do
        table.insert(parts, chunk[1])
      end
      return table.concat(parts)
    end
    return {
      relative = config.relative,
      title = text(config.title),
      footer = text(config.footer),
      width = config.width,
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
      statuscolumn = vim.wo[win].statuscolumn,
      border = config.border,
    }
  ]])
end

local FRUITS = { "apple", "banana", "cherry" }

T["vim.ui.select is the presenter after setup"] = function()
  local same = "vim.ui.select == require('iara.core.select').select"
  eq(child.lua_get(same), true)
end

T["the prompt is the title and items are numbered"] = function()
  open(FRUITS, { prompt = "Fruit: " })
  local shown = float()
  eq(shown.relative, "editor")
  eq(shown.title, "─ Fruit ")
  eq(shown.lines, { " 1  apple", " 2  banana", " 3  cherry" })
  eq(shown.footer, " ⏎ choose · 1-9 pick · q cancel ")
  -- The presenter holds the focus: a straight frame in the focus color.
  eq(shown.border[1], { "┌", "IaraFloatBorderFocus" })
  eq(shown.border[5], { "┘", "IaraFloatBorderFocus" })
  eq(shown.width, 48)
  -- The selection bar is drawn by the shared list status column.
  eq(shown.statuscolumn, require("iara.features.picker.layout").BAR)
end

T["format_item shapes the rows"] = function()
  child.lua([[
    vim.ui.select({ { name = "a" }, { name = "b" } }, {
      prompt = "Pick",
      format_item = function(item) return "item " .. item.name end,
    }, function() end)
  ]])
  local shown = float()
  eq(shown.lines, { " 1  item a", " 2  item b" })
  eq(shown.title, "─ Pick ")
end

T["Enter chooses the row under the cursor after j and k"] = function()
  open(FRUITS)
  child.type_keys("j", "j", "k", "<CR>")
  eq(calls(), { { item = "banana", index = 2 } })
  eq(child.lua_get("vim.api.nvim_win_get_config(0).relative"), "")
end

T["movement wraps around the list"] = function()
  open(FRUITS)
  child.type_keys("k", "l")
  eq(calls(), { { item = "cherry", index = 3 } })
end

T["a digit chooses its item at once"] = function()
  open(FRUITS)
  child.type_keys("3")
  eq(calls(), { { item = "cherry", index = 3 } })
end

T["q, Esc, and leaving the window cancel with nil once"] = function()
  for _, key in ipairs({ "q", "<Esc>" }) do
    child.lua("_G.calls = {}")
    open(FRUITS)
    child.type_keys(key)
    eq(calls(), { { item = vim.NIL, index = vim.NIL } })
  end
  child.lua("_G.calls = {}")
  open(FRUITS)
  child.cmd("wincmd p")
  eq(calls(), { { item = vim.NIL, index = vim.NIL } })
  -- Closing after the cancel reports nothing more.
  child.type_keys("<Esc>")
  eq(#calls(), 1)
end

T["an empty list is cancelled at once"] = function()
  open({})
  eq(calls(), { { item = vim.NIL, index = vim.NIL } })
  eq(child.lua_get("vim.api.nvim_win_get_config(0).relative"), "")
end

T["without Snacks a long list still opens the float"] = function()
  local items = {}
  for index = 1, 20 do
    items[index] = "item " .. index
  end
  open(items, { prompt = "Many" })
  local shown = float()
  eq(shown.lines[20], " 20  item 20")
  child.type_keys("G", "k", "<CR>")
  eq(calls(), { { item = "item 19", index = 19 } })
end

T["safe mode installs the presenter"] = function()
  local step = nil
  for _, entry in ipairs(child.lua_get("require('iara').STEPS")) do
    if entry.module == "iara.core.select" then
      step = entry
    end
  end
  eq(step and step.safe, true)
end

return T
