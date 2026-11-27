--- External change reconciliation.
---
--- Detection reuses Neovim's own timestamp check (`:checktime {buf}`),
--- run per buffer on focus return and on explicit request, never on
--- terminal output or file watchers. A FileChangedShell handler replaces
--- the native warnings and prompts: unmodified buffers reload, modified
--- (or deleted) ones keep their text and become conflicts. A conflict
--- keeps a bounded disk snapshot, streamed in chunks, for comparison.
--- A file too large for a snapshot, or one arriving when the session cap
--- is full, keeps buffer and disk untouched and offers explicitly
--- partial excerpts, an external diff, or a copy of the buffer saved to
--- an unused path. Nothing here forces a reload or overwrites a file.
--- See contracts.md, section `iara.core.reconcile`.
local M = {}

local uv = vim.uv

---Admission limits for disk snapshots.
local LIMITS = {
  file_bytes = 1024 * 1024,
  lines = 10000,
  line_bytes = 64 * 1024,
  snapshots = 2,
  session_bytes = 4 * 1024 * 1024,
  chunk_bytes = 64 * 1024,
  -- A file rewritten during the read is read again, at most this often,
  -- after `retry_ms`; a writer still active then leaves it unreadable.
  read_retries = 3,
  retry_ms = 50,
  excerpt_bytes = 64 * 1024,
}

---Buffers checked per main-loop tick, so a check of many buffers never
---blocks input for long.
local CHECK_BATCH = 32

local GROUP = "IaraReconcile"

---@class IaraConflictRecord: IaraConflict
---@field text string|nil Snapshot content when `snapshot` is "available".
---@field reserved integer Bytes counted against the session cap.
---@field generation integer Identifies the current snapshot read.
---@field deleted boolean The file was missing at detection.
---@field detail string|nil Why no complete snapshot exists.
---@field noted boolean|nil The fallbacks of this conflict were announced.
---@field retries integer Snapshot reads restarted after a concurrent write.

local state = {
  initialized = false,
  ---@type table<integer, IaraConflictRecord>
  conflicts = {},
  admitted = { count = 0, bytes = 0 },
  generation = 0,
  queue = {},
  queued = {},
  draining = false,
  ---@type table<integer, true> Buffers kept unreloaded in this check.
  held = {},
  ---@type string[]
  pending_notes = {},
  ---@type table<integer, integer> Conflict buffer -> disk view buffer.
  views = {},
  ---@type table<integer, integer> View buffer -> bytes it reserved.
  view_bytes = {},
}

local function make_error(code, message)
  return { code = code, message = message }
end

local function fire(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    data = data,
    modeline = false,
  })
end

local function public_view(record)
  return {
    bufnr = record.bufnr,
    path = record.path,
    detected_at = record.detected_at,
    snapshot = record.snapshot,
    disk = record.disk and vim.deepcopy(record.disk) or nil,
    detail = record.detail,
  }
end

local function buffer_path(bufnr)
  return vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
end

