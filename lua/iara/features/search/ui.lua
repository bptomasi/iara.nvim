--- Search UI: Snacks Picker as presentation only, fed by session
--- snapshots. See contracts.md, sections 9.5 and 9.8.
---
--- The picker runs in live mode with an empty matcher pattern, so Snacks
--- never filters or sorts: its finder returns the rows built from the
--- latest snapshot by `iara.features.search.view`. The query is read
--- verbatim from the input buffer (Snacks trims its own copy) and sent
--- to the session. Notice and placeholder rows are skipped by every
--- movement, selection, and open action, and so are file group headers.
---
--- One picker shows one step of a chain (`iara.features.search.chain`):
--- `Ctrl-g` hands the current files to the next step, `Ctrl-o` (or
--- `Backspace` on an empty prompt) goes back. The title shows the step
--- or the breadcrumb and the switches that are not at their defaults;
--- the prompt shows a spinner and the result count; the footer shows key
--- hints. Snacks redraws its titles and prompt status on its own events,
--- so this picker replaces its `update_titles` and `input.update` with
--- versions that draw Iara's.
---
--- Vim-style modes and the symmetric layout come from
--- `iara.features.picker.modal` and `.layout` (UX4): `Esc` turns the
--- prompt to Normal mode, whose keys move over selectable rows only.
---
--- Opening and previewing records use the shared picker helpers
--- (`iara.features.picker.open` and `.preview`); previews show saved disk
--- content, as the search does.
local chain = require("iara.features.search.chain")
local dir_step = require("iara.features.search.dir_step")
local picker_layout = require("iara.features.picker.layout")
local picker_modal = require("iara.features.picker.modal")
local picker_open = require("iara.features.picker.open")
local picker_preview = require("iara.features.picker.preview")
local view = require("iara.features.search.view")

local M = {}

local CASE_ORDER = { smart = "sensitive", sensitive = "insensitive" }
local SPINNER_MS = 80
local PREVIEW_PLACEHOLDER = "Nothing selected"

local status_ns = vim.api.nvim_create_namespace("iara.search.status")

---Selection intent and chain of the last closed picker, restored when a
---picker opens on the same root and request (resume).
local last_intent = nil
---@type table|nil Picker of the live search, closed by the next open.
local active = nil

-- Opening and preview ---------------------------------------------------

---Rows the cursor may rest on: records, and directories in the
---directory step (S9).
local function selectable(row)
  return view.is_selectable(row) or dir_step.is_selectable(row)
end

local function absolute(record)
  local root = record.root == "/" and "" or record.root
  return root .. "/" .. record.path
end

---Picker location of a record: occurrences at their line and disk byte
---column, file names without an invented location.
---@param record IaraSearchRecord
---@return IaraPickerLocation
local function location(record)
  if record.kind ~= "occurrence" then
    return { path = absolute(record) }
  end
  return {
    path = absolute(record),
    row = record.row,
    col = record.byte_start,
    disk_bytes = true,
  }
end

---A subtle placeholder instead of an empty buffer with a line number.
local function preview_placeholder(state, preview)
  state.previewer:clear(preview)
  preview:minimal()
  preview:set_lines({ "", "  " .. PREVIEW_PLACEHOLDER })
  local buf = preview.win.buf
  pcall(vim.api.nvim_buf_set_extmark, buf, preview:ns(), 1, 0, {
    end_col = #PREVIEW_PLACEHOLDER + 2,
    hl_group = "IaraSearchPlaceholder",
  })
end

---A directory row previews its file count and subdirectories; a file
---row of the tree (S10) previews the file.
local function preview_dir(state, ctx)
  local data = ctx.item.iara
  if data.kind == "entry" then
    state.previewed = { path = data.path }
    ctx.preview:set_title(view.display_path(data.path))
    local path = vim.fs.joinpath(state.dir.root, data.path)
    return state.previewer:show(ctx.preview, { path = path })
  end
  state.previewed = nil
  local lines = state.dir:preview(data)
  if not lines then
    return preview_placeholder(state, ctx.preview)
  end
  ctx.preview:set_title("")
  state.previewer:show(ctx.preview, { lines = lines, filetype = "" })
