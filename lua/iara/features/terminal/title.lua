--- Clean display names for terminal buffers (UX2): "Terminal · zsh",
--- "Terminal 2 · zsh in src", "Claude Code", "Codex 2", never the
--- `term://` buffer name. Used by the status line, the tab line, and the
--- panel headers.
local registry = require("iara.features.terminal.registry")

local M = {}

---@class IaraTerminalDescription
---@field kind "terminal"|"agent"
---@field title string Clean name, without secrets or `term://`.
---@field state string "running", "stopping", "exited N", or "failed".
---@field cwd string|nil Launch directory (V7: the panel header).

---Display names of agents by name, given by `iara.extras.agents`.
---@type table<string, string>
local agent_titles = {}

---@param name string Agent name of registry records ("claude").
---@param title string Display name ("Claude Code").
function M.name_agent(name, title)
  agent_titles[name] = title
end

---Last path component of a program, without arguments.
local function program(argv0)
  return vim.fs.basename(argv0 or "") or ""
end

---Program of a terminal buffer not owned by Iara, from its
---`term://{cwd}//{pid}:{cmd}` name.
local function native_program(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local command = name:match("^term://.-//%d+:(.*)$") or ""
  return program(vim.split(command, "%s+", { trimempty = true })[1])
end

local function state_of(record)
  if record.status == "exited" then
    local code = record.exit_code and (" " .. record.exit_code) or ""
    return "exited" .. code
  end
  return record.status
end

local function numbered(name, number)
  return number > 1 and ("%s %d"):format(name, number) or name
end

---Where a shell started, relative to its project, when not the root.
local function place(record)
  if record.cwd == record.root_path then
    return ""
  end
  local relative = vim.fs.relpath(record.root_path, record.cwd)
  return " in " .. (relative or vim.fn.fnamemodify(record.cwd, ":~"))
end

local function record_title(record)
  if record.role == "agent" then
    local name = agent_titles[record.name] or record.name
    return numbered(name, record.instance)
  end
  -- The main terminal is "Terminal"; extra shells count on from it.
  local number = record.role == "main" and 1 or record.instance + 1
  local shell = program(record.argv[1])
  return ("%s · %s%s"):format(
    numbered("Terminal", number),
    shell,
    place(record)
  )
end

---@return IaraTerminalRecord|nil
local function record_for(bufnr)
  for _, record in ipairs(registry.list()) do
    if record.bufnr == bufnr then
      return record
    end
  end
  return nil
end

---Clean description of a terminal buffer; nil for other buffers.
---Previous transcripts of a restarted record read as exited.
---@param bufnr integer
---@return IaraTerminalDescription|nil
function M.describe(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if vim.bo[bufnr].buftype ~= "terminal" then
    return nil
  end
  local record = record_for(bufnr)
  if not record then
    local running = vim.fn.jobwait({ vim.bo[bufnr].channel }, 0)[1] == -1
    local name = vim.api.nvim_buf_get_name(bufnr)
    return {
      kind = "terminal",
      title = "Terminal · " .. native_program(bufnr),
      state = running and "running" or "exited",
      cwd = name:match("^term://(.-)//%d+:"),
    }
  end
  return {
    kind = record.role == "agent" and "agent" or "terminal",
    title = record_title(record),
    state = state_of(record),
    cwd = record.cwd,
  }
end

---Title alone, for window titles; "" for other buffers.
---@param bufnr integer
---@return string
function M.title(bufnr)
  local description = M.describe(bufnr)
  return description and description.title or ""
end

return M
