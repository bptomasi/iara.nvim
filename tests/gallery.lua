--- Color gallery (task V2): a child `nvim --embed` whose screen keeps the
--- highlight of every cell, and snapshots of it with resolved colors.
---
--- The child is `ui_child`'s. Its UI is attached again with
--- `ext_hlstate`, which makes Neovim send every highlight attribute again
--- (`hl_attr_define`) together with the groups that produced it. The
--- screen extends the test grid with a second one for highlight ids, so
--- text and colors are decoded by the same code.
local ui_child = require("ui_child")
local grid_model = require("ui_grid")

local M = {}

local Base = getmetatable(grid_model.new())

---@class gallery.Attr
---@field rgb table<string, any> `rgb_attrs` of `hl_attr_define`.
---@field groups string[] Groups that produced it, as "Ui (Group)".

---@class gallery.Snapshot
---@field width integer
---@field height integer
---@field text string[][] Cell text by row and column, one-based; the
---  right half of a double-width character is "".
---@field ids integer[][] Attribute id by row and column; 0 is default.
---@field attrs table<integer, gallery.Attr>
---@field defaults { fg: integer, bg: integer, sp: integer }

---@class gallery.ColorGrid: ui.Grid
---@field ids ui.Grid Same shape; each cell holds an attribute id.
---@field attrs table<integer, gallery.Attr>
---@field defaults { fg: integer, bg: integer, sp: integer }
local ColorGrid = setmetatable({}, { __index = Base })
ColorGrid.__index = ColorGrid

function ColorGrid:resize(width, height)
  Base.resize(self, width, height)
  self.ids:resize(width, height)
end

---`grid_line` cells name an attribute only when it changes.
local function id_cells(cells)
  local out, id = {}, 0
  for index, cell in ipairs(cells) do
    id = cell[2] or id
    out[index] = { id, id, cell[3] }
  end
  return out
end

function ColorGrid:put_line(row, col_start, cells)
  Base.put_line(self, row, col_start, cells)
  self.ids:put_line(row, col_start, id_cells(cells))
end

function ColorGrid:scroll(top, bot, left, right, rows)
  Base.scroll(self, top, bot, left, right, rows)
  self.ids:scroll(top, bot, left, right, rows)
end

---"EndOfBuffer (NonText)" for a UI role drawn by a linked group.
local function group_name(entry)
  local hi, ui = entry.hi_name, entry.ui_name
  if ui and hi and ui ~= hi then
    return ("%s (%s)"):format(ui, hi)
  end
  return ui or hi or entry.kind or "?"
end

local function define_attr(grid, args)
  local groups = {}
  for _, entry in ipairs(args[4] or {}) do
    local name = group_name(entry)
    if not vim.tbl_contains(groups, name) then
      table.insert(groups, name)
    end
  end
  grid.attrs[args[1]] = { rgb = args[2], groups = groups }
end

local function set_defaults(grid, args)
  grid.defaults = { fg = args[1], bg = args[2], sp = args[3] }
end

local color_handlers = {
  hl_attr_define = define_attr,
  default_colors_set = set_defaults,
}

---Apply a redraw notification: cells through the grid model, then the
---attribute definitions and default colors.
---@param batches any[]
---@param on_flush fun()
function ColorGrid:apply(batches, on_flush)
  Base.apply(self, batches, on_flush)
  for _, batch in ipairs(batches) do
    local handler = color_handlers[batch[1]]
    for index = 2, handler and #batch or 1 do
      handler(self, batch[index])
    end
  end
end

---A copy of the screen that later redraws do not change.
---@return gallery.Snapshot
function ColorGrid:snapshot()
  local text, ids = {}, {}
  for row = 1, self.height do
    text[row] = vim.list_slice(self.rows[row])
    ids[row] = vim.tbl_map(function(value)
      return tonumber(value) or 0
    end, self.ids.rows[row])
  end
  return {
    width = self.width,
    height = self.height,
    text = text,
    ids = ids,
    attrs = vim.deepcopy(self.attrs),
    defaults = vim.deepcopy(self.defaults),
  }
