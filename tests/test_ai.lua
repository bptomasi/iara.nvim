-- Ask AI popup (AI1). The real `claude` and `codex` are never started:
-- the child's PATH holds only fake executables that record their argv
-- and stdin, then answer as the real CLIs' JSON output does.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil
local embedded = nil

-- Modes (FAKE_MODE): "stream" (default) sends one piece, waits for the
-- file `$FAKE_LOG.go`, then sends the rest; "hang" never answers;
-- "fail" exits 3 with a message on stderr; "auth" reports a missing
-- sign-in; "plain" prints plain text; "empty" exits 0 without an
-- answer, after a warning on stderr. Only absolute paths and shell
-- builtins are used, since PATH holds nothing else.
local FAKE = [[#!/bin/sh
log=$FAKE_LOG
: > "$log.argv"
for arg in "$@"; do printf '[%s]\n' "$arg" >> "$log.argv"; done
/bin/cat > "$log.stdin"
echo $$ > "$log.pid"
delta() {
  printf '{"type":"stream_event","event":{"type":"content_block_delta",'
  printf '"delta":{"type":"text_delta","text":"%s"}}}\n' "$1"
}
case "$FAKE_MODE" in
  hang) exec /bin/sleep 30 ;;
  fail) echo "boom: model unavailable" >&2; exit 3 ;;
  auth)
    printf '{"type":"result","subtype":"success","is_error":true,'
    printf '"result":"Invalid API key. Please run /login"}\n'
    exit 1 ;;
  plain) echo "plain answer"; exit 0 ;;
  long) delta "0123456789012345678901234567890123456789"; exec /bin/sleep 30 ;;
  empty)
    echo "warning: quota low" >&2
    if [ "${0##*/}" = codex ]; then
      printf '{"type":"thread.started","thread_id":"t"}\n'
      printf '{"type":"turn.completed"}\n'
    else
      printf '{"type":"result","subtype":"success","is_error":false,'
      printf '"result":"  "}\n'
    fi
    exit 0 ;;
esac
if [ "${0##*/}" = codex ]; then
  printf '{"type":"thread.started","thread_id":"t"}\n'
  printf '{"type":"item.completed","item":{"id":"i","type":"reasoning",'
  printf '"text":"thinking"}}\n'
  printf '{"type":"item.completed","item":{"id":"j","type":"agent_message",'
  printf '"text":"Codex **answer**"}}\n'
  printf '{"type":"turn.completed"}\n'
  exit 0
fi
delta "Hello "
while [ ! -e "$log.go" ]; do /bin/sleep 0.02; done
delta "**world**\\n\\n- item"
printf '{"type":"result","subtype":"success","is_error":false,'
printf '"result":"Hello **world**"}\n'
]]

---Child-side helpers: collected notifications, a fake clipboard, and
---a project with a `.git` marker.
local CHILD_HELPERS = [[
local fake_bin, log, config = ...
vim.env.PATH = fake_bin
vim.env.FAKE_LOG = log
vim.g.mapleader = " "
_G.messages = {}
vim.notify = function(message) table.insert(_G.messages, message) end
_G.copied = {}
vim.g.clipboard = {
  name = "test",
  copy = { ["+"] = function(lines) _G.copied["+"] = lines end,
    ["*"] = function(lines) _G.copied["*"] = lines end },
  paste = { ["+"] = function() return _G.copied["+"] or {} end,
    ["*"] = function() return {} end },
}
ai = require("iara.extras.ai")
popup_mod = require("iara.extras.ai.popup")
conv_mod = require("iara.extras.ai.conversation")
ctx = require("iara.extras.agents.context")
ai.setup(config)

function _G.edit(dir, lines)
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/sample.lua"))
  vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
end

function _G.conversation_text()
  local popup = ai.current()
  return table.concat(vim.api.nvim_buf_get_lines(popup.buf, 0, -1, false),
    "\n")
end

function _G.wait_text(pattern)
  vim.wait(10000, function()
    return ai.current() ~= nil and conversation_text():find(pattern) ~= nil
  end, 20)
  return ai.current() and conversation_text()
end

function _G.wait_status(index, status)
  vim.wait(10000, function()
    local turn = ai.current().conversation.turns[index]
    return turn ~= nil and turn.status == status
  end, 20)
  return ai.current().conversation.turns[index].status
end

function _G.title()
  local chunks = vim.api.nvim_win_get_config(ai.current().win).title
  return table.concat(vim.tbl_map(function(c) return c[1] end, chunks))
end
]]

