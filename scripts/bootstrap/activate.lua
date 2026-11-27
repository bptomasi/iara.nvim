-- Activation: switching the `current`, `previous`, and configuration
-- links. A release is made current only after it is verified against
-- its manifest; a rollback target must also start Iara cleanly first.
-- Stage the current link first so a write failure leaves the old pair
-- intact. If publication fails, restore the previous link.
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")
local startup = require("bootstrap.startup")
local verify = require("bootstrap.verify")

local M = {}

local function stage_link(link, target)
  local temporary = link .. ".new"
  vim.uv.fs_unlink(temporary)
  local ok, err = vim.uv.fs_symlink(target, temporary)
  if not ok then
    common.abort("cannot stage " .. link .. ": " .. err)
  end
  return temporary
end

---Point `link` at `target` atomically (a rename over the old link).
local function switch_link(link, target)
  local temporary = stage_link(link, target)
  local ok, err = vim.uv.fs_rename(temporary, link)
  if not ok then
    vim.uv.fs_unlink(temporary)
    common.abort("cannot switch " .. link .. ": " .. err)
  end
end

local function restore_link(link, original)
  if original then
    switch_link(link, original)
    return
  end
  assert(vim.uv.fs_unlink(link))
end

local function switch_pair(layout, current, previous)
  local original = vim.uv.fs_readlink(layout.previous)
  local staged = stage_link(layout.current, current)
  local ok, err =
    xpcall(switch_link, common.describe, layout.previous, previous)
  if not ok then
    vim.uv.fs_unlink(staged)
    common.abort(err)
  end
  ok, err = vim.uv.fs_rename(staged, layout.current)
  if ok then
    return
  end
  vim.uv.fs_unlink(staged)
  local message = "cannot switch " .. layout.current .. ": " .. err
  local restored, recovery =
    xpcall(restore_link, common.describe, layout.previous, original)
  if not restored then
    local text = "\nCould not restore %s (original target %s): %s"
    message = message
      .. text:format(layout.previous, vim.inspect(original), recovery)
  end
  common.abort(message)
end

---Links store paths relative to the data directory, so it may move.
local function release_target(release)
  return "releases/" .. vim.fs.basename(release)
end

local function release_root(layout)
  local stat = vim.uv.fs_lstat(layout.releases)
  if stat and stat.type == "directory" then
    return vim.uv.fs_realpath(layout.releases)
  end
end

local function managed(layout, dir)
  return dir and vim.fs.dirname(dir) == release_root(layout)
end

---Refuse to use an active release outside the installation's store.
---@param layout IaraLayout
---@return string|nil
function M.current(layout)
  if common.exists(layout.releases) and not release_root(layout) then
    common.abort("release store is not a directory: " .. layout.releases)
  end
  local dir = lazy.release_dir("current")
  if dir and not managed(layout, dir) then
    common.abort("current release is outside the managed release store")
  end
  return dir
end

---Remove releases that are neither current nor previous. Only
---directories with a manifest are Iara's; anything else is kept.
local function prune(layout)
  local root = release_root(layout)
  if not root then
    return
  end
  local keep = {
    [lazy.release_dir("current") or ""] = true,
    [lazy.release_dir("previous") or ""] = true,
  }
  for name, kind in vim.fs.dir(root) do
    local dir = root .. "/" .. name
    if
      kind == "directory"
      and not keep[dir]
      and vim.uv.fs_realpath(dir) == dir
      and lazy.read_manifest(dir)
    then
      if vim.fn.delete(dir, "rf") ~= 0 then
        common.say("could not prune old release " .. dir)
      end
    end
  end
end

local function switch_release(layout, current, previous)
  local link = vim.fn.stdpath("config")
  local original = vim.uv.fs_readlink(link)
  local changed = original ~= layout.current .. "/config"
  -- Prepare the configuration link before committing the active release.
  M.ensure_config_link(layout)
  local ok, problem = xpcall(function()
    if previous then
      switch_pair(layout, release_target(current), release_target(previous))
    else
      switch_link(layout.current, release_target(current))
    end
  end, common.describe)
  if ok then
    return
  end
  if changed then
    local restored, recovery =
      xpcall(restore_link, common.describe, link, original)
    if not restored then
      problem = problem .. "\nCould not restore " .. link .. ": " .. recovery
    end
  end
  common.abort(problem)
end

---Make a published, started `release` current after verifying it; the
---replaced one becomes previous.
---@param layout IaraLayout
---@param release string
function M.promote(layout, release)
  if not managed(layout, vim.uv.fs_realpath(release)) then
    common.abort("candidate is outside the managed release store")
  end
  verify.release(release)
  local replaced = M.current(layout)
  switch_release(layout, release, replaced)
  local ok, problem = pcall(prune, layout)
  if not ok then
    common.say("could not prune old releases: " .. common.describe(problem))
  end
  common.say("promoted release " .. vim.fs.basename(release))
end

---Start Iara from `release` in an owned temporary directory.
local function check_startup(layout, release)
  local work = common.new_temporary(layout)
  common.guarded(work, function()
    startup.check(work, release, "release " .. release)
  end)
  vim.fn.delete(work, "rf")
end

---Swap `current` and `previous` after the previous release is verified
---and starts cleanly.
---@param layout IaraLayout
---@return string previous The release made current.
---@return table manifest Its manifest.
function M.rollback(layout)
  local current = lazy.release_dir("current")
  local previous = lazy.release_dir("previous")
  if not current or not previous or previous == current then
    common.abort("no previous release is retained; nothing was changed")
  end
  if not managed(layout, current) or not managed(layout, previous) then
    common.abort("current or previous release is outside the managed store")
  end
  local manifest = verify.release(previous)
  check_startup(layout, previous)
  switch_release(layout, previous, current)
  return previous, manifest
end

---Link `destination` to `target`, creating its parent directories.
---@param target string
---@param destination string
function M.link(target, destination)
  vim.fn.mkdir(vim.fs.dirname(destination), "p")
  assert(vim.uv.fs_symlink(target, destination))
  common.say(("linked %s -> %s"):format(destination, target))
end

---The configuration link must lead to the current release.
---@param layout IaraLayout
function M.ensure_config_link(layout)
  local config_dir = vim.fn.stdpath("config")
  local target = layout.current .. "/config"
  if not common.exists(config_dir) then
    return M.link(target, config_dir)
  end
  local original = vim.uv.fs_readlink(config_dir)
  if not original then
    common.abort(config_dir .. " is not a link; move it away and retry")
  end
  if original ~= target then
    switch_link(config_dir, target)
    common.say(("linked %s -> %s"):format(config_dir, target))
  end
end

return M
