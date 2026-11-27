--- Structured data presentation for JSON buffers (task D4): the
--- active-window breadcrumb and the key search picker.
---
--- Breadcrumb: cursor and text events only start a 25 ms timer; when it
--- fires, one target request for the current window's cursor replaces
--- any older one (iara.features.structured.json keeps the latest intent).
--- A published breadcrumb is cached as `{win, buf, row, text}` and drawn
--- by a decoration provider as an ephemeral end-of-line mark in that
--- window only, so redraws consume the cache and do no parsing, and a
--- buffer shown in two windows carries the breadcrumb only where the
--- cursor is. Leaving the window or buffer clears it. A missing parser
--- pauses the buffer until an explicit request; a parse watchdog pauses
--- it until an explicit retry (`json.retry`), and no automatic request
--- is made in between. Turning the breadcrumb off cancels its request.
---
--- Key search: the explicit bounded index (`json.index`) becomes a Snacks
--- picker whose rows keep their targets. The shared picker helpers
--- (`iara.features.picker.open` and `.preview`) jump to and preview the
--- recorded locations; a display path is never parsed back.
local json = require("iara.features.structured.json")
local path = require("iara.features.structured.path")

---Shared picker helper `name`, loaded on first key search or jump: the
---breadcrumb alone does not need them at startup (FU-V12-PERF).
local function picker_module(name)
  return require("iara.features.picker." .. name)
end

local M = {}

M.COALESCE_MS = 25
M.PREFIX = "  → "
M.HIGHLIGHT = "IaraBreadcrumb"
-- ARCH, Structured paths: preview of 20 lines and 8 KiB.
M.PREVIEW_LINES = 20
M.PREVIEW_BYTES = 8 * 1024
-- The target line gets a byte window around the key; the other 19 lines
-- share the rest of the 8 KiB budget.
local TARGET_LINE_BYTES = 2048
local CONTEXT_LINE_BYTES = 300
local CONTEXT_BEFORE = 5

local api = vim.api
local namespace = api.nvim_create_namespace("IaraStructuredBreadcrumb")

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.INFO)
end

-- Breadcrumb ---------------------------------------------------------------

---@class IaraBreadcrumbIntent
---@field win integer
---@field buf integer
---@field row integer
---@field col integer
---@field tick integer

local state = {
  enabled = true,
  generation = 0,
  ---@type uv.uv_timer_t|nil
  timer = nil,
  ---@type { win: integer, buf: integer, row: integer, text: string }|nil
  shown = nil,
  ---@type string|nil Key of the latest requested intent.
  requested = nil,
  ---@type { intent: IaraBreadcrumbIntent, target: table }|nil
  latest = nil,
  ---@type table<integer, string> Paused buffers and why.
  paused = {},
  ---@type { cancel: fun(self) }|nil Handle of the request in flight.
  pending = nil,
}

local function invalidate(shown)
  if not shown or not api.nvim_win_is_valid(shown.win) then
    return
  end
  if api.nvim_win_get_buf(shown.win) ~= shown.buf then
    return
  end
  local range = { shown.row, shown.row + 1 }
  pcall(api.nvim__redraw, { win = shown.win, range = range })
end

local function set_shown(next_shown)
  local previous = state.shown
  state.shown = next_shown
  invalidate(previous)
  invalidate(next_shown)
end

local function hide()
  if state.shown then
    set_shown(nil)
  end
end

---Forget the shown breadcrumb and every pending request.
function M.clear_breadcrumb()
  state.generation = state.generation + 1
  state.requested, state.latest = nil, nil
  hide()
end

local function intent_key(intent)
  local parts = { intent.win, intent.buf, intent.row, intent.col, intent.tick }
  return table.concat(parts, ":")
end

---Cursor intent of the current window, or nil when it shows no JSON.
---@return IaraBreadcrumbIntent|nil
local function current_intent()
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative ~= "" then
    return nil
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].filetype ~= "json" or state.paused[buf] then
    return nil
  end
  local cursor = api.nvim_win_get_cursor(win)
  local tick = api.nvim_buf_get_changedtick(buf)
  return {
    win = win,
    buf = buf,
    row = cursor[1] - 1,
    col = cursor[2],
    tick = tick,
  }
end

local function still_focused(intent)
  return api.nvim_win_is_valid(intent.win)
    and api.nvim_get_current_win() == intent.win
    and api.nvim_win_get_buf(intent.win) == intent.buf
end