---A loaded buffer backed by a file on disk.
local function is_file_buffer(bufnr)
  return vim.api.nvim_buf_is_loaded(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function validate_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    error("invalid buffer: " .. vim.inspect(bufnr), 3)
  end
end

local function resolve_buffer(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  validate_buffer(bufnr)
  return bufnr
end

-- Notifications ----------------------------------------------------------

local function flush_notes()
  local notes = state.pending_notes
  state.pending_notes = {}
  if #notes == 0 then
    return
  end
  local hint = ":IaraCompareDisk compares; :IaraKeepBuffer or"
    .. " :IaraLoadDisk resolves."
  local text = "Iara: " .. table.concat(notes, "\n") .. "\n" .. hint
  vim.notify(text, vim.log.levels.WARN)
end

---Collect messages and show them once per tick, so a burst of external
---writes produces one message instead of a prompt per buffer.
local function note(message)
  table.insert(state.pending_notes, message)
  if #state.pending_notes == 1 then
    vim.schedule(flush_notes)
  end
end

-- Snapshot admission and streaming -------------------------------------

local function release(record)
  if record.reserved > 0 then
    state.admitted.count = state.admitted.count - 1
    state.admitted.bytes = state.admitted.bytes - record.reserved
  end
  record.reserved = 0
  record.text = nil
end

local function mib(bytes)
  return ("%.1f MiB"):format(bytes / 1048576)
end

---Reserve session bytes for a view or excerpt, which hold copies.
---@return boolean ok
local function reserve_bytes(bytes)
  if state.admitted.bytes + bytes > LIMITS.session_bytes then
    return false
  end
  state.admitted.bytes = state.admitted.bytes + bytes
  return true
end

---Reserve room for a snapshot of `size` bytes, or report why not.
---@return string|nil refused "oversized" or "over_cap"
---@return string|nil detail
local function admit(record, size)
  if size > LIMITS.file_bytes then
    return "oversized", mib(size) .. " > 1 MiB"
  end
  local admitted = state.admitted
  if admitted.count >= LIMITS.snapshots then
    return "over_cap", "two disk snapshots are already held"
  end
  if admitted.bytes + size > LIMITS.session_bytes then
    return "over_cap", "the 4 MiB session snapshot memory is full"
  end
  -- An empty file still occupies a snapshot slot.
  record.reserved = math.max(size, 1)
  admitted.count = admitted.count + 1
  admitted.bytes = admitted.bytes + record.reserved
  return nil
end

local LONG_LINE = "a line is longer than 64 KiB"
local MANY_LINES = "more than 10000 lines"

---Track line count and line length across chunks while streaming.
---@return string|nil problem Set once a line limit is exceeded.
local function scan_chunk(scan, chunk)
  local position = 1
  while true do
    local newline = chunk:find("\n", position, true)
    local stop = newline or (#chunk + 1)
    scan.line_bytes = scan.line_bytes + (stop - position)
    if scan.line_bytes > LIMITS.line_bytes then
      return LONG_LINE
    end
    if not newline then
      return nil
    end
    scan.lines = scan.lines + 1
    scan.line_bytes = 0
    if scan.lines > LIMITS.lines then
      return MANY_LINES
    end
    position = newline + 1
  end
end

local function line_total(scan)
  return scan.lines + (scan.line_bytes > 0 and 1 or 0)
end

---Outcome of a read that reached EOF after `offset` bytes.
local function end_of_file(scan, chunks, offset, admitted_size, done)
  if offset < admitted_size then
    -- Never present a mix of two versions as the disk text.
    return done("changed", nil, "the file shrank while it was read")
  end
  if line_total(scan) > LIMITS.lines then
    return done("oversized", nil, MANY_LINES)
  end
  done("available", table.concat(chunks))
end

---Read `fd` in bounded chunks, enforcing the limits while streaming.
---`done(outcome, text, detail)` runs once, from a libuv callback;
---outcome is "available", "oversized", "unreadable", or "changed" (a
---concurrent write; the caller reads again).
local function stream(fd, admitted_size, done)
  local chunks, offset = {}, 0
  local scan = { lines = 0, line_bytes = 0 }
  local function read_next()
    -- Ask for one byte past the admission to notice growth.
    local want = math.min(LIMITS.chunk_bytes, admitted_size - offset + 1)
    uv.fs_read(fd, want, offset, function(err, data)
      if err then
        return done("unreadable", nil, "read failed: " .. err)
      end
      if data == nil or data == "" then
        return end_of_file(scan, chunks, offset, admitted_size, done)
      end
      offset = offset + #data
      if offset > admitted_size then
        -- Admission decides on the new size when the read restarts.
        return done("changed", nil, "the file grew while it was read")
      end
      local problem = scan_chunk(scan, data)
      if problem then
        return done("oversized", nil, problem)
      end
      table.insert(chunks, data)
      read_next()
    end)
  end
  read_next()
end

local function close_and(fd, callback)
  return function(...)
    local args = { ... }
    uv.fs_close(fd, function()
      callback(unpack(args, 1, 3))
    end)
  end
end

local function display_name(record)
  return vim.fn.fnamemodify(record.path, ":~:.")
end

---Tell the user which fallbacks remain without a complete snapshot, once
---per conflict: the choices are the same for both states.
local function note_fallbacks(record)
  local fallback = record.snapshot == "oversized"
    or record.snapshot == "over_cap"
  if not fallback or record.noted then
    return
  end
  record.noted = true
  note(
    ("%s: no complete disk snapshot (%s); :IaraDiskExcerpt shows part"):format(
      display_name(record),
      record.detail or record.snapshot
    )
      .. " of it, :IaraSaveCopy {path} saves the buffer for an external diff"
  )
end

local start_snapshot

---A writer changed the file during the read: drop the partial read and
---read again shortly, silently, while retries remain.
---@return boolean retried
local function retry_snapshot(record, generation)
  if record.retries >= LIMITS.read_retries then
    return false
  end
  record.retries = record.retries + 1
  release(record)
  vim.defer_fn(function()
    local current = state.conflicts[record.bufnr] == record
      and record.generation == generation
    if current then
      start_snapshot(record)
    end
  end, LIMITS.retry_ms)
  return true
end

---Publish the outcome of a snapshot read on the main loop. Results of a
---read that a newer detection or a resolution replaced are dropped.
local function finish_snapshot(record, generation, outcome, text, detail)
  vim.schedule(function()
    if state.conflicts[record.bufnr] ~= record then
      return release(record)
    end
    if record.generation ~= generation then
      return
    end
    if outcome == "changed" then
      if retry_snapshot(record, generation) then
        return
      end
      outcome = "unreadable"
      detail = "the file kept changing while it was read; check again"
    end
    record.snapshot, record.detail = outcome, detail
    if outcome == "available" then
      record.text = text
    else
      release(record)
    end
    note_fallbacks(record)
    fire("IaraConflictDetected", {
      bufnr = record.bufnr,
      path = record.path,
      snapshot = record.snapshot,
    })
    vim.cmd.redrawstatus({ bang = true })
  end)
end

local function read_admitted(record, generation, fd, stat, finish)
  local current = state.conflicts[record.bufnr] == record
    and record.generation == generation
  if not current then
    -- Never reserve room for a read that a newer one replaced.
    return finish("unreadable")
  end
  record.disk = { size = stat.size, mtime = stat.mtime.sec }
  if stat.type ~= "file" then
    return finish("unreadable", nil, "not a regular file")
  end
  local refused, detail = admit(record, stat.size)
  if refused then
    return finish(refused, nil, detail)
  end
  stream(fd, stat.size, finish)
end

---Start a streamed, bounded read of the record's file.
function start_snapshot(record)
  local generation = record.generation
  local function finish(outcome, text, detail)
    finish_snapshot(record, generation, outcome, text, detail)
  end
  uv.fs_open(record.path, "r", 0, function(open_err, fd)
    if open_err or not fd then
      return finish("unreadable", nil, open_err)
    end
    local finish_closing = close_and(fd, finish)
    uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        return finish_closing("unreadable")
      end
      read_admitted(record, generation, fd, stat, finish_closing)
    end)
  end)
end

-- Conflict state ---------------------------------------------------------

---Create or refresh the conflict of `bufnr` after a disk change. A
---refresh during a burst of writes renews the snapshot silently.
local function record_conflict(bufnr, deleted)
  local record = state.conflicts[bufnr]
  local repeated = record ~= nil and record.deleted == deleted
  if record then
    release(record)
  else
    record = { bufnr = bufnr, reserved = 0 }
    state.conflicts[bufnr] = record
  end
  state.generation = state.generation + 1
  record.generation = state.generation
  record.path = buffer_path(bufnr)
  record.detected_at = uv.now()
  record.disk = nil
  record.detail = nil
  record.retries = 0
  record.deleted = deleted
  record.snapshot = deleted and "unreadable" or "pending"
  local name = display_name(record)
  local message = deleted and " was deleted on disk"
    or " changed on disk while modified"
  if not repeated then
    note(name .. message .. "; the buffer keeps its text")
  end
  if deleted then
    finish_snapshot(record, record.generation, "unreadable")
  else
    start_snapshot(record)
  end
end

local function clear_conflict(bufnr, choice)
  local record = state.conflicts[bufnr]
  if not record then
    return
  end
  state.conflicts[bufnr] = nil
  release(record)
  if choice then
    fire("IaraConflictResolved", {
      bufnr = bufnr,
      path = record.path,
      choice = choice,
    })
  end
  vim.cmd.redrawstatus({ bang = true })
end

---FileChangedShellPost handler. It follows both Neovim's own 'autoread'
---reload (which skips FileChangedShell) and a reload chosen below.
local function on_file_handled(args)
  local bufnr = args.buf
  if state.held[bufnr] then
    return
  end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    clear_conflict(bufnr, "load_disk")
    fire("IaraBufferReloaded", { bufnr = bufnr, path = buffer_path(bufnr) })
  end)
end

---FileChangedShell handler. Installing it suppresses Neovim's native
---warnings and prompts, so every reason gets a deliberate answer here.
local function on_file_changed(args)
  local bufnr = args.buf
  local reason = vim.v.fcs_reason
  vim.v.fcs_choice = ""
  -- FileChangedShellPost may follow within this same check only.
  state.held[bufnr] = true
  vim.schedule(function()
    state.held[bufnr] = nil
  end)
  if reason == "deleted" then
    return record_conflict(bufnr, true)
  end
  if reason == "conflict" or vim.bo[bufnr].modified then
    return record_conflict(bufnr, false)
  end
  if reason == "changed" or reason == "mode" then
    state.held[bufnr] = nil
    vim.v.fcs_choice = "reload"
  end
  -- "time": only the timestamp changed; the content is the same.
end

-- Checks -----------------------------------------------------------------

local function drain()
  local checked = 0
  while #state.queue > 0 and checked < CHECK_BATCH do
    local bufnr = table.remove(state.queue, 1)
    state.queued[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) and is_file_buffer(bufnr) then
      -- Per-buffer checktime runs immediately; the global form may be
      -- postponed when not typed.
      vim.cmd("checktime " .. bufnr)
      checked = checked + 1
    end
  end
  if #state.queue > 0 then
    return vim.schedule(drain)
  end
  state.draining = false
end

local function enqueue(bufnr)
  if state.queued[bufnr] then
    return
  end
  state.queued[bufnr] = true
  table.insert(state.queue, bufnr)
end

---Check now (asynchronous, bounded). Nil checks every loaded file
---buffer. Unmodified buffers reload; modified ones become conflicts.
---@param bufnr integer?
function M.check(bufnr)
  if bufnr ~= nil then
    validate_buffer(bufnr)
    enqueue(bufnr)
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if is_file_buffer(buf) then
        enqueue(buf)
      end
    end
  end
  if not state.draining and #state.queue > 0 then
    state.draining = true
    vim.schedule(drain)
  end
end

-- Queries ----------------------------------------------------------------

---@param bufnr integer
---@return IaraConflict|nil
function M.conflict(bufnr)
  local record = state.conflicts[bufnr]
  return record and public_view(record) or nil
end

---@return IaraConflict[] conflicts Sorted by bufnr.
function M.conflicts()
  local list = {}
  for _, record in pairs(state.conflicts) do
    table.insert(list, public_view(record))
  end
  table.sort(list, function(a, b)
    return a.bufnr < b.bufnr
  end)
  return list
end

---@param bufnr integer? Defaults to the current buffer.
---@return string text "" without a conflict.
function M.statusline(bufnr)
  local record = state.conflicts[resolve_buffer(bufnr)]
  if not record then
    return ""
  end
  if record.deleted then
    return "[disk: deleted]"
  end
  return "[disk: changed]"
end

-- Comparison -------------------------------------------------------------

---Split disk text into buffer lines as Neovim would read them.
---@param text string
---@param bufnr integer The conflicted buffer, for its 'fileformat'.
local function disk_lines(text, bufnr)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" and #lines > 1 then
    table.remove(lines)
  end
  if vim.bo[bufnr].fileformat == "dos" then
    for index, line in ipairs(lines) do
      lines[index] = line:gsub("\r$", "")
    end
  end
  return lines
end

local function release_view_bytes(view)
  local bytes = state.view_bytes[view]
  state.view_bytes[view] = nil
  if bytes then
    state.admitted.bytes = state.admitted.bytes - bytes
  end
end

local function close_view(bufnr)
  local view = state.views[bufnr]
  state.views[bufnr] = nil
  if view and vim.api.nvim_buf_is_valid(view) then
    vim.api.nvim_buf_delete(view, { force = true })
  end
end

---Make `view` a read-only scratch copy that holds `bytes` of the session
---cap until it is wiped, however it is closed.
local function fill_view(view, record, spec)
  local options = vim.bo[view]
  options.buftype = "nofile"
  options.bufhidden = "wipe"
  options.swapfile = false
  vim.api.nvim_buf_set_lines(view, 0, -1, false, spec.lines)
  vim.api.nvim_buf_set_name(view, spec.name)
  options.filetype = vim.bo[record.bufnr].filetype
  options.modifiable = false
  options.readonly = true
  state.view_bytes[view] = spec.bytes
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = GROUP,
    buffer = view,
    once = true,
    callback = function()
      release_view_bytes(view)
    end,
  })
