--- Terminal mappings.
---
--- Normal mode gets F7 and the `Space t` group. Terminal input gets only
--- F7, and only in Iara-owned terminal buffers: a leader there would
--- capture ordinary application text, and Esc, Ctrl+c, and Ctrl+\ Ctrl+n
--- must reach the program or Neovim unchanged. A `config.keymaps` entry
--- for the same "<mode> <lhs>" (a replacement or `false`) wins over these
--- defaults; core keymaps (F6) applies it.
local M = {}

---@class IaraTerminalMapping
---@field mode string
---@field lhs string
---@field action string Function name in `iara.features.terminal`.
---@field desc string

---@type IaraTerminalMapping[]
M.NORMAL = {
  {
    mode = "n",
    lhs = "<F7>",
    action = "toggle_main",
    desc = "Toggle main terminal",
  },
  {
    mode = "n",
    lhs = "<leader>tt",
    action = "toggle_main",
    desc = "Toggle main terminal",
  },
  {
    mode = "n",
    lhs = "<leader>tn",
    action = "new",
    desc = "New terminal at project root",
  },
  {
    mode = "n",
    lhs = "<leader>tl",
    action = "select",
    desc = "List terminals of all projects",
  },
  {
    mode = "n",
    lhs = "<leader>t.",
    action = "new_here",
    desc = "New terminal in file directory",
  },
  {
    mode = "n",
    lhs = "<leader>ts",
    action = "show_side",
    desc = "Main terminal at the side",
  },
  {
    mode = "n",
    lhs = "<leader>tv",
    action = "toggle_position",
    desc = "Move terminal panel bottom/side",
  },
}

---@type IaraTerminalMapping
M.TERMINAL = {
  mode = "t",
  lhs = "<F7>",
  action = "toggle_main",
  desc = "Toggle main terminal",
}

---@type table<string, any>
local user_keymaps = {}

local function user_owns(mapping)
  return user_keymaps[mapping.mode .. " " .. mapping.lhs] ~= nil
end

local function rhs(terminal, mapping)
  return function()
    terminal[mapping.action]()
  end
end

---Define the normal-mode mappings unless `config.keymaps` names them.
---@param terminal table The `iara.features.terminal` module.
---@param keymaps table<string, any>? `config.keymaps`.
function M.setup(terminal, keymaps)
  user_keymaps = type(keymaps) == "table" and keymaps or {}
  for _, mapping in ipairs(M.NORMAL) do
    if not user_owns(mapping) then
      vim.keymap.set(mapping.mode, mapping.lhs, rhs(terminal, mapping), {
        desc = mapping.desc,
      })
    end
  end
end

---Map F7 in terminal input of one owned terminal buffer.
---@param terminal table The `iara.features.terminal` module.
---@param bufnr integer
function M.map_buffer(terminal, bufnr)
  local mapping = M.TERMINAL
  if user_owns(mapping) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.keymap.set(mapping.mode, mapping.lhs, rhs(terminal, mapping), {
    buffer = bufnr,
    desc = mapping.desc,
  })
end

return M
