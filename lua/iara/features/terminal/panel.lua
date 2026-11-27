--- Terminal panels: windows that show Iara-owned terminal buffers at a
--- side of the current tab (bottom, top, left, right) or floating in its
--- center.
---
--- There are two panels per session (UX2): `shell` for shells and
--- `agent` for agent sessions, each with its own position and sizes, so
--- both can be visible at once. Showing a panel in another tab moves it
--- there instead of duplicating it. Changing the position moves the same
--- window, so the buffer and its job are untouched. Hiding closes only
--- the window; the buffer and its job keep running. Panels never start,
--- stop, or choose terminals; `iara.features.terminal` does. Their
--- surface and headers are `iara.features.terminal.header`'s (V7).
local retention = require("iara.core.term_retention")

local M = {}

---Label provider of panel headers, kept until the header loads.
---@type (fun(bufnr: integer): string)|nil
local title_provider = nil

---The header module, loaded when the first panel opens so startup does
---not pay for it.
local function header()
  local module = package.loaded["iara.features.terminal.header"]
  if module then
    return module
  end
  module = require("iara.features.terminal.header")
  module.set_title_provider(title_provider)
  return module
end

local MIN_HEIGHT = 3
local MIN_WIDTH = 20

---Share of the columns a left or right panel takes before resizing.
local SIDE_SHARE = 0.4

---Share of the editor area a floating panel takes before resizing.
local FLOAT_SHARE = 0.8

---@alias IaraPanelPosition "bottom"|"top"|"left"|"right"|"float"

---@type table<string, true>
M.POSITIONS =
  { bottom = true, top = true, left = true, right = true, float = true }

---Cycle order of `next_position`.
---@type IaraPanelPosition[]
M.ORDER = { "bottom", "right", "top", "left", "float" }

local SPLITS = { bottom = "below", top = "above", left = "left" }
SPLITS.right = "right"

local VERTICAL = { left = true, right = true }

---@class IaraPanel
---@field name string "shell" or "agent".
---@field win integer|nil Panel window, wherever it currently is.
---@field side IaraPanelPosition|nil Where `win` currently is.
---@field place IaraPanelPosition Where the panel opens next.
---@field sizes table<string, { width: integer?, height: integer? }>
---@field origins table<integer, integer> Editing window per tab page.
local Panel = {}
Panel.__index = Panel

---@type IaraPanel[]
local panels = {}

