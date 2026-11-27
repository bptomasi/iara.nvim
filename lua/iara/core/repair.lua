--- `:IaraRepair` (X3): runs the bootstrap repair of the running
--- installation in a terminal window, so its progress and any error stay
--- readable. Repair completes the current release (or an installation
--- made before releases) at its locks; the editor keeps its loaded
--- plugins until it restarts.
local M = {}

---Lines of the repair window.
local HEIGHT = 15

---The repair command: this Neovim running the current release's
---bootstrap with `--repair`, under the same application name (the same
---as `provision_command("repair")` shows).
---@return string[] argv
---@return table<string, string> env Added to the editor's environment.
function M.command()
  local script = require("iara.core.lazy").bootstrap_script("repair")
  local argv = { vim.v.progpath, "-l", script, "--repair" }
  return argv, { NVIM_APPNAME = vim.env.NVIM_APPNAME or "iara" }
end

---What the user reads when the repair ends.
---@param code integer Exit code of the bootstrap.
---@return string message
---@return integer level
function M.result_message(code)
  if code == 0 then
    return "Iara: repair complete; restart Iara to load the repaired "
      .. "plugins",
      vim.log.levels.INFO
  end
  return (
    "Iara: repair failed (exit %d); its output is in the repair" .. " window"
  ):format(code),
    vim.log.levels.ERROR
end

local function on_exit(_, code)
  vim.schedule(function()
    vim.notify(M.result_message(code))
  end)
end

---Open a window at the bottom and run the repair in a terminal there.
---@return integer|nil job Job id, or nil when it could not start.
function M.run()
  local argv, env = M.command()
  vim.cmd(("botright %dnew"):format(HEIGHT))
  local ok, job = pcall(vim.fn.jobstart, argv, {
    term = true,
    env = env,
    on_exit = on_exit,
  })
  if not ok or job <= 0 then
    vim.notify(
      "Iara: cannot start the repair: " .. table.concat(argv, " "),
      vim.log.levels.ERROR
    )
    return nil
  end
  return job
end

return M