end

local function preview_row(state, ctx)
  local row = ctx.item
  if state.dir and dir_step.is_selectable(row) then
    return preview_dir(state, ctx)
  end
  if not view.is_selectable(row) then
    state.previewed = nil
    return preview_placeholder(state, ctx.preview)
  end
  local record = row.iara
  state.previewed = record
  ctx.preview:set_title(view.display_path(record.path))
  local target = location(record)
  target.byte_start, target.byte_end = record.byte_start, record.byte_end
  state.previewer:show(ctx.preview, target)
end

-- Title, footer, and prompt status --------------------------------------

local function preview_title(state, focused, force)
  local picker = state.picker
  local preview = picker.preview and picker.preview.win
  if not preview or not preview:valid() then
    return
  end
  local record = state.previewed
  local width = vim.api.nvim_win_get_width(preview.win)
  local key = { preview.win, width, focused }
  if record then
    key.path, key.row, key.kind = record.path, record.row, record.kind
  end
  local cached = state.preview_title
  local changed = not cached or not vim.deep_equal(cached.key, key)
  if changed then
    local chunks = record and view.preview_title(record, width, focused) or {}
    cached = { key = key, chunks = chunks }
    state.preview_title = cached
  end
  if changed or force then
    picker_layout.set_preview_title(picker, cached.chunks)
  end
end

local function title_key(state, focused)
  local request = state.snapshot.request
  local input = state.picker.input.win
  local key = { win = input.win, mode = request.mode, focused = focused }
  if state.dir then
    key.directory = state.dir.from
    return key
  end
  key.step = tostring(chain.current(state.chain))
  key.query = #state.chain.steps > 1 and request.query or nil
  key.glob = request.glob
  key.hidden, key.ignored = request.hidden, request.ignored
  key.regex = request.mode ~= "files" and request.regex or nil
  key.case = request.case
  key.scope, key.path = request.scope.kind, request.scope.path
  return key
end

local function result_title(state, focused, force)
  local key = title_key(state, focused)
  local cached = state.result_title
  local changed = not cached or not vim.deep_equal(cached.key, key)
  if changed then
    local request = state.snapshot.request
    local chunks
    if state.dir then
      chunks = state.dir:title(view.search_title(request), focused)
    else
      local labels = chain.crumbs(state.chain, request.query)
      chunks = view.title(labels, request, state.snapshot.root.path, focused)
    end
    cached = { key = key, chunks = chunks }
    state.result_title = cached
  end
  if changed or force then
    picker_layout.set_title(state.picker, cached.chunks)
  end
end

local function draw_frame(state, force)
  local picker = state.picker
  local width = picker and picker_layout.results_width(picker)
  if not width then
    return
  end
  local on_preview = picker_layout.preview_focused(picker)
  result_title(state, not on_preview, force)
  preview_title(state, on_preview, force)
  local depth, normal = #state.chain.steps, state.modal.normal
  local mode = state.snapshot.request.mode
  local footer = state.dir and dir_step.footer(normal, width)
    or view.footer(mode, depth, width, normal)
  picker_layout.set_footer(picker, footer)
end

local function draw_status(state)
  local input = state.picker and state.picker.input
  if not input or not input.win:valid() then
    return
  end
  picker_modal.draw_prompt(input, state.modal.normal)
  local chunks = state.dir and state.dir:status(vim.uv.now())
    or view.status(state.snapshot, vim.uv.now())
  local selected = state.dir and 0 or #state.picker.list.selected
  if selected > 0 then
    table.insert(chunks, 1, { selected .. " selected · ", "IaraSearchCount" })
  end
  if state.modal.normal then
    table.insert(chunks, 1, { picker_modal.CHIP, "IaraSearchModeChip" })
    table.insert(chunks, 2, { " ", "IaraSearchCount" })
  end
  vim.api.nvim_buf_set_extmark(input.win.buf, status_ns, 0, 0, {
    id = 1,
    virt_text = chunks,
    virt_text_pos = "right_align",
  })
