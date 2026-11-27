--- One Ask AI conversation (task AI1): the excerpt payload, the turns,
--- and the request in flight. Every question starts a fresh one-shot
--- process whose stdin holds the excerpt, the earlier turns, and the
--- question; nothing is stored anywhere else. Every limit refuses
--- instead of dropping text.
local backend = require("iara.extras.ai.backend")
local proc = require("iara.core.proc")

local M = {}

M.LIMITS = {
  question_bytes = 16 * 1024,
  turns = 8,
  request_bytes = 256 * 1024,
  answer_bytes = 256 * 1024,
  stdout_bytes = 4 * 1024 * 1024,
  line_bytes = 1024 * 1024,
  stderr_bytes = 1024 * 1024,
  stderr_lines = 20,
}

local INSTRUCTIONS = table.concat({
  "You are answering a question from a Neovim user about an excerpt of",
  "their code. Answer in concise Markdown. Do not modify files and do",
  "not run commands; the answer is shown in a small popup.",
}, "\n")

---@class IaraAiTurn
---@field question string
---@field answer string Text received so far.
---@field status "running"|"done"|"failed"|"cancelled"
---@field error string? Failure message.

---@class IaraAiConversation
---@field payload string Formatted excerpt (A2), sent with every question.
---@field cwd string Absolute working directory of the CLI.
---@field backend "claude"|"codex"
---@field command string[] Command before the one-shot arguments.
---@field timeout_ms integer
---@field turns IaraAiTurn[]
---@field job IaraProcHandle?

local function failure(code, message)
  return { code = code, message = message }
end

---@param fields table `payload`, `cwd`, `backend`, `command`, `timeout_ms`.
---@return IaraAiConversation
function M.new(fields)
  local conversation = vim.deepcopy(fields)
  conversation.turns = {}
  return conversation
end

---Whether a request is in flight.
---@param conversation IaraAiConversation
---@return boolean
function M.busy(conversation)
  return conversation.job ~= nil and conversation.job:is_active()
end

---Finished turns, oldest first, as the earlier part of the conversation.
local function history(conversation)
  local parts = {}
  for _, turn in ipairs(conversation.turns) do
    if turn.status == "done" then
      table.insert(parts, "Question:\n" .. turn.question)
      table.insert(parts, "Your answer:\n" .. turn.answer)
    end
  end
  if #parts == 0 then
    return nil
  end
  return "Conversation so far:\n\n" .. table.concat(parts, "\n\n")
end

---Exact stdin of a request for `question`.
---@param conversation IaraAiConversation
---@param question string
---@return string|nil stdin
---@return IaraError|nil err Code "too_large".
function M.request_text(conversation, question)
  local parts = { INSTRUCTIONS, conversation.payload }
  table.insert(parts, history(conversation))
  table.insert(parts, "Question:\n" .. question)
  local text = table.concat(parts, "\n\n") .. "\n"
  if #text > M.LIMITS.request_bytes then
    return nil,
      failure(
        "too_large",
        ("the conversation exceeds %d KiB; close and ask again"):format(
          M.LIMITS.request_bytes / 1024
        )
      )
  end
  return text
end

local function check_question(conversation, question)
  if M.busy(conversation) then
    return failure("busy", "an answer is still running; Ctrl-c cancels it")
  end
  if question == "" then
    return failure("empty", "type a question first")
  end
  if #question > M.LIMITS.question_bytes then
    return failure("too_large", "the question exceeds 16 KiB")
  end
  if #conversation.turns >= M.LIMITS.turns then
    local message = "at most %d questions per popup; close and ask again"
    return failure("too_long", message:format(M.LIMITS.turns))
  end
  return nil
end

---Bounded tail of stderr, for failure messages.
local function stderr_stream(tail)
  return {
    mode = "lines",
    max_bytes = M.LIMITS.stderr_bytes,
    on_data = function(lines)
      for _, line in ipairs(lines) do
        table.insert(tail, line)
        if #tail > M.LIMITS.stderr_lines then
          table.remove(tail, 1)
        end
      end
    end,
  }
end

