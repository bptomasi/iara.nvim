-- Options, statusline, and the Tree-sitter gate: the safe-mode baseline
-- that needs no plugin.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = helpers.new_child()

local function setup(options)
  child.lua(
    [[
    local config = { options = ... }
    require("iara.core.options").setup(config)
    require("iara.core.root").setup(config)
    require("iara.core.eligibility").setup(config)
    require("iara.core.reconcile").setup(config)
  ]],
    { options or {} }
  )
end

local HIGHLIGHTED = "vim.treesitter.highlighter.active"
  .. "[vim.api.nvim_get_current_buf()] ~= nil"

local function render()
  return child.lua_get("require('iara.core.statusline').render()")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

T["sets the leaders and the default options"] = function()
  setup()
  eq(child.g.mapleader, " ")
  eq(child.o.expandtab, true)
  eq(child.o.shiftwidth, 2)
  eq(child.o.undofile, true)
end

T["bounds matchparen scans on long lines"] = function()
  setup()
  eq(child.g.matchparen_timeout, 20)
  eq(child.g.matchparen_insert_timeout, 20)
end

T["personal options override the defaults"] = function()
  setup({ shiftwidth = 4, number = false, fillchars = { eob = "~" } })
  eq(child.o.shiftwidth, 4)
  eq(child.o.number, false)
  match(child.o.fillchars, "eob:~")
end

T["an invalid option is reported and the others still apply"] = function()
  setup({ no_such_option = 1, tabstop = 8, shiftwidth = "wide" })
  eq(child.o.tabstop, 8)
  eq(child.o.shiftwidth, 2)
  local messages = child.cmd_capture("messages")
  match(messages, "Iara: invalid option no_such_option = 1")
  match(messages, 'Iara: invalid option shiftwidth = "wide"')
end

T["the statusline shows root and conservative reason"] = function()
  setup()
  child.api.nvim_buf_set_name(0, helpers.temp_dir() .. "/large.txt")
  child.lua([[
    local line = ("x"):rep(80)
    local lines = {}
    for i = 1, 15000 do lines[i] = line end
    vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  ]])
  child.lua("require('iara.core.eligibility').recheck(0)")
  local text = render()
  match(text, "conservative: large file")
  match(text, vim.pesc(child.lua_get("require('iara.core.root').statusline()")))
end

T["the statusline shows an external change conflict"] = function()
  setup()
  -- Keep the conflict notification out of the child's message area.
  child.lua("vim.notify = function() end")
  local path = helpers.temp_dir() .. "/file.txt"
  helpers.write_file(path, "one\n")
  child.cmd("edit " .. vim.fn.fnameescape(path))
  -- Let the check queued by BufEnter finish before the file changes.
  child.lua("vim.wait(20)")
  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, true, { 'local edit' })")
  -- A different size makes the change visible regardless of mtime.
  helpers.write_file(path, "changed on disk\n")
  child.lua("require('iara.core.reconcile').check()")
  local conflict = "return require('iara.core.reconcile')"
    .. ".conflict(vim.api.nvim_get_current_buf()) ~= nil"
  eq(
    child.lua("return vim.wait(5000, function() " .. conflict .. " end)"),
    true
  )
  match(render(), "%[disk: changed%]")
end

T["the statusline escapes percent signs in owner text"] = function()
  setup()
  local dir = helpers.temp_dir() .. "/100%done"
  vim.fn.mkdir(dir, "p")
  child.lua("require('iara.core.root').set_override(...)", { dir })
  child.api.nvim_buf_set_name(0, dir .. "/notes.txt")
  match(render(), "100%%%%done")
end

T["the statusline leaves the root of a fresh unnamed buffer open"] = function()
  setup()
  -- Resolving here would fix the root before an owner sets its context.
  local root = "require('iara.core.root').statusline()"
  eq(render():find(child.lua_get(root), 1, true), nil)
  child.lua("vim.b.iara_context_root = vim.fn.getcwd()")
  eq(render():find(child.lua_get(root), 1, true) ~= nil, true)
end

T["a failing owner shows a question mark"] = function()
  setup()
  child.lua([[
    package.loaded["iara.core.reconcile"] = {
      statusline = function() error("broken") end,
    }
  ]])
  match(render(), "%?")
end

T["Tree-sitter highlights only eligible buffers"] = function()
  setup()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/small.lua", "local x = 1\n")
  local line = ("local value = %q\n"):format(("x"):rep(100))
  helpers.write_file(dir .. "/large.lua", line:rep(12000))
  child.cmd("edit " .. dir .. "/small.lua")
  eq(child.lua_get(HIGHLIGHTED), true)
  child.cmd("edit " .. dir .. "/large.lua")
  eq(child.lua_get(HIGHLIGHTED), false)
end

T["Tree-sitter stops when a buffer becomes conservative"] = function()
  setup()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/small.lua", "local x = 1\n")
  child.cmd("edit " .. dir .. "/small.lua")
  eq(child.lua_get(HIGHLIGHTED), true)
  child.lua("vim.api.nvim_buf_set_lines(0, -1, -1, true, { ('y'):rep(12000) })")
  local wait = "vim.wait(5000, function() return not (%s) end)"
  eq(child.lua_get(wait:format(HIGHLIGHTED)), true)
end

return T
