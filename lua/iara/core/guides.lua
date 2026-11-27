--- Native indent guides (task V8, design 09 section 3.2).
---
--- Guides are 'listchars' drawn by Neovim itself: a `│` at every
--- 'shiftwidth' of leading spaces (`leadmultispace`) and at every leading
--- tab (`leadtab`), in the `Whitespace` group. They cost nothing per
--- keystroke: no decoration provider, no extmarks, no timer. They are set
--- window-locally, for the buffer the window shows, and only for eligible
--- file buffers in normal windows; conservative buffers (large files and
--- long lines), special buffers, and floats get the global 'list' and
--- 'listchars' back. Blank lines show no guide (accepted in the design).
---
--- With 'noexpandtab' the indentation is tabs and leading spaces are
--- alignment, so only tabs get guides.
local M = {}

---The guide glyph (light vertical bar).
M.GUIDE = "\u{2502}"

---Options whose change redraws the guides of the current buffer.
M.OPTIONS = { "shiftwidth", "tabstop", "expandtab" }

local api = vim.api

local did_setup = false

---'listchars' with a guide at every indentation level.
---@param width integer Indent width in columns ('shiftwidth', or
---  'tabstop' when it is 0); values below 1 count as 1.
---@param expandtab boolean Indentation is spaces.
---@return string
function M.listchars(width, expandtab)
  local parts = { "tab:  ", "leadtab:" .. M.GUIDE .. " ", "nbsp:+" }
  if expandtab then
    local spaces = (" "):rep(math.max(width, 1) - 1)
    table.insert(parts, "leadmultispace:" .. M.GUIDE .. spaces)
  end
  return table.concat(parts, ",")
end

---Whether `win` should draw guides for the buffer it shows.
---@param win integer
---@return boolean
function M.wanted(win)
  if api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local bufnr = api.nvim_win_get_buf(win)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  return require("iara.core.eligibility").is_eligible(bufnr)
end

local function set_local(win, name, value)
  if vim.wo[win][name] ~= value then
    api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
end

---Show or hide the guides of `win` for the buffer it shows now.
---@param win integer
function M.update(win)
  if not api.nvim_win_is_valid(win) then
    return
  end
  if not M.wanted(win) then
    set_local(win, "listchars", vim.go.listchars)
    set_local(win, "list", vim.go.list)
    return
  end
  local bo = vim.bo[api.nvim_win_get_buf(win)]
  local width = bo.shiftwidth > 0 and bo.shiftwidth or bo.tabstop
  set_local(win, "listchars", M.listchars(width, bo.expandtab))
  set_local(win, "list", true)
end

---Update every window that shows `bufnr`.
---@param bufnr integer
local function update_buffer(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    M.update(win)
  end
end

---Keep guides in step with buffers, indentation options, and
---eligibility. Personal 'list' or 'listchars' options turn them off.
---@param manage boolean False when the user set 'list' or 'listchars'.
function M.setup(manage)
  if did_setup or manage == false then
    return
  end
  did_setup = true
  local group = api.nvim_create_augroup("IaraGuides", { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "TermOpen" }, {
    group = group,
    callback = function()
      M.update(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = M.OPTIONS,
    callback = function()
      update_buffer(api.nvim_get_current_buf())
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = function(args)
      update_buffer(args.data.bufnr)
    end,
  })
end

return M
