--- Panel presentation (task V7, design 09 section 3.6). Terminal and
--- agent panels follow the theme's background mode. Each has a header:
---
--- - docked: a winbar with a bar (`tide` for shells, `hint` for agents,
---   `accent` when focused), the icon and label, the launch directory,
---   the job state, and right-aligned key hints, dropped when narrow;
--- - float: one straight frame, `border_focus` when focused and the
---   subtle `border` when not, a title at the left of its top edge
---   (accent when focused), the job state chip at its right, and key
---   hints in the footer.
---
--- Headers are rebuilt on job state changes, focus changes, resizes, and
--- buffer changes of a panel window; terminal output never touches them,
--- so a streaming panel costs nothing extra per line or keystroke.
local float = require("iara.core.float")
local icons = require("iara.core.icons")
local title = require("iara.features.terminal.title")

local M = {}

---Window variable that marks a window decorated as a panel.
M.MARK = "iara_panel"

---Group of the panel surface; also the winbar fill.
M.SURFACE = "IaraPanel"

local SURFACE_HIGHLIGHT = table.concat({
  "Normal:IaraPanel",
  "NormalNC:IaraPanel",
  "NormalFloat:IaraPanel",
  "WinBar:IaraPanelHeader",
  "WinBarNC:IaraPanelHeader",
}, ",")

---Frame of a floating panel, idle and focused (V13: focus is the border
---color). Always mapped, so V3's focus handling
---(`iara.core.float.focus`) leaves the panel's own frame alone; the
---title's idle groups are remapped with the border.
local FRAME = {
  [false] = "FloatBorder:FloatBorder,FloatTitle:FloatTitle",
  [true] = "FloatBorder:IaraFloatBorderFocus,"
    .. "FloatTitle:IaraFloatTitleFocus",
}

---Neutral links of the panel groups under a foreign colorscheme.
M.FALLBACK_LINKS = {
  IaraPanel = "NormalFloat",
  IaraPanelHeader = "WinBar",
  IaraPanelBarShell = "String",
  IaraPanelBarAgent = "Special",
  IaraPanelBarFocus = "Title",
  IaraPanelTitle = "Title",
  IaraPanelCwd = "Comment",
  IaraPanelRunning = "String",
  IaraPanelStopping = "WarningMsg",
  IaraPanelExited = "ErrorMsg",
  IaraPanelDone = "Comment",
  IaraPanelKey = "Special",
  IaraPanelHint = "Comment",
}

---@class IaraPanelHint
---@field lhs string|nil Normal-mode mapping that must exist to show it.
---@field key string Key as shown ("<leader>" becomes the leader).
---@field text string What the key does.

---Key hints per kind, most important first: narrow headers drop them
---from the end. A hint whose mapping was removed is not shown.
---@type table<string, IaraPanelHint[]>
M.HINTS = {
  terminal = {
    { lhs = "<F7>", key = "F7", text = "hide" },
    { lhs = "<leader>tn", key = "<leader>tn", text = "new" },
    { key = "^\\^n", text = "normal" },
  },
  agent = {
    { lhs = "<leader>at", key = "<leader>at", text = "hide" },
    { lhs = "<leader>ap", key = "<leader>ap", text = "move" },
    { key = "^\\^n", text = "normal" },
  },
}

---Leader as shown in hints: a visible symbol for Space.
local function leader()
  local key = vim.g.mapleader or "\\"
  return key == " " and "␣" or key
end

---Hints of `kind` whose mappings exist, keys as typed.
---@param kind "terminal"|"agent"
---@return { key: string, text: string }[]
function M.hints(kind)
  local result = {}
  for _, hint in ipairs(M.HINTS[kind] or {}) do
    local mapped = not hint.lhs or vim.fn.maparg(hint.lhs, "n") ~= ""
    if mapped then
      local key = hint.key:gsub("<leader>", leader())
      table.insert(result, { key = key, text = hint.text })
    end
  end
  return result
end

---Text and group of a job state.
---@param state string "running", "stopping", "exited N", or "failed".
---@return string text, string group
function M.state(state)
  if state == "running" then
    return "● running", "IaraPanelRunning"
  end
  if state == "stopping" then
    return "● stopping", "IaraPanelStopping"
  end
  if state == "exited 0" or state == "exited" then
    return state, "IaraPanelDone"
  end
  return state, "IaraPanelExited"