end

---Animate the spinner while a shown lane loads.
local function update_spinner(state)
  local busy = state.dir and state.dir:busy() or view.is_busy(state.snapshot)
  busy = busy and not state.closed
  if busy and not state.spinner then
    state.spinner = assert(vim.uv.new_timer())
    state.spinner:start(
      SPINNER_MS,
      SPINNER_MS,
      vim.schedule_wrap(function()
        draw_status(state)
      end)
    )
  elseif not busy and state.spinner then
    state.spinner:stop()
    state.spinner:close()
    state.spinner = nil
  end
end

---Route Snacks' own redraws of the titles and prompt status to Iara's,
---and drop the item count Snacks already drew.
local function own_decorations(state, picker)
  local update_titles = picker.update_titles
  picker.update_titles = function(self)
    update_titles(self)
    draw_frame(state, true)
  end
  picker.input.update = function()
    draw_status(state)
  end
  local snacks_ns = vim.api.nvim_create_namespace("snacks.picker.input")
  vim.api.nvim_buf_clear_namespace(picker.input.win.buf, snacks_ns, 0, -1)
end

-- Cursor and selection --------------------------------------------------

local function first_selectable(state)
  for index, row in ipairs(state.rows) do
    if selectable(row) then
      return index
    end
  end
end

local function index_of(state, id)
  for index, row in ipairs(state.rows) do
    if id and row.text == id and selectable(row) then
      return index
    end
  end
end

---Keep the cursor on the record the user chose; otherwise place it on
---the first record.
local function restore_cursor(state)
  local index = index_of(state, state.cursor_id)
  if not index then
    index = first_selectable(state)
    state.placed_id = index and state.rows[index].text
  end
  if index and state.picker.list.cursor ~= index then
    state.picker.list:view(index)
  end
end

local function apply_pending_selection(state)
  local pending = state.pending_selection
  if not pending or next(pending) == nil then
    return
  end
  local selected = vim.list_slice(state.picker.list.selected)
  for _, row in ipairs(state.rows) do
    if pending[row.text] and view.is_selectable(row) then
      pending[row.text] = nil
      table.insert(selected, row)
    end
  end
  state.picker.list:set_selected(selected)
end

---Selected records, or the current one when nothing is selected.
local function chosen_records(picker)
  local records = {}
  for _, row in ipairs(picker:selected({ fallback = true })) do
    if view.is_selectable(row) then
      table.insert(records, row.iara)
    end
  end
  return records
end

---Snacks puts the cursor on the first row whenever it renders new rows
---itself (after the prompt changed): move it to the chosen record, or
---the first one, when it lands on a notice or a file header.
local function settle_cursor(state, picker, row)
  if state.closed or selectable(row) then
    return
  end
  local list, first = picker.list, nil
  for index = 1, list:count() do
    local candidate = list:get(index)
    if selectable(candidate) then
      if candidate.text == state.cursor_id then
        return list:view(index)
      end
      first = first or index
    end
  end
  if first then
    state.placed_id = list:get(first).text
    list:view(first)
  end
end

---Another record under the cursor ends the UI's placement, so a later
---return to the placed record is a choice that survives updates. Every
---cursor move renders the list; `on_change` is not enough because Snacks
---throttles it and can miss a move away and back. While a target is
---pending the cursor is not where it was sent, so it proves nothing.
local function track_moves(state, picker)
  local list = picker.list
  local render = list.render
  list.render = function(self)
    render(self)
    local current = self:current()
    if self.target or not selectable(current) then
      return
    end
    if current.text ~= state.placed_id then
      state.placed_id = nil
    end
  end