local LINES = {
  "local M = {}",
  "function M.add(a, b)",
  "  return a + b",
  "end",
  "return M",
}

local function fake_bin(names)
  local dir = helpers.temp_dir()
  for _, name in ipairs(names or { "claude", "codex" }) do
    helpers.write_file(dir .. "/" .. name, FAKE)
    vim.uv.fs_chmod(dir .. "/" .. name, tonumber("755", 8))
  end
  return dir
end

local function run(code, ...)
  return child.lua(code, { ... })
end

---Start the module in the child; returns the fake log prefix.
local function start(config, names)
  local bin = fake_bin(names)
  local log = helpers.temp_dir() .. "/fake"
  config = config or { extras = { ai = {} }, keymaps = {} }
  child.lua(CHILD_HELPERS, { bin, log, config })
  -- Never reach the real CLIs: both names must resolve to fakes or fail.
  for _, name in ipairs({ "claude", "codex" }) do
    local path = child.fn.exepath(name)
    assert(path == "" or vim.startswith(path, bin), "real CLI on PATH")
  end
  run("edit(...)", helpers.temp_dir(), LINES)
  return log
end

local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function wait_file(path)
  vim.wait(10000, function()
    return read(path) ~= nil and read(path) ~= ""
  end, 20)
  return read(path)
end

local function release(log)
  helpers.write_file(log .. ".go", "")
end

local function argv_of(log)
  local text = wait_file(log .. ".argv")
  local argv = {}
  for item in text:gmatch("%[(.-)%]\n") do
    table.insert(argv, item)
  end
  return argv
end

local CLAUDE_ARGS = {
  "-p",
  "--output-format",
  "stream-json",
  "--verbose",
  "--include-partial-messages",
  "--tools",
  "",
  "--strict-mcp-config",
  "--disable-slash-commands",
  "--no-session-persistence",
}

local CODEX_ARGS = {
  "exec",
  "--sandbox",
  "read-only",
  "-c",
  'approval_policy="never"',
  "--ephemeral",
  "--skip-git-repo-check",
  "--color",
  "never",
  "--json",
  "-",
}

---Select lines 2-3 linewise and ask `question` through the mapping.
local function ask_lines(question, key)
  child.type_keys("2GVj", key or " ai")
  child.type_keys(question, "<CR>")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
    end,
    post_case = function()
      if embedded then
        embedded:stop()
        embedded = nil
      end
      child.stop()
    end,
  },
})

local function embedded_positions()
  return embedded:lua([[
    local top = vim.api.nvim_win_get_config(_G.popup.win)
    local input = vim.api.nvim_win_get_config(_G.popup.input_win)
    return { top.row, top.col, input.row, input.col }
  ]])
end

local function send_mouse(action, row, col)
  embedded:request("nvim_input_mouse", { "left", action, "", 0, row, col })
  vim.wait(50)
end

T["dragging the title moves both panes and keeps focus"] = function()
  embedded = require("ui_child").start(120, 35)
  embedded:lua([[
      vim.o.mouse = "a"
      _G.popup = require("iara.extras.ai.popup").open({
        conversation = { turns = {} },
        title = "Codex",
        location = "sample.lua:2-3",
        excerpt = { "local example = 1" },
        filetype = "lua",
      })
    ]])
  local top, left, input = unpack(embedded_positions())
  send_mouse("press", top, left + 5)
  send_mouse("drag", top + 3, left + 12)
  send_mouse("release", top + 3, left + 12)
  eq(embedded_positions(), { top + 3, left + 7, input + 3, left + 7 })
  eq(
    embedded:lua([[
      return vim.api.nvim_get_current_win() == _G.popup.input_win
        and vim.fn.mode() == "i"
    ]]),
    true
  )
  send_mouse("press", top + 3, left + 12)
  send_mouse("drag", 0, 0)
  send_mouse("release", 0, 0)
  eq(embedded_positions(), { 0, 0, input - top, 0 })
