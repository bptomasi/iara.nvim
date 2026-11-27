-- The ui2 messages spike (V11): native by default, ui2 only on request,
-- and with ui2 the `:messages` history still holds Iara's notices (the
-- G1 check of test_options.lua). ui2 needs an attached UI, so these
-- children are `nvim --embed` with a 120x35 grid.
local helpers = require("helpers")
local ui_child = require("ui_child")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local messages = require("iara.core.messages")

local INIT = [[
vim.opt.runtimepath:prepend(%q)
vim.o.swapfile = false
vim.o.shadafile = "NONE"
_G.mode = require("iara.core.messages").setup({ ui = { messages = %s } })
]]

local child = nil

local function start(value)
  local path = helpers.temp_dir() .. "/init.lua"
  helpers.write_file(path, INIT:format(helpers.iara_dir, vim.inspect(value)))
  child = ui_child.start(120, 35, { init = path })
  child:lua("return 1")
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      if child then
        child:stop()
        child = nil
      end
    end,
  },
})

T["mode is native by default and for bad values"] = function()
  eq({ messages.mode({}) }, { "native" })
  eq({ messages.mode({ ui = { messages = "ui2" } }) }, { "ui2" })
  local mode, problem = messages.mode({ ui = { messages = "noice" } })
  eq(mode, "native")
  match(problem, 'ui.messages must be "native" or "ui2", not "noice"')
end

T["native mode leaves ui2 unloaded"] = function()
  start(nil)
  eq(child:lua("return _G.mode"), "native")
  eq(child:lua("return package.loaded['vim._core.ui2'] == nil"), true)
end

T["a bad value is reported and stays native"] = function()
  start("fancy")
  eq(child:lua("return _G.mode"), "native")
  local history = child:lua("return vim.fn.execute('messages')")
  match(history, 'Iara: ui.messages must be "native" or "ui2"')
end

T["ui2 shows notices in its window and keeps the history"] = function()
  start("ui2")
  eq(child:lua("return _G.mode"), "ui2")
  child:lua("vim.notify('Iara: invalid option tabstop = \"wide\"')")
  child:wait_screen("invalid option tabstop")
  local state = child:lua([[
    local ui2 = require("vim._core.ui2")
    local win = ui2.wins.msg
    return {
      history = vim.fn.execute("messages"),
      winhighlight = vim.api.nvim_win_is_valid(win)
        and vim.wo[win].winhighlight or "",
    }
  ]])
  match(state.history, 'Iara: invalid option tabstop = "wide"')
  match(state.winhighlight, "Normal:NormalFloat")
end

return T