local function pause(buf, reason)
  state.paused[buf] = reason
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t")
  local text = "JSON breadcrumb paused in %s: %s"
  vim.notify_once(
    "Iara: " .. text:format(name ~= "" and name or "this buffer", reason),
    vim.log.levels.WARN
  )
end

local request_breadcrumb

local function on_breadcrumb_error(intent, err)
  if err.code == "stale" then
    -- An edit schedules a new request itself; an explicit request that
    -- superseded this one schedules it when done.
    state.requested = nil
    return
  end
  hide()
  if err.code == "watchdog" then
    pause(intent.buf, err.message)
  elseif err.code == "no_parser" then
    pause(intent.buf, err.message .. "; show the path to retry")
  end
end

local function on_target(generation, intent, target, err)
  if generation ~= state.generation or not state.enabled then
    return
  end
  if not still_focused(intent) then
    return
  end
  if err then
    return on_breadcrumb_error(intent, err)
  end
  state.latest = { intent = intent, target = target }
  local text = M.PREFIX .. path.breadcrumb(target)
  local shown = state.shown
  if shown and shown.win == intent.win and shown.row == intent.row then
    if shown.text == text then
      return
    end
  end
  set_shown({
    win = intent.win,
    buf = intent.buf,
    row = intent.row,
    text = text,
  })
end

request_breadcrumb = function()
  if not state.enabled then
    return
  end
  local intent = current_intent()
  if not intent then
    state.requested, state.latest = nil, nil
    return hide()
  end
  local key = intent_key(intent)
  if key == state.requested then
    return
  end
  state.requested = key
  state.generation = state.generation + 1
  local generation = state.generation
  state.pending = json.target_at(
    intent.buf,
    intent.row,
    intent.col,
    function(target, err)
      on_target(generation, intent, target, err)
    end
  )
end

---Request the breadcrumb of the current cursor within 25 ms; calls in
---between coalesce into that one request.
function M.schedule_breadcrumb()
  if not state.enabled then
    return
  end
  state.timer = state.timer or vim.uv.new_timer()
  if state.timer:is_active() then
    return
  end
  state.timer:start(M.COALESCE_MS, 0, vim.schedule_wrap(request_breadcrumb))
end

---Latest breadcrumb target for exactly this buffer text and cursor.
---@return IaraStructuredTarget|nil
function M.cached_target(buf, row, col)
  local latest = state.latest
  if not latest then
    return nil
  end
  local intent = latest.intent
  local same = intent.buf == buf
    and intent.row == row
    and intent.col == col
    and intent.tick == api.nvim_buf_get_changedtick(buf)
  return same and latest.target or nil
end

---Whether the breadcrumb of `buf` is paused (watchdog, missing parser).
---@param buf integer
---@return boolean
function M.breadcrumb_paused(buf)
  return state.paused[buf] ~= nil
end

---Lift a pause caused by the watchdog or a missing parser.
---@param buf integer
function M.resume_breadcrumb(buf)
  if state.paused[buf] then
    state.paused[buf] = nil
    M.schedule_breadcrumb()
  end
end

---@param enabled boolean
function M.set_breadcrumb(enabled)
  state.enabled = enabled
  if enabled then
    state.paused[api.nvim_get_current_buf()] = nil
    return M.schedule_breadcrumb()
  end
  if state.timer then
    state.timer:stop()
  end
  if state.pending then
    state.pending:cancel()
    state.pending = nil
  end
  M.clear_breadcrumb()
end

---@return boolean
function M.breadcrumb_enabled()
  return state.enabled
end

---Shown breadcrumb, for statuslines and tests.
---@return { win: integer, buf: integer, row: integer, text: string }|nil
function M.breadcrumb()
  return state.shown and vim.deepcopy(state.shown) or nil
end

local function draw_line(_, _, buf, row)
  local shown = state.shown
  if not shown or row ~= shown.row then
    return
  end
  api.nvim_buf_set_extmark(buf, namespace, row, 0, {
    virt_text = { { shown.text, M.HIGHLIGHT } },
    virt_text_pos = "eol",
    hl_mode = "combine",
    ephemeral = true,
  })
end

local function on_cursor_event()
  if vim.bo.filetype == "json" or state.shown then
    M.schedule_breadcrumb()
  end
end

local function on_buffer_gone(args)
  state.paused[args.buf] = nil
  if state.shown and state.shown.buf == args.buf then
    M.clear_breadcrumb()
  end
end

local function on_eligibility(args)
  local data = args.data or {}
  if state.shown and state.shown.buf == data.bufnr then
    hide()
  end
  if data.bufnr == api.nvim_get_current_buf() then
    state.requested = nil
    M.schedule_breadcrumb()
  end
