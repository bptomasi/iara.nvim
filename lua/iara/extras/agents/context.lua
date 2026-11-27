--- Context preview and copy for agent terminals (task A2).
---
--- A snapshot captures the exact buffer text of a selection (or a disk
--- reference) before focus changes. Admission runs on cheap row and byte
--- offsets before any text is read, and every cap refuses instead of
--- truncating. The payload is shown in a scratch preview and copied to a
--- register for manual paste; nothing is inserted into an agent.
local M = {}

local api = vim.api

local LIMITS = {
  input_bytes = 64 * 1024,
  payload_bytes = 128 * 1024,
  metadata_bytes = 8 * 1024,
  char_rows = 512,
  block_rows = 256,
  block_columns = 256,
  diagnostic_count = 100,
  diagnostic_message_bytes = 4 * 1024,
  diagnostic_bytes = 32 * 1024,
  retained_snapshots = 4,
  retained_bytes = 2 * 1024 * 1024,
}

local MODES = {
  v = "charwise",
  V = "linewise",
  ["\22"] = "blockwise",
  charwise = "charwise",
  linewise = "linewise",
  blockwise = "blockwise",
  reference = "reference",
}

-- Control bytes other than tab and line feed are escaped in the payload.
local CONTROL = "[%z\1-\8\11-\31\127]"

local group = api.nvim_create_augroup("IaraAgentsContext", { clear = true })

---@type table<integer, table> Retained snapshots by id, with byte charges.
local retained = {}
local next_id = 0

local function failure(code, message)
  return { code = code, message = message }
end

local function too_large(what, limit)
  return failure(
    "too_large",
    ("%s exceeds %d KiB; select less or attach a disk reference"):format(
      what,
      limit / 1024
    )
  )
end

-- Retention ---------------------------------------------------------------

local function retained_bytes()
  local total = 0
  for _, entry in pairs(retained) do
    total = total + entry.raw + entry.preview + entry.copy
  end
  return total
end

local function retention_full(extra)
  if retained_bytes() + extra <= LIMITS.retained_bytes then
    return nil
  end
  return failure(
    "retention_cap",
    "context retention is limited to 2 MiB; release a snapshot first"
  )
end

---Reserve worst-case capacity before any text is read.
local function reserve_capture()
  local count = vim.tbl_count(retained)
  if count >= LIMITS.retained_snapshots then
    return failure(
      "retention_cap",
      ("at most %d context snapshots are retained; release one first"):format(
        LIMITS.retained_snapshots
      )
    )
  end
  return retention_full(LIMITS.input_bytes + LIMITS.metadata_bytes)
end

---Replace the `kind` charge of an entry when the new total fits.
local function charge(entry, kind, bytes)
  local err = retention_full(bytes - entry[kind])
  if err then
    return err
  end
  entry[kind] = bytes
  return nil
end

local function entry_of(snapshot)
  local entry = type(snapshot) == "table" and retained[snapshot.id]
  if not entry then
    error("iara.extras.agents.context: unknown or released snapshot", 4)
  end
  return entry
end

-- Identity ----------------------------------------------------------------

---Project root and worktree identity, through F3 when it is installed.
local function project_of(bufnr)
  local ok, root = pcall(require, "iara.core.root")
  if ok and type(root.resolve) == "function" then
    local resolved = root.resolve(bufnr)
    return resolved.path, resolved.worktree_id
  end
  local cwd = vim.uv.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
  return cwd, "dir:" .. cwd
end

local function buffer_label(bufnr, path, root)
  if not path then
    local name = api.nvim_buf_get_name(bufnr)
    local shown = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
    return ("%s (buffer %d)"):format(shown, bufnr)
  end
  local relative = vim.fs.relpath(root, path)
  return relative or path
end

