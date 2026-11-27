--- Search mappings and commands: the `features.search` init step.
---
--- `Space ff` finds files by name, `Space fw` finds text in files, and
--- `Space fa` finds files by name including hidden and ignored files
--- (symlinks are still not followed); `Space fr` resumes the last search
--- (task UX1). Mappings are normal mode only. A `config.keymaps` entry
--- for the same "<mode> <lhs>" (a replacement or `false`) wins over these
--- defaults; core keymaps (F6) applies it.
---
--- The search root is snapshotted from the current buffer, so every entry
--- point first leaves picker and floating windows for the editing window
--- that invoked them: opening from inside the picker would otherwise
--- search the root of the picker's scratch buffer.
local M = {}

---@class IaraSearchMapping
---@field mode string
---@field lhs string
---@field desc string
---@field request IaraSearchRequest? Initial request of the opened search.
---@field resume boolean? Resume the last search instead.

---@type IaraSearchMapping[]
M.MAPPINGS = {
  {
    mode = "n",
    lhs = "<leader>ff",
    desc = "Find files",
    request = { mode = "files" },
  },
  {
    mode = "n",
    lhs = "<leader>fw",
    desc = "Find in files (grep)",
    request = { mode = "content" },
  },
  {
    mode = "n",
    lhs = "<leader>fa",
    desc = "Find files, including hidden and ignored",
    request = { mode = "files", hidden = true, ignored = true },
  },
  {
    mode = "n",
    lhs = "<leader>fr",
    desc = "Resume the last search",
    resume = true,
  },
}

local function search()
  return require("iara.features.search")
end

---Picker windows (input, list, preview) and floats never own the root.
local function is_editing_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local filetype = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return not vim.startswith(filetype, "snacks_picker")
    and not vim.w[win].snacks_picker_preview
end

---The editing window that invoked the search: the current one, else the
---previous one, else the first editing window of the tab page.
---@return integer|nil win
local function invoking_window()
  local current = vim.api.nvim_get_current_win()
  if is_editing_window(current) then
    return current
  end
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= 0 and is_editing_window(previous) then
    return previous
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editing_window(win) then
      return win
    end
  end
end

---Focus the invoking editing window; false when there is none.
local function focus_invoking_window()
  local win = invoking_window()
  if not win then
    vim.notify("Iara: no editing window to search from", vim.log.levels.WARN)
    return false
  end
  vim.api.nvim_set_current_win(win)
  return true
end

---Open a search from the invoking editing window, so its buffer gives
---the root even when called from inside the picker.
---@param request IaraSearchRequest? Copied; the caller's table is kept.
---@return table|nil session Nil when there is no editing window.
function M.open(request)
  if not focus_invoking_window() then
    return nil
  end
  return search().open(vim.deepcopy(request or {}))
end

---Resume the previous search from the invoking editing window.
---@return table|nil session
function M.resume()
  if not focus_invoking_window() then
    return nil
  end
  return search().resume()
end

local function create_mappings(user_keymaps)
  for _, mapping in ipairs(M.MAPPINGS) do
    if user_keymaps[mapping.mode .. " " .. mapping.lhs] == nil then
      vim.keymap.set(mapping.mode, mapping.lhs, function()
        if mapping.resume then
          return M.resume()
        end
        M.open(mapping.request)
      end, { desc = mapping.desc })
    end
  end
end

local function create_commands()
  vim.api.nvim_create_user_command("IaraFiles", function(args)
    M.open({ mode = "files", query = args.args })
  end, {
    nargs = "*",
    desc = "Find files by name, optionally with a query",
  })
  vim.api.nvim_create_user_command("IaraGrep", function(args)
    M.open({ mode = "content", query = args.args })
  end, {
    nargs = "*",
    desc = "Find text in files, optionally with a query",
  })
  vim.api.nvim_create_user_command("IaraSearchResume", function()
    M.resume()
  end, { desc = "Resume the previous search" })
end

---Define the search mappings (unless `config.keymaps` names them) and
---the `:IaraFiles`, `:IaraGrep`, and `:IaraSearchResume` commands. Runs
---only when `features.search` is enabled (init skips the step
---otherwise).
---@param config table Composed configuration.
function M.setup(config)
  local user_keymaps = type(config) == "table" and config.keymaps or nil
  create_mappings(type(user_keymaps) == "table" and user_keymaps or {})
  create_commands()
end

return M
