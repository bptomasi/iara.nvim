--- Lua language policy: lua_ls through native LSP.
---
--- Reads `config.languages.lua`:
---   cmd      absolute argv of the server (personal override, wins)
---   settings map merged over Iara's `Lua` settings
--- The executable is resolved once at setup: personal `cmd`, then the
--- retained Mason artifact, then PATH. Mason never edits PATH and nothing
--- is installed. A missing server disables only Lua LSP, with one notice
--- when a Lua buffer opens. Formatting belongs to features/format_lua.lua.
local M = {}

M.SERVER = "lua_ls"
M.EXECUTABLE = "lua-language-server"
M.FILETYPES = { "lua" }

local function not_found(message)
  return { code = "not_found", message = message }
end

local function valid_cmd(cmd)
  if type(cmd) ~= "table" or #cmd == 0 then
    return false
  end
  for _, item in ipairs(cmd) do
    if type(item) ~= "string" then
      return false
    end
  end
  return vim.startswith(cmd[1], "/")
end

---Server argv for `settings`, resolved without starting anything.
---Error codes: "invalid_cmd", "not_found".
---@param settings table `config.languages.lua`.
---@return string[]|nil cmd
---@return IaraError|nil err
function M.command(settings)
  local cmd = settings.cmd
  if cmd ~= nil then
    if not valid_cmd(cmd) then
      local text = "languages.lua.cmd must be a list of strings starting"
        .. " with an absolute path"
      return nil, { code = "invalid_cmd", message = text }
    end
    if vim.fn.executable(cmd[1]) == 0 then
      return nil, not_found(cmd[1] .. " is not executable")
    end
    return vim.deepcopy(cmd)
  end
  local mason = vim.fn.stdpath("data") .. "/mason/bin/" .. M.EXECUTABLE
  if vim.fn.executable(mason) == 1 then
    return { mason }
  end
  local on_path = vim.fn.exepath(M.EXECUTABLE)
  if on_path ~= "" then
    return { on_path }
  end
  return nil,
    not_found(
      M.EXECUTABLE
        .. " not found; install it with :MasonInstall "
        .. M.EXECUTABLE
        .. " or put it on PATH"
    )
end

---Server settings for Neovim Lua, merged with `settings.settings`.
---@param settings table
---@return table
function M.server_settings(settings)
  local defaults = {
    Lua = {
      runtime = { version = "LuaJIT" },
      workspace = {
        checkThirdParty = false,
        library = { vim.env.VIMRUNTIME },
      },
      telemetry = { enable = false },
    },
  }
  local user = type(settings.settings) == "table" and settings.settings or {}
  return vim.tbl_deep_extend("force", defaults, user)
end

---Enable lua_ls for eligible Lua buffers, or report why it cannot run.
---@param settings table `config.languages.lua`.
function M.setup(settings)
  local lsp = require("iara.core.lsp")
  local cmd, err = M.command(settings)
  if not cmd then
    lsp.report_unavailable(M.SERVER, M.FILETYPES, err)
    return
  end
  lsp.enable(M.SERVER, {
    cmd = cmd,
    settings = M.server_settings(settings),
  })
end

return M
