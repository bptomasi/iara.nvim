-- Startup smoke test of a release: Iara must start from it in full mode,
-- without a failed step and with every locked plugin available, from
-- separate XDG roots (the user's state is never read or written).
local common = require("bootstrap.common")

local M = {}

-- Runs inside the release under test.
local STARTUP_CHECK = [[
local problems = {}
local status = require("iara").status()
if not status or status.mode ~= "full" then
  local reason = status and tostring(status.reason) or "no status"
  table.insert(problems, "Iara did not start in full mode: " .. reason)
end
for _, step in ipairs(status and status.steps or {}) do
  if step.state == "failed" then
    table.insert(problems, step.name .. " failed: " .. tostring(step.error))
  end
end
local lock_path = vim.fn.stdpath("config") .. "/lazy-lock.json"
local lock = vim.json.decode(table.concat(vim.fn.readfile(lock_path), "\n"))
local ok, config = pcall(require, "lazy.core.config")
for name in pairs(lock) do
  local plugin = ok and config.plugins[name]
  local disabled = ok and config.spec.disabled[name]
  local available = disabled or (plugin and plugin._.installed)
  if name ~= "lazy.nvim" and not available then
    table.insert(problems, name .. " is not available")
  end
end
-- Iara disables a missing pinned plugin, so disabled is not enough.
for _, name in ipairs(require("iara.core.lazy").missing()) do
  table.insert(problems, name .. " is missing")
end
if #problems > 0 then
  io.stderr:write(table.concat(problems, "\n") .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
]]

local TIMEOUT_MS = 60000

---Separate XDG roots below `roots` whose configuration and current
---release are `dir`.
local function isolated_env(roots, dir)
  local app = vim.env.NVIM_APPNAME
  local env = { IARA_SAFE = "0" }
  for _, kind in ipairs({ "config", "data", "state", "cache" }) do
    env["XDG_" .. kind:upper() .. "_HOME"] = roots .. "/" .. kind
  end
  vim.fn.mkdir(roots .. "/config", "p")
  vim.fn.mkdir(roots .. "/data/" .. app, "p")
  assert(vim.uv.fs_symlink(dir .. "/config", roots .. "/config/" .. app))
  assert(vim.uv.fs_symlink(dir, roots .. "/data/" .. app .. "/current"))
  return env
end

---Start Iara from release `dir`; stops with the reason when it does not
---start cleanly.
---@param work string Owned temporary directory for the XDG roots.
---@param dir string Release directory.
---@param what string The release as the user knows it ("the candidate").
function M.check(work, dir, what)
  local env = isolated_env(work .. "/check", dir)
  local script = work .. "/startup-check.lua"
  local file = assert(io.open(script, "wb"))
  file:write(STARTUP_CHECK)
  file:close()
  local argv = { vim.v.progpath, "--headless", "+luafile " .. script }
  local result = vim.system(argv, { env = env, text = true }):wait(TIMEOUT_MS)
  if result.code ~= 0 then
    local text = "%s does not start cleanly:\n%s"
    common.abort(text:format(what, result.stderr or "timed out"))
  end
end

return M