end

-- Refresh ---------------------------------------------------------------

---The notice row: a refused chain step, then the lanes' errors and
---truncation, then the limit disclosed when this step was handed in.
local function current_notice(state, snapshot)
  local refusal = state.refusal
  if refusal and refusal.generation == snapshot.generation then
    return { text = refusal.text, level = "notice" }
  end
  local notice = view.notice(snapshot)
  if notice then
    return notice
  end
  local handed = chain.current(state.chain).notice
  return handed and { text = handed, level = "notice" } or nil
end

---What the picker shows for `rows`: a snapshot with the same key needs
---no new find and render.
local function display_key(rows_list, snapshot)
  local parts = { tostring(snapshot.generation) }
  for index, row in ipairs(rows_list) do
    local data = row.iara
    parts[index + 1] = data.notice and data.notice.text or data.text or row.text
  end
  return table.concat(parts, "\0")
end

---Show `rows`, the cursor on `cursor_id` or the first selectable row.
local function render_rows(state, rows, cursor_id)
  state.rows, state.cursor_id, state.display_key = rows, cursor_id, nil
  state.picker:find({
    on_done = function()
      if not state.closed then
        restore_cursor(state)
      end
    end,
  })
end

local function refresh(state, snapshot)
  if state.closed then
    return
  end
  state.snapshot = snapshot
  update_spinner(state)
  draw_status(state)
  draw_frame(state)
  if state.dir then
    return
  end
  local next_rows = view.rows(snapshot, current_notice(state, snapshot))
  local key = display_key(next_rows, snapshot)
  if key == state.display_key then
    return
  end
  state.display_key = key
  local current = state.picker:current({ resolve = false })
  -- A row the UI placed is not a user choice: it follows the results.
  if view.is_selectable(current) and current.text ~= state.placed_id then
    state.cursor_id = current.text
  end
  state.rows = next_rows
  state.picker:find({
    on_done = function()
      if not state.closed then
        restore_cursor(state)
        apply_pending_selection(state)
      end
    end,
  })
end

local function remember_intent(state)
  local current = state.picker:current({ resolve = false })
  local selected = {}
  for _, row in ipairs(state.picker.list.selected) do
    if view.is_selectable(row) then
      selected[row.text] = true
    end
  end
  local snapshot = state.session:snapshot()
  last_intent = {
    root = snapshot.root.path,
    request = snapshot.request,
    chain = vim.deepcopy(state.chain),
    cursor_id = view.is_selectable(current) and current.text or state.cursor_id,
    selected = selected,
  }
end

---Restore the chain, cursor, and selection of the last closed picker
---when it showed the same root and request.
local function restore_intent(state, snapshot)
  local intent = last_intent
  state.chain = chain.new(snapshot.request)
  if not intent or intent.root ~= snapshot.root.path then
    return
  end
  if not vim.deep_equal(intent.request, snapshot.request) then
    return
  end
  state.chain = vim.deepcopy(intent.chain)
  state.cursor_id = intent.cursor_id
  state.pending_selection = vim.deepcopy(intent.selected)
end

-- Controls --------------------------------------------------------------

local function update(state, changes)
  state.session:update(changes)
end

---Directory and file scopes come from the buffer the search started in.
local function next_scope(state)
  local kind = state.session:snapshot().request.scope.kind
  local file = state.invoking_file
  if not file or kind == "file" then
    return { kind = "root" }
  end
  if kind == "root" then
    return { kind = "directory", path = vim.fs.dirname(file) }
  end
  return { kind = "file", path = file }
end

local function cycle_scope(state)
  update(state, { scope = next_scope(state) })
end

---Show `query` in the prompt without sending it again.
local function set_query(state, query)
  if state.picker.input:get() ~= query then
    state.picker.input:set(nil, query)
  end
end

