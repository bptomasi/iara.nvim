-- The exclusive owner record of a provisioning run. A concurrent run is
-- refused; a record left by an interrupted run stops every step except
-- --repair, which removes that run's temporary files and takes over.
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")

local M = {}

local owner_token = nil

local function describe_owner(record)
  local text = "pid %s, %s, started %s"
  return text:format(record.pid, record.mode, record.started)
end

---Create the owner record; false when one exists already.
local function write_owner(layout, mode)
  local fd = vim.uv.fs_open(layout.owner, "wx", 420)
  if not fd then
    return false
  end
  owner_token = ("%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime())
  local record = {
    pid = vim.uv.os_getpid(),
    host = vim.uv.os_gethostname(),
    mode = mode,
    started = common.utc_now(),
    token = owner_token,
  }
  vim.uv.fs_write(fd, vim.json.encode(record))
  vim.uv.fs_close(fd)
  return true
end

---Repair takes over from an interrupted run: its temporary directories
---and link replacements are left-overs that only an owner may remove.
local function take_over(layout, record)
  local leftovers = vim.fn.glob(layout.data .. "/iara-tmp-*", true, true)
  vim.list_extend(leftovers, { layout.current .. ".new" })
  vim.list_extend(leftovers, { layout.previous .. ".new" })
  leftovers = vim.tbl_filter(common.exists, leftovers)
  for _, path in ipairs(leftovers) do
    vim.fn.delete(path, "rf")
  end
  vim.uv.fs_unlink(layout.owner)
  if not write_owner(layout, "repair") then
    common.abort("another provisioning run started during repair; retry later")
  end
  local text = "took over from an interrupted run (%s), removed: %s"
  common.say(text:format(describe_owner(record), table.concat(leftovers, ", ")))
end

---Become the only provisioning run of this installation.
---@param layout IaraLayout
---@param mode string
function M.acquire(layout, mode)
  vim.fn.mkdir(layout.data, "p")
  if write_owner(layout, mode) then
    return
  end
  local record, state = lazy.owner()
  if not record then
    common.abort("another provisioning run just finished; retry")
  end
  if state == "live" then
    local text = "another provisioning run owns %s (%s); nothing was"
      .. " changed. Wait for it to finish."
    common.abort(text:format(layout.owner, describe_owner(record)))
  end
  if mode ~= "repair" then
    local text = "an interrupted provisioning run left %s (%s); nothing"
      .. " was changed. Check the installation, then run: %s"
    local repair = lazy.provision_command("repair")
    common.abort(text:format(layout.owner, describe_owner(record), repair))
  end
  take_over(layout, record)
end

---Remove the record if this run wrote it.
---@param layout IaraLayout
function M.release(layout)
  local record = lazy.owner()
  if record and record.token == owner_token then
    vim.uv.fs_unlink(layout.owner)
  end
end

return M
