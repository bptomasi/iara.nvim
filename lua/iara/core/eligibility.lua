--- Buffer eligibility and conservative mode.
---
--- A buffer is conservative when it holds more than LIMITS.max_bytes or a
--- line of LIMITS.max_line_bytes bytes or more. Sizes come from byte
--- offsets (nvim_buf_get_offset), which Neovim keeps per memline chunk, so
--- no text is copied. Line checks probe spans of rows: a span whose bytes
--- stay below the line limit cannot contain a long line, so only suspect
--- spans are inspected row by row. Every pass is capped at SLICE_PROBES
--- offset lookups; the rest continues on a later main-loop iteration while
--- the state is "unknown" (reason "pending").
---
--- After a full pass finds the buffer eligible, edits only recheck the
--- rows they touched (from nvim_buf_attach) plus the total size.
--- See contracts.md, section `iara.core.eligibility`.
local M = {}

M.LIMITS = { max_bytes = 1048576, max_line_bytes = 10000 }

local SPAN_LINES = 64
local SLICE_PROBES = 4096
local MIB = 1048576

---@class IaraEligibility
---@field state "eligible"|"conservative"|"unknown"
---@field reason "size"|"long_line"|"pending"|"invalid"|nil
---@field message string?
---@field bytes integer?

---Private per-buffer cache.
---@class IaraEligibilityEntry: IaraEligibility
---@field tick integer|nil changedtick of the last size check.
---@field attached boolean nvim_buf_attach callbacks are live.
---@field full boolean The next check must scan every row.
---@field dirty { from: integer, to: integer }|nil Rows edited since.
---@field scan { row: integer, stop: integer }|nil Unfinished line scan.
---@field scheduled boolean A refresh is queued on the main loop.

---@type table<integer, IaraEligibilityEntry>
local entries = {}

local is_setup = false

local api = vim.api

local function offset(bufnr, row)
  return api.nvim_buf_get_offset(bufnr, row)
end

local function format_mib(bytes)
  local value = bytes / MIB
  if value == math.floor(value) then
    return ("%d MiB"):format(value)
  end
  return ("%.1f MiB"):format(value)
end

local function size_message(bytes)
  local limit = M.LIMITS.max_bytes
  return ("large file (%s > %s)"):format(format_mib(bytes), format_mib(limit))
end

local function long_line_message(row, length)
  local text = "long line %d (%d >= %d bytes)"
  return text:format(row + 1, length, M.LIMITS.max_line_bytes)
end

local function fire(payload)
  if not api.nvim_buf_is_valid(payload.bufnr) then
    return
  end
  api.nvim_exec_autocmds("User", {
    pattern = "IaraEligibilityChanged",
    data = payload,
    modeline = false,
  })
end

---Update the cache first, then announce a change on a later main-loop
---iteration: checks may run during redraw (statusline) or text locks.
local function set_state(bufnr, entry, state, reason, message)
  local previous, previous_reason = entry.state, entry.reason
  entry.state, entry.reason, entry.message = state, reason, message
  if previous == state and previous_reason == reason then
    return
  end
  local payload =
    { bufnr = bufnr, state = state, previous = previous, reason = reason }
  vim.schedule(function()
    fire(payload)
  end)
end

local function line_length(bufnr, row)
  return #api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1]
end

---Rows [from, to) whose offsets allow a long line; returns the first one
---that really is long. Offsets include line endings, so confirm by length.
local function find_in_span(bufnr, from, to, limit)
  local start = offset(bufnr, from)
  for row = from, to - 1 do
    local finish = offset(bufnr, row + 1)
    if finish - start >= limit then
      local length = line_length(bufnr, row)
      if length >= limit then
        return row, length
      end
    end
    start = finish
  end
end

---Advance `scan` by at most SLICE_PROBES offset lookups.
---@return integer|nil row, integer|nil length The first long line found.
local function scan_slice(bufnr, scan)
  local limit = M.LIMITS.max_line_bytes
  local probes = 0
  local start = offset(bufnr, scan.row)
  while scan.row < scan.stop and probes < SLICE_PROBES do
    local span_end = math.min(scan.row + SPAN_LINES, scan.stop)
    local finish = offset(bufnr, span_end)
    probes = probes + 1
    if finish - start >= limit then
      local row, length = find_in_span(bufnr, scan.row, span_end, limit)
      if row then
        return row, length
      end
      probes = probes + span_end - scan.row
    end
    scan.row, start = span_end, finish
  end
end

local refresh

local function schedule_refresh(bufnr, entry)
  if entry.scheduled then
    return
  end
  entry.scheduled = true
  vim.schedule(function()
    entry.scheduled = false
    if entries[bufnr] == entry and api.nvim_buf_is_valid(bufnr) then
      refresh(bufnr, entry, true)
    end
  end)
end

---Rows to scan after a size check: the edited rows when the buffer was
---fully verified eligible, otherwise every row.
local function scan_range(entry, line_count)
  local incremental = entry.state == "eligible"
    and not entry.scan
    and not entry.full
  if not incremental then
    return 0, line_count
  end
  local dirty = entry.dirty or { from = 0, to = 0 }
  local from = math.min(dirty.from, line_count)
  return from, math.max(from, math.min(dirty.to, line_count))
end

