-- Native indent guides (task V8): 'listchars' guides follow the indent
-- options, appear only in eligible file buffers in normal windows, and
-- leave conservative buffers, special buffers, and floats alone.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = helpers.new_child()

local GUIDE = "\u{2502}"

local function setup(options)
  child.lua(
    [[
    local config = { options = ... }
    require("iara.core.options").setup(config)
    require("iara.core.eligibility").setup(config)
  ]],
    { options or {} }
  )
end

---Write `lines` to a new file and edit it in the current window.
local function edit(lines, name)
  local path = helpers.temp_dir() .. "/" .. (name or "sample.lua")
  helpers.write_file(path, table.concat(lines, "\n") .. "\n")
  child.cmd("edit " .. vim.fn.fnameescape(path))
  return path
end

local INDENTED = {
  "local function f()",
  "    if true then",
  "        return 1",
  "    end",
  "end",
}

local function list()
  return child.lua_get("vim.wo.list")
end

local function listchars()
  return child.lua_get("vim.wo.listchars")
end

---Text of screen row `row` (1-based), from a child screenshot.
local function screen_row(row)
  return table.concat(child.get_screenshot().text[row])
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

T["listchars draw a guide at every indent width"] = function()
  local guides = child.lua_get("require('iara.core.guides').listchars(4, true)")
  match(guides, "leadmultispace:" .. GUIDE .. "   ,?")
  match(guides, "leadtab:" .. GUIDE .. " ")
  -- Tabs after text stay blank; only leading tabs are guides.
  match(guides, "tab:  ")
  local narrow = child.lua_get("require('iara.core.guides').listchars(0, true)")
  match(narrow, "leadmultispace:" .. GUIDE .. "$")
end

T["listchars without expandtab mark only tabs"] = function()
  local guides =
    child.lua_get("require('iara.core.guides').listchars(4, false)")
  eq(guides:find("leadmultispace", 1, true), nil)
  match(guides, "leadtab:" .. GUIDE .. " ")
end

T["an eligible file shows guides on its indentation"] = function()
  setup()
  edit(INDENTED)
  child.lua("vim.bo.shiftwidth = 4")
  eq(list(), true)
  match(listchars(), "leadmultispace:" .. GUIDE .. "   ")
  -- Number column, then a guide at each level of four columns.
  match(screen_row(3), "3 " .. GUIDE .. "   " .. GUIDE .. "   return 1")
  match(screen_row(2), "2 " .. GUIDE .. "   if true")
end

T["guides follow shiftwidth, tabstop, and expandtab changes"] = function()
  setup()
  edit(INDENTED)
  child.lua("vim.bo.shiftwidth = 8")
  match(listchars(), "leadmultispace:" .. GUIDE .. (" "):rep(7) .. ",?")
  child.lua("vim.bo.shiftwidth = 0; vim.bo.tabstop = 3")
  match(listchars(), "leadmultispace:" .. GUIDE .. "  ,?")
  child.lua("vim.bo.expandtab = false")
  eq(listchars():find("leadmultispace", 1, true), nil)
  child.cmd("setlocal expandtab")
  match(listchars(), "leadmultispace:")
end

T["guides apply to every window of the buffer"] = function()
  setup()
  edit(INDENTED)
  child.cmd("vsplit")
  child.lua("vim.bo.shiftwidth = 6")
  local both = child.lua_get([[vim.tbl_map(function(win)
    return vim.wo[win].listchars
  end, vim.api.nvim_tabpage_list_wins(0))]])
  eq(#both, 2)
  match(both[1], "leadmultispace:" .. GUIDE .. (" "):rep(5))
  eq(both[1], both[2])
end

T["a large file gets no guides"] = function()
  setup()
  local lines = {}
  for i = 1, 15000 do
    lines[i] = "    " .. ("x"):rep(80)
  end
  edit(lines, "large.lua")
  eq(
    child.lua_get("require('iara.core.eligibility').check(0).state"),
    "conservative"
  )
  eq(list(), false)
end

T["a file that becomes conservative loses its guides"] = function()
  setup()
  edit(INDENTED)
  eq(list(), true)
  -- A long line makes the buffer conservative; the event follows.
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, 0, true,
    { ("x"):rep(10000) })]])
  child.lua("require('iara.core.eligibility').check(0)")
  vim.wait(1000, function()
    return not list()
  end)
  eq(list(), false)
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 1, true, {})")
  vim.wait(1000, function()
    return list()
  end)
  eq(list(), true)
end

T["special buffers in the same window get no guides"] = function()
  setup()
  edit(INDENTED)
  eq(list(), true)
  child.cmd("enew")
  child.lua("vim.bo.buftype = 'nofile'")
  child.cmd("edit #")
  eq(list(), true)
  child.cmd("terminal")
  eq(list(), false)
  eq(listchars(), child.lua_get("vim.go.listchars"))
  child.cmd("buffer #")
  eq(list(), true)
end

T["a float showing a file gets no guides"] = function()
  setup()
  edit(INDENTED)
  local float = child.lua_get([[(function()
    local win = vim.api.nvim_open_win(0, true, {
      relative = "editor", row = 1, col = 1, width = 30, height = 4,
    })
    return { list = vim.wo[win].list, listchars = vim.wo[win].listchars }
  end)()]])
  eq(float.list, false)
  eq(float.listchars, child.lua_get("vim.go.listchars"))
end

T["personal list options leave guides off"] = function()
  setup({ list = false })
  edit(INDENTED)
  eq(list(), false)
  eq(child.lua_get("vim.fn.exists('#IaraGuides')"), 0)
end

T["guides use the faint Whitespace color in every theme"] = function()
  local failures = {}
  local theme = require("iara.theme")
  local roles = require("iara.theme.roles")
  local hl = require("iara.theme.highlights")
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups = hl.resolve(palette)
    if groups.Whitespace.fg ~= roles.resolve(palette).faint then
      table.insert(failures, name)
    end
  end
  eq(failures, {})
end

return T
