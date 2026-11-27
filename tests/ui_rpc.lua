--- Minimal msgpack-RPC client for a child `nvim --embed` process.
---
--- Requests are pipelined: `request` never waits, so callers can submit
--- input at a fixed cadence while earlier requests are still queued.
--- Every incoming message is stamped with `vim.uv.hrtime()` when its bytes
--- arrive, before decoding, so decoding cost does not hide latency.
local M = {}

local REQUEST, RESPONSE, NOTIFICATION = 0, 1, 2

-- Diagnostics only; a chatty child must not grow harness memory.
local STDERR_LIMIT = 64 * 1024

---@class ui.RpcHandlers
---@field on_notification fun(method: string, params: any[], recv_ns: integer)
---@field on_exit fun(code: integer, signal: integer)|nil

---@class ui.RpcClient
---@field pid integer
---@field launch_ns integer hrtime just before the process was spawned.
---@field stderr string First bytes the child wrote to stderr.
---@field private stdin uv.uv_pipe_t
---@field private next_id integer
---@field private callbacks table<integer, function>
local Client = {}
Client.__index = Client

-- Neovim sends Buffer, Window, and Tabpage handles as extension types.
local function ext_handle(code, data)
  return { ext = code, data = data }
end

local function make_unpacker()
  return vim.mpack.Unpacker({
    ext = { [0] = ext_handle, [1] = ext_handle, [2] = ext_handle },
  })
end

---@param environment table<string, string>
---@return string[]
local function env_list(environment)
  local list = {}
  for name, value in pairs(environment) do
    table.insert(list, name .. "=" .. value)
  end
  table.sort(list)
  return list
end

function Client:dispatch(message, recv_ns, handlers)
  local kind = message[1]
  if kind == RESPONSE then
    local callback = self.callbacks[message[2]]
    self.callbacks[message[2]] = nil
    if callback then
      callback(message[3], message[4], recv_ns)
    end
  elseif kind == NOTIFICATION then
    handlers.on_notification(message[2], message[3], recv_ns)
  elseif kind == REQUEST then
    -- The harness exposes no methods; answer so the child never blocks.
    self:send({ RESPONSE, message[2], "no methods in UI test client", vim.NIL })
  end
end

function Client:reader(handlers)
  local unpack = make_unpacker()
  return function(err, chunk)
    local recv_ns = vim.uv.hrtime()
    if err or not chunk then
      return
    end
    local position = 1
    while position <= #chunk do
      local message
      message, position = unpack(chunk, position)
      if message == nil then
        break
      end
      self:dispatch(message, recv_ns, handlers)
    end
  end
end

function Client:send(message)
  if not self.stdin:is_closing() then
    self.stdin:write(vim.mpack.encode(message))
  end
end

---Send a request without waiting; `callback(err, result, recv_ns)` runs
---when the response arrives.
---@param method string
---@param params any[]
---@param callback fun(err: any, result: any, recv_ns: integer)|nil
function Client:request(method, params, callback)
  local id = self.next_id
  self.next_id = id + 1
  self.callbacks[id] = callback or function() end
  self:send({ REQUEST, id, method, params })
end

---Send a notification.
---@param method string
---@param params any[]
function Client:notify(method, params)
  self:send({ NOTIFICATION, method, params })
end

---Kill the child if it is still running.
function Client:kill()
  if self.process and not self.process:is_closing() then
    self.process:kill("sigkill")
  end
end

local function capture_stderr(client, pipe)
  pipe:read_start(function(_, chunk)
    if chunk and #client.stderr < STDERR_LIMIT then
      client.stderr = (client.stderr .. chunk):sub(1, STDERR_LIMIT)
    end
  end)
end

---Spawn `argv` with `environment` as its complete environment.
---@param argv string[] Command and arguments, for example nvim --embed.
---@param environment table<string, string>
---@param handlers ui.RpcHandlers
---@param cwd string|nil Working directory of the child.
---@return ui.RpcClient|nil client
---@return string|nil error
function M.spawn(argv, environment, handlers, cwd)
  local stdin, stdout = vim.uv.new_pipe(), vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()
  local client = setmetatable({ next_id = 1, callbacks = {} }, Client)
  client.stdin, client.stderr = stdin, ""
  client.launch_ns = vim.uv.hrtime()
  local process, pid = vim.uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2),
    env = env_list(environment),
    cwd = cwd,
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    for _, pipe in ipairs({ stdin, stdout, stderr }) do
      pipe:close()
    end
    if handlers.on_exit then
      handlers.on_exit(code, signal)
    end
  end)
  if not process then
    return nil, tostring(pid)
  end
  client.process, client.pid = process, pid
  stdout:read_start(client:reader(handlers))
  capture_stderr(client, stderr)
  return client
end

return M
