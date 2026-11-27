--- Split winbars and inactive windows (V4, design 09 sections 2.5 and
--- 3.2).
---
--- While two or more normal windows (not floating, showing a file
--- buffer) share the tab page, each of them at least `MIN_ROWS` tall
--- gets a one-line winbar: file icon, the path relative to the working
--- directory in a muted color, the file name, and a modified dot. The
--- current window's bar leads with an accent bar and its name in the
--- accent; the others are drawn in the subtle color. With one normal
--- window there is no winbar. Terminal and agent panels, the explorer,
--- and scratch windows never get one here (V7 owns the panel header).
---
--- The winbar is a literal string per window, built on window, buffer,
--- and size events, never per keystroke. Only winbars this module wrote
--- (they start with `%#IaraWinbar`) or empty ones are changed, so a
--- winbar set by another owner (A3's conflict view) is left alone.
---
--- 'cursorline' is the current window's: entering a normal window turns
--- it off in the other normal windows of the tab page and back on in
--- the entered one if Iara turned it off there. Floats do not count as
--- focus changes, so opening a picker keeps the editor's cursor line.
local icons = require("iara.core.icons")

local M = {}

---Smallest window height (with the winbar) that gets a winbar.
M.MIN_ROWS = 6

---Prefix of every winbar written here: it identifies ours.
M.PREFIX = "%#IaraWinbar"

---Accent bar of the current window (U+258E).
M.BAR = icons.START.bar

local did_setup = false
local pending = false

local function literal(text)
  return (text:gsub("%%", "%%%%"))
end

local function floating(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

---Whether `win` is a normal window: not floating, showing a file
---buffer (empty 'buftype').
---@param win integer
---@return boolean
function M.is_normal(win)
  if floating(win) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  return vim.bo[bufnr].buftype == ""
end

---Normal windows of the current tab page.
---@return integer[]
function M.normal_windows()
  return vim.tbl_filter(M.is_normal, vim.api.nvim_tabpage_list_wins(0))
end

local function owned(win)
  local text = vim.wo[win].winbar
  return text == "" or vim.startswith(text, M.PREFIX)
end

---Directory part and file name of a buffer, relative to the working
---directory; "[No Name]" for an unnamed buffer.
local function path_parts(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "", "[No Name]"
  end
  local relative = vim.fn.fnamemodify(name, ":~:.")
  local tail = vim.fn.fnamemodify(relative, ":t")
  return relative:sub(1, #relative - #tail), tail
end

---Winbar text of `win`, as the current window or not.
---@param win integer
---@param current boolean
---@return string
function M.text(win, current)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local dir, name = path_parts(bufnr)
  local glyph = icons.file(vim.api.nvim_buf_get_name(bufnr))
  local dot = vim.bo[bufnr].modified and " " .. icons.MODIFIED or ""
  if not current then
    return M.PREFIX
      .. "Inactive#"
      .. literal("  " .. glyph .. " ")
      .. "%<"
      .. literal(dir .. name .. dot)
  end
  return M.PREFIX
    .. "Bar#"
    .. M.BAR
    .. "%#IaraWinbarIcon#"
    .. literal(" " .. glyph .. " ")
    .. "%<%#IaraWinbarPath#"
    .. literal(dir)
    .. "%#IaraWinbarName#"
    .. literal(name)
    .. "%#IaraWinbarModified#"
    .. dot
end

---Height of `win` counting its winbar row.
local function rows(win)
  local winbar = vim.wo[win].winbar ~= "" and 1 or 0
  return vim.api.nvim_win_get_height(win) + winbar
end

local function set_winbar(win, text)
  if vim.wo[win].winbar ~= text then
    vim.wo[win].winbar = text
  end
end

---Set or clear the winbar of every window of the current tab page.
function M.update()
  pending = false
  local split = #M.normal_windows() >= 2
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if owned(win) then
      local wanted = split and M.is_normal(win) and rows(win) >= M.MIN_ROWS
      set_winbar(win, wanted and M.text(win, win == current) or "")
    end
  end
end

---Turn 'cursorline' off in the other normal windows of the tab page and
---back on in `win` where Iara turned it off.
---@param win integer
function M.focus(win)
  if not M.is_normal(win) then
    return
  end
  for _, other in ipairs(M.normal_windows()) do
    local options, vars = vim.wo[other], vim.w[other]
    if other == win and vars.iara_cursorline_off then
      vars.iara_cursorline_off = nil
      options.cursorline = true
    elseif other ~= win and options.cursorline then
      vars.iara_cursorline_off = true
      options.cursorline = false
    end
  end
end

---Coalesce the events of one change into one update.
local function schedule_update()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    -- A window may be gone or locked (command-line window) by now.
    if pending then
      pcall(M.update)
      pending = false
    end
  end)
end

local UPDATE_EVENTS = {
  "WinNew",
  "WinClosed",
  "WinEnter",
  "BufWinEnter",
  "BufModifiedSet",
  "BufFilePost",
  "WinResized",
  "VimResized",
  "TabEnter",
  "DirChanged",
  "TermOpen",
}

---Manage split winbars and the inactive windows' cursor line, once.
---A user value of 'winbar' in `config.options` turns the winbars off.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup("IaraWinbar", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      M.focus(vim.api.nvim_get_current_win())
    end,
  })
  if require("iara.config").get("options.winbar") ~= nil then
    return
  end
  vim.api.nvim_create_autocmd(UPDATE_EVENTS, {
    group = group,
    callback = schedule_update,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "buftype",
    callback = schedule_update,
  })
end

return M
