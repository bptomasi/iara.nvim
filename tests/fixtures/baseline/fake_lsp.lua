-- Minimal language server for tests, run with `nvim -l fake_lsp.lua LOG`.
-- It answers initialize, definition (always the first line's `target`
-- word), and completion (one plain item and one snippet), advertises
-- semantic tokens and document colors, and appends every received method
-- name to LOG so tests can prove which requests were made.
local log_path = arg[1]

local function log(method)
  local file = io.open(log_path, "a")
  if file then
    file:write(method, "\n")
    file:close()
  end
end

local function read_message()
  local length
  while true do
    local line = io.stdin:read("*l")
    if not line then
      return nil
    end
    line = line:gsub("\r$", "")
    if line == "" then
      break
    end
    length = tonumber(line:match("^Content%-Length: (%d+)")) or length
  end
  return vim.json.decode(io.stdin:read(length))
end

local function send(message)
  message.jsonrpc = "2.0"
  local body = vim.json.encode(message)
  io.stdout:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
  io.stdout:flush()
end

local CAPABILITIES = {
  definitionProvider = true,
  completionProvider = { triggerCharacters = { "." } },
  semanticTokensProvider = {
    legend = { tokenTypes = { "variable" }, tokenModifiers = {} },
    full = true,
  },
  colorProvider = true,
  textDocumentSync = 1,
}

local function definition(params)
  return {
    uri = params.textDocument.uri,
    range = {
      start = { line = 0, character = 15 },
      ["end"] = { line = 0, character = 21 },
    },
  }
end

local function completion()
  return {
    isIncomplete = false,
    items = {
      { label = "iara_fake_completion", kind = 6 },
      {
        label = "iara_snippet",
        kind = 15,
        insertTextFormat = 2,
        insertText = "iara_snippet(${1:argument})",
      },
    },
  }
end

local HANDLERS = {
  initialize = function()
    return { capabilities = CAPABILITIES }
  end,
  ["textDocument/definition"] = definition,
  ["textDocument/completion"] = completion,
  ["textDocument/semanticTokens/full"] = function()
    return { data = {} }
  end,
  ["textDocument/documentColor"] = function()
    return {}
  end,
}

while true do
  local message = read_message()
  if not message or message.method == "exit" then
    break
  end
  log(message.method or "response")
  if message.id and message.method then
    local handler = HANDLERS[message.method]
    local result = handler and handler(message.params)
    send({ id = message.id, result = result or vim.NIL })
  end
end