---Edit the path glob in a separate prompt. A typed query (such as
---`*.lua`) is offered as the glob and cleared once it becomes one.
local function edit_glob(state, picker)
  local request = state.session:snapshot().request
  local from_query = request.query ~= ""
  local default = from_query and request.query or request.glob or ""
  vim.ui.input(
    { prompt = "Path glob (empty clears): ", default = default },
    function(value)
      if value ~= nil and not state.closed then
        local changes = { glob = value }
        if from_query then
          changes.query = ""
        end
        update(state, changes)
        set_query(state, state.session:snapshot().request.query)
      end
      if not state.closed then
        picker:focus("input")
      end
    end
  )
end

---Turn the current results into a filter step and open the next one.
local function chain_next(state)
  local snapshot = state.session:snapshot()
  local hand_off, refusal = chain.hand_off(snapshot)
  if not hand_off then
    state.refusal = { text = refusal, generation = snapshot.generation }
    state.display_key = nil
    return refresh(state, snapshot)
  end
  chain.push(state.chain, snapshot.request, hand_off)
  state.cursor_id, state.refusal = nil, nil
  update(state, chain.changes(hand_off.request))
  set_query(state, hand_off.request.query)
end

---Go back one step, restoring its query, switches, and results.
---@return boolean went_back
local function chain_back(state)
  local request = chain.pop(state.chain)
  if not request then
    return false
  end
  state.cursor_id, state.refusal = nil, nil
  update(state, chain.changes(request))
  set_query(state, request.query)
  return true
end

local function backspace(state)
  local empty = state.picker.input:get() == ""
  if empty and state.dir then
    state.dir:up()
    return
  end
  if empty and chain_back(state) then
    return
  end
  local keys = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

-- Directory step (S9) -----------------------------------------------------

---Scope of a root-relative directory chosen in the directory step.
local function scope_of(state, path)
  if path == "" then
    return { kind = "root" }
  end
  local root = state.session:snapshot().root.path
  return { kind = "directory", path = vim.fs.joinpath(root, path) }
end

---End the directory step: back to the search with its query, scoped to
---`path` (a root-relative directory), to the root (false), or unchanged
---(nil).
local function leave_dir(state, path)
  local step = state.dir
  if not step then
    return
  end
  step:close()
  state.dir = nil
  set_query(state, step.saved_query)
  state.cursor_id, state.refusal, state.display_key = nil, nil, nil
  if path ~= nil then
    update(
      state,
      { scope = path and scope_of(state, path) or { kind = "root" } }
    )
  end
  refresh(state, state.session:snapshot())
end

local function open_dir(state)
  if state.dir then
    -- Keys typed ahead of TextChangedI (`src<A-d>`) count.
    state.dir:on_query(state.picker.input:get())
    return state.dir:search_here()
  end
  local saved_query = state.picker.input:get()
  state.dir = dir_step.new(state.session, {
    render = function(rows, cursor_id)
      render_rows(state, rows, cursor_id)
    end,
    set_prompt = function(text)
      set_query(state, text)
    end,
    redraw = function()
      update_spinner(state)
      draw_status(state)
      draw_frame(state)
    end,
    leave = function(path)
      leave_dir(state, path)
    end,
    open = function(path)
      local picker = state.picker
      picker:norm(function()
        picker:close()
        picker_open.jump({ path = path })
      end)
    end,
  })
  state.dir.saved_query = saved_query
  set_query(state, "")
end

---`Alt-x`: search the whole root again, from the search or the step.
local function clear_scope(state)
  if state.dir then
    return leave_dir(state, false)
  end
  update(state, { scope = { kind = "root" } })
end

---`h` and `-` go up in the directory step and keep their Vim meaning
---in the prompt otherwise.
local function dir_up(state, _, key)
  if state.dir then
    state.dir:up()
    return
  end
  local keys = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

---Quickfix title naming the query and the glob.
---@param state table
---@return string
local function quickfix_title(state)
  local request = state.session:snapshot().request
  local text = ("Iara search: %s"):format(request.query)
  if request.glob then
    text = text .. (" (glob %s)"):format(request.glob)
  end
  return text