end

---An empty color grid; the first `grid_resize` sizes it.
---@return gallery.ColorGrid
function M.new_grid()
  local grid = setmetatable(grid_model.new(), ColorGrid)
  grid.ids = grid_model.new()
  grid.attrs = {}
  grid.defaults = { fg = -1, bg = -1, sp = -1 }
  return grid
end

---Start a `ui_child` (same options) whose grid records colors. The UI is
---attached a second time, after startup, with `ext_hlstate`.
---@param width integer
---@param height integer
---@param opts { init: string?, args: string[]? }|nil
---@return UiChild child Its `grid` is a `gallery.ColorGrid`.
function M.start(width, height, opts)
  local child = ui_child.start(width, height, opts)
  -- Answered only once startup has finished (VimEnter included), so the
  -- startup code saw a UI.
  child:lua("return vim.v.vim_did_enter")
  child:request("nvim_ui_detach", {})
  child.grid = M.new_grid()
  child:request("nvim_ui_attach", {
    width,
    height,
    { ext_linegrid = true, ext_hlstate = true, rgb = true },
  })
  return child
end

---Wait until the screen shows `text` and has been unchanged for
---`quiet_ms`, then return a snapshot of it. Fails when `text` never
---shows.
---@param child UiChild
---@param text string|nil
---@param quiet_ms integer|nil Default 300.
---@return gallery.Snapshot
function M.capture(child, text, quiet_ms)
  if text and not child:screen():find(text, 1, true) then
    local shown = child:wait_screen(text)
    if not shown:find(text, 1, true) then
      error(("screen never showed %q:\n%s"):format(text, shown), 0)
    end
  end
  local last, since = child:screen(), vim.uv.now()
  child:wait(function(c)
    local screen = c:screen()
    if screen ~= last then
      last, since = screen, vim.uv.now()
    end
    return vim.uv.now() - since >= (quiet_ms or 300)
  end)
  return child.grid:snapshot()
end

-- Rendering ----------------------------------------------------------------

-- Used when the child sent no default color (-1).
local FALLBACK = { fg = 0xffffff, bg = 0x000000 }

-- Attribute flags and their SGR parameters, in output order.
local FLAGS = {
  { "bold", "1" },
  { "italic", "3" },
  { "underline", "4" },
  { "undercurl", "4:3" },
  { "underdouble", "4:2" },
  { "underdotted", "4:4" },
  { "underdashed", "4:5" },
  { "strikethrough", "9" },
}

---@class gallery.Style
---@field fg integer Resolved foreground (24-bit).
---@field bg integer Resolved background.
---@field sp integer|nil Special (underline) color.
---@field flags string[] Names from FLAGS that are set.
---@field groups string[]

---@param color integer
---@return string hex "#rrggbb"
function M.hex(color)
  return ("#%06x"):format(color)
end

local function default_color(snapshot, kind)
  local color = snapshot.defaults[kind]
  if color == nil or color < 0 then
    return FALLBACK[kind]
  end
  return color
end

---Colors and attributes a UI draws for attribute `id`: defaults fill
---missing colors, then `reverse` swaps them.
---@param snapshot gallery.Snapshot
---@param id integer
---@return gallery.Style
function M.style(snapshot, id)
  local attr = snapshot.attrs[id] or { rgb = {}, groups = {} }
  local rgb = attr.rgb
  local fg = rgb.foreground or default_color(snapshot, "fg")
  local bg = rgb.background or default_color(snapshot, "bg")
  if rgb.reverse then
    fg, bg = bg, fg
  end
  local flags = {}
  for _, flag in ipairs(FLAGS) do
    if rgb[flag[1]] then
      table.insert(flags, flag[1])
    end
  end
  return {
    fg = fg,
    bg = bg,
    sp = rgb.special,
    flags = flags,
    groups = attr.groups,
  }