end

---Open a new tab with the buffer beside a read-only view described by
---`spec` ({ lines, name, bytes, diff, label? }). The caller reserved
---`spec.bytes` already.
local function open_view(record, spec)
  vim.cmd("tab split")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, record.bufnr)
  vim.cmd("vertical rightbelow new")
  local view = vim.api.nvim_get_current_buf()
  fill_view(view, record, spec)
  state.views[record.bufnr] = view
  if spec.label then
    vim.wo.winbar = spec.label:gsub("%%", "%%%%")
  end
  if spec.diff then
    vim.cmd.diffthis()
    vim.api.nvim_win_call(source_win, function()
      vim.cmd.diffthis()
    end)
  end
end

local function over_cap_error(what)
  return make_error(
    "over_cap",
    what
      .. " does not fit the 4 MiB session snapshot memory; close a"
      .. " disk view or resolve a conflict first"
  )
end

---Open a read-only diff of the buffer against the disk snapshot. The
---view's copy counts against the session cap until it is closed.
---Error codes: "no_conflict", "snapshot_unavailable", "over_cap".
---@param bufnr integer? Defaults to the current buffer.
---@return boolean ok
---@return IaraError|nil err
function M.compare(bufnr)
  bufnr = resolve_buffer(bufnr)
  local record = state.conflicts[bufnr]
  if not record then
    return false, make_error("no_conflict", "the buffer has no conflict")
  end
  if record.snapshot ~= "available" then
    local message = (
      "no disk snapshot to compare (%s); try"
      .. " :IaraDiskExcerpt or :IaraSaveCopy"
    ):format(record.detail or record.snapshot)
    return false, make_error("snapshot_unavailable", message)
  end
  close_view(bufnr)
  if not reserve_bytes(record.reserved) then
    return false, over_cap_error("the comparison view")
  end
  open_view(record, {
    lines = disk_lines(record.text, bufnr),
    name = "iara-disk://" .. record.path,
    bytes = record.reserved,
    diff = true,
  })
  return true
