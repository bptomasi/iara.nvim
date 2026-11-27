--- One border look for every Iara float (tasks UX5, V13): a thin
--- straight frame (`┌─┐│└┘`) in the theme's `FloatBorder` color, titles
--- drawn inline on the top edge in `FloatTitle`, and footers in
--- `FloatFooter`. Straight lines fill their cells, so no corner shows a
--- second background (design 09, section 7). Plugins and features take
--- their borders from here so the frames never drift apart.
local M = {}

---Border style name for `nvim_open_win` and plugin options.
M.BORDER = "single"

---The straight border as characters, clockwise from the top-left corner.
M.CHARS = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }

---Top part of a split frame: top corners and a separator whose ends
---join the sides (`├────┤`). Stacks on `BOTTOM`.
M.TOP = { "┌", "─", "┐", "│", "┤", "─", "├", "│" }

---Bottom part of a split frame: sides and bottom corners only.
M.BOTTOM = { "", "", "", "│", "┘", "─", "└", "│" }

---Title or footer text padded to sit on a border line: `┌─ text ─┐`.
---Empty text gives an empty title.
---@param text string
---@return string
function M.label(text)
  text = vim.trim(text)
  return text == "" and "" or (" " .. text .. " ")
end

---Title chunks for a left-aligned title that starts one border dash
---after the corner, as a centered title would (`┌─ Find files ───┐`).
---@param chunks table[] Title text chunks `{ text, group }`.
---@param group string|nil Group of the dash (default `FloatBorder`).
---@return table[]
function M.left_title(chunks, group)
  if #chunks == 0 then
    return chunks
  end
  local result = { { "─", group or "FloatBorder" } }
  return vim.list_extend(result, chunks)
end

---Border characters drawn in `group` (`{ char, group }` pairs), for a
---frame whose color does not come from the window's `FloatBorder`.
---@param chars string[] Eight characters, as `CHARS`.
---@param group string
---@return table[]
function M.colored(chars, group)
  return vim.tbl_map(function(char)
    return { char, group }
  end, chars)
end

---Float window options with Iara's border and an inline title (and
---footer) on it; `config` fields win.
---@param config table `nvim_open_win` configuration.
---@return table
function M.float(config)
  local result = vim.tbl_extend("keep", config, { border = M.BORDER })
  if type(result.title) == "string" then
    result.title = M.label(result.title)
  end
  if type(result.footer) == "string" then
    result.footer = M.label(result.footer)
  end
  return result
end

return M
