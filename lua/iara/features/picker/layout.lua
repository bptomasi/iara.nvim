--- Symmetric Snacks picker layout shared by Iara pickers (task UX4).
---
--- The results frame (prompt and list, titled, with a footer) and the
--- preview are flex children of the root box, so Snacks splits the root
--- in two equal halves. Frames are thin straight lines (UX5, V13,
--- `iara.core.ui`): the prompt draws the top of the results frame and a
--- separator joined to its sides (`├──┤`), the list draws the sides and
--- the bottom, and the title sits inline on the top edge. The root size
--- is always even: an odd column (or line) goes to the outer margin,
--- never to one pane. When the preview is hidden, the results frame
--- takes the whole root.
---
--- Identity (V10, V13; design 09 sections 3.3 and 7): focus is the
--- border color. The focused pane's frame is `border_focus` with an
--- `accent` title, the other's the subtle `border` with a `muted` one;
--- titles are plain padded text, and the row under the cursor gets a
--- `▎` accent bar in a one-column status column of the list window.
local ui = require("iara.core.ui")

local M = {}

---Editors at least this wide put the preview beside the list.
M.WIDE_COLUMNS = 120

---Groups of a focused and an idle title: its text, then its frame.
local TITLE_GROUPS = {
  [true] = { "IaraSearchTitle", "IaraSearchBorderFocus" },
  [false] = { "IaraSearchCrumb", "IaraSearchBorder" },
}

---Columns the selection bar takes at the left of every list row.
M.BAR_WIDTH = 1

---Status column of a list window: the `▎` bar on the cursor row while
---the window shows its cursor line, a blank elsewhere. Pure Vim script,
---so a redraw calls no Lua.
M.BAR = "%{%&cursorline&&v:relnum==0"
  .. "?'%#IaraSearchSelectionBar#▎'"
  .. ":'%#IaraSearchSelectionGap# '%}"

---Groups of titles, frames, and the selection, and the semantic groups
---they fall back to when the colorscheme does not define them.
M.HIGHLIGHTS = {
  IaraSearchTitle = "FloatTitle",
  IaraSearchCrumb = "Comment",
  IaraSearchBorder = "FloatBorder",
  IaraSearchBorderFocus = "FloatBorder",
  IaraSearchSelection = "CursorLine",
  IaraSearchSelectionBar = "Special",
  IaraSearchSelectionGap = "NormalFloat",
}

---Define the fallback links without replacing a theme's groups.
function M.define_highlights()
  for name, link in pairs(M.HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

---Window options of a list window that shows the selection bar. No
---conceal (Snacks sets 2): Iara's rows conceal nothing, and with conceal
---on, every line drawn or set calls Tree-sitter's conceal-line callback
---(S11 profile: about 10% of the Lua time of a key burst).
---@return table wo
function M.list_wo()
  return { statuscolumn = M.BAR, conceallevel = 0 }
end

---Group of a title's text: the accent when `focused`, else muted.
---@param focused boolean
---@return string
function M.title_group(focused)
  return TITLE_GROUPS[focused == true][1]
end

---Group of a pane's frame: `border_focus` when `focused`, else `border`.
---@param focused boolean
---@return string
function M.border_group(focused)
  return TITLE_GROUPS[focused == true][2]
end

---Title chunks of plain padded text (` text `) in the focused (accent)
---or idle (muted) color, for the top border.
---@param text string
---@param focused boolean
---@return table[] chunks
function M.title_chunks(text, focused)
  return { { ui.label(text), M.title_group(focused) } }
end

---Largest even number not above `fraction` of `total`.
---@param total integer
---@param fraction number
---@return integer
local function even_share(total, fraction)
  local size = math.floor(total * fraction)
  return math.max(size - size % 2, 2)
end

---The results frame: the prompt (top edge, title, separator) over the
---list (sides, bottom edge, footer).
---@param size table? Box size fields (`width`, `height`, ...).
---@return table box Snacks layout box.
local function results_frame(size)
  return vim.tbl_extend("error", size or {}, {
    box = "vertical",
    border = "none",
    {
      win = "input",
      height = 1,
      border = ui.colored(ui.TOP, M.border_group(true)),
      title = "{title}",
      title_pos = "left",
    },
    -- The footer is replaced by the key hints once the picker knows its
    -- width.
    {
      win = "list",
      border = ui.colored(ui.BOTTOM, M.border_group(true)),
      footer = " ",
      footer_pos = "center",
    },
  })
end

---Snacks layout of an Iara picker for the current editor size.
---@return table layout Snacks layout box.
function M.layout()
  local results = results_frame()
  local preview = {
    win = "preview",
    title = "{preview}",
    title_pos = "left",
    border = ui.colored(ui.CHARS, M.border_group(false)),
    -- No `~` past the end of a short file, as in editor windows.
    wo = { fillchars = "eob: " },
  }
  if vim.o.columns >= M.WIDE_COLUMNS then
    local width = function()
      return even_share(vim.o.columns, 0.9)
    end
    local box = { box = "horizontal", width = width, height = 0.85 }
    return vim.list_extend(box, { results, preview })
  end
  local height = function()
    return even_share(vim.o.lines, 0.9)
  end
  local box = { box = "vertical", width = 0.95, height = height }
  return vim.list_extend(box, { results, preview })
end

---Lines of a compact picker's frame around its prompt and list.
local COMPACT_CHROME = 4

---Snacks layout of a compact picker without a preview window (a list
---of choices, such as themes): the results frame alone, centered,
---`width` columns wide inside and tall enough for `count` rows.
---@param count integer Number of items.
---@param width integer Inside width in columns.
---@return table layout Snacks layout box.
function M.compact(count, width)
  local height = math.min(count + COMPACT_CHROME, vim.o.lines - 4)
  return results_frame({
    -- The editor stays undimmed: the theme picker previews on it.
    backdrop = false,
    width = math.min(width + 2, vim.o.columns - 4),
    height = math.max(height, COMPACT_CHROME + 1),
  })
end

---Width of the results frame's inside (prompt and list), or nil when
---the picker has no open list window.
---@param picker table Snacks picker.
---@return integer|nil
function M.results_width(picker)
  local list = picker.list and picker.list.win
  if list and list:valid() then
    return vim.api.nvim_win_get_width(list.win)
  end
end

---Whether the picker's preview window has the focus (the results
---frame is then idle).
---@param picker table Snacks picker.
---@return boolean
function M.preview_focused(picker)
  local preview = picker.preview and picker.preview.win
  return preview ~= nil
    and preview:valid()
    and vim.api.nvim_get_current_win() == preview.win