end

---Add the files of `records` to the buffer list without showing them.
local function add_buffers(records)
  for _, record in ipairs(records) do
    local buf = vim.fn.bufadd(absolute(record))
    vim.bo[buf].buflisted = true
  end
end

---Open the record under the cursor (in the current window, or with
---`command`); the other selected files become listed buffers. Only
---`Ctrl-q` makes a quickfix list.
local function open_chosen(_, picker, command)
  local records = chosen_records(picker)
  if #records == 0 then
    return
  end
  local current = picker:current({ resolve = false })
  local focus = view.is_selectable(current) and current.iara or records[1]
  -- norm() leaves Insert mode first, so the cursor is not moved after
  -- the jump.
  picker:norm(function()
    picker:close()
    add_buffers(records)
    picker_open.jump(location(focus), command)
  end)
end

---Selected records, or every record shown when nothing is selected.
local function export_quickfix(state, picker)
  local records = chosen_records(picker)
  if #picker.list.selected == 0 then
    records = {}
    for _, row in ipairs(state.rows) do
      if view.is_selectable(row) then
        table.insert(records, row.iara)
      end
    end
  end
  state.session:to_quickfix(records, quickfix_title(state))
  picker:norm(function()
    picker:close()
    vim.cmd("botright copen")
  end)
end

local function toggle(state, _, field)
  local request = state.session:snapshot().request
  update(state, { [field] = not request[field] })
  if state.dir then
    -- The tree follows the switches; the session cached the old one.
    state.dir:load()
  end
end

local function cycle_case(state)
  local case = state.session:snapshot().request.case
  update(state, { case = CASE_ORDER[case] or "smart" })
end

local function select_records(picker)
  local rows = {}
  for _, row in ipairs(picker.list.items) do
    if view.is_selectable(row) then
      table.insert(rows, row)
    end
  end
  local all = #picker.list.selected == #rows
  picker.list:set_selected(all and {} or rows)
end

local function select_and_move(state, picker, delta)
  if view.is_selectable(picker:current({ resolve = false })) then
    picker.list:select()
  end
  state.modal:step(picker, delta)
end

---The directory step's row under the cursor, after it caught up with
---the prompt: keys typed ahead of `TextChangedI` (`src<A-d>`) count,
---and then the best row of the new listing stands for the cursor.
local function dir_current(state, picker)
  local step, text = state.dir, picker.input:get()
  if text == step.query then
    return picker:current({ resolve = false })
  end
  step:on_query(text)
  for _, row in ipairs(step:rows()) do
    if row.iara.kind == "dir" then
      return row
    end
  end
end

local function enter_dir(state, picker)
  if not state.dir then
    return open_chosen(state, picker)
  end
  state.dir:enter(dir_current(state, picker))
end

local function open_oil(state, picker)
  local step = state.dir
  if not step then
    return vim.api.nvim_feedkeys("E", "n", false)
  end
  if vim.fn.exists(":Oil") ~= 2 then
    return step:notify("Oil is unavailable")
  end
  local path = step:oil_directory(dir_current(state, picker))
  picker:norm(function()
    picker:close()
    vim.cmd({ cmd = "Oil", args = { path } })
  end)
end

---`Enter`: a directory of the directory step, or the record.
local function confirm(state, picker, command)
  if not state.dir then
    return open_chosen(state, picker, command)
  end
  if not command then
    state.dir:confirm(dir_current(state, picker))
  end
end

---`Tab` completes a path in the directory step, else selects.
local function tab_key(state, picker, delta)
  if not state.dir then
    return select_and_move(state, picker, delta)
  end
  if delta > 0 then
    return state.dir:complete(dir_current(state, picker))
  end
  state.modal:step(picker, delta)
end

---`Ctrl-o`: leave the directory step unchanged, else go back a step.
local function back(state)
  if state.dir then
    return leave_dir(state, nil)
  end
  chain_back(state)