end

local function close_timer()
  if state.timer and not state.timer:is_closing() then
    state.timer:stop()
    state.timer:close()
  end
  state.timer = nil
end

local function create_breadcrumb_autocmds(group)
  local function on(events, callback, pattern)
    api.nvim_create_autocmd(events, {
      group = group,
      pattern = pattern,
      callback = function(args)
        callback(args)
      end,
    })
  end
  local cursor_events =
    { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI" }
  on(cursor_events, on_cursor_event)
  on({ "BufEnter", "WinEnter", "FileType" }, M.schedule_breadcrumb)
  -- Focus changes clear at once; the next window asks for its own path.
  on({ "WinLeave", "BufLeave" }, M.clear_breadcrumb)
  on({ "BufWipeout", "BufUnload" }, on_buffer_gone)
  on("User", on_eligibility, "IaraEligibilityChanged")
  on("VimLeavePre", close_timer)
end

---Install the breadcrumb's decoration provider and autocmds in `group`.
---@param group integer Owner augroup.
---@param enabled boolean Initial breadcrumb state.
function M.setup(group, enabled)
  state.enabled = enabled
  api.nvim_set_decoration_provider(namespace, {
    on_win = function(_, win, buf)
      local shown = state.shown
      return shown ~= nil and shown.win == win and shown.buf == buf
    end,
    on_line = draw_line,
  })
  create_breadcrumb_autocmds(group)
  if enabled then
    M.schedule_breadcrumb()
  end
end

-- Jump ---------------------------------------------------------------------

local function recorded_range(target)
  return target.key_range or target.value_range
end

local function jump_refusal(target)
  if not api.nvim_buf_is_valid(target.bufnr) then
    return "the buffer of this location is gone"
  end
  if api.nvim_buf_get_changedtick(target.bufnr) ~= target.changedtick then
    return "the buffer changed after this location was recorded; search again"
  end
  if not recorded_range(target) then
    return "this entry has no recorded location"
  end
end

---Jump to a target's recorded key (or value) start, after an optional
---window command. Refused, with a notice, when the buffer changed since
---the target was recorded. Never parses a display path.
---@param target IaraStructuredTarget
---@param command string? "split", "vsplit", or "tabnew".
---@return boolean jumped
function M.jump(target, command)
  local refusal = jump_refusal(target)
  if refusal then
    notify("cannot jump: " .. refusal, vim.log.levels.WARN)
    return false
  end
  local range = recorded_range(target)
  picker_module("open").jump(
    { bufnr = target.bufnr, row = range[1], col = range[2] },
    command
  )
  return true
end

-- Key search picker --------------------------------------------------------

---@type table|nil Open key search picker, closed by the next one.
local active = nil

---One-based `line:column` (byte column) of a target's recorded start.
---@param target IaraStructuredTarget
---@return string
function M.location_label(target)
  local range = recorded_range(target)
  return ("%d:%d"):format(range[1] + 1, range[2] + 1)
end

local function row_item(target)
  return { text = path.breadcrumb(target), iara = target }
end

local function format_row(item)
  local target = item.iara
  local chunks = {
    { item.text, "Normal" },
    { "  " .. M.location_label(target), "LineNr" },
  }
  if target.certainty.unique == "no" then
    table.insert(chunks, { "  duplicate key", "DiagnosticWarn" })
  elseif target.certainty.unique == "unverified" then
    table.insert(chunks, { "  uniqueness unverified", "DiagnosticWarn" })
  end
  return chunks
end

---Byte-bounded copy of `line` from zero-based `from`, never splitting a
---UTF-8 character at either end.
local function cut(line, from, max_bytes)
  if #line <= max_bytes and from == 0 then
    return line, 0
  end
  local start = from + 1
  start = start + vim.str_utf_start(line, start)
  local stop = math.min(start + max_bytes - 1, #line)
  if stop < #line then
    stop = stop + vim.str_utf_start(line, stop + 1) - 1
  end
  return line:sub(start, stop), start - 1
end

---Preview of a target from the current buffer text: at most 20 lines
---and 8 KiB, the key marked; a huge target line shows a byte window
---around the key.
---@param target IaraStructuredTarget
---@return IaraPreviewTarget
function M.preview_target(target)
  local range = recorded_range(target)
  local first = math.max(range[1] - CONTEXT_BEFORE, 0)
  local last = first + M.PREVIEW_LINES
  local lines = api.nvim_buf_get_lines(target.bufnr, first, last, false)
  local row = range[1] - first
  for index, line in ipairs(lines) do
    if index ~= row + 1 then
      lines[index] = cut(line, 0, CONTEXT_LINE_BYTES)
    end
  end
  local from = math.max(range[2] - TARGET_LINE_BYTES / 4, 0)
  local shown, offset = cut(lines[row + 1] or "", from, TARGET_LINE_BYTES)
  lines[row + 1] = shown
  local stop = range[3] == range[1] and range[4] or #shown + offset
  return {
    lines = lines,
    filetype = "json",
    row = row,
    byte_start = range[2] - offset,
    byte_end = math.min(stop - offset, #shown),
  }
end

local function preview_row(state_, ctx)
  local item = ctx.item
  if not item or not item.iara then
    return state_.previewer:clear(ctx.preview)
  end
  local target = item.iara
  local refusal = jump_refusal(target)
  if refusal then
    return state_.previewer:show(ctx.preview, { lines = { refusal } })
  end
  ctx.preview:set_title(M.location_label(target))
  state_.previewer:show(ctx.preview, M.preview_target(target))
end

local function picker_title(bufnr, result)
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
  local title = ("JSON keys: %s (%d)"):format(
    name ~= "" and name or "[No Name]",
    #result.targets
  )
  if result.state == "partial" then
    title = title .. " | partial index: uniqueness unverified"
  end
  return title
end

local function open_current(picker, command)
  local item = picker:current({ resolve = false })
  if not item or not item.iara then
    return
  end
  picker:norm(function()
    picker:close()
    M.jump(item.iara, command)
  end)
end

local function actions(modal)
  local function open_with(command)
    return function(picker)
      open_current(picker, command)
    end
  end
  return vim.tbl_extend("force", modal:actions(), {
    confirm = open_with(nil),
    edit_split = open_with("split"),
    edit_vsplit = open_with("vsplit"),
    tab = open_with("tabnew"),
  })
end

---Keys of the input or list window: the Normal mode keys of the picker
---modes, without Snacks keys that act on item files, history, or a live
---query, which these rows do not have.
---@param window "input"|"list"
local function keys(window)
  local removed = { "<c-q>", "<S-CR>", "<a-h>", "<a-i>", "<a-f>", "<c-g>" }
  local result = picker_module("modal").keys(window)
  for _, lhs in ipairs(removed) do
    result[lhs] = false
  end
  return result
end

local INSERT_HINTS = {
  { "⏎", "open" },
  { "C-v", "vsplit" },
  { "C-s", "split" },
  { "Esc", "normal" },
}

local function hints()
  return {
    insert = INSERT_HINTS,
    normal = picker_module("modal").normal_hints({
      { "v", "vsplit" },
      { "s", "split" },
      { "p", "preview" },
    }),
  }
end

local function load_snacks()
  local ok, snacks = pcall(require, "snacks")
  if ok and type(snacks) == "table" and snacks.picker then
    return snacks
  end
end

local function picker_options(picker_state, bufnr, result)
  local items = vim.tbl_map(row_item, result.targets)
  return {
    title = picker_title(bufnr, result),
    finder = function()
      return items
    end,
    format = format_row,
    preview = function(ctx)
      preview_row(picker_state, ctx)
    end,
    prompt = " ❯ ",
    layout = { preview = true, layout = picker_module("layout").layout() },
    actions = actions(picker_state.modal),
    win = { input = { keys = keys("input") }, list = { keys = keys("list") } },
    on_close = function()
      picker_state.previewer:close()
      if active == picker_state.picker then
        active = nil
      end
    end,
  }
end

---Present a finished key index of `bufnr` in a Snacks picker.
---@param bufnr integer
---@param result { state: string, targets: IaraStructuredTarget[] }
---@return table|nil picker Nil when Snacks is missing.
function M.open_key_search(bufnr, result)
  local snacks = load_snacks()
  if not snacks then
    notify(
      "key search needs snacks.nvim, which is not installed",
      vim.log.levels.ERROR
    )
    return nil
  end
  local reopened = active ~= nil
  if active then
    active:close()
  end
  local modal = picker_module("modal")
  modal.define_highlights()
  local picker_state = { previewer = picker_module("preview").new() }
  picker_state.modal = modal.new()
  picker_state.picker =
    snacks.picker.pick(picker_options(picker_state, bufnr, result))
  active = picker_state.picker
  picker_state.modal:decorate(active, hints())
  picker_state.modal:attach(active, reopened)
  return active
end

return M