local function identity(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  local is_file = vim.bo[bufnr].buftype == "" and name ~= ""
  local path = is_file and vim.fs.normalize(name) or nil
  local root, worktree_id = project_of(bufnr)
  local snapshot = {
    bufnr = bufnr,
    changedtick = api.nvim_buf_get_changedtick(bufnr),
    path = path,
    buffer_label = buffer_label(bufnr, path, root),
    worktree_id = worktree_id,
    unsaved = path == nil or vim.bo[bufnr].modified,
    filetype = vim.bo[bufnr].filetype,
    notes = {},
  }
  local size = #(path or "") + #snapshot.buffer_label + #worktree_id
  if size + #snapshot.filetype > LIMITS.metadata_bytes then
    return nil, too_large("context metadata", LIMITS.metadata_bytes)
  end
  return snapshot
end

-- Selection positions -----------------------------------------------------

local function is_before(a, b)
  return a[2] < b[2] or (a[2] == b[2] and a[3] < b[3])
end

---Positions and mode of the live Visual selection, or else of the last
---one (marks '< and '>). Runs in the buffer's context.
local function selection_of(bufnr, requested)
  local live = MODES[api.nvim_get_mode().mode]
  if live and live ~= "reference" and bufnr == api.nvim_get_current_buf() then
    -- "$" extends to the line end; only getcurpos() records it.
    local dollar = vim.fn.getcurpos()[5] == vim.v.maxcol
    return vim.fn.getpos("v"), vim.fn.getpos("."), requested or live, dollar
  end
  local first, last = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local mode = requested or MODES[vim.fn.visualmode()]
  if first[2] == 0 or last[2] == 0 or not mode then
    return nil
  end
  return first, last, mode, false
end

local function line_at(bufnr, row)
  return api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1]
end

---Clamp a position to its line (marks may carry MAXCOL) after admission.
local function clamp(bufnr, pos)
  local length = #line_at(bufnr, pos[2] - 1)
  return { 0, pos[2], math.max(1, math.min(pos[3], length + 1)), 0 }
end

---Cheap admission on rows and byte offsets, before reading any line.
local function admit_rows(bufnr, first_row, last_row, max_rows)
  local rows = last_row - first_row + 1
  if rows > max_rows then
    return failure(
      "too_large",
      ("selection has %d lines; at most %d are accepted"):format(rows, max_rows)
    )
  end
  local span = api.nvim_buf_get_offset(bufnr, last_row + 1)
    - api.nvim_buf_get_offset(bufnr, first_row)
  if span > LIMITS.input_bytes then
    return failure(
      "too_large",
      ("selected lines span %d bytes; at most 64 KiB are accepted"):format(span)
        .. " (long lines count fully)"
    )
  end
  return nil
end

-- Extraction --------------------------------------------------------------

---Join API lines with LF; the API reports NUL bytes as "\n" inside lines.
local function join_lines(lines)
  local parts = {}
  for index, line in ipairs(lines) do
    parts[index] = line:gsub("\n", "\0")
  end
  return table.concat(parts, "\n")
end

local function read_text(bufnr, range)
  local start_row, start_col, end_row, end_col = unpack(range)
  local lines =
    api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
  return join_lines(lines)
end