end

---Draw the frame of a Snacks window in the focused or idle color,
---keeping its characters. Snacks keeps the border table, so the color
---lasts until its layout is updated, which redraws the titles (and so
---calls this again).
---@param win table|nil Snacks window.
---@param focused boolean
local function paint(win, focused)
  if not win or not win:valid() or type(win.opts.border) ~= "table" then
    return
  end
  local chars = vim.tbl_map(function(char)
    return type(char) == "table" and char[1] or char
  end, win.opts.border)
  local border = ui.colored(chars, M.border_group(focused))
  if vim.deep_equal(border, win.opts.border) then
    return
  end
  win.opts.border = border
  vim.api.nvim_win_set_config(win.win, { border = border })
end

---Color both frames for the focus: the preview's when it has the
---focus, else the results frame's (prompt and list).
---@param picker table Snacks picker.
function M.paint_focus(picker)
  local on_preview = M.preview_focused(picker)
  paint(picker.input and picker.input.win, not on_preview)
  paint(picker.list and picker.list.win, not on_preview)
  paint(picker.preview and picker.preview.win, on_preview)
end

---Show `title` inline on the top edge of the results frame, one dash
---after its corner, and color the frames for the focus. A string
---becomes plain title text, focused unless the preview has the focus.
---@param picker table Snacks picker.
---@param title string|table[] Text, or title chunks `{ text, group }`.
function M.set_title(picker, title)
  local input = picker.input and picker.input.win
  if not input or not input:valid() then
    return
  end
  local focused = not M.preview_focused(picker)
  if type(title) == "string" then
    title = M.title_chunks(title, focused)
  end
  input:set_title(ui.left_title(title, M.border_group(focused)), "left")
  M.paint_focus(picker)
end

---Show `chunks` at the left of the preview's top edge, one dash after
---its corner (no title when empty).
---@param picker table Snacks picker.
---@param chunks table[] Title chunks.
function M.set_preview_title(picker, chunks)
  local preview = picker.preview and picker.preview.win
  if preview and preview:valid() then
    local group = M.border_group(M.preview_focused(picker))
    preview:set_title(ui.left_title(chunks, group), "left")
  end
end

---Show `chunks` in the footer of the results frame (a blank when empty).
---@param picker table Snacks picker.
---@param chunks table[] Footer text chunks.
function M.set_footer(picker, chunks)
  local box = picker.list and picker.list.win
  if not box or not box:valid() then
    return
  end
  local footer = #chunks > 0 and chunks or " "
  if vim.deep_equal(box.opts.footer, footer) then
    return
  end
  box.opts.footer = footer
  vim.api.nvim_win_set_config(box.win, {
    footer = footer,
    footer_pos = box.opts.footer_pos,
  })
end

return M