end

-- Partial excerpts and copies -----------------------------------------

---Cut excerpt bytes at line boundaries where the file continues.
---@param data string Bytes read at offset `first`.
---@param first integer Zero-based offset of `data` in the file.
---@param size integer File size when read.
---@return { text: string, first: integer, cut: boolean }
local function trim_excerpt(data, first, size)
  local text, cut = data, false
  local reaches_end = first + #data >= size
  if first > 0 then
    local newline = text:find("\n", 1, true)
    if newline and newline < #text then
      first, text = first + newline, text:sub(newline + 1)
    else
      cut = true
    end
  end
  if not reaches_end and text:sub(-1) ~= "\n" then
    -- A reversed plain find stays linear, unlike a backtracking pattern.
    local from_end = text:reverse():find("\n", 1, true)
    if from_end then
      text = text:sub(1, #text - from_end + 1)
    else
      cut = true
    end
  end
  return { text = text, first = first, cut = cut, size = size }
end

---Read at most `excerpt_bytes` from an open file; `done(err, excerpt)`.
local function read_excerpt_fd(fd, part, done)
  uv.fs_fstat(fd, function(stat_err, stat)
    if stat_err or not stat or stat.type ~= "file" then
      return uv.fs_close(fd, function()
        done(stat_err or "not a regular file")
      end)
    end
    local first = 0
    if part == "tail" then
      first = math.max(0, stat.size - LIMITS.excerpt_bytes)
    end
    uv.fs_read(fd, LIMITS.excerpt_bytes, first, function(read_err, data)
      uv.fs_close(fd, function()
        if read_err then
          return done(read_err)
        end
        done(nil, trim_excerpt(data or "", first, stat.size))
      end)
    end)
  end)
end

local function read_excerpt(path, part, done)
  uv.fs_open(path, "r", 0, function(open_err, fd)
    if open_err or not fd then
      return done(open_err or "cannot open the file")
    end
    read_excerpt_fd(fd, part, done)
  end)
end

local function excerpt_label(excerpt)
  local label = ("Partial disk excerpt: bytes %d-%d of %d"):format(
    excerpt.first + 1,
    excerpt.first + #excerpt.text,
    excerpt.size
  )
  if excerpt.cut then
    label = label .. ", a line is cut"
  end
  return label .. "; the rest of the file is not shown"
end

---Main loop: show a finished excerpt read, or report why not.
local function show_excerpt(record, generation, err, excerpt)
  local current = state.conflicts[record.bufnr] == record
    and record.generation == generation
  if not current or err then
    state.admitted.bytes = state.admitted.bytes - LIMITS.excerpt_bytes
    if not current then
      return false, make_error("no_conflict", "the conflict changed; retry")
    end
    return false, make_error("disk_unavailable", "cannot read: " .. err)
  end
  close_view(record.bufnr)
  open_view(record, {
    lines = disk_lines(excerpt.text, record.bufnr),
    name = ("iara-disk-excerpt://%s:%d"):format(record.path, excerpt.first),
    bytes = LIMITS.excerpt_bytes,
    label = excerpt_label(excerpt),
  })
  return true
end

---Show an explicitly partial, read-only excerpt (at most 64 KiB, cut at
---line boundaries) of the conflicted file beside the buffer. Works for
---any snapshot state; buffer and disk stay untouched. The read is
---asynchronous; `on_done` reports its outcome.
---Error codes: "no_conflict", "disk_unavailable", "over_cap".
---@param bufnr integer? Defaults to the current buffer.
---@param part "head"|"tail"|nil Start or end of the file; "head".
---@param on_done fun(ok: boolean, err: IaraError|nil)?
---@return boolean started
---@return IaraError|nil err
function M.excerpt(bufnr, part, on_done)
  bufnr = resolve_buffer(bufnr)
  part = part or "head"
  if part ~= "head" and part ~= "tail" then
    error("invalid part: " .. vim.inspect(part), 2)
  end
  local record = state.conflicts[bufnr]
  if not record then
    return false, make_error("no_conflict", "the buffer has no conflict")
  end
  if not reserve_bytes(LIMITS.excerpt_bytes) then
    return false, over_cap_error("a disk excerpt")
  end
  local generation = record.generation
  read_excerpt(record.path, part, function(err, excerpt)
    vim.schedule(function()
      local ok, problem = show_excerpt(record, generation, err, excerpt)
      if on_done then
        on_done(ok, problem)
      end
    end)
  end)
  return true
end

---Create `path` exclusively, so an existing file is never replaced.
local function create_unused(path)
  local fd, message, name = uv.fs_open(path, "wx", tonumber("644", 8))
  if fd then
    uv.fs_close(fd)
    return nil
  end
  if name == "EEXIST" then
    return make_error("path_exists", path .. " already exists")
  end
  local err = make_error("write_failed", "cannot create the copy: " .. message)
  err.uv_error = name
  return err
end

---User-directed save-as: write the buffer text to `path`, which must not
---exist, without renaming the buffer, clearing 'modified', or touching
---the conflicted file. Returns an argv comparing the two externally.
---Error codes: "no_conflict", "invalid_path", "path_exists",
---"write_failed".
---@param bufnr integer? Defaults to the current buffer.
---@param path string Relative paths resolve against the current directory.
---@return boolean ok
---@return IaraError|nil err
---@return string[]|nil diff_argv `diff -u -- DISK COPY`, not run here.
function M.save_copy(bufnr, path)
  bufnr = resolve_buffer(bufnr)
  if type(path) ~= "string" or path == "" then
    error("invalid path: " .. vim.inspect(path), 2)
  end
  local record = state.conflicts[bufnr]
  if not record then
    return false, make_error("no_conflict", "the buffer has no conflict")
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if path == record.path then
    local message = "the copy must go to another path than the file"
    return false, make_error("invalid_path", message)
  end
  local err = create_unused(path)
  if err then
    return false, err
  end
  local command = "silent keepalt noautocmd write! " .. vim.fn.fnameescape(path)
  local ok, problem = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd(command)
  end)
  if not ok then
    local message = ("writing %s failed: %s"):format(path, problem)
    return false, make_error("write_failed", message)
  end
  return true, nil, { "diff", "-u", "--", record.path, path }