end

T["streams a Claude answer from a read-only one-shot run"] = function()
  local log = start()
  ask_lines("What does it do?", " ac")
  eq(argv_of(log), CLAUDE_ARGS)
  local stdin = wait_file(log .. ".stdin")
  match(stdin, "Do not modify files")
  match(stdin, "Selection: linewise, lines 2%-3%.")
  match(stdin, "```lua\nfunction M%.add%(a, b%)\n  return a %+ b\n```")
  match(stdin, "Question:\nWhat does it do%?\n$")
  -- The first piece shows while the CLI still runs.
  match(run("return wait_text('Hello')"), "❯ What does it do%?\n\nHello $")
  eq(run("return ai.current().conversation.turns[1].status"), "running")
  match(run("return title()"), "answering")
  release(log)
  eq(run("return wait_status(1, 'done')"), "done")
  local text = run("return conversation_text()")
  match(text, "Hello %*%*world%*%*\n\n%- item$")
  eq(run("return title()"):find("answering"), nil)
  eq(
    run("return vim.treesitter.highlighter.active[ai.current().buf] ~= nil"),
    true
  )
end

T["prefers Codex when both CLIs are installed"] = function()
  local log = start()
  ask_lines("Explain")
  -- The fake records its arguments; its name shows it is the codex one.
  eq(argv_of(log), CODEX_ARGS)
  eq(run("return wait_status(1, 'done')"), "done")
  match(run("return conversation_text()"), "Codex %*%*answer%*%*$")
  match(run("return title()"), "Ask Codex")
end

T["the default falls back to Claude when Codex is unavailable"] = function()
  local log = start(nil, { "claude" })
  run("vim.env.FAKE_MODE = 'plain'")
  ask_lines("Explain")
  eq(argv_of(log), CLAUDE_ARGS)
  match(run("return title()"), "Ask Claude")
end

T["the Claude mapping reports a missing Claude even with Codex"] = function()
  local log = start(nil, { "codex" })
  ask_lines("Explain", " ac")
  match(run("return conversation_text()"), "Claude is not installed")
  eq(read(log .. ".argv"), nil)
end

T["uses the configured backend and command prefix"] = function()
  local config = {
    extras = {
      ai = { backend = "codex", argv = { "codex", "-m", "small" } },
    },
    keymaps = {},
  }
  local log = start(config)
  ask_lines("Explain")
  local expected = vim.list_extend({ "-m", "small" }, vim.deepcopy(CODEX_ARGS))
  eq(argv_of(log), expected)
  match(run("return title()"), "Ask Codex")
end

T["refuses a command with an unsafe argument"] = function()
  local cases = {
    { "claude", "--dangerously-skip-permissions" },
    { "claude", "--permission-mode=bypassPermissions" },
    { "codex", "-c", 'sandbox_mode="danger-full-access"' },
    { "codex", "--full-auto" },
  }
  for _, argv in ipairs(cases) do
    local refused = run(
      [[
      local backend = require("iara.extras.ai.backend")
      return backend.unsafe_argument(...)
    ]],
      argv
    )
    eq({ argv, type(refused) }, { argv, "string" })
  end
  local config = {
    extras = { ai = { backend = "claude", argv = { "claude", "--yolo" } } },
    keymaps = {},
  }
  local log = start(config)
  match(run("return table.concat(_G.messages, '\\n')"), "unsafe argument")
  ask_lines("Explain")
  eq(argv_of(log), CLAUDE_ARGS)
end

T["refuses every bypass argument of the agent terminals"] = function()
  start()
  local missing = run([[
    local unsafe = require("iara.extras.ai.backend").unsafe_argument
    local missing = {}
    for _, arg in ipairs(require("iara.extras.agents").BYPASS_ARGUMENTS) do
      if not unsafe({ "claude", arg }) then table.insert(missing, arg) end
    end
    return missing
  ]])
  eq(missing, {})
end

T["reports a command without a backend and ignores it"] = function()
  local config = { extras = { ai = { argv = { "claude" } } }, keymaps = {} }
  start(config)
  match(run("return table.concat(_G.messages, '\\n')"), "argv needs backend")
