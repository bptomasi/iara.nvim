--- The Ask AI popup (tasks AI1, V13): one straight frame split in two,
--- the conversation above (excerpt, questions, streamed answers as
--- Markdown) and the question below. The frame follows the Iara float
--- language: a thin straight border in the focus color (the popup holds
--- the focus while it is open), the title on the top edge
--- with the request state chip at its right end, key hints centered in
--- the bottom edge.
local conversation = require("iara.extras.ai.conversation")
local float = require("iara.core.float")
local ui = require("iara.core.ui")

local M = {}

local api = vim.api

---Excerpt lines shown while the excerpt is collapsed; an excerpt
---collapses when it has more than two lines beyond these.
M.EXCERPT_LINES = 6

M.INPUT_HEIGHT = 3

local SPINNER =
  { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 100

local HINTS = {
  { "⏎", "ask" },
  { "^j", "newline" },
  { "^c", "cancel" },
  { "y", "copy" },
  { "Esc", "close" },
}

local STATES = {
  running = { " answering ", "IaraAskSpinner" },
  failed = { " failed ", "IaraAskError" },
  cancelled = { " cancelled ", "IaraAskMeta" },
}

local ns = api.nvim_create_namespace("IaraAsk")

---@class IaraAiPopup
---@field conversation IaraAiConversation
---@field title string Backend name for the title.
---@field location string File and line range.
---@field excerpt string[] Excerpt lines.
---@field filetype string
---@field notices table[] Messages shown after the turns.
---@field expanded boolean Whole excerpt shown.
---@field buf integer Conversation buffer.
---@field input_buf integer Question buffer.
---@field win integer
---@field input_win integer
---@field closed boolean
---@field on_close fun()?

-- Rendering -------------------------------------------------------------

local function add(lines, marks, text, group)
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, line)
    if group then
      table.insert(marks, { #lines - 1, group })
    end
  end
end

local function excerpt_lines(popup, lines)
  local shown = popup.excerpt
  local hidden = 0
  if not popup.expanded and #shown > M.EXCERPT_LINES + 2 then
    hidden = #shown - M.EXCERPT_LINES
    shown = vim.list_slice(shown, 1, M.EXCERPT_LINES)
  end
  local fence = popup.filetype:match("^[%w_+-]+$") or ""
  table.insert(lines, "```" .. fence)
  vim.list_extend(lines, shown)
  table.insert(lines, "```")
  return hidden
end

local function turn_lines(turn, lines, marks)
  add(lines, marks, "")
  add(lines, marks, "❯ " .. turn.question, "IaraAskQuestion")
  add(lines, marks, "")
  if turn.answer ~= "" then
    add(lines, marks, turn.answer)
  elseif turn.status == "running" then
    -- The line the streamed answer starts on.
    add(lines, marks, "")
  end
  if turn.error then
    add(lines, marks, "")
    add(lines, marks, "✗ " .. turn.error, "IaraAskError")
  elseif turn.status == "cancelled" then
    add(lines, marks, "")
    add(lines, marks, "Cancelled.", "IaraAskMeta")
  end
end

local function draw_marks(popup, marks, hidden)
  api.nvim_buf_clear_namespace(popup.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    api.nvim_buf_set_extmark(popup.buf, ns, mark[1], 0, {
      line_hl_group = mark[2],
    })
  end
  if hidden > 0 then
    local unit = hidden == 1 and "line" or "lines"
    local note = ("⋯ %d more %s  o shows all"):format(hidden, unit)
    api.nvim_buf_set_extmark(popup.buf, ns, M.EXCERPT_LINES + 1, 0, {
      virt_lines = { { { note, "IaraAskMeta" } } },
    })
  end
end

local function set_lines(popup, first, lines)
  vim.bo[popup.buf].modifiable = true
  api.nvim_buf_set_lines(popup.buf, first, -1, false, lines)
  vim.bo[popup.buf].modifiable = false
end

---Keep the newest text in view unless the conversation has focus.
local function follow(popup)
  if api.nvim_get_current_win() == popup.win then
    return
  end
  local last = api.nvim_buf_line_count(popup.buf)
  api.nvim_win_set_cursor(popup.win, { last, 0 })
end

---Draw the whole conversation from its state.
---@param popup IaraAiPopup
function M.render(popup)
  if popup.closed then
    return
  end
  local lines, marks = {}, {}
  local hidden = excerpt_lines(popup, lines)
  for _, turn in ipairs(popup.conversation.turns) do
    turn_lines(turn, lines, marks)
  end
  for _, notice in ipairs(popup.notices) do
    add(lines, marks, "")
    add(lines, marks, notice[1], notice[2])
  end
  set_lines(popup, 0, lines)
  draw_marks(popup, marks, hidden)
  follow(popup)
end

---Append streamed `text` to the end of the conversation, which is the
---answer in flight; only the last line is rewritten.
---@param popup IaraAiPopup
---@param text string
function M.append(popup, text)
  if popup.closed then
    return
  end
  if #popup.notices > 0 then
    -- A notice follows the answer; draw both again in order.
    M.render(popup)
    return
  end
  local last = api.nvim_buf_line_count(popup.buf) - 1
  local tail = api.nvim_buf_get_lines(popup.buf, last, last + 1, true)[1]
  local lines = vim.split(tail .. text, "\n", { plain = true })
  set_lines(popup, last, lines)
  follow(popup)
end

-- Frame -----------------------------------------------------------------

local function even(value)
  return value - value % 2
end

---Positions and sizes of both windows, centered on the editor.
local function geometry()
  local columns, rows = vim.o.columns, vim.o.lines
  local width = even(math.min(math.max(math.floor(columns * 0.6), 60), 100))
  width = math.min(width, columns - 4)
  local total = even(math.min(math.max(math.floor(rows * 0.7), 16), rows - 4))
  local top_height = math.max(total - M.INPUT_HEIGHT - 3, 3)
  local row = math.max(math.floor((rows - total) / 2) - 1, 0)
  local col = math.floor((columns - width - 2) / 2)
  return {
    width = width,
    top = { row = row, col = col, height = top_height },
    input = { row = row + top_height + 2, col = col },
  }
end

---Title chunks: name and location on the left, state chip on the right.
local function title_chunks(popup, width)
  -- The popup holds focus while it is open: the accent title.
  local chunks = float.title("Ask " .. popup.title, true, width)
  table.insert(chunks, { " " .. popup.location .. " ", "IaraAskMeta" })
  local state = STATES[popup.state or ""]
  if not state then
    return chunks
  end
  local text = state[1]
  if popup.state == "running" then
    text = " " .. SPINNER[popup.frame % #SPINNER + 1] .. text
  end
  local used = 0
  for _, chunk in ipairs(chunks) do
    used = used + api.nvim_strwidth(chunk[1])
  end
  local filler = width - used - api.nvim_strwidth(text) - 1
  if filler < 1 then
    return chunks
  end
  table.insert(chunks, float.rule(filler, true))
  table.insert(chunks, { text, state[2] })
  table.insert(chunks, float.rule(1, true))
  return chunks
end

local function draw_title(popup)
  if popup.closed or not api.nvim_win_is_valid(popup.win) then
    return
  end
  local width = api.nvim_win_get_width(popup.win)
  api.nvim_win_set_config(popup.win, {
    title = title_chunks(popup, width),
    title_pos = "left",
  })
end

local function open_windows(popup)
  local size = geometry()
  local base = { relative = "editor", style = "minimal", width = size.width }
  popup.win = api.nvim_open_win(
    popup.buf,
    false,
    vim.tbl_extend("force", base, size.top, {
      border = float.border(ui.TOP, true),
      title = title_chunks(popup, size.width),
      title_pos = "left",
    })
  )
  popup.input_win = api.nvim_open_win(
    popup.input_buf,
    true,
    vim.tbl_extend("force", base, size.input, {
      height = M.INPUT_HEIGHT,
      border = float.border(ui.BOTTOM, true),
      footer = float.footer(HINTS, size.width),
      footer_pos = "center",
    })
  )
end

local function window_options(popup)
  local wo = vim.wo[popup.win]
  wo.wrap, wo.linebreak = true, true
  wo.statuscolumn = " "
  wo.cursorline = false
  local input = vim.wo[popup.input_win]
  input.wrap = true
  -- The prompt glyph on the first line only; one cell of padding.
  input.statuscolumn = "%#IaraAskPrompt# %{v:lnum == 1 && v:virtnum == 0"
    .. " ? '❯' : ' '} %*"
end

local function markdown(buf)
  if not pcall(vim.treesitter.start, buf, "markdown") then
    vim.bo[buf].syntax = "markdown"
  end
end

local function new_buffer(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_name(buf, ("iara-ask://%d/%s"):format(buf, name))
  return buf
end

-- Spinner ---------------------------------------------------------------

local function stop_spinner(popup)
  if popup.timer then
    popup.timer:stop()
    popup.timer:close()
    popup.timer = nil
  end
end

---Show `state` in the title chip; "running" animates the spinner.
---@param popup IaraAiPopup
---@param state "running"|"done"|"failed"|"cancelled"|nil
function M.set_state(popup, state)
  popup.state = state
  stop_spinner(popup)
  if state == "running" and not popup.closed then
    popup.timer = vim.uv.new_timer()
    popup.timer:start(
      SPINNER_MS,
      SPINNER_MS,
      vim.schedule_wrap(function()
        popup.frame = popup.frame + 1
        draw_title(popup)
      end)
    )
  end
  draw_title(popup)
end

-- Actions ---------------------------------------------------------------

---Close both windows, cancel the request, and run `on_close` once.
---@param popup IaraAiPopup
function M.close(popup)
  if popup.closed then
    return
  end
  popup.closed = true
  stop_spinner(popup)
  conversation.cancel(popup.conversation)
  for _, win in ipairs({ popup.input_win, popup.win }) do
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  if popup.on_close then
    popup.on_close()
  end
end

local function notice(popup, text, group)
  table.insert(popup.notices, { text, group })
  M.render(popup)
end

local function on_done(popup, turn)
  if popup.closed then
    return
  end
  M.set_state(popup, turn.status ~= "done" and turn.status or nil)
  M.render(popup)
end

---Send the question typed in the input window.
---@param popup IaraAiPopup
function M.submit(popup)
  local lines = api.nvim_buf_get_lines(popup.input_buf, 0, -1, false)
  local question = vim.trim(table.concat(lines, "\n"))
  if popup.unavailable then
    notice(popup, "✗ " .. popup.unavailable, "IaraAskError")
    return
  end
  local turn, err = conversation.ask(popup.conversation, question, {
    on_text = function(_, text)
      M.append(popup, text)
    end,
    on_done = function(done)
      on_done(popup, done)
    end,
  })
  if not turn then
    notice(popup, "✗ " .. err.message, "IaraAskError")
    return
  end
  popup.notices = {}
  api.nvim_buf_set_lines(popup.input_buf, 0, -1, false, {})
  M.render(popup)
  M.set_state(popup, "running")
end

---The newest answer with text, or nil.
---@param popup IaraAiPopup
---@return string|nil
function M.answer(popup)
  local turns = popup.conversation.turns
  for index = #turns, 1, -1 do
    if turns[index].answer ~= "" then
      return turns[index].answer
    end
  end
  return nil
end

local function copy(popup)
  local answer = M.answer(popup)
  if not answer then
    vim.notify("Iara: no answer to copy yet", vim.log.levels.WARN)
    return
  end
  local register = vim.fn.has("clipboard") == 1 and "+" or '"'
  vim.fn.setreg(register, answer, "v")
  vim.notify(("Iara: answer copied to the %s register"):format(register))
end

local function focus_input(popup)
  api.nvim_set_current_win(popup.input_win)
  vim.cmd.startinsert({ bang = true })
end

local function toggle_window(popup)
  vim.cmd.stopinsert()
  local current = api.nvim_get_current_win()
  local target = current == popup.win and popup.input_win or popup.win
  api.nvim_set_current_win(target)
end

local function cancel_or_leave(popup)
  if not conversation.cancel(popup.conversation) then
    vim.cmd.stopinsert()
  end
end

local function dismiss(popup)
  if vim.fn.mode():find("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  vim.cmd.stopinsert()
  M.close(popup)
end

local function map(buf, modes, lhs, fn, desc)
  vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = desc })
end

local function shared_keys(popup, buf)
  local function bind(fn)
    return function()
      fn(popup)
    end
  end
  map(buf, "n", "q", bind(M.close), "Close the Ask AI popup")
  map(buf, { "n", "i", "x" }, "<Esc>", bind(dismiss), "Close the Ask AI popup")
  map(buf, "n", "y", bind(copy), "Copy the answer")
  map(buf, { "n", "i" }, "<C-c>", bind(cancel_or_leave), "Cancel the answer")
  map(buf, { "n", "i" }, "<Tab>", bind(toggle_window), "Switch popup window")
end

local function set_keys(popup)
  local input, buf = popup.input_buf, popup.buf
  shared_keys(popup, input)
  shared_keys(popup, buf)
  local function submit()
    M.submit(popup)
  end
  map(input, { "n", "i" }, "<CR>", submit, "Ask")
  -- Not recursive: these insert the line break `<CR>` would.
  map(input, "i", "<C-j>", "<CR>", "New line")
  map(input, "i", "<S-CR>", "<CR>", "New line")
  map(buf, "n", "i", function()
    focus_input(popup)
  end, "Edit the question")
  map(buf, "n", "o", function()
    popup.expanded = not popup.expanded
    M.render(popup)
  end, "Show or collapse the excerpt")
end

local function close_with_windows(popup)
  local group = api.nvim_create_augroup("IaraAsk", { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(popup.win), tostring(popup.input_win) },
    callback = function()
      -- Closing a window from WinClosed is not allowed.
      vim.schedule(function()
        M.close(popup)
      end)
      return true
    end,
  })
end

---Open the popup for `fields` and focus the question in Insert mode.
---@param fields table `conversation`, `title`, `location`, `excerpt`,
---  `filetype`, `unavailable` (a message when no CLI can answer),
---  `on_close`.
---@return IaraAiPopup
function M.open(fields)
  local popup = vim.tbl_extend("force", fields, {
    notices = {},
    expanded = false,
    closed = false,
    frame = 0,
  })
  popup.buf = new_buffer("conversation")
  popup.input_buf = new_buffer("question")
  vim.bo[popup.buf].modifiable = false
  markdown(popup.buf)
  open_windows(popup)
  window_options(popup)
  set_keys(popup)
  require("iara.extras.ai.drag").setup(popup)
  close_with_windows(popup)
  M.render(popup)
  if popup.unavailable then
    notice(popup, "✗ " .. popup.unavailable, "IaraAskError")
  end
  vim.cmd.startinsert()
  return popup
end

return M