---Feed stdout lines through the decoder into the turn.
local function stdout_stream(conversation, turn, handlers)
  local decode = backend.decoder(conversation.backend)
  return {
    mode = "lines",
    max_bytes = M.LIMITS.stdout_bytes,
    max_line_bytes = M.LIMITS.line_bytes,
    on_data = function(lines)
      for _, line in ipairs(lines) do
        local event = decode(line)
        turn.error = event.error or turn.error
        if event.text and turn.status == "running" then
          turn.answer = turn.answer .. event.text
          handlers.on_text(turn, event.text)
        end
      end
      if #turn.answer > M.LIMITS.answer_bytes then
        turn.too_long = true
        conversation.job:cancel("answer_bytes")
      end
    end,
  }
end

---Failure message of a finished request, or nil when it succeeded.
local function result_failure(conversation, turn, result, stderr)
  local name = conversation.backend
  local title = backend.BACKENDS[name].title
  if turn.too_long then
    return ("the answer exceeded %d KiB and was stopped"):format(
      M.LIMITS.answer_bytes / 1024
    )
  end
  if result.status == "not_found" then
    return ("%s is not installed: %q was not found on PATH"):format(
      title,
      conversation.command[1]
    )
  end
  if result.status == "exited" and result.code == 0 and not turn.error then
    return nil
  end
  local detail = turn.error or (result.error and result.error.message)
  if not detail or detail == "" then
    detail = table.concat(stderr, "\n")
  end
  if detail == "" then
    detail = ("exit status %s"):format(tostring(result.code))
  end
  return backend.failure_message(name, detail)
end

---Notice for a successful run whose answer is blank, or nil: the CLI
---exited 0 yet sent no text, which an empty "done" turn would hide.
local function missing_answer(conversation, turn, result, stderr)
  if vim.trim(turn.answer) ~= "" then
    return nil
  end
  local title = backend.BACKENDS[conversation.backend].title
  local notice = ("No answer received from %s (exit status %s)"):format(
    title,
    tostring(result.code)
  )
  local detail = vim.trim(table.concat(stderr, "\n"))
  return detail == "" and notice or (notice .. ": " .. detail)
end

local function finish(conversation, turn, result, stderr, handlers)
  conversation.job = nil
  if result.status == "cancelled" and not turn.too_long then
    turn.status = "cancelled"
  else
    turn.error = result_failure(conversation, turn, result, stderr)
      or missing_answer(conversation, turn, result, stderr)
    turn.status = turn.error and "failed" or "done"
  end
  handlers.on_done(turn)
end

---Ask `question`: start a one-shot request and stream its answer.
---`handlers.on_text(turn, text)` runs for each piece of the answer and
---`handlers.on_done(turn)` once at the end, with `turn.status`.
---Error codes (nothing starts): "busy", "empty", "too_large",
---"too_long".
---@param conversation IaraAiConversation
---@param question string
---@param handlers { on_text: fun(turn: IaraAiTurn, text: string),
---  on_done: fun(turn: IaraAiTurn) }
---@return IaraAiTurn|nil turn
---@return IaraError|nil err
function M.ask(conversation, question, handlers)
  local err = check_question(conversation, question)
  local stdin
  if not err then
    stdin, err = M.request_text(conversation, question)
  end
  if err then
    return nil, err
  end
  local turn = { question = question, answer = "", status = "running" }
  table.insert(conversation.turns, turn)
  local stderr = {}
  local argv = backend.argv(conversation.backend, conversation.command)
  conversation.job = proc.spawn(argv, {
    cwd = conversation.cwd,
    stdin = stdin,
    timeout_ms = conversation.timeout_ms,
    tag = "iara-ai",
    stdout = stdout_stream(conversation, turn, handlers),
    stderr = stderr_stream(stderr),
    on_complete = function(result)
      finish(conversation, turn, result, stderr, handlers)
    end,
  })
  return turn
end

---Cancel the request in flight, if any.
---@param conversation IaraAiConversation
---@return boolean cancelled
function M.cancel(conversation)
  if not M.busy(conversation) then
    return false
  end
  conversation.job:cancel("user")
  return true
end

return M