end

---Text and style of one cell.
---@param snapshot gallery.Snapshot
---@param row integer One-based.
---@param col integer One-based.
---@return { text: string, id: integer, style: gallery.Style }
function M.cell(snapshot, row, col)
  local id = snapshot.ids[row][col]
  local text = snapshot.text[row][col]
  return { text = text, id = id, style = M.style(snapshot, id) }
end

---Position of the first cell where `text` starts on screen.
---@param snapshot gallery.Snapshot
---@param text string
---@return integer|nil row
---@return integer|nil col
function M.find(snapshot, text)
  for row = 1, snapshot.height do
    local cells = snapshot.text[row]
    for col = 1, snapshot.width do
      local rest = table.concat(cells, "", col)
      if cells[col] ~= "" and vim.startswith(rest, text) then
        return row, col
      end
    end
  end
  return nil
end

---@class gallery.Run
---@field id integer
---@field text string
---@field col integer First cell, one-based.
---@field cells integer

---Runs of cells with the same attribute id on a row.
---@param snapshot gallery.Snapshot
---@param row integer
---@return gallery.Run[]
function M.runs(snapshot, row)
  local runs, current = {}, nil
  for col = 1, snapshot.width do
    local id = snapshot.ids[row][col]
    if not current or current.id ~= id then
      current = { id = id, parts = {}, col = col }
      table.insert(runs, current)
    end
    table.insert(current.parts, snapshot.text[row][col])
  end
  return vim.tbl_map(function(run)
    local text = table.concat(run.parts)
    return { id = run.id, text = text, col = run.col, cells = #run.parts }
  end, runs)
end

---@param snapshot gallery.Snapshot
---@return string text The screen text, one row per line.
function M.text(snapshot)
  local lines = {}
  for row = 1, snapshot.height do
    lines[row] = table.concat(snapshot.text[row])
  end
  return table.concat(lines, "\n")
end

-- Contrast, legend, audit -----------------------------------------------------

local function channel(value)
  local c = value / 255
  if c <= 0.03928 then
    return c / 12.92
  end
  return ((c + 0.055) / 1.055) ^ 2.4
end

local function luminance(color)
  local r = math.floor(color / 0x10000) % 0x100
  local g = math.floor(color / 0x100) % 0x100
  local b = color % 0x100
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
end

---WCAG 2 contrast ratio of two 24-bit colors (1 to 21).
---@param a integer
---@param b integer
---@return number
function M.contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

---@class gallery.Entry
---@field groups string[]
---@field style gallery.Style
---@field ratio number Contrast of fg on bg.
---@field cells integer Cells drawn with it.
---@field visible boolean Whether it draws any non-blank text.
---@field sample string First non-blank text drawn with it (trimmed).
---@field at { row: integer, col: integer } Where it first appears.

local function entry_key(style)
  return table.concat({
    table.concat(style.groups, "+"),
    style.fg,
    style.bg,
    table.concat(style.flags, ","),
  }, "|")
end

local SAMPLE_WIDTH = 24

local function count_run(entry, run, row)
  entry.cells = entry.cells + run.cells
  local text = vim.trim(run.text)
  if text == "" or entry.visible then
    return
  end
  entry.visible = true
  entry.sample = vim.fn.strcharpart(text, 0, SAMPLE_WIDTH)
  entry.at = { row = row, col = run.col }
end

local function new_entry(key, style, row, col)
  return {
    key = key,
    groups = style.groups,
    style = style,
    ratio = M.contrast(style.fg, style.bg),
    cells = 0,
    visible = false,
    sample = "",
    at = { row = row, col = col },
  }
end

local function by_cells(a, b)
  if a.cells ~= b.cells then
    return a.cells > b.cells
  end
  return a.key < b.key
end

---Every distinct style on screen (groups, colors, attributes), most
---used first.
---@param snapshot gallery.Snapshot
---@return gallery.Entry[]
function M.legend(snapshot)
  local entries, list = {}, {}
  for row = 1, snapshot.height do
    for _, run in ipairs(M.runs(snapshot, row)) do
      local style = M.style(snapshot, run.id)
      local key = entry_key(style)
      if not entries[key] then
        entries[key] = new_entry(key, style, row, run.col)
        table.insert(list, entries[key])
      end
      count_run(entries[key], run, row)
    end
  end
  table.sort(list, by_cells)
  return list
end

---Styles that draw visible text with a contrast below `min_ratio`
---(default 4.5), lowest first.
---@param snapshot gallery.Snapshot
---@param min_ratio number|nil
---@return gallery.Entry[]
function M.audit(snapshot, min_ratio)
  local low = vim.tbl_filter(function(entry)
    return entry.visible and entry.ratio < (min_ratio or 4.5)
  end, M.legend(snapshot))
  table.sort(low, function(a, b)
    return a.ratio < b.ratio
  end)
  return low
end

local function groups_label(groups)
  if #groups == 0 then
    return "(default)"
  end
  return table.concat(groups, " + ")
end
M.groups_label = groups_label

local function table_cell(text)
  return (text:gsub("|", "\\|"):gsub("`", "'"))
end

local function entry_row(entry)
  local style = entry.style
  return ("| %s | `%s` | `%s` | %.2f | %s | %d | %s |"):format(
    table_cell(groups_label(entry.groups)),
    M.hex(style.fg),
    M.hex(style.bg),
    entry.ratio,
    table.concat(style.flags, " "),
    entry.cells,
    entry.sample == "" and "" or "`" .. table_cell(entry.sample) .. "`"
  )
end

---Markdown table of legend or audit entries.
---@param entries gallery.Entry[]
---@return string
function M.markdown(entries)
  local lines = {
    "| Groups | fg | bg | Contrast | Attributes | Cells | Sample |",
    "| --- | --- | --- | ---: | --- | ---: | --- |",
  }
  for _, entry in ipairs(entries) do
    table.insert(lines, entry_row(entry))
  end
  return table.concat(lines, "\n")
end

-- HTML and ANSI ---------------------------------------------------------------

local HTML_ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }
HTML_ESCAPES['"'] = "&quot;"