end

T["Ctrl-c cancels the answer and stops the process"] = function()
  local log = start()
  run("vim.env.FAKE_MODE = 'hang'")
  ask_lines("Explain")
  local pid = tonumber(wait_file(log .. ".pid"))
  eq(vim.uv.kill(pid, 0), 0)
  child.type_keys("<C-c>")
  eq(run("return wait_status(1, 'cancelled')"), "cancelled")
  match(run("return title()"), "cancelled")
  match(run("return conversation_text()"), "Cancelled%.$")
  eq(vim.uv.kill(pid, 0) == 0, false)
  eq(run("return require('iara.core.proc').active_count('iara-ai')"), 0)
end

T["Escape closes the popup and releases the running request"] = function()
  local log = start()
  run("vim.env.FAKE_MODE = 'hang'")
  ask_lines("Explain")
  local pid = tonumber(wait_file(log .. ".pid"))
  child.type_keys("<Esc>")
  vim.wait(5000, function()
    return vim.uv.kill(pid, 0) ~= 0
  end, 20)
  eq(vim.uv.kill(pid, 0) == 0, false)
  eq(run("return ai.current()"), vim.NIL)
  eq(run("return vim.fn.mode()"), "n")
  local floats = run([[
    return #vim.tbl_filter(function(win)
      return vim.api.nvim_win_get_config(win).relative ~= ""
    end, vim.api.nvim_list_wins())
  ]])
  eq(floats, 0)
  -- Four snapshots can be captured again: the popup released its own.
  local captured = run([[
    local count = 0
    for _ = 1, 4 do
      if ctx.capture({ mode = "reference" }) then count = count + 1 end
    end
    return count
  ]])
  eq(captured, 4)
end

T["shows a missing CLI in the popup and starts nothing"] = function()
  start(nil, {})
  ask_lines("Explain")
  local text = run("return wait_text('no AI CLI found')")
  match(text, "✗ no AI CLI found: install Codex")
  eq(run("return #ai.current().conversation.turns"), 0)
end

T["shows a missing configured CLI with its name"] = function()
  start({ extras = { ai = { backend = "codex" } }, keymaps = {} }, {
    "claude",
  })
  ask_lines("Explain")
  match(
    run("return wait_text('not installed')"),
    'Codex is not installed: "codex" was not found on PATH'
  )
end

T["shows a failing CLI's message and exit"] = function()
  start()
  run("vim.env.FAKE_MODE = 'fail'")
  ask_lines("Explain")
  eq(run("return wait_status(1, 'failed')"), "failed")
  match(
    run("return conversation_text()"),
    "✗ Codex failed: boom: model unavailable$"
  )
  match(run("return title()"), "failed")
end

---A run of `backend` that succeeds without answer text is a notice,
---with the CLI's exit status and stderr, not an empty "done" answer.
local function expect_no_answer(backend)
  start(nil, { backend:lower() })
  run("vim.env.FAKE_MODE = 'empty'")
  ask_lines("Explain")
  eq(run("return wait_status(1, 'failed')"), "failed")
  local notice = "✗ No answer received from %s %%(exit status 0%%): "
    .. "warning: quota low$"
  match(run("return conversation_text()"), notice:format(backend))
end

T["says when Claude finishes without an answer"] = function()
  expect_no_answer("Claude")
end

T["says when Codex finishes without an answer"] = function()
  expect_no_answer("Codex")
end

T["explains a missing sign-in"] = function()
  start()
  run("vim.env.FAKE_MODE = 'auth'")
  ask_lines("Explain", " ac")
  eq(run("return wait_status(1, 'failed')"), "failed")
  match(
    run("return conversation_text()"),
    "Claude is not signed in: run `claude` in a terminal and sign in"
  )
end

T["stops an answer at its deadline"] = function()
  start({ extras = { ai = { timeout_ms = 1000 } }, keymaps = {} })
  run("vim.env.FAKE_MODE = 'hang'")
  ask_lines("Explain")
  eq(run("return wait_status(1, 'failed')"), "failed")
  match(run("return conversation_text()"), "exceeded its 1000 ms deadline")
end