end

local function width_of(chunks)
  local total = 0
  for _, chunk in ipairs(chunks) do
    total = total + vim.api.nvim_strwidth(chunk[1])
  end
  return total
end

---Hint chunks: keys in `IaraPanelKey`, texts in `IaraPanelHint`, two
---spaces apart.
local function hint_chunks(hints)
  local chunks = {}
  for index, hint in ipairs(hints) do
    local gap = index > 1 and "  " or ""
    table.insert(chunks, { gap .. hint.key, "IaraPanelKey" })
    table.insert(chunks, { " " .. hint.text, "IaraPanelHint" })
  end
  return chunks
end

---Hints that fit in `room` columns, dropped from the end.
local function fitting_hints(hints, room)
  local kept = vim.list_slice(hints, 1, #hints)
  while #kept > 0 and width_of(hint_chunks(kept)) > room do
    table.remove(kept)
  end
  return kept
end

---Label provider (`iara.features.terminal.panel.set_title_provider`);
---nil uses the description's title.
---@type (fun(bufnr: integer): string)|nil
local title_provider = nil

---Set the provider of panel labels.
---@param provider (fun(bufnr: integer): string)|nil
function M.set_title_provider(provider)
  title_provider = provider
end

---Description of a terminal buffer with the provider's label.
---@return IaraTerminalDescription|nil
local function describe(bufnr)
  local description = title.describe(bufnr)
  local label = description and title_provider and title_provider(bufnr)
  if label and label ~= "" then
    description.title = label
  end
  return description
end

local function icon(description)
  return description.kind == "agent" and icons.AGENT or icons.TERMINAL
end

---Bar group of a docked header.
local function bar_group(description, focused)
  if focused then
    return "IaraPanelBarFocus"
  end
  return description.kind == "agent" and "IaraPanelBarAgent"
    or "IaraPanelBarShell"
end

---Left part of a docked header: bar, icon and label, the launch
---directory when wanted, and the job state.
local function docked_left(description, focused, with_cwd)
  local state, state_group = M.state(description.state)
  local label = " " .. icon(description) .. " " .. description.title
  local chunks = {
    { "▎", bar_group(description, focused) },
    { label, "IaraPanelTitle" },
  }
  if with_cwd and description.cwd then
    local cwd = vim.fn.fnamemodify(description.cwd, ":~")
    table.insert(chunks, { "  " .. cwd, "IaraPanelCwd" })
  end
  table.insert(chunks, { "  " .. state, state_group })
  return chunks
end

local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

local function statusline_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    table.insert(parts, ("%%#%s#%s"):format(chunk[2], escape(chunk[1])))
  end
  return table.concat(parts)
end

---Docked header chunks for a window `width` columns wide: left part,
---then right-aligned hints. The directory goes first when narrow, then
---the hints from the end.
---@param description IaraTerminalDescription
---@param width integer
---@param focused boolean
---@return table[] left, table[] right Chunks `{ text, group }`.
function M.docked_chunks(description, width, focused)
  local hints = M.hints(description.kind)
  local all_hints = width_of(hint_chunks(hints)) + 2
  local left = docked_left(description, focused, true)
  if width_of(left) + all_hints > width then
    left = docked_left(description, focused, false)
  end
  local kept = fitting_hints(hints, width - width_of(left) - 2)
  local right = hint_chunks(kept)
  if #right > 0 then
    table.insert(right, { " ", "IaraPanelHint" })
  end
  return left, right
end

---Winbar of a docked panel showing `bufnr`; "" for other buffers.
---@param bufnr integer
---@param width integer
---@param focused boolean
---@return string
function M.winbar(bufnr, width, focused)
  local description = describe(bufnr)
  if not description then
    return ""
  end
  local left, right = M.docked_chunks(description, width, focused)
  return statusline_text(left)
    .. "%#IaraPanelHeader#%="
    .. statusline_text(right)
end

---Title chunks of a float `width` columns wide (inside the corners):
---the float language's title (`iara.core.float.title`: accent when
---focused, muted when idle), a frame filler in the frame's color, the
---state chip, and a dash. The state goes when it does not fit; the
---label is cut last.
---@param description IaraTerminalDescription
---@param width integer
---@param focused boolean
---@return table[]
function M.float_title(description, width, focused)
  local label = icon(description) .. " " .. description.title
  local state, state_group = M.state(description.state)
  local chip = { " " .. state .. " ", state_group }
  local chunks = float.title(label, focused)
  local fill = width - float.width(chunks) - float.width({ chip }) - 1
  if fill < 1 then
    return float.title(label, focused, width)
  end
  table.insert(chunks, float.rule(fill, focused))
  table.insert(chunks, chip)
  table.insert(chunks, float.rule(1, focused))
  return chunks