local function charwise(bufnr, first, last, dollar)
  local regions = vim.fn.getregionpos(first, last, { type = "v", eol = true })
  local head, tail = regions[1][1], regions[#regions][2]
  local start_row, end_row = head[2] - 1, tail[2] - 1
  local start_col = math.min(head[3] - 1, #line_at(bufnr, start_row))
  local end_length = #line_at(bufnr, end_row)
  local range = { start_row, start_col, end_row, tail[3] }
  -- An end past the line (or on an empty line) includes its line break,
  -- except after the last line, as with a native yank.
  local past_end = dollar or tail[3] > end_length or end_length == 0
  if past_end and end_row + 1 < api.nvim_buf_line_count(bufnr) then
    range[3], range[4] = end_row + 1, 0
  elseif past_end then
    range[4] = end_length
  end
  return read_text(bufnr, range), range
end

local function linewise(bufnr, first, last)
  local start_row, end_row = first[2] - 1, last[2] - 1
  local lines = api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, true)
  return join_lines(lines) .. "\n", { start_row, 0, end_row + 1, 0 }
end

local function cell_width(row, col)
  local cells = vim.fn.virtcol({ row, col }, true)
  return cells[2] - cells[1] + 1
end

---Text of one block row from its region; partial cells become spaces.
---@return string text
---@return integer partial Number of partially selected cells replaced.
local function block_row(line, region, dollar)
  local row, start_col, start_off = region[1][2], region[1][3], region[1][4]
  local end_col, end_off = region[2][3], region[2][4]
  if start_col > #line then
    return "", 0
  end
  if dollar then
    end_col, end_off = #line, 0
  end
  end_col = math.min(end_col, #line)
  local end_char = end_col + vim.str_utf_start(line, end_col)
  if start_off > 0 and end_off > 0 and end_char == start_col then
    return (" "):rep(end_off - start_off), 1
  end
  local left, right, partial = "", "", 0
  local first, last = start_col, end_col
  if start_off > 0 then
    left = (" "):rep(cell_width(row, start_col) - start_off)
    first = start_col + vim.str_utf_end(line, start_col) + 1
    partial = 1
  end
  if end_off > 0 then
    right = (" "):rep(end_off)
    last = end_char - 1
    partial = partial + 1
  end
  return left .. line:sub(first, last) .. right, partial
end

---Display columns of a block, zero-based and end exclusive.
local function block_columns(first, last, dollar)
  local a = vim.fn.virtcol({ first[2], first[3] }, true)
  local b = vim.fn.virtcol({ last[2], last[3] }, true)
  local left, right = math.min(a[1], b[1]), math.max(a[2], b[2])
  -- Same rule as getregionpos() for an exclusive block selection.
  if vim.o.selection == "exclusive" and a[2] < b[1] and b[2] > a[2] then
    right = b[1] - 1
  end
  if dollar then
    for row = first[2], last[2] do
      right = math.max(right, vim.fn.virtcol({ row, "$" }) - 1)
    end
  end
  return { left - 1, math.max(right, left) }
end

local function block_text(bufnr, first, last, dollar)
  local regions = vim.fn.getregionpos(first, last, { type = "\22", eol = true })
  local rows, partial = {}, 0
  local start_col, end_col = 0, 0
  for index, region in ipairs(regions) do
    local line = line_at(bufnr, region[1][2] - 1)
    local text, cells = block_row(line, region, dollar)
    rows[index] = text
    partial = partial + cells
    if index == 1 then
      start_col = math.min(region[1][3] - 1, #line)
    end
    end_col = dollar and #line or math.min(region[2][3], #line)
  end
  local range = { first[2] - 1, start_col, last[2] - 1, end_col }
  return join_lines(rows), range, partial
end

local function blockwise(bufnr, first, last, dollar, snapshot)
  local columns = block_columns(first, last, dollar)
  local width = columns[2] - columns[1]
  if width > LIMITS.block_columns then
    return nil,
      nil,
      failure(
        "too_large",
        ("block is %d display columns wide; at most %d are accepted"):format(
          width,
          LIMITS.block_columns
        )
      )
  end
  local text, range, partial = block_text(bufnr, first, last, dollar)
  snapshot.columns, snapshot.to_line_end = columns, dollar
  table.insert(snapshot.notes, "block rows are not padded to the block width.")
  if partial > 0 then
    local note = "%d partially selected cells (tabs or wide characters)"
      .. " are shown as spaces."
    table.insert(snapshot.notes, note:format(partial))
  end
  return text, range
end

local function extract(bufnr, first, last, mode, dollar, snapshot)
  local max_rows = mode == "blockwise" and LIMITS.block_rows or LIMITS.char_rows
  local err = admit_rows(bufnr, first[2] - 1, last[2] - 1, max_rows)
  if err then
    return nil, nil, err
  end
  first, last = clamp(bufnr, first), clamp(bufnr, last)
  if mode == "charwise" then
    return charwise(bufnr, first, last, dollar)
  elseif mode == "linewise" then
    return linewise(bufnr, first, last)
  end
  return blockwise(bufnr, first, last, dollar, snapshot)
end

---Fill the selection text of `snapshot`. Runs in the buffer's context.
local function capture_selection(snapshot, requested)
  local bufnr = snapshot.bufnr
  local first, last, mode, dollar = selection_of(bufnr, requested)
  if not first then
    return failure("no_selection", "no Visual selection to capture")
  end
  if is_before(last, first) then
    -- A charwise "$" only matters when the cursor ends the selection.
    first, last = last, first
    dollar = dollar and mode == "blockwise"
  end
  local text, range, err = extract(bufnr, first, last, mode, dollar, snapshot)
  if not text then
    return err
  end
  snapshot.mode, snapshot.text, snapshot.range = mode, text, range
  if range[3] > range[1] then
    table.insert(
      snapshot.notes,
      "line breaks are shown as LF; original line-ending bytes are not claimed."
    )
  end
  return nil
end

-- Diagnostics -------------------------------------------------------------

local function diagnostic_count(bufnr)
  local ok, counts = pcall(vim.diagnostic.count, bufnr)
  if not ok or type(counts) ~= "table" then
    return nil
  end
  local total = 0
  for _, count in pairs(counts) do
    total = total + count
  end
  return total
end

local function overlaps(item, range)
  if not range then
    return true
  end
  local last_row = range[4] == 0 and range[3] - 1 or range[3]
  return item.lnum <= last_row and (item.end_lnum or item.lnum) >= range[1]
end

local function plain_diagnostic(item)
  local severity = vim.diagnostic.severity[item.severity] or "UNKNOWN"
  return {
    row = item.lnum,
    col = item.col,
    end_row = item.end_lnum,
    end_col = item.end_col,
    severity = severity:lower(),
    source = item.source,
    code = item.code ~= nil and tostring(item.code) or nil,
    message = item.message,
  }
end

---Bounded diagnostics of one buffer, limited to the selected rows.
local function collect_diagnostics(bufnr, range)
  local total = diagnostic_count(bufnr)
  if not total then
    return nil, failure("diagnostics_unavailable", "no diagnostic counts")
  end
  if total > LIMITS.diagnostic_count then
    return nil,
      failure(
        "too_large",
        ("buffer has %d diagnostics; at most %d can be attached"):format(
          total,
          LIMITS.diagnostic_count
        )
      )
  end
  local items, bytes = {}, 0
  for _, item in ipairs(vim.diagnostic.get(bufnr)) do
    if overlaps(item, range) then
      local size = #item.message + #(item.source or "")
      if size > LIMITS.diagnostic_message_bytes then
        return nil, too_large("a diagnostic message", 4096)
      end
      bytes = bytes + size
      table.insert(items, plain_diagnostic(item))
    end
  end
  if bytes > LIMITS.diagnostic_bytes then
    return nil, too_large("diagnostics", LIMITS.diagnostic_bytes)
  end
  table.sort(items, function(a, b)
    return a.row < b.row or (a.row == b.row and a.col < b.col)
  end)
  return items, nil, bytes
end

-- Capture -----------------------------------------------------------------

local function attach_diagnostics(snapshot)
  local items, err, bytes = collect_diagnostics(snapshot.bufnr, snapshot.range)
  if not items then
    return err
  end
  if #(snapshot.text or "") + bytes > LIMITS.input_bytes then
    return too_large("selection and diagnostics", LIMITS.input_bytes)
  end
  snapshot.diagnostics = items
  return nil
end

local function build_snapshot(bufnr, opts, mode)
  local snapshot, err = identity(bufnr)
  if not snapshot then
    return nil, err
  end
  if mode == "reference" then
    if not snapshot.path then
      local message = "an unnamed buffer has no file to reference"
      return nil, failure("no_path", message)
    end
    snapshot.mode = "reference"
  else
    err = api.nvim_buf_call(bufnr, function()
      return capture_selection(snapshot, mode)
    end)
  end
  if not err and #(snapshot.text or "") > LIMITS.input_bytes then
    err = too_large("selection", LIMITS.input_bytes)
  end
  if not err and opts.diagnostics then
    err = attach_diagnostics(snapshot)
  end
  return (not err) and snapshot or nil, err
end

local function check_capture_opts(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("context.capture: opts must be a table", 3)
  end
  opts = opts or {}
  local bufnr = opts.bufnr
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if type(bufnr) ~= "number" or not api.nvim_buf_is_valid(bufnr) then
    error("context.capture: invalid buffer " .. tostring(opts.bufnr), 3)
  end
  if opts.mode ~= nil and not MODES[opts.mode] then
    error("context.capture: unknown mode " .. tostring(opts.mode), 3)
  end
  return opts, bufnr, MODES[opts.mode]
end

---Capture a selection or disk reference before focus changes. Without
---`mode`, the live Visual selection is used, else the last one.
---Error codes: "too_large", "changed", "retention_cap", "no_selection",
---"no_path" (disk reference to an unnamed buffer),
---"diagnostics_unavailable".
---@param opts { bufnr: integer?, mode: string?, diagnostics: boolean? }?
---  `mode`: "charwise", "linewise", "blockwise", "reference", or a
---  Visual mode character.
---@return IaraContextSnapshot|nil snapshot
---@return IaraError|nil err
function M.capture(opts)
  local bufnr, mode
  opts, bufnr, mode = check_capture_opts(opts)
  local err = reserve_capture()
  if err then
    return nil, err
  end
  if not api.nvim_buf_is_loaded(bufnr) and mode ~= "reference" then
    return nil, failure("no_selection", "the buffer is not loaded")
  end
  local snapshot
  snapshot, err = build_snapshot(bufnr, opts, mode)
  if not snapshot then
    return nil, err
  end
  next_id = next_id + 1
  snapshot.id = next_id
  local raw = #(snapshot.text or "") + LIMITS.metadata_bytes
  for _, item in ipairs(snapshot.diagnostics or {}) do
    raw = raw + #item.message
  end
  retained[next_id] = { snapshot = snapshot, raw = raw, preview = 0, copy = 0 }
  return snapshot
end

-- Payload -----------------------------------------------------------------

local function escape(text)
  return (
    text:gsub(CONTROL, function(byte)
      return ("\\x%02X"):format(byte:byte())
    end)
  )
end

---Bounded pass over the text: control bytes and the longest backtick run.
local function scan(text)
  local controls, ticks = 0, 0
  for _ in text:gmatch(CONTROL) do
    controls = controls + 1
  end
  for run in text:gmatch("`+") do
    ticks = math.max(ticks, #run)
  end
  return controls, ticks
end

local function content_line(snapshot)
  if snapshot.mode == "reference" then
    if snapshot.unsaved then
      return "Content: not included; the agent reads the file on disk,"
        .. " which lacks the buffer's unsaved changes."
    end
    return "Content: not included; the agent reads the file on disk."
  end
  if not snapshot.path then
    return "Content: current buffer text, not saved to any file."
  end
  if snapshot.unsaved then
    return "Content: current buffer text with unsaved changes"
      .. " (differs from disk)."
  end
  return "Content: current buffer text (no unsaved changes)."
end

local function selection_line(snapshot)
  local range = snapshot.range
  if snapshot.mode == "linewise" then
    return ("Selection: linewise, lines %d-%d."):format(range[1] + 1, range[3])
  elseif snapshot.mode == "blockwise" then
    local columns = snapshot.columns
    local right = snapshot.to_line_end and "end of line"
      or ("column %d"):format(columns[2])
    local line = "Selection: blockwise, lines %d-%d, display column %d to %s."
    return line:format(range[1] + 1, range[3] + 1, columns[1] + 1, right)
  end
  return (
    "Selection: charwise, line %d column %d to line %d column %d"
    .. " (byte columns, end exclusive)."
  ):format(range[1] + 1, range[2] + 1, range[3] + 1, range[4] + 1)
end

local function header(snapshot, controls)
  local lines = { "Editor context from Iara (" .. snapshot.mode .. ")" }
  table.insert(lines, "Buffer: " .. snapshot.buffer_label)
  if snapshot.path then
    table.insert(lines, "Path: " .. snapshot.path)
  end
  table.insert(lines, "Project: " .. snapshot.worktree_id)
  table.insert(lines, content_line(snapshot))
  if snapshot.range then
    table.insert(lines, selection_line(snapshot))
  end
  for _, note in ipairs(snapshot.notes or {}) do
    table.insert(lines, "Note: " .. note)
  end
  if controls > 0 then
    table.insert(
      lines,
      ("Note: %d control bytes are shown as \\xNN escapes."):format(controls)
    )
  end
  if snapshot.text and snapshot.text:sub(-1) == "\n" then
    table.insert(lines, "Note: the text ends with a line break.")
  end
  return lines
end

local function diagnostic_lines(diagnostics)
  if #diagnostics == 0 then
    return { "Diagnostics: none in the captured range." }
  end
  local lines = { ("Diagnostics (%d):"):format(#diagnostics) }
  for _, item in ipairs(diagnostics) do
    local source = item.source and (" (" .. escape(item.source) .. ")") or ""
    local message = escape(item.message):gsub("\n", "\n  ")
    table.insert(
      lines,
      ("- line %d, column %d, %s%s: %s"):format(
        item.row + 1,
        item.col + 1,
        item.severity,
        source,
        message
      )
    )
  end
  return lines
end

local function fenced(snapshot, fence)
  local text = escape(snapshot.text)
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local info = snapshot.filetype:match("^[%w_+-]+$") or ""
  return fence .. info .. "\n" .. text .. fence
end

---Final payload exactly as previewed and copied. Pure; it does not check
---whether the buffer changed. Error code: "too_large" (128 KiB).
---@param snapshot IaraContextSnapshot
---@return string|nil payload
---@return IaraError|nil err
function M.format(snapshot)
  local text = snapshot.text
  local controls, ticks = scan(text or "")
  local fence = ("`"):rep(math.max(3, ticks + 1))
  -- Header and diagnostics are small by admission; only the selection
  -- text can expand, so its escaped size is counted before escaping.
  local parts = { table.concat(header(snapshot, controls), "\n") }
  if snapshot.diagnostics then
    local lines = diagnostic_lines(snapshot.diagnostics)
    table.insert(parts, table.concat(lines, "\n"))
  end
  local size = #table.concat(parts, "\n\n") + 4
  if text then
    size = size + #text + 3 * controls + 2 * #fence + #snapshot.filetype + 3
  end
  if size > LIMITS.payload_bytes then
    return nil, too_large("the formatted payload", LIMITS.payload_bytes)
  end
  if text then
    table.insert(parts, 2, fenced(snapshot, fence))
  end
  return table.concat(parts, "\n\n")
end

-- Preview and copy --------------------------------------------------------

local function unchanged(snapshot)
  local bufnr = snapshot.bufnr
  if
    api.nvim_buf_is_valid(bufnr)
    and api.nvim_buf_get_changedtick(bufnr) == snapshot.changedtick
  then
    return nil
  end
  return failure(
    "changed",
    "the buffer changed since the context was captured; capture it again"
  )
end

---Checked payload of a retained, unchanged snapshot.
local function payload_of(snapshot)
  local entry = entry_of(snapshot)
  local err = unchanged(entry.snapshot)
  if err then
    return nil, nil, err
  end
  local payload
  payload, err = M.format(entry.snapshot)
  return entry, payload, err
end

local function default_register()
  return vim.fn.has("clipboard") == 1 and "+" or '"'
end

---Copy the final payload into `register` (default "+" when a clipboard
---provider is available, else the unnamed register).
---Error codes: "changed", "too_large", "retention_cap".
---@param snapshot IaraContextSnapshot
---@param register string?
---@return boolean ok
---@return IaraError|nil err
---@return string|nil register The register written.
function M.copy(snapshot, register)
  local entry, payload, err = payload_of(snapshot)
  if not payload then
    return false, err
  end
  err = charge(entry, "copy", #payload)
  if err then
    return false, err
  end
  register = register or default_register()
  vim.fn.setreg(register, payload, "v")
  return true, nil, register
end

local function register_label(register)
  if register == '"' then
    return "the unnamed register (clipboard unavailable)"
  end
  return ("the %s register"):format(register)
end

local function copy_from_preview(snapshot)
  local ok, err, register = M.copy(snapshot)
  if ok then
    vim.notify("Iara: context copied to " .. register_label(register))
  else
    vim.notify("Iara: context not copied: " .. err.message, vim.log.levels.WARN)
  end
end

local function open_preview(entry, payload)
  local snapshot = entry.snapshot
  -- The window's look is `iara.extras.agents.preview` (V11).
  local buf, win = require("iara.extras.agents.preview").open(
    payload,
    snapshot,
    LIMITS.payload_bytes
  )
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local map = { buffer = buf, nowait = true }
  vim.keymap.set("n", "y", function()
    copy_from_preview(snapshot)
  end, vim.tbl_extend("force", map, { desc = "Copy context" }))
  vim.keymap.set("n", "q", close, map)
  vim.keymap.set("n", "<Esc>", close, map)
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      entry.preview, entry.preview_buf = 0, nil
    end,
  })
  entry.preview_buf = buf
  return buf, win
end

---Show the final payload in a scratch floating window. `y` copies it,
---`q` closes it. Error codes: "changed", "too_large", "retention_cap".
---@param snapshot IaraContextSnapshot
---@return boolean ok
---@return IaraError|nil err
function M.preview(snapshot)
  local entry, payload, err = payload_of(snapshot)
  if not payload then
    return false, err
  end
  if entry.preview_buf and api.nvim_buf_is_valid(entry.preview_buf) then
    api.nvim_buf_delete(entry.preview_buf, { force = true })
  end
  err = charge(entry, "preview", #payload)
  if err then
    return false, err
  end
  open_preview(entry, payload)
  return true, nil
end

---Forget a snapshot and close its preview. Unknown ids are ignored.
---@param id integer
function M.release(id)
  local entry = retained[id]
  if not entry then
    return
  end
  retained[id] = nil
  if entry.preview_buf and api.nvim_buf_is_valid(entry.preview_buf) then
    api.nvim_buf_delete(entry.preview_buf, { force = true })
  end
end

return M