local function is_floating(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function in_current_tab(win)
  return vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
end

---Rows available to windows: neither the command line nor the global
---status line.
local function editor_lines()
  local status = vim.o.laststatus > 0 and 1 or 0
  return math.max(MIN_HEIGHT, vim.o.lines - vim.o.cmdheight - status)
end

---@return integer|nil
function Panel:current()
  local win = self.win
  local valid = win and vim.api.nvim_win_is_valid(win)
  -- A window the user filled with another buffer belongs to the user.
  if not valid or not retention.is_owned(vim.api.nvim_win_get_buf(win)) then
    self.win = nil
    return nil
  end
  return win
end

local function default_size(side)
  if side == "float" then
    return {
      width = math.max(MIN_WIDTH, math.floor(vim.o.columns * FLOAT_SHARE)),
      height = math.max(MIN_HEIGHT, math.floor(editor_lines() * FLOAT_SHARE)),
    }
  end
  if VERTICAL[side] then
    return {
      width = math.max(MIN_WIDTH, math.floor(vim.o.columns * SIDE_SHARE)),
    }
  end
  return { height = math.max(MIN_HEIGHT, math.floor(vim.o.lines / 3)) }
end

---Size for `side`: the remembered one, kept inside the screen.
function Panel:size(side)
  local size = vim.deepcopy(self.sizes[side] or default_size(side))
  if size.width then
    size.width = math.min(size.width, math.max(1, vim.o.columns - 2))
  end
  if size.height then
    size.height = math.min(size.height, math.max(1, editor_lines() - 2))
  end
  return size
end

---Window configuration that puts a window at `side` of the whole tab, or
---centered over it with a straight border for "float"; the header
---decorates it once open.
function Panel:layout(side)
  local size = self:size(side)
  if side ~= "float" then
    return {
      split = SPLITS[side],
      win = -1,
      width = size.width,
      height = size.height,
    }
  end
  return require("iara.core.ui").float({
    relative = "editor",
    width = size.width,
    height = size.height,
    row = math.max(0, math.floor((editor_lines() - size.height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - size.width - 2) / 2)),
    zindex = 40,
  })
end

---Remember the size the panel window has at its current side.
function Panel:remember_size(win)
  local side = self.side
  if not side then
    return
  end
  local size = {}
  if side == "float" or VERTICAL[side] then
    size.width = vim.api.nvim_win_get_width(win)
  end
  if side == "float" or not VERTICAL[side] then
    size.height = vim.api.nvim_win_get_height(win)
  end
  self.sizes[side] = size
end

---Apply a layout; a moved split takes its size afterwards as well, since
---the layout change may share space out again.
local function apply_layout(win, config)
  vim.api.nvim_win_set_config(win, config)
  if config.relative then
    return
  end
  if config.width then
    vim.api.nvim_win_set_width(win, config.width)
  else
    vim.api.nvim_win_set_height(win, config.height)
  end
end

---Keep a split panel's size when other windows open or close.
local function fix_size(win, side)
  vim.wo[win].winfixheight = side == "bottom" or side == "top"
  vim.wo[win].winfixwidth = VERTICAL[side] == true
end

local function split_count(tabpage)
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if not is_floating(win) then
      count = count + 1
    end
  end
  return count
end

---A buffer to leave in a window that cannot be closed: the first listed
---editing buffer, or a new empty one.
local function replacement_buffer()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local listed = vim.bo[bufnr].buflisted and vim.bo[bufnr].buftype == ""
    if listed and vim.api.nvim_buf_is_loaded(bufnr) then
      return bufnr
    end
  end
  return vim.api.nvim_create_buf(true, false)
end

---Whether `win` is the only split of its tab (closing it closes the tab).
local function is_last_split(win)
  local tabpage = vim.api.nvim_win_get_tabpage(win)
  return not is_floating(win) and split_count(tabpage) <= 1
end

---Take the panel window away without touching its buffer. The last
---window of a tab is kept and shows an editing buffer instead.
function Panel:release(win)
  self.win = nil
  if is_last_split(win) then
    header().clear(win)
    vim.api.nvim_win_set_buf(win, replacement_buffer())
    return
  end
  self:remember_size(win)
  -- `force` hides the buffer even with 'nohidden'; it never deletes it.
  vim.api.nvim_win_close(win, true)
end

---Whether `win` is the window of any panel.
local function is_panel_window(win)
  for _, panel in ipairs(panels) do
    if panel.win == win then
      return true
    end
  end
  return false
end

function Panel:restore_focus()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local origin = self.origins[tabpage]
  local valid = origin
    and vim.api.nvim_win_is_valid(origin)
    and vim.api.nvim_win_get_tabpage(origin) == tabpage
  if valid then
    vim.api.nvim_set_current_win(origin)
  end
end

function Panel:remember_origin()
  local win = vim.api.nvim_get_current_win()
  if not is_panel_window(win) and not is_floating(win) then
    self.origins[vim.api.nvim_get_current_tabpage()] = win
  end
end

local function set_window_options(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
end

function Panel:open_window(bufnr)
  local config = self:layout(self.place)
  local win = vim.api.nvim_open_win(bufnr, false, config)
  self.side = self.place
  fix_size(win, self.side)
  set_window_options(win)
  header().decorate(win)
  return win
end

---Move the panel window to `side` of its tab, keeping the window, its
---buffer, and the job. The only split of a tab cannot move and stays.
function Panel:move(win, side)
  if is_last_split(win) then
    return
  end
  self:remember_size(win)
  local config = self:layout(side)
  if not pcall(apply_layout, win, config) then
    return
  end
  self.side = side
  fix_size(win, side)
  header().decorate(win)
end

---Close the panel window; focus returns to the editing window that was
---current before the panel was shown, when the panel had it.
function Panel:close(win)
  local had_focus = vim.api.nvim_get_current_win() == win
  self:release(win)
  if had_focus then
    self:restore_focus()
  end
end

---Panel window in the current tab, if the panel is visible here.
---@return integer|nil win
function Panel:window()
  local win = self:current()
  if win and in_current_tab(win) then
    return win
  end
  return nil
end

---Buffer shown by the panel in the current tab.
---@return integer|nil bufnr
function Panel:buffer()
  local win = self:window()
  return win and vim.api.nvim_win_get_buf(win) or nil
end

---@return IaraPanelPosition position Where the panel opens next.
function Panel:position()
  return self.place
end

---Set where the panel opens; a panel visible in the current tab moves
---there at once, without restarting its job. Raises for an unknown side.
---@param side IaraPanelPosition
function Panel:set_position(side)
  if not M.POSITIONS[side] then
    error("iara.features.terminal.panel: unknown position " .. tostring(side))
  end
  self.place = side
  local win = self:window()
  if win and self.side ~= side then
    self:move(win, side)
  end
end

---Show `bufnr` in the panel of the current tab and focus it, moving the
---panel here from another tab. Raises when no window can be opened (for
---example in the command-line window).
---@param bufnr integer Owned terminal buffer.
---@return integer win
function Panel:show(bufnr)
  self:remember_origin()
  local win = self:current()
  if win and not in_current_tab(win) then
    self:release(win)
    win = nil
  end
  if win then
    vim.api.nvim_win_set_buf(win, bufnr)
    if self.side ~= self.place then
      self:move(win, self.place)
    end
    header().decorate(win)
  else
    win = self:open_window(bufnr)
  end
  self.win = win
  vim.api.nvim_set_current_win(win)
  return win
end

---Hide the panel of the current tab. Focus returns to the editing window
---that was current before the panel was shown, when the panel had it.
---@return boolean hidden False when the panel was not visible here.
function Panel:hide()
  local win = self:window()
  if not win then
    return false
  end
  self:close(win)
  return true
end

---Close the panel, in any tab, if it shows `bufnr`; focus returns as for
---hide(). The buffer and its job are left alone.
---@param bufnr integer
---@return boolean closed
function Panel:close_buffer(bufnr)
  local win = self:current()
  if not win or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return false
  end
  self:close(win)
  return true
end

---@param name string
---@param place IaraPanelPosition
---@return IaraPanel
local function new(name, place)
  local panel = setmetatable({
    name = name,
    place = place,
    sizes = {},
    origins = {},
  }, Panel)
  table.insert(panels, panel)
  return panel
end

---Panel of shells (roles main and shell); opens at the bottom.
M.shell = new("shell", "bottom")

---Panel of agent sessions; opens at the right.
M.agent = new("agent", "right")

---@param role "main"|"shell"|"agent"
---@return IaraPanel
function M.for_role(role)
  return role == "agent" and M.agent or M.shell
end

---The panel whose window is `win`, if any.
---@param win integer
---@return IaraPanel|nil
function M.containing(win)
  for _, panel in ipairs(panels) do
    if panel:current() == win then
      return panel
    end
  end
  return nil
end

---Position after `side` in `ORDER`.
---@param side IaraPanelPosition
---@return IaraPanelPosition
function M.next_position(side)
  for index, candidate in ipairs(M.ORDER) do
    if candidate == side then
      return M.ORDER[index % #M.ORDER + 1]
    end
  end
  return M.ORDER[1]
end

---Set the label provider of panel headers (the terminal's clean label).
---@param provider fun(bufnr: integer): string
function M.set_title_provider(provider)
  title_provider = provider
  local module = package.loaded["iara.features.terminal.header"]
  if module then
    module.set_title_provider(provider)
  end
end

return M