end

-- Resolution -------------------------------------------------------------

local function load_disk(bufnr, record)
  if not uv.fs_stat(record.path) then
    local message = "the file no longer exists on disk"
    return false, make_error("disk_unavailable", message)
  end
  -- Clear first so the BufReadPost handler does not resolve it twice.
  clear_conflict(bufnr, nil)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent edit!")
  end)
  fire("IaraConflictResolved", {
    bufnr = bufnr,
    path = record.path,
    choice = "load_disk",
  })
  return true
end

---Explicit user choice: "keep_buffer" clears the conflict and keeps the
---text; "load_disk" reloads from disk. Never called automatically.
---Error codes: "no_conflict", "disk_unavailable".
---@param bufnr integer? Defaults to the current buffer.
---@param choice "keep_buffer"|"load_disk"
---@return boolean ok
---@return IaraError|nil err
function M.resolve(bufnr, choice)
  bufnr = resolve_buffer(bufnr)
  if choice ~= "keep_buffer" and choice ~= "load_disk" then
    error("invalid choice: " .. vim.inspect(choice), 2)
  end
  local record = state.conflicts[bufnr]
  if not record then
    return false, make_error("no_conflict", "the buffer has no conflict")
  end
  close_view(bufnr)
  if choice == "load_disk" then
    return load_disk(bufnr, record)
  end
  clear_conflict(bufnr, "keep_buffer")
  return true