T["stops an answer over the answer cap"] = function()
  start()
  run("vim.env.FAKE_MODE = 'long'; conv_mod.LIMITS.answer_bytes = 16")
  ask_lines("Explain", " ac")
  eq(run("return wait_status(1, 'failed')"), "failed")
  match(run("return conversation_text()"), "the answer exceeded 0 KiB")
  eq(run("return require('iara.core.proc').active_count('iara-ai')"), 0)
end

T["refuses a selection over the context caps"] = function()
  start()
  run(
    "vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.fn['repeat']({'x'}, 600))"
  )
  child.type_keys("ggVG", " ai")
  eq(run("return ai.current()"), vim.NIL)
  match(
    run("return table.concat(_G.messages, '\\n')"),
    "cannot ask about this selection: selection has 600 lines"
  )
  eq(run("return vim.fn.mode()"), "n")
end

T["captures charwise and blockwise selections exactly"] = function()
  local log = start()
  run("vim.env.FAKE_MODE = 'plain'")
  child.type_keys("2G0fMvt(", " ai", "Q1<CR>")
  local stdin = wait_file(log .. ".stdin")
  match(stdin, "Selection: charwise, line 2")
  match(stdin, "```lua\nM%.add\n```")
  eq(run("return wait_status(1, 'done')"), "done")
  match(run("return conversation_text()"), "plain answer")
  child.type_keys("<Esc>")
  vim.fn.delete(log .. ".stdin")
  child.type_keys("2G0<C-v>j$", " ai", "Q2<CR>")
  stdin = wait_file(log .. ".stdin")
  match(stdin, "Selection: blockwise, lines 2%-3")
  match(stdin, "```lua\nfunction M%.add%(a, b%)\n  return a %+ b\n```")
  match(run("return title()"), "sample%.lua:2%-3")
end

T["follow-up questions resend the excerpt and earlier turns"] = function()
  local log = start()
  ask_lines("First?", " ac")
  release(log)
  eq(run("return wait_status(1, 'done')"), "done")
  vim.fn.delete(log .. ".stdin")
  child.type_keys("Second?", "<CR>")
  local stdin = wait_file(log .. ".stdin")
  match(stdin, "```lua\nfunction M%.add")
  match(stdin, "Conversation so far:\n\nQuestion:\nFirst%?\n\nYour answer:\n")
  match(stdin, "Hello %*%*world%*%*\n\n%- item\n\nQuestion:\nSecond%?\n$")
  eq(run("return wait_status(2, 'done')"), "done")
  local text = run("return conversation_text()")
  match(text, "❯ First%?.*❯ Second%?")
end

T["refuses a question while one runs and past the turn limit"] = function()
  local log = start()
  run("conv_mod.LIMITS.turns = 1")
  ask_lines("First?", " ac")
  child.type_keys("Again", "<CR>")
  match(run("return wait_text('still running')"), "an answer is still running")
  local question = "local buf = ai.current().input_buf\n"
    .. "return vim.api.nvim_buf_get_lines(buf, 0, 1, true)[1]"
  eq(run(question), "Again")
  release(log)
  eq(run("return wait_status(1, 'done')"), "done")
  child.type_keys("<CR>")
  match(run("return wait_text('at most 1')"), "at most 1 questions per popup")
end

T["draws one straight frame split by the question"] = function()
  start()
  child.o.columns, child.o.lines = 120, 35
  ask_lines("Explain")
  local borders = run([[
    local popup = ai.current()
    return { vim.api.nvim_win_get_config(popup.win).border,
      vim.api.nvim_win_get_config(popup.input_win).border }
  ]])
  -- The popup holds the focus: the whole frame is the focus color.
  local float = require("iara.core.float")
  local ui = require("iara.core.ui")
  eq(borders[1], float.border(ui.TOP, true))
  eq(borders[2], float.border(ui.BOTTOM, true))
  local lines = vim.split(tostring(child.get_screenshot()), "\n")
  local frame = {}
  for _, line in ipairs(lines) do
    for _, edge in ipairs({ "┌", "├", "└", "╭", "╰" }) do
      if line:find(edge, 1, true) then
        table.insert(frame, edge)
      end
    end
  end
  eq(frame, { "┌", "├", "└" })
  local screen = table.concat(lines, "\n")
  match(screen, "┌─ Ask Codex  sample%.lua:2%-3 ")
  match(screen, "⏎ ask · %^j newline · %^c cancel · y copy · Esc close")
  match(screen, "│ ❯ ")
