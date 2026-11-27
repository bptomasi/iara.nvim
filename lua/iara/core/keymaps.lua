--- Global mappings that need no plugin.
---
--- Plugin mappings live in their lazy.nvim specs (`keys`), buffer-local
--- ones at their FileType/LspAttach owner. `config.keymaps` maps
--- "<mode> <lhs>" to `false` (remove an Iara default) or
--- `{ rhs, desc = string? }` (add or replace). An invalid entry is
--- reported once and the default for that key, if any, is kept.
--- See contracts.md, sections 3 and 13.
local M = {}

---Move like Ctrl-w, resuming input when the destination is a live panel.
function M.move_window(direction, count)
  local previous = vim.api.nvim_get_current_win()
  vim.cmd.wincmd({ args = { direction }, count = count or 1 })
  local moved = previous ~= vim.api.nvim_get_current_win()
  if moved and vim.bo.buftype == "terminal" then
    require("iara.features.terminal").resume_panel_input()
  end
end

local function window_mapping(direction, name)
  return {
    function()
      M.move_window(direction, vim.v.count1)
    end,
    desc = "Go to " .. name .. " window",
  }
end

---@class IaraKeymap
---@field [1] string|function Right-hand side.
---@field desc string?

---@type table<string, IaraKeymap>
M.DEFAULTS = {
  ["n <Esc>"] = { "<cmd>nohlsearch<CR>", desc = "Clear search highlight" },
  ["n ;"] = { ":", desc = "Enter command line" },
  ["n <C-s>"] = { "<cmd>write<CR>", desc = "Save file" },
  ["n <C-h>"] = window_mapping("h", "left"),
  ["n <C-j>"] = window_mapping("j", "lower"),
  ["n <C-k>"] = window_mapping("k", "upper"),
  ["n <C-l>"] = window_mapping("l", "right"),
  ["n <Tab>"] = { "<cmd>bnext<CR>", desc = "Next buffer" },
  ["n <S-Tab>"] = { "<cmd>bprevious<CR>", desc = "Previous buffer" },
  ["n <leader>x"] = { "<cmd>bdelete<CR>", desc = "Close buffer" },
  ["n <leader>b"] = { "<cmd>enew<CR>", desc = "New buffer" },
  ["n <leader>n"] = { "<cmd>set number!<CR>", desc = "Toggle line numbers" },
  ["n <leader>rn"] = {
    "<cmd>set relativenumber!<CR>",
    desc = "Toggle relative numbers",
  },
  ["n <leader>/"] = { "gcc", desc = "Toggle comment", remap = true },
  ["x <leader>/"] = { "gc", desc = "Toggle comment", remap = true },
  ["n <leader>th"] = { "<cmd>IaraTheme<CR>", desc = "Themes" },
  ["n <leader>sd"] = {
    function()
      vim.diagnostic.setloclist()
    end,
    desc = "Diagnostics to location list",
  },
}

---@class IaraResolvedKeymap
---@field mode string
---@field lhs string
---@field rhs string|function
---@field opts table

---Split "<mode> <lhs>" into its parts.
---@return string|nil mode, string|nil lhs
local function parse_key(key)
  if type(key) ~= "string" then
    return nil
  end
  return key:match("^(%a+) (%S.*)$")
end

---@return string|nil problem
local function entry_problem(key, value)
  if not parse_key(key) then
    return ("keymaps key %s is not '<mode> <lhs>'"):format(vim.inspect(key))
  end
  if value == false then
    return nil
  end
  local rhs = type(value) == "table" and value[1]
  local valid = (type(rhs) == "string" or type(rhs) == "function")
    and (value.desc == nil or type(value.desc) == "string")
  if not valid then
    return ("keymaps[%q] must be false or { rhs, desc = string }"):format(key)
  end
end

---Merge `user` over the defaults. Invalid user entries are dropped (the
---default stays) and returned as problems.
---@param user table<string, any>|nil
---@return IaraResolvedKeymap[] keymaps Sorted by key.
---@return string[] problems
function M.resolve(user)
  local merged = vim.deepcopy(M.DEFAULTS)
  local problems = {}
  for key, value in pairs(user or {}) do
    local problem = entry_problem(key, value)
    if problem then
      table.insert(problems, problem)
    else
      merged[key] = value or nil
    end
  end
  local keys = vim.tbl_keys(merged)
  table.sort(keys)
  local resolved = {}
  for _, key in ipairs(keys) do
    local mode, lhs = parse_key(key)
    local opts = vim.deepcopy(merged[key])
    local rhs = table.remove(opts, 1)
    table.insert(resolved, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
  end
  table.sort(problems)
  return resolved, problems
end

local did_setup = false

---Define the default mappings merged with `config.keymaps`, once.
---@param config table Composed configuration.
function M.setup(config)
  if did_setup then
    return
  end
  did_setup = true
  local user = type(config) == "table" and config.keymaps or nil
  if user ~= nil and type(user) ~= "table" then
    vim.notify("Iara: keymaps must be a table", vim.log.levels.ERROR)
    user = nil
  end
  local keymaps, problems = M.resolve(user)
  for _, problem in ipairs(problems) do
    vim.notify("Iara: " .. problem, vim.log.levels.ERROR)
  end
  for _, map in ipairs(keymaps) do
    local ok, err = pcall(vim.keymap.set, map.mode, map.lhs, map.rhs, map.opts)
    if not ok then
      local text = "Iara: cannot map %s %s: %s"
      vim.notify(text:format(map.mode, map.lhs, err), vim.log.levels.ERROR)
    end
  end
end

return M
