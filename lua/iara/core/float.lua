--- The float language (tasks V3, V13; design 09 sections 2.4 and 7):
--- chunk builders for titles and key-hint footers on a float's straight
--- border, and the focused look of floats that do not style their own
--- frame.
---
--- Focus is the border color: an idle frame is the subtle `border` role
--- with a `muted` title; the focused float's frame is `border_focus`
--- with an `accent` title. Titles are plain padded text on the top
--- border (`┌─ Find files ───┐`), never pills or caps, so every cell has
--- one background. Builders return `{ text, group }` chunks for
--- `nvim_open_win`'s `title` and `footer`; they never exceed the width
--- they are given. Idle chunks use `FloatBorder` and `FloatTitle`, which
--- a window's 'winhighlight' remaps; that is how `focus` lights them.
local M = {}

---Most hints a footer shows.
M.MAX_HINTS = 5

---Between two footer hints.
M.HINT_SEPARATOR = " · "

---Groups of an idle and a focused frame.
M.GROUPS = {
  idle = { border = "FloatBorder", title = "FloatTitle" },
  focused = { border = "IaraFloatBorderFocus", title = "IaraFloatTitleFocus" },
}

---Groups of footer hints: keys, their descriptions, and the separator.
M.FOOTER = { key = "IaraFloatFooterKey", text = "FloatFooter" }

---Neutral links of the groups above under a foreign colorscheme.
M.FALLBACK_LINKS = {
  IaraFloatBorderFocus = "FloatBorder",
  IaraFloatTitleFocus = "FloatTitle",
  IaraFloatFooterKey = "Special",
}

---'winhighlight' entries that give a float the focused frame.
M.FOCUS_WINHIGHLIGHT = "FloatBorder:IaraFloatBorderFocus,"
  .. "FloatTitle:IaraFloatTitleFocus"

local ELLIPSIS = "…"

local function width_of(text)
  return vim.api.nvim_strwidth(text)
end

---Display width of title or footer chunks.
---@param chunks table[] `{ text, group }` chunks.
---@return integer
function M.width(chunks)
  local total = 0
  for _, chunk in ipairs(chunks) do
    total = total + width_of(chunk[1])
  end
  return total
end

---Groups of a focused or an idle frame.
---@param focused boolean|nil
---@return { border: string, title: string }
function M.groups(focused)
  return focused and M.GROUPS.focused or M.GROUPS.idle
end

---Border characters of a focused or idle frame with their group, for
---floats that hold the focus while they are open.
---@param chars string[] Eight characters (`iara.core.ui.CHARS`).
---@param focused boolean|nil
---@return table[]
function M.border(chars, focused)
  return require("iara.core.ui").colored(chars, M.groups(focused).border)
end

---A run of `count` border dashes in the frame's color, to fill a title
---line between its parts.
---@param count integer
---@param focused boolean|nil
---@return table chunk
function M.rule(count, focused)
  return { ("─"):rep(math.max(count, 0)), M.groups(focused).border }
end

---`text` cut to at most `max` display cells, ending in an ellipsis when
---cut; "" when not even the ellipsis fits.
---@param text string
---@param max integer
---@return string
function M.truncate(text, max)
  if width_of(text) <= max then
    return text
  end
  if max < 1 then
    return ""
  end
  local cut = vim.fn.strcharpart(text, 0, max - 1)
  -- Wide characters can still overflow by one cell: shorten until it fits.
  while width_of(cut) > max - 1 do
    cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
  end
  return cut .. ELLIPSIS
end

---Title chunks for a float's top border: one border dash after the
---corner, then the padded text (`┌─ Find files ───┐`), `accent` when
---focused and `muted` when idle. The text is cut with an ellipsis to
---fit `width`; no chunks when the text is blank or nothing of it fits.
---@param text string
---@param focused boolean|nil
---@param width integer|nil Most display cells of the result.
---@return table[] chunks
function M.title(text, focused, width)
  text = vim.trim(text or "")
  -- The dash and the two padding spaces.
  if width then
    text = M.truncate(text, width - 3)
  end
  if text == "" then
    return {}
  end
  local groups = M.groups(focused)
  return { { "─", groups.border }, { " " .. text .. " ", groups.title } }
end