local function escape(text)
  return (text:gsub('[&<>"]', HTML_ESCAPES))
end

local CSS_FLAGS = {
  bold = "font-weight:bold",
  italic = "font-style:italic",
  underline = "text-decoration:underline",
  undercurl = "text-decoration:underline wavy",
  underdouble = "text-decoration:underline double",
  underdotted = "text-decoration:underline dotted",
  underdashed = "text-decoration:underline dashed",
  strikethrough = "text-decoration:line-through",
}

local function css_rule(id, style)
  local parts = {
    "color:" .. M.hex(style.fg),
    "background:" .. M.hex(style.bg),
  }
  for _, flag in ipairs(style.flags) do
    table.insert(parts, CSS_FLAGS[flag])
  end
  if style.sp then
    table.insert(parts, "text-decoration-color:" .. M.hex(style.sp))
  end
  return (".h%d{%s}"):format(id, table.concat(parts, ";"))
end

local function used_ids(snapshot)
  local seen, ids = {}, {}
  for row = 1, snapshot.height do
    for _, id in ipairs(snapshot.ids[row]) do
      if not seen[id] then
        seen[id] = true
        table.insert(ids, id)
      end
    end
  end
  table.sort(ids)
  return ids
end

local function html_screen(snapshot)
  local lines = {}
  for row = 1, snapshot.height do
    local spans = {}
    for _, run in ipairs(M.runs(snapshot, row)) do
      local groups = groups_label(M.style(snapshot, run.id).groups)
      local span = '<span class="h%d" title="%s">%s</span>'
      table.insert(spans, span:format(run.id, escape(groups), escape(run.text)))
    end
    lines[row] = table.concat(spans)
  end
  return table.concat(lines, "\n")