end

-- Setup ------------------------------------------------------------------

local function report(ok, err)
  if not ok and err then
    vim.notify("Iara: " .. err.message, vim.log.levels.ERROR)
  end
end

local function save_copy_command(args)
  local ok, err, argv = M.save_copy(nil, args.args)
  if not ok then
    return report(ok, err)
  end
  local quoted = vim.tbl_map(vim.fn.shellescape, argv)
  vim.notify(
    ("Iara: saved the buffer to %s; compare externally with: %s"):format(
      argv[#argv],
      table.concat(quoted, " ")
    ),
    vim.log.levels.INFO
  )
end

local function create_fallback_commands(command)
  command("IaraDiskExcerpt", function(args)
    local part = args.args ~= "" and args.args or "head"
    if part ~= "head" and part ~= "tail" then
      return report(false, make_error("invalid", "expected head or tail"))
    end
    report(M.excerpt(nil, part, report))
  end, {
    nargs = "?",
    complete = function()
      return { "head", "tail" }
    end,
    desc = "Show a partial excerpt of the file on disk",
  })
  command("IaraSaveCopy", save_copy_command, {
    nargs = 1,
    complete = "file",
    desc = "Save the buffer text to an unused path",
  })
end

local function create_commands()
  local command = vim.api.nvim_create_user_command
  command("IaraCheckDisk", function()
    M.check()
  end, { desc = "Check loaded buffers for external changes" })
  command("IaraCompareDisk", function()
    report(M.compare())
  end, { desc = "Diff the buffer against its disk snapshot" })
  command("IaraKeepBuffer", function()
    report(M.resolve(nil, "keep_buffer"))
  end, { desc = "Keep the buffer text and clear the conflict" })
  command("IaraLoadDisk", function()
    report(M.resolve(nil, "load_disk"))
  end, { desc = "Replace the buffer text with the file on disk" })
  create_fallback_commands(command)
end

---A user write or reload of a conflicted buffer is an explicit choice.
---Writing the text to another file (`:w other`) resolves nothing.
local function on_user_resolution(choice)
  return function(args)
    local record = state.conflicts[args.buf]
    local target = vim.fs.normalize(vim.fn.fnamemodify(args.file, ":p"))
    if record and target == record.path then
      close_view(args.buf)
      clear_conflict(args.buf, choice)
    end
  end
end

local function forget(args)
  close_view(args.buf)
  clear_conflict(args.buf, nil)
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  local autocmd = vim.api.nvim_create_autocmd
  autocmd("FileChangedShell", { group = group, callback = on_file_changed })
  autocmd("FileChangedShellPost", {
    group = group,
    callback = on_file_handled,
  })
  autocmd("FocusGained", {
    group = group,
    callback = function()
      M.check()
    end,
  })
  autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if is_file_buffer(args.buf) then
        M.check(args.buf)
      end
    end,
  })
  autocmd("BufWritePost", {
    group = group,
    callback = on_user_resolution("keep_buffer"),
  })
  autocmd("BufReadPost", {
    group = group,
    callback = on_user_resolution("load_disk"),
  })
  autocmd("BufUnload", { group = group, callback = forget })
end

---Install the FileChangedShell handler, focus-return checks, and
---commands. Idempotent.
---@param config table Composed configuration (unused).
function M.setup(config)
  local _ = config
  if state.initialized then
    return
  end
  state.initialized = true
  create_autocmds()
  create_commands()
end

return M