end

---Snacks actions bound to this search; they replace the Snacks actions
---of the same names, which would act on Snacks' own items and query.
---Search actions (`only`) do nothing in the directory step.
local function actions(state)
  local function bind(fn, arg)
    return function(picker)
      fn(state, picker, arg)
    end
  end
  local function only(fn, ...)
    local bound = bind(fn, ...)
    return function(picker)
      if not state.dir then
        bound(picker)
      end
    end
  end
  return vim.tbl_extend("error", state.modal:actions(), {
    select_and_next = bind(tab_key, 1),
    select_and_prev = bind(tab_key, -1),
    select_all = only(select_records),
    confirm = bind(confirm),
    edit_split = bind(confirm, "split"),
    edit_vsplit = bind(confirm, "vsplit"),
    tab = bind(confirm, "tabnew"),
    qflist = only(export_quickfix),
    iara_chain = only(chain_next),
    iara_back = bind(back),
    iara_backspace = bind(backspace),
    iara_glob = only(edit_glob),
    iara_hidden = bind(toggle, "hidden"),
    iara_ignored = bind(toggle, "ignored"),
    iara_regex = only(toggle, "regex"),
    iara_case = only(cycle_case),
    iara_scope = only(cycle_scope),
    iara_dir = bind(open_dir),
    iara_dir_enter = bind(enter_dir),
    iara_dir_oil = bind(open_oil),
    iara_scope_root = bind(clear_scope),
    iara_dir_up = bind(dir_up, "h"),
    iara_dir_parent = bind(dir_up, "-"),
  })
end

---Keys of the input (`insert`) or list window, with the Normal mode
---keys of `iara.features.picker.modal`. `false` removes Snacks defaults
---that would act on its own query, history, or item files.
local function keys(insert)
  local mode = insert and { "i", "n" } or { "n" }
  local function key(action)
    return { action, mode = mode }
  end
  local result = picker_modal.keys(insert and "input" or "list")
  local own = {
    ["<c-g>"] = key("iara_chain"),
    ["<c-o>"] = key("iara_back"),
    ["<a-g>"] = key("iara_glob"),
    ["<a-h>"] = key("iara_hidden"),
    ["<a-i>"] = key("iara_ignored"),
    ["<a-r>"] = key("iara_regex"),
    ["<a-c>"] = key("iara_case"),
    ["<a-s>"] = key("iara_scope"),
    ["<a-d>"] = key("iara_dir"),
    ["<a-x>"] = key("iara_scope_root"),
    ["<a-f>"] = false,
    ["<S-CR>"] = false,
    ["<C-Up>"] = false,
    ["<C-Down>"] = false,
    ["<c-r>#"] = false,
  }
  result = vim.tbl_extend("force", result, own)
  result.h = { "iara_dir_up", mode = "n" }
  result["-"] = { "iara_dir_parent", mode = "n" }
  result.l = { "iara_dir_enter", mode = "n" }
  result.E = { "iara_dir_oil", mode = "n" }
  if insert then
    result["<bs>"] = { "iara_backspace", mode = { "i" } }
  end
  return result
end

-- Picker ----------------------------------------------------------------

local function on_input(state)
  local input = state.picker.input
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = vim.api.nvim_create_augroup("IaraSearchUi", { clear = true }),
    buffer = input.win.buf,
    callback = function()
      if state.closed then
        return
      end
      if state.dir then
        return state.dir:on_query(input:get())
      end
      update(state, { query = input:get() })
    end,
  })
end

local focus_group = vim.api.nvim_create_augroup("IaraSearchUiFocus", {})

---Redraw the titles and frame colors when the focus moves between the
---panes.
local function follow_focus(state)
  vim.api.nvim_clear_autocmds({ group = focus_group })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = focus_group,
    callback = function()
      if not state.closed then
        draw_frame(state)
      end
    end,
  })
end

