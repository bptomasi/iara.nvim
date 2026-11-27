--- Terminal mappings.
---
--- Normal mode gets F7 and the `Space t` group. Iara-owned terminal
--- buffers get F7 and directional window navigation during input.
--- Leader keys, Esc, Ctrl+c, and Ctrl+\ Ctrl+n keep their native
--- behavior. A `config.keymaps` entry for the same "<mode> <lhs>"
--- (a replacement or `false`) wins over these defaults.
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

local function user_owns(mode, lhs)
  return user_keymaps[mode .. " " .. lhs] ~= nil
end

local WINDOW_DIRECTIONS = { h = "left", j = "lower", k = "upper", l = "right" }

local function map_window_navigation(bufnr, direction, name)
  local lhs = ("<C-%s>"):format(direction)
  if user_owns("t", lhs) then
    return
  end
  vim.keymap.set("t", lhs, function()
    local target = vim.fn.winnr(direction)
    if target == 0 or target == vim.fn.winnr() then
      return lhs
    end
    local move = [[<Cmd>lua require("iara.core.keymaps").move_window(%q)<CR>]]
    return [[<C-\><C-n>]] .. move:format(direction)
  end, {
    buffer = bufnr,
    desc = "Go to " .. name .. " window",
    expr = true,
  })
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
    if not user_owns(mapping.mode, mapping.lhs) then
      vim.keymap.set(mapping.mode, mapping.lhs, rhs(terminal, mapping), {
        desc = mapping.desc,
      })
    end
  end
end

---Map controls in terminal input of one owned terminal buffer.
---@param terminal table The `iara.features.terminal` module.
---@param bufnr integer
function M.map_buffer(terminal, bufnr)
  local mapping = M.TERMINAL
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not user_owns(mapping.mode, mapping.lhs) then
    vim.keymap.set(mapping.mode, mapping.lhs, rhs(terminal, mapping), {
      buffer = bufnr,
      desc = mapping.desc,
    })
  end
  for direction, name in pairs(WINDOW_DIRECTIONS) do
    map_window_navigation(bufnr, direction, name)
  end
end

return M