end

T["y copies the answer and o shows the whole excerpt"] = function()
  local log = start()
  run("vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.fn['repeat']({'z'}, 12))")
  child.type_keys("ggVG", " ac", "Explain", "<CR>")
  release(log)
  eq(run("return wait_status(1, 'done')"), "done")
  child.type_keys("<Tab>", "y")
  eq(run("return _G.copied['+']"), { "Hello **world**", "", "- item" })
  local collapsed = run("return conversation_text()")
  eq(select(2, collapsed:gsub("\nz", "")), 6)
  child.type_keys("o")
  eq(select(2, run("return conversation_text()"):gsub("\nz", "")), 12)
  child.type_keys("i")
  eq(
    run("return vim.api.nvim_get_current_win() == ai.current().input_win"),
    true
  )
  eq(run("return vim.fn.mode()"), "i")
end

T["Ctrl-j adds a line to the question instead of sending it"] = function()
  local log = start()
  child.type_keys("2GVj", " ai", "one", "<C-j>", "two", "<CR>")
  match(wait_file(log .. ".stdin"), "Question:\none\ntwo\n$")
end

T[":IaraAsk asks about a range with a question"] = function()
  local log = start()
  run("vim.env.FAKE_MODE = 'plain'")
  child.cmd("3,4IaraAsk why this")
  local stdin = wait_file(log .. ".stdin")
  match(stdin, "Selection: linewise, lines 3%-4%.")
  match(stdin, "Question:\nwhy this\n$")
  match(run("return title()"), "sample%.lua:3%-4")
  eq(argv_of(log), CODEX_ARGS)
end

T["is not set up when disabled and keeps user mappings"] = function()
  start({ extras = { ai = false }, keymaps = {} })
  eq(child.fn.exists(":IaraAsk"), 0)
  eq(child.fn.maparg(" ai", "x"), "")
  eq(child.fn.maparg(" ac", "x"), "")
  child.stop()
  child = helpers.new_child()
  start({
    extras = { ai = {} },
    keymaps = { ["x <leader>ai"] = false, ["x <leader>ac"] = false },
  })
  eq(child.fn.exists(":IaraAsk"), 2)
  eq(child.fn.maparg(" ai", "x"), "")
  eq(child.fn.maparg(" ac", "x"), "")
end

-- Decoders (pure) -----------------------------------------------------------

local backend = require("iara.extras.ai.backend")

local function feed(name, lines)
  local decode = backend.decoder(name)
  local text, errors = {}, {}
  for _, line in ipairs(lines) do
    local event = decode(line)
    table.insert(text, event.text)
    table.insert(errors, event.error)
  end
  return table.concat(text), errors
end

T["Claude decoder uses whole messages when no pieces stream"] = function()
  local text = feed("claude", {
    '{"type":"assistant","message":{"content":[{"type":"text","text":"A"},'
      .. '{"type":"tool_use"},{"type":"text","text":"B"}]}}',
    '{"type":"result","subtype":"success","is_error":false,"result":"AB"}',
  })
  eq(text, "AB")
  text = feed("claude", {
    '{"type":"result","subtype":"success","is_error":false,"result":"R"}',
  })
  eq(text, "R")
  local _, errors = feed("claude", {
    '{"type":"result","subtype":"error_max_turns","is_error":true}',
  })
  eq(errors, { "error_max_turns" })
end

T["decoders treat other lines as text and report Codex failures"] = function()
  eq(feed("claude", { "not json" }), "not json\n")
  local text, errors = feed("codex", {
    '{"type":"item.completed","item":{"type":"agent_message","text":"A"}}',
    '{"type":"item.completed","item":{"type":"agent_message","text":"B"}}',
    '{"type":"turn.failed","error":{"message":"usage limit"}}',
  })
  eq(text, "A\n\nB")
  eq(errors, { "usage limit" })
end

return T
