--- One-shot, read-only command lines for the Ask AI popup (task AI1),
--- and decoders for their streamed output.
---
--- Each backend runs the user's installed CLI once per question, with
--- the question on stdin, and exits:
---
---   claude -p --output-format stream-json --verbose
---     --include-partial-messages --tools "" --strict-mcp-config
---     --disable-slash-commands --no-session-persistence
---   codex exec --sandbox read-only -c approval_policy="never"
---     --ephemeral --skip-git-repo-check --color never --json -
---
--- Claude Code gets no tools at all (`--tools ""`), no MCP servers but
--- those named on the command line (none), no slash commands, and keeps
--- no session on disk. Codex runs its commands in its read-only sandbox,
--- never asks for approval (it cannot be answered here, and "never"
--- refuses escalation instead of granting it), and keeps no session
--- files. Neither command contains a permission or sandbox bypass, and a
--- configured command that does is refused.
local M = {}

---@class IaraAiBackend
---@field title string Display name.
---@field argv string[] Default command (the executable).
---@field args string[] One-shot arguments Iara appends to the command.

---@type table<string, IaraAiBackend>
M.BACKENDS = {
  claude = {
    title = "Claude",
    argv = { "claude" },
    args = {
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
    },
  },
  codex = {
    title = "Codex",
    argv = { "codex" },
    args = {
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
    },
  },
}

---Preference order when no backend is configured.
M.ORDER = { "codex", "claude" }

---Arguments a configured command must not contain: the agent terminals'
---bypass arguments (`iara.extras.agents.BYPASS_ARGUMENTS`, a test keeps
---this a superset) and those that would widen the one-shot command's
---tools, sandbox, or approvals.
M.UNSAFE_ARGUMENTS = {
  "--dangerously-skip-permissions",
  "--allow-dangerously-skip-permissions",
  "--dangerously-bypass-approvals-and-sandbox",
  "--dangerously-bypass-hook-trust",
  "--yolo",
  "--full-auto",
  "--approve-for-me",
  "bypassPermissions",
  "acceptEdits",
  "danger-full-access",
  "workspace-write",
  "--permission-mode",
  "--tools",
  "--allowedTools",
  "--allowed-tools",
  "--mcp-config",
  "--add-dir",
  "--sandbox",
  "-s",
}

---Text that makes any argument unsafe wherever it appears, which also
---covers configuration overrides such as `-c sandbox_mode="..."`.
M.UNSAFE_TEXT = {
  "danger",
  "bypass",
  "yolo",
  "full-auto",
  "sandbox_mode",
  "approval_policy",
  "permissionMode",
}

local function unsafe_in(argument)
  local flag, value = argument:match("^(%-%-?[^=]+)=(.*)$")
  for _, unsafe in ipairs(M.UNSAFE_ARGUMENTS) do
    if argument == unsafe or flag == unsafe or value == unsafe then
      return unsafe
    end
  end
  for _, text in ipairs(M.UNSAFE_TEXT) do
    if argument:find(text, 1, true) then
      return argument
    end
  end
  return nil
end

---The unsafe argument found in `argv`, if any; `--flag=value` counts.
---@param argv string[]
---@return string|nil
function M.unsafe_argument(argv)
  for _, argument in ipairs(argv) do
    local unsafe = unsafe_in(argument)
    if unsafe then
      return unsafe
    end
  end
  return nil
end

---Full argv of a one-shot request: `command` (default: the backend's
---executable) followed by the backend's read-only arguments.
---@param name "claude"|"codex"
---@param command string[]?
---@return string[]
function M.argv(name, command)
  local backend = M.BACKENDS[name]
  if not backend then
    error("iara.extras.ai.backend: unknown backend " .. tostring(name), 2)
  end
  local argv = vim.deepcopy(command or backend.argv)
  return vim.list_extend(argv, backend.args)
end

-- Decoders ------------------------------------------------------------------

local function decode(line)
  local ok, event = pcall(vim.json.decode, line, {
    luanil = { object = true, array = true },
  })
  if ok and type(event) == "table" then
    return event
  end
  return nil
end

---Text blocks of a Claude message, joined.
local function message_text(message)
  local parts = {}
  for _, block in ipairs(type(message) == "table" and message.content or {}) do
    if type(block) == "table" and block.type == "text" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts)
end

local function claude_delta(state, event)
  local inner = event.event or {}
  local delta = inner.delta or {}
  if inner.type == "content_block_delta" and delta.type == "text_delta" then
    state.streamed = true
    return { text = delta.text }
  end
  return {}
end

local function claude_result(state, event)
  if event.is_error or event.subtype ~= "success" then
    local message = event.result or event.subtype or "unknown error"
    return { error = tostring(message) }
  end
  if not state.emitted and type(event.result) == "string" then
    return { text = event.result }
  end
  return {}
end

local CLAUDE_EVENTS = {
  stream_event = claude_delta,
  assistant = function(state, event)
    if state.streamed then
      return {}
    end
    return { text = message_text(event.message) }
  end,
  result = claude_result,
}

local function codex_item(state, event)
  local item = event.item or {}
  if item.type ~= "agent_message" or type(item.text) ~= "string" then
    return {}
  end
  local separator = state.emitted and "\n\n" or ""
  return { text = separator .. item.text }
end

local function event_message(_, event)
  local err = type(event.error) == "table" and event.error or event
  return { error = tostring(err.message or "unknown error") }
end

local CODEX_EVENTS = {
  ["item.completed"] = codex_item,
  ["turn.failed"] = event_message,
  error = event_message,
}

---A decoder for one request of `name`: called with each stdout line, it
---returns `{ text = string? , error = string? }`. Lines that are not
---JSON events are answer text (wrappers that print plain text work).
---@param name "claude"|"codex"
---@return fun(line: string): { text: string?, error: string? }
function M.decoder(name)
  local handlers = name == "claude" and CLAUDE_EVENTS or CODEX_EVENTS
  local state = { streamed = false, emitted = false }
  return function(line)
    local event = decode(line)
    local result
    if not event then
      result = { text = line .. "\n" }
    else
      local handler = handlers[event.type]
      result = handler and handler(state, event) or {}
    end
    if result.text == "" then
      result.text = nil
    end
    state.emitted = state.emitted or result.text ~= nil
    return result
  end
end

-- Failures ------------------------------------------------------------------

local AUTH_PATTERNS = {
  "not logged in",
  "/login",
  "log in",
  "login",
  "unauthori[sz]ed",
  "authenticat",
  "invalid api key",
  "401",
}

---Whether a failure message says the CLI has no valid sign-in.
---@param text string
---@return boolean
function M.is_auth_failure(text)
  local lower = text:lower()
  for _, pattern in ipairs(AUTH_PATTERNS) do
    if lower:find(pattern) then
      return true
    end
  end
  return false
end

local SIGN_IN = {
  claude = "run `claude` in a terminal and sign in with /login",
  codex = "run `codex login` in a terminal",
}

---Readable message for a failed request.
---@param name "claude"|"codex"
---@param detail string What the CLI or the runner reported.
---@return string
function M.failure_message(name, detail)
  local title = M.BACKENDS[name].title
  detail = vim.trim(detail)
  if M.is_auth_failure(detail) then
    return ("%s is not signed in: %s. (%s)"):format(
      title,
      SIGN_IN[name],
      detail
    )
  end
  return ("%s failed: %s"):format(title, detail)
end

return M