end

-- No font is embedded: the page names a Nerd Font and falls back to the
-- viewer's monospace font.
local PAGE = [[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>%s</title>
<style>
body{margin:16px;background:#%06x;color:#%06x;font:14px sans-serif}
pre{font-family:"JetBrainsMono Nerd Font","Symbols Nerd Font Mono",
monospace;font-size:14px;line-height:1.25;margin:0;display:inline-block}
table{border-collapse:collapse;margin-top:16px}
td,th{border:1px solid #8888;padding:2px 6px;text-align:left}
%s
</style>
</head>
<body>
<h1>%s</h1>
<pre>%s</pre>
%s
</body>
</html>
]]

local function html_table(entries, heading)
  local rows = { ("<h2>%s</h2>"):format(escape(heading)), "<table>" }
  table.insert(rows, "<tr><th>Groups</th><th>Sample</th><th>fg</th>")
  table.insert(rows, "<th>bg</th><th>Contrast</th><th>Cells</th></tr>")
  for _, entry in ipairs(entries) do
    local style = entry.style
    local cell = '<td>%s</td><td style="color:%s;background:%s">%s</td>'
    local row = cell:format(
      escape(groups_label(entry.groups)),
      M.hex(style.fg),
      M.hex(style.bg),
      escape(entry.sample)
    ) .. ("<td>%s</td><td>%s</td><td>%.2f</td><td>%d</td>"):format(
      M.hex(style.fg),
      M.hex(style.bg),
      entry.ratio,
      entry.cells
    )
    table.insert(rows, "<tr>" .. row .. "</tr>")
  end
  table.insert(rows, "</table>")
  return table.concat(rows, "\n")
end

---A standalone HTML page: the screen with one CSS class per attribute
---(exact colors and attributes, groups in each span's title), the
---legend, and the audit when `opts.audit` is a list of entries.
---@param snapshot gallery.Snapshot
---@param opts { title: string, audit: gallery.Entry[]|nil }
---@return string
function M.html(snapshot, opts)
  local rules = {}
  for _, id in ipairs(used_ids(snapshot)) do
    table.insert(rules, css_rule(id, M.style(snapshot, id)))
  end
  local tables = { html_table(M.legend(snapshot), "Legend") }
  if opts.audit then
    local heading = ("Contrast below 4.5:1 (%d)"):format(#opts.audit)
    table.insert(tables, html_table(opts.audit, heading))
  end
  return PAGE:format(
    escape(opts.title),
    default_color(snapshot, "bg"),
    default_color(snapshot, "fg"),
    table.concat(rules, "\n"),
    escape(opts.title),
    html_screen(snapshot),
    table.concat(tables, "\n")
  )
end

local function rgb_params(prefix, color)
  local r = math.floor(color / 0x10000) % 0x100
  local g = math.floor(color / 0x100) % 0x100
  return ("%d;2;%d;%d;%d"):format(prefix, r, g, color % 0x100)
end

local function sgr(style)
  local params = { "0", rgb_params(38, style.fg), rgb_params(48, style.bg) }
  for _, flag in ipairs(FLAGS) do
    if vim.tbl_contains(style.flags, flag[1]) then
      table.insert(params, flag[2])
    end
  end
  return "\27[" .. table.concat(params, ";") .. "m"
end

---The screen as 24-bit ANSI text (one SGR sequence per run, reset at
---the end of each row), for `cat` in a truecolor terminal.
---@param snapshot gallery.Snapshot
---@return string
function M.ansi(snapshot)
  local lines = {}
  for row = 1, snapshot.height do
    local parts = {}
    for _, run in ipairs(M.runs(snapshot, row)) do
      table.insert(parts, sgr(M.style(snapshot, run.id)) .. run.text)
    end
    lines[row] = table.concat(parts) .. "\27[0m"
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
