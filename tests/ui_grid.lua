--- Text model of the default grid (grid 1) of a linegrid UI.
---
--- Cell text, cell highlight ids, and the cursor are kept. Highlights
--- are irrelevant to recognizing whether an edit is displayed; the ids
--- let a driver tell whether text is shown highlighted. Rows and
--- columns follow the protocol and are zero-based in the public methods.
local M = {}

local DEFAULT_GRID = 1

---@class ui.Grid
---@field width integer
---@field height integer
---@field cursor { row: integer, col: integer }
---@field private rows string[][]
---@field private hls integer[][]
local Grid = {}
Grid.__index = Grid

local function blank_row(width)
  local row = {}
  for col = 1, width do
    row[col] = " "
  end
  return row
end

function Grid:resize(width, height)
  self.width, self.height = width, height
  self.rows, self.hls = {}, {}
  for row = 1, height do
    self.rows[row] = blank_row(width)
    self.hls[row] = {}
  end
end

function Grid:put_line(row, col_start, cells)
  local target, hls = self.rows[row + 1], self.hls[row + 1]
  if not target then
    return
  end
  local col, hl = col_start + 1, 0
  for _, cell in ipairs(cells) do
    hl = cell[2] or hl
    for _ = 1, cell[3] or 1 do
      target[col], hls[col] = cell[1], hl
      col = col + 1
    end
  end
end

function Grid:scroll(top, bot, left, right, rows)
  local first, last, step = top, bot - rows - 1, 1
  if rows < 0 then
    first, last, step = bot - 1, top - rows, -1
  end
  for dst = first, last, step do
    local source, source_hls =
      self.rows[dst + rows + 1], self.hls[dst + rows + 1]
    local target, target_hls = self.rows[dst + 1], self.hls[dst + 1]
    for col = left + 1, right do
      target[col], target_hls[col] = source[col], source_hls[col]
    end
  end
end

local handlers = {
  grid_resize = function(grid, args)
    grid:resize(args[2], args[3])
  end,
  grid_clear = function(grid)
    grid:resize(grid.width, grid.height)
  end,
  grid_line = function(grid, args)
    grid:put_line(args[2], args[3], args[4])
  end,
  grid_scroll = function(grid, args)
    grid:scroll(args[2], args[3], args[4], args[5], args[6])
  end,
  grid_cursor_goto = function(grid, args)
    grid.cursor = { row = args[2], col = args[3] }
  end,
}

---Apply the event batches of one "redraw" notification in order and call
---`on_flush` at each "flush" event, when the screen state is consistent.
---@param batches any[] Parameters of the redraw notification.
---@param on_flush fun()
function Grid:apply(batches, on_flush)
  for _, batch in ipairs(batches) do
    local name = batch[1]
    local handler = handlers[name]
    if name == "flush" then
      on_flush()
    end
    for index = 2, handler and #batch or 1 do
      local args = batch[index]
      if args[1] == DEFAULT_GRID then
        handler(self, args)
      end
    end
  end
end

---Text of a row, or nil when the row does not exist; with `col` and
---`width`, only those columns (zero-based start).
---@param row integer Zero-based row.
---@param col integer?
---@param width integer?
---@return string|nil
function Grid:row_text(row, col, width)
  local cells = self.rows[row + 1]
  if not cells then
    return nil
  end
  if not col then
    return table.concat(cells)
  end
  return table.concat(cells, "", col + 1, math.min(col + width, #cells))
end

---Highlight id of a cell (0 for the default), or nil outside the grid.
---@param row integer Zero-based row.
---@param col integer Zero-based column.
---@return integer|nil
function Grid:hl_at(row, col)
  local hls = self.hls[row + 1]
  if not hls or col < 0 or col >= self.width then
    return nil
  end
  return hls[col + 1] or 0
end

---Text on the cursor row to the left of the cursor.
---@return string
function Grid:text_before_cursor()
  local cells = self.rows[self.cursor.row + 1] or {}
  return table.concat(cells, "", 1, math.min(self.cursor.col, #cells))
end

---Whole screen text, one row per line, for failure diagnostics.
---@return string
function Grid:screen_text()
  local lines = {}
  for row = 0, self.height - 1 do
    lines[row + 1] = self:row_text(row)
  end
  return table.concat(lines, "\n")
end

---Create an empty grid; the first grid_resize event sizes it.
---@return ui.Grid
function M.new()
  local grid = setmetatable({ cursor = { row = 0, col = 0 } }, Grid)
  grid:resize(0, 0)
  return grid
end

return M
