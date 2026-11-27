--- A provisioned Iara editor driven over RPC, for baseline workflow tests.
--- The editor runs the real startup (lazy.nvim and the pinned plugins)
--- inside the isolated XDG directories of a provisioned checkout.
local helpers = require("helpers")
local fixture = require("lazy_fixture")

local editor_fixture = {}

editor_fixture.FAKE_LSP = helpers.iara_dir
  .. "/tests/fixtures/baseline/fake_lsp.lua"

---Personal configuration that runs the fake server as lua_ls.
---@param log string File receiving the server's request log.
---@return string path
function editor_fixture.fake_server_personal(log)
  local path = helpers.temp_dir() .. "/user.lua"
  local cmd = { vim.v.progpath, "-l", editor_fixture.FAKE_LSP, log }
  local source = "return { languages = { lua = { cmd = %s } } }"
  helpers.write_file(path, source:format(vim.inspect(cmd)))
  return path
end

---@class EditorFixture
---@field lua fun(self: EditorFixture, code: string, args: table?): any
---@field input fun(self: EditorFixture, keys: string)
---@field wait fun(self: EditorFixture, code: string, timeout: integer?):
---  boolean
---@field stop fun(self: EditorFixture)

local Editor = {}
Editor.__index = Editor

function Editor:lua(code, args)
  return vim.rpcrequest(self.channel, "nvim_exec_lua", code, args or {})
end

function Editor:input(keys)
  vim.rpcrequest(self.channel, "nvim_input", keys)
end

---Poll `code` (a Lua chunk returning a boolean) until it holds. Generous
---timeouts keep the tests robust on a loaded machine.
function Editor:wait(code, timeout)
  return vim.wait(timeout or 15000, function()
    return self:lua(code) == true
  end, 20)
end

function Editor:stop()
  pcall(vim.rpcrequest, self.channel, "nvim_command", "qa!")
  vim.fn.jobstop(self.job)
end

local function connect(address)
  local channel
  vim.wait(10000, function()
    local ok, result = pcall(vim.fn.sockconnect, "pipe", address, {
      rpc = true,
    })
    channel = ok and result or nil
    return channel ~= nil
  end, 20)
  return channel
end

---Start a provisioned editor in `cwd` with `env`.
---@param env table<string, string>
---@param cwd string
---@return EditorFixture
function editor_fixture.start(env, cwd)
  local address = helpers.temp_dir() .. "/nvim.sock"
  local argv = { vim.v.progpath, "--headless", "--listen", address }
  local job = vim.fn.jobstart(argv, { env = env, cwd = cwd })
  local channel = connect(address)
  if not channel then
    vim.fn.jobstop(job)
    error("cannot connect to the editor", 2)
  end
  return setmetatable({ job = job, channel = channel }, Editor)
end

---Provision a checkout once; returns its environment.
---@return table<string, string>
function editor_fixture.provisioned()
  return (fixture.provisioned())
end

---A Git repository with `files` committed.
---@param files table<string, string>
---@return string path
function editor_fixture.git_repo(files)
  local path = helpers.temp_dir()
  fixture.git({ "init", "--quiet", path })
  for name, content in pairs(files) do
    helpers.write_file(path .. "/" .. name, content)
  end
  fixture.git({ "add", "." }, path)
  fixture.git({ "commit", "--quiet", "-m", "fixture" }, path)
  return path
end

return editor_fixture
