-- Global mappings and their personal customization.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = helpers.new_child()

---@param keymaps string Lua expression of `config.keymaps`; mixed
---tables such as `{ rhs, desc = s }` cannot cross RPC as values.
local function setup(keymaps)
  child.lua(
    "vim.g.mapleader = ' '\n"
      .. "require('iara.core.keymaps').setup({ keymaps = "
      .. keymaps
      .. " })"
  )
end

local function rhs(mode, lhs)
  return child.fn.maparg(lhs, mode)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

T["defines the default mappings with descriptions"] = function()
  setup("{}")
  eq(rhs("n", "<C-S>"), "<Cmd>write<CR>")
  local map = child.fn.maparg(" x", "n", false, true)
  eq(map.desc, "Close buffer")
end

T["false removes a default and a table replaces it"] = function()
  setup([[{
    ["n ;"] = false,
    ["n <C-s>"] = { "<cmd>update<CR>", desc = "Save if changed" },
    ["n <leader>q"] = { "<cmd>quit<CR>", desc = "Quit" },
  }]])
  eq(rhs("n", ";"), "")
  eq(rhs("n", "<C-S>"), "<Cmd>update<CR>")
  eq(rhs("n", " q"), "<Cmd>quit<CR>")
end

T["an invalid entry is reported and the default stays"] = function()
  setup([[{ ["n <C-s>"] = { 42 }, ["nowhere"] = false }]])
  eq(rhs("n", "<C-S>"), "<Cmd>write<CR>")
  local messages = child.cmd_capture("messages")
  match(messages, 'keymaps%["n <C%-s>"%] must be false or')
  match(messages, "keymaps key \"nowhere\" is not '<mode> <lhs>'")
end

return T
