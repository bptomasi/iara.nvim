--- Open a picker location in a window (extracted from the search UI,
--- task S8). Pickers that list files or locations, such as search (S6)
--- and the structured key search (D4), share it. See contracts.md,
--- section 9.6.
local M = {}

local BOM = "\239\187\191"

---@class IaraPickerLocation
---@field path string? Absolute file path, taken literally: spaces, `%`,
---  and newlines need no escaping.
---@field bufnr integer? Buffer to show instead of `path`.
---@field row integer? Zero-based line. Nil opens without moving the
---  cursor (a file name has no location).
---@field col integer? Zero-based byte column; default 0.
---@field disk_bytes boolean? `col` counts a UTF-8 BOM on line 0, as
---  ripgrep `--encoding none` does; Neovim strips the BOM.

local function disk_has_bom(path)
  local file = path and path ~= "" and io.open(path, "rb")
  if not file then
    return false
  end
  local head = file:read(#BOM)
  file:close()
  return head == BOM
end

---Whether line 0 of the buffer lacks the BOM the file starts with.
---A loaded buffer shows whether Neovim stripped it (`++bin` keeps it);
---a file not loaded yet will be read with the BOM stripped.
local function bom_stripped(bufnr, path)
  if not (bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then
    return disk_has_bom(path)
  end
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  if first:sub(1, #BOM) == BOM then
    return false
  end
  return vim.bo[bufnr].bomb or disk_has_bom(path)
end

---Loaded buffer of `path`; bufnr() would read the path as a pattern.
local function loaded_buffer(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) == path
    then
      return bufnr
    end
  end
end

---Byte column of `location` in the text Neovim shows for its file: a
---disk-byte column on line 0 loses the BOM Neovim strips. The picker
---jump and the quickfix export both convert through it.
---@param location IaraPickerLocation
---@param col integer? Column to convert instead of `location.col`.
---@return integer column Zero-based, never negative.
function M.buffer_column(location, col)
  local column = col or location.col or 0
  if not location.disk_bytes or location.row ~= 0 or column == 0 then
    return column
  end
  local bufnr = location.bufnr
  if not bufnr and location.path then
    bufnr = loaded_buffer(location.path)
  end
  local path = location.path or vim.api.nvim_buf_get_name(bufnr)
  if bom_stripped(bufnr, path) then
    column = math.max(column - #BOM, 0)
  end
  return column
end

local function target_buffer(location)
  if location.bufnr then
    return location.bufnr
  end
  if type(location.path) ~= "string" or location.path == "" then
    error("picker.open: location needs a path or a bufnr", 3)
  end
  -- bufadd() takes the name literally, unlike :edit.
  local bufnr = vim.fn.bufadd(location.path)
  vim.bo[bufnr].buflisted = true
  return bufnr
end

---Show the location in the current window, after an optional window
---command, and record the jump. With a `row`, the cursor goes to that
---line (clamped to the buffer) and byte column.
---@param location IaraPickerLocation
---@param command string? Run first, for example "split", "vsplit",
---  or "tabnew".
---@return integer bufnr
function M.jump(location, command)
  local bufnr = target_buffer(location)
  if command then
    vim.cmd(command)
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(0, bufnr)
  if location.row == nil then
    return bufnr
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  local line = math.min(location.row + 1, last)
  local column = M.buffer_column(vim.tbl_extend("force", location, {
    bufnr = bufnr,
  }))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, column })
  return bufnr
end

return M