end

---Footer chunks of a float: V3's key hints (`iara.core.float.footer`)
---that fit between a border dash at each end.
---@param description IaraTerminalDescription
---@param width integer
---@return table[]
function M.float_footer(description, width)
  local hints = vim.tbl_map(function(hint)
    return { hint.key, hint.text }
  end, M.hints(description.kind))
  return float.footer(hints, width - 2)
end

local function set_local(win, name, value)
  vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

local function is_floating(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function decorate_float(win, description, focused)
  local width = vim.api.nvim_win_get_width(win)
  set_local(win, "winbar", "")
  local frame = FRAME[focused == true]
  set_local(win, "winhighlight", SURFACE_HIGHLIGHT .. "," .. frame)
  local footer = M.float_footer(description, width)
  vim.api.nvim_win_set_config(win, {
    title = M.float_title(description, width, focused),
    title_pos = "left",
    footer = #footer > 0 and footer or "",
    footer_pos = "center",
  })
end

---Put the panel surface and header on `win`, which shows a terminal
---buffer: the winbar when docked, the border title and footer when
---floating. Other buffers get no header.
---@param win integer
function M.decorate(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local description = describe(bufnr)
  if not description then
    return
  end
  M.setup()
  vim.w[win][M.MARK] = true
  local focused = win == vim.api.nvim_get_current_win()
  if is_floating(win) then
    decorate_float(win, description, focused)
    return
  end
  set_local(win, "winhighlight", SURFACE_HIGHLIGHT)
  local width = vim.api.nvim_win_get_width(win)
  set_local(win, "winbar", M.winbar(bufnr, width, focused))
end

---Remove the panel surface and header from a window that no longer
---shows a panel (the user put another buffer in it).
---@param win integer
function M.clear(win)
  if not vim.api.nvim_win_is_valid(win) or not vim.w[win][M.MARK] then
    return
  end
  vim.w[win][M.MARK] = nil
  set_local(win, "winhighlight", "")
  set_local(win, "winbar", "")
  if is_floating(win) then
    vim.api.nvim_win_set_config(win, { title = "", footer = "" })
  end
end

---Panel windows of the current tab.
local function panel_windows()
  local panel = require("iara.features.terminal.panel")
  local wins = {}
  for _, item in ipairs({ panel.shell, panel.agent }) do
    local win = item:window()
    if win then
      table.insert(wins, win)
    end
  end
  return wins
end

---Rebuild the header of every panel window in the current tab.
function M.refresh()
  for _, win in ipairs(panel_windows()) do
    M.decorate(win)
  end
end

---A decorated window that shows something else loses its decoration.
local function on_buf_win_enter()
  local win = vim.api.nvim_get_current_win()
  if not vim.w[win][M.MARK] then
    return
  end
  local panel = require("iara.features.terminal.panel")
  if panel.containing(win) then
    M.decorate(win)
  else
    M.clear(win)
  end
end

---Under a foreign colorscheme the panel groups link to neutral ones.
local function link_fallbacks()
  if require("iara.theme").current() then
    return
  end
  for name, target in pairs(M.FALLBACK_LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local configured = false

---Create the autocommands that keep headers current, once. Called by the
---first `decorate`, so editors that never show a panel pay nothing.
function M.setup()
  if configured then
    return
  end
  configured = true
  local group = vim.api.nvim_create_augroup("IaraPanelHeader", {})
  local autocmd = vim.api.nvim_create_autocmd
  autocmd({ "WinEnter", "WinResized", "VimResized" }, {
    group = group,
    callback = M.refresh,
  })
  autocmd("User", {
    group = group,
    pattern = "IaraTerminalChanged",
    callback = M.refresh,
  })
  autocmd("BufWinEnter", { group = group, callback = on_buf_win_enter })
  autocmd("ColorScheme", { group = group, callback = link_fallbacks })
  link_fallbacks()
end

return M