---The border dash before title chunks that already carry their own
---padding (`{ " text ", group }`), such as which-key's prefix trail.
---Chunks are returned unchanged when they are empty or not a list.
---@param chunks table[]|any `{ text, group }` chunks.
---@param focused boolean|nil
---@return table[]|any chunks
function M.wrap_title(chunks, focused)
  if type(chunks) ~= "table" or #chunks == 0 then
    return chunks
  end
  local wrapped = { { "─", M.groups(focused).border } }
  return vim.list_extend(wrapped, chunks)
end

local function hint_chunks(hint, groups)
  return {
    { hint[1], groups.key },
    { " " .. hint[2], groups.text },
  }
end

---@class IaraFooterOpts
---@field key string|nil Group of the keys (default `FOOTER.key`).
---@field text string|nil Group of the rest (default `FOOTER.text`).
---@field max integer|nil Most hints shown (default `MAX_HINTS`).

---Footer chunks of key hints, centered by the caller (`footer_pos`):
---` key desc · key desc `, keys in the accent, `HINT_SEPARATOR`
---between hints, at most `opts.max`. Hints that do not fit `width` are
---dropped from the right; no chunks when none fits.
---@param hints { [1]: string, [2]: string }[] Key and description.
---@param width integer Most display cells of the result.
---@param opts IaraFooterOpts|nil
---@return table[] chunks
function M.footer(hints, width, opts)
  opts = opts or {}
  local groups = { key = opts.key or M.FOOTER.key }
  groups.text = opts.text or M.FOOTER.text
  local chunks, used = {}, 2 -- the padding spaces at both ends
  for index = 1, math.min(#hints, opts.max or M.MAX_HINTS) do
    local hint = hint_chunks(hints[index], groups)
    local gap = index == 1 and "" or M.HINT_SEPARATOR
    local cost = width_of(gap) + M.width(hint)
    if used + cost > width then
      break
    end
    used = used + cost
    if gap ~= "" then
      table.insert(chunks, { gap, groups.text })
    end
    vim.list_extend(chunks, hint)
  end
  if #chunks == 0 then
    return {}
  end
  table.insert(chunks, 1, { " ", groups.text })
  table.insert(chunks, { " ", groups.text })
  return chunks
end

local function winhighlight(win)
  return vim.api.nvim_get_option_value("winhighlight", { win = win })
end

local function set_winhighlight(win, value)
  vim.api.nvim_set_option_value(
    "winhighlight",
    value,
    { win = win, scope = "local" }
  )
end

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

---Give a float the focused frame (border and title) unless it maps its
---own frame groups (pickers, completion menus, Snacks windows). Safe to
---call again after the window's 'winhighlight' was replaced.
---@param win integer
function M.focus(win)
  if not vim.api.nvim_win_is_valid(win) or not is_float(win) then
    return
  end
  local current = winhighlight(win)
  local own = current:find("FloatBorder:", 1, true)
    or current:find("FloatTitle:", 1, true)
  if own then
    return
  end
  vim.w[win].iara_float_focus = true
  local separator = current == "" and "" or ","
  set_winhighlight(win, current .. separator .. M.FOCUS_WINHIGHLIGHT)
end

---Return a float given the focused frame by `focus` to the idle one,
---keeping any other 'winhighlight' entry.
---@param win integer
function M.blur(win)
  if not vim.api.nvim_win_is_valid(win) or not vim.w[win].iara_float_focus then
    return
  end
  vim.w[win].iara_float_focus = nil
  local entries = vim.split(winhighlight(win), ",", { trimempty = true })
  local focus = vim.split(M.FOCUS_WINHIGHLIGHT, ",")
  local kept = vim.tbl_filter(function(entry)
    return not vim.tbl_contains(focus, entry)
  end, entries)
  set_winhighlight(win, table.concat(kept, ","))
end

---Link the float groups to standard ones unless the colorscheme (an
---Iara theme or one that knows them) defines them.
function M.link_fallbacks()
  for name, target in pairs(M.FALLBACK_LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local did_setup = false

---Switch floats between the idle and focused frame on WinEnter and
---WinLeave (events only, never per keystroke), and keep the float groups
---defined under foreign colorschemes. Safe step: no plugin.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup("iara.float", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.link_fallbacks,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      M.focus(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      M.blur(vim.api.nvim_get_current_win())
    end,
  })
end

return M