local function begin_check(bufnr, entry)
  local line_count = api.nvim_buf_line_count(bufnr)
  entry.bytes = offset(bufnr, line_count)
  if entry.bytes > M.LIMITS.max_bytes then
    entry.scan, entry.dirty, entry.full = nil, nil, true
    set_state(bufnr, entry, "conservative", "size", size_message(entry.bytes))
    return
  end
  local from, to = scan_range(entry, line_count)
  entry.scan, entry.dirty, entry.full = { row = from, stop = to }, nil, false
end

local function continue_scan(bufnr, entry)
  local row, length = scan_slice(bufnr, entry.scan)
  if row then
    entry.scan = nil
    local message = long_line_message(row, length)
    set_state(bufnr, entry, "conservative", "long_line", message)
  elseif entry.scan.row >= entry.scan.stop then
    entry.scan = nil
    set_state(bufnr, entry, "eligible", nil, nil)
  else
    -- Conservative stays conservative until proven otherwise.
    if entry.state ~= "conservative" then
      set_state(bufnr, entry, "unknown", "pending", "checking line lengths")
    end
    schedule_refresh(bufnr, entry)
  end
end

---Start a check when the text changed since the last one. An unfinished
---scan advances only from its scheduled continuation (`continuing`), so
---queries such as the statusline stay cheap.
refresh = function(bufnr, entry, continuing)
  if not api.nvim_buf_is_loaded(bufnr) then
    entry.tick, entry.scan, entry.full, entry.bytes = nil, nil, true, nil
    set_state(bufnr, entry, "unknown", "pending", "buffer not loaded")
    return
  end
  local tick = api.nvim_buf_get_changedtick(bufnr)
  local changed = entry.tick ~= tick
  if changed then
    entry.tick = tick
    begin_check(bufnr, entry)
  end
  if entry.scan and (changed or continuing) then
    continue_scan(bufnr, entry)
  end
end

---Grow the pending dirty range by an edit of rows [first, last_old) that
---now spans [first, last_new). Over-approximation only costs extra probes.
local function mark_dirty(entry, first, last_old, last_new)
  local dirty = entry.dirty
  if not dirty then
    entry.dirty = { from = first, to = last_new }
    return
  end
  local to = last_new
  if dirty.to > first then
    to = math.max(dirty.to + last_new - last_old, last_new)
  end
  entry.dirty = { from = math.min(dirty.from, first), to = to }
end

local function attach(bufnr, entry)
  entry.attached, entry.full, entry.tick = true, true, nil
  api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      if entries[bufnr] ~= entry then
        return true
      end
      mark_dirty(entry, first, last_old, last_new)
      schedule_refresh(bufnr, entry)
    end,
    on_reload = function()
      entry.full, entry.tick = true, nil
      schedule_refresh(bufnr, entry)
    end,
    on_detach = function()
      entry.attached = false
    end,
  })
end

local function track(bufnr)
  local entry = entries[bufnr]
  if not entry then
    entry = {
      state = "unknown",
      reason = "pending",
      message = "checking buffer size",
      attached = false,
      full = true,
      scheduled = false,
    }
    entries[bufnr] = entry
  end
  if not entry.attached and api.nvim_buf_is_loaded(bufnr) then
    attach(bufnr, entry)
  end
  return entry
end

---@return integer|nil bufnr Nil when the handle is not a valid buffer.
local function resolve(bufnr)
  if bufnr ~= nil and type(bufnr) ~= "number" then
    error("bufnr must be an integer or nil", 3)
  end
  if bufnr == nil or bufnr == 0 then
    return api.nvim_get_current_buf()
  end
  return api.nvim_buf_is_valid(bufnr) and bufnr or nil
end

local function snapshot(entry)
  return {
    state = entry.state,
    reason = entry.reason,
    message = entry.message,
    bytes = entry.bytes,
  }
end

local INVALID = {
  state = "unknown",
  reason = "invalid",
  message = "invalid buffer",
}

---Cheap query: returns cached state and schedules a budgeted recheck
---when stale. Never scans a whole buffer synchronously.
---@param bufnr integer? 0 or nil for the current buffer.
---@return IaraEligibility
function M.check(bufnr)
  local resolved = resolve(bufnr)
  if not resolved then
    return vim.deepcopy(INVALID)
  end
  local entry = track(resolved)
  refresh(resolved, entry, false)
  return snapshot(entry)
end

---True only for state "eligible". Unknown counts as suspended.
---@param bufnr integer? 0 or nil for the current buffer.
---@return boolean
function M.is_eligible(bufnr)
  return M.check(bufnr).state == "eligible"
end

---Force a full recheck (text change, paste, reload trigger one too).
---@param bufnr integer? 0 or nil for the current buffer.
function M.recheck(bufnr)
  local resolved = resolve(bufnr)
  if not resolved then
    return
  end
  local entry = track(resolved)
  entry.full, entry.tick, entry.scan = true, nil, nil
  refresh(resolved, entry, false)
end

---@param bufnr integer? 0 or nil for the current buffer.
---@return string text "" when eligible, else a short reason.
function M.statusline(bufnr)
  local result = M.check(bufnr)
  if result.state == "eligible" then
    return ""
  end
  local label = result.state == "conservative" and "conservative" or "suspended"
  return label .. ": " .. result.message
end

---Register buffer autocmds and check buffers that are already loaded.
---@param _ table Composed configuration (unused).
function M.setup(_)
  if is_setup then
    return
  end
  is_setup = true
  local group = api.nvim_create_augroup("IaraEligibility", { clear = true })
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(args)
      M.recheck(args.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      entries[args.buf] = nil
    end,
  })
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) then
      M.check(bufnr)
    end
  end
end

return M