local function close_state(state)
  if state.closed then
    return
  end
  if state.dir then
    state.dir:close()
    state.dir = nil
  end
  remember_intent(state)
  state.closed = true
  vim.api.nvim_clear_autocmds({ group = focus_group })
  update_spinner(state)
  state.previewer:close()
  state.session:close()
  if active == state.picker then
    active = nil
  end
  require("iara.features.search.collect").start()
end

---Snacks format of a row: its chunks are resolved at the window width.
local function format_row(row)
  return {
    {
      resolve = function(width)
        if dir_step.is_selectable(row) then
          return dir_step.format(row.iara)
        end
        -- Snacks passes the window width; the bar takes a column.
        return view.format(row, width - picker_layout.BAR_WIDTH)
      end,
    },
  }
end

local function picker_options(state, snapshot)
  return {
    title = "Search",
    prompt = " ❯ ",
    live = true,
    search = snapshot.request.query,
    show_empty = true,
    matcher = { sort_empty = false },
    finder = function()
      return state.rows
    end,
    format = format_row,
    preview = function(ctx)
      preview_row(state, ctx)
    end,
    on_change = function(picker, row)
      settle_cursor(state, picker, row)
    end,
    layout = { preview = true, layout = picker_layout.layout() },
    actions = actions(state),
    win = {
      input = { keys = keys(true) },
      list = { keys = keys(false), wo = picker_layout.list_wo() },
      preview = { wo = { wrap = false } },
    },
    on_close = function()
      close_state(state)
    end,
  }
end

---Create the picker with FileType events ignored. Snacks gives each of
---its windows a filetype, and every FileType event searches
---'runtimepath' for ftplugin, indent, and syntax files that Snacks
---pickers do not have: about 2-3 ms per window on every open (M2-S).
---The filetypes are still set, so Snacks and later events see them.
local function pick_quietly(snacks, opts)
  local saved = vim.o.eventignore
  vim.o.eventignore = saved == "" and "FileType" or saved .. ",FileType"
  local ok, picker = pcall(snacks.picker.pick, opts)
  vim.o.eventignore = saved
  if not ok then
    error(picker, 0)
  end
  return picker
end

local function load_snacks()
  local ok, snacks = pcall(require, "snacks")
  if ok and type(snacks) == "table" and snacks.picker then
    return snacks
  end
end

local function new_state(session, snapshot)
  local name = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or ""
  local state = {
    session = session,
    snapshot = snapshot,
    previewer = picker_preview.new(),
    invoking_file = name ~= "" and vim.fs.normalize(name) or nil,
  }
  state.modal = picker_modal.new({
    selectable = selectable,
    on_mode = function()
      if not state.closed then
        draw_status(state)
        draw_frame(state)
      end
    end,
  })
  restore_intent(state, snapshot)
  state.rows = view.rows(snapshot, current_notice(state, snapshot))
  return state
end

---Present a search session. Takes ownership: closing the picker closes
---the session, and the session's snapshots drive the picker.
---@param session table See iara.features.search.session.new().
---@return table|nil picker Snacks picker, nil when Snacks is missing.
function M.open(session)
  local snacks = load_snacks()
  if not snacks then
    session:close()
    vim.notify(
      "Iara: search needs snacks.nvim, which is not installed",
      vim.log.levels.ERROR
    )
    return nil
  end
  local reopened = active ~= nil
  if active then
    active:close()
  end
  view.define_highlights()
  local snapshot = session:snapshot()
  local state = new_state(session, snapshot)
  state.picker = pick_quietly(snacks, picker_options(state, snapshot))
  active = state.picker
  own_decorations(state, state.picker)
  track_moves(state, state.picker)
  state.modal:attach(state.picker, reopened)
  on_input(state)
  follow_focus(state)
  session:on_change(function(next_snapshot)
    refresh(state, next_snapshot)
  end)
  refresh(state, snapshot)
  return state.picker
end

return M
