--- Highlighting of pooled preview buffers (task S11). See contracts.md,
--- section 9.6.
---
--- A preview is always highlighted, also while a key is held: a first
--- screen (a few dozen lines) is parsed synchronously before it is
--- shown, which costs about a millisecond, and a complete window is
--- parsed asynchronously (Tree-sitter's 3 ms slices) before it replaces
--- the screen, so the colors never go away. Buffers keep their
--- highlighter while their language stays the same; Markdown drops the
--- `conceal_lines` work like file buffers (MD2). Without a parser or a
--- highlight query, the filetype's regex syntax highlights, as in file
--- buffers; lines are cut at LINE_BYTES, which bounds its cost.
local M = {}

---The Markdown query change of MD2, applied once per session.
local conceal_dropped = false

---Lines a filetype check may look at (shebangs, modelines).
local CONTENT_LINES = 5

---Filetype of a target: given, else detected from its path and its
---first lines, without a buffer (no events, no ftplugin).
---@param target IaraPreviewTarget
---@param lines string[]
---@return string|nil
function M.filetype(target, lines)
  if target.filetype ~= nil then
    return target.filetype ~= "" and target.filetype or nil
  end
  if not target.path then
    return nil
  end
  local ok, detected = pcall(vim.filetype.match, {
    filename = target.path,
    contents = vim.list_slice(lines, 1, CONTENT_LINES),
  })
  return ok and detected or nil
end

---Tree-sitter language of `filetype` when its parser and highlight
---query are installed (Iara keeps regex syntax otherwise, as for files).
---@param filetype string|nil
---@return string|nil
function M.lang(filetype)
  if not filetype then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  local ok, added = pcall(vim.treesitter.language.add, lang)
  if not (ok and added) then
    return nil
  end
  local found, query = pcall(vim.treesitter.query.get, lang, "highlights")
  return (found and query) and lang or nil
end

local function drop_conceal_lines(lang)
  if lang == "markdown" and not conceal_dropped then
    conceal_dropped = true
    require("iara.features.markdown").drop_conceal_lines()
  end
end

local function stop(entry)
  if entry.highlight == "treesitter" then
    vim.treesitter.stop(entry.buf)
  elseif entry.highlight == "syntax" then
    vim.bo[entry.buf].syntax = ""
  end
  entry.highlight, entry.filetype = nil, nil
end

local function start(entry, filetype, lang)
  if lang then
    drop_conceal_lines(lang)
    if pcall(vim.treesitter.start, entry.buf, lang) then
      return "treesitter"
    end
  end
  vim.bo[entry.buf].syntax = filetype
  return "syntax"
end

---Highlight the entry's buffer for `filetype`: with Tree-sitter when
---`lang` (from `M.lang`) is given, else with its regex syntax (lines
---are cut at LINE_BYTES, which bounds its cost). An entry already
---highlighted for `filetype` keeps its highlighter. Returns how, or nil
---for plain text.
---@param entry IaraPreviewEntry
---@param filetype string|nil
---@param lang string|nil
---@return "treesitter"|"syntax"|nil
function M.attach(entry, filetype, lang)
  if entry.highlight and entry.filetype == filetype then
    return entry.highlight
  end
  stop(entry)
  if filetype then
    entry.highlight, entry.filetype = start(entry, filetype, lang), filetype
  end
  return entry.highlight
end

---Parse rows `first`..`last` (zero-based) of a Tree-sitter highlighted
---entry with their injections, so the first redraw is highlighted.
---Synchronous without `on_done`; otherwise in slices, and `on_done()`
---runs when done (at once when it was quick).
---@param entry IaraPreviewEntry
---@param first integer
---@param last integer
---@param on_done fun()|nil
function M.parse(entry, first, last, on_done)
  local ok, parser = pcall(vim.treesitter.get_parser, entry.buf)
  if entry.highlight ~= "treesitter" or not ok or not parser then
    return on_done and on_done()
  end
  local range = { first, last }
  if not on_done then
    parser:parse(range)
    return
  end
  -- Runs the callback also when the parse finishes synchronously.
  parser:parse(range, function()
    on_done()
  end)
end

return M
