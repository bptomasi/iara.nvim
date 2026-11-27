-- Candidate releases: built complete in an owned temporary directory
-- with their own roots, never touching the active release, started once
-- from separate XDG roots, and only then published under releases/.
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")
local manifest = require("bootstrap.manifest")
local parsers = require("iara.core.parsers")
local provision = require("bootstrap.provision")
local startup = require("bootstrap.startup")
local verify = require("bootstrap.verify")

local IARA_DIR = common.IARA_DIR

local M = {}

local function copy_tree(from, to)
  common.run_command({ "cp", "-R", "-P", "-p", from, to })
end

---The personal file carried into a new release: the active one first.
local function personal_file()
  local active = vim.fn.stdpath("config") .. "/" .. manifest.PERSONAL
  if vim.uv.fs_stat(active) then
    return active
  end
  local checkout = IARA_DIR .. "/" .. manifest.PERSONAL
  return vim.uv.fs_stat(checkout) and checkout or nil
end

local LOCAL_METADATA = {
  [".agents"] = true,
  [".aws"] = true,
  [".claude"] = true,
  [".codex"] = true,
  [".git"] = true,
  [".tools"] = true,
  ["nvim.log"] = true,
}

local function local_metadata(name)
  return LOCAL_METADATA[name] == true
end

---Copy this checkout (without development tools) as the release's
---configuration, keeping the user's personal file.
local function copy_config(target)
  local personal = personal_file()
  vim.fn.mkdir(target, "p")
  for name in vim.fs.dir(IARA_DIR) do
    if not local_metadata(name) then
      copy_tree(IARA_DIR .. "/" .. name, target .. "/" .. name)
    end
  end
  vim.fn.delete(target .. "/" .. manifest.PERSONAL)
  if personal then
    assert(vim.uv.fs_copyfile(personal, target .. "/" .. manifest.PERSONAL))
  end
end

---Copy plugin trees of the active installation that the candidate can
---reuse: those at the candidate's locked commit and personal ones.
local function reusable_plugin(path, entry, sum)
  return not entry
    or (
      lazy.checkout_commit(path) == entry.commit
      and common.clean_checkout(path)
      and (not sum or manifest.plugin_content(path) == sum)
    )
end

local function seed_plugins(active, paths, lock)
  if not active or not vim.uv.fs_stat(active.root) then
    return
  end
  vim.fn.mkdir(paths.root, "p")
  local recorded = active.release and lazy.read_manifest(active.release)
  local sums = recorded and recorded.plugin_contents or {}
  for name, kind in vim.fs.dir(active.root) do
    local from = active.root .. "/" .. name
    local finished = not common.exists(from .. ".cloning")
    if
      kind == "directory"
      and finished
      and reusable_plugin(from, lock[name], sums[name])
    then
      copy_tree(from, paths.root .. "/" .. name)
    end
  end
end

---Whether the checkout already matches a verified active release.
---@param active IaraLazyPaths
---@return boolean
function M.unchanged(active)
  if not active.release then
    return false
  end
  local recorded = lazy.read_manifest(active.release)
  if
    not recorded
    or not recorded.plugin_contents
    or not recorded.config
    or recorded.nvim ~= tostring(vim.version())
  then
    return false
  end
  local files = manifest.config_files(IARA_DIR, local_metadata)
  if not vim.deep_equal(files, recorded.config.files) then
    return false
  end
  local ok = pcall(verify.release, active.release)
  return ok
end

---Copy one active parser and its stamp into `paths`.
local function copy_parser(active, paths, lang)
  vim.fn.mkdir(paths.parsers .. "/parser", "p")
  vim.fn.mkdir(paths.parsers .. "/stamps", "p")
  local stamp = "/stamps/" .. lang
  assert(vim.uv.fs_copyfile(active.parsers .. stamp, paths.parsers .. stamp))
  local from = parsers.parser_path(active.parsers, lang)
  assert(vim.uv.fs_copyfile(from, parsers.parser_path(paths.parsers, lang)))
end

local function reusable_parser(active, pin, artifact)
  if parsers.installed_commit(active.parsers, pin.lang) ~= pin.commit then
    return false
  end
  if not artifact then
    return true
  end
  local binary = parsers.parser_path(active.parsers, pin.lang)
  local ok, sum = pcall(common.sha256, binary)
  return ok and sum == artifact.sha256
end

---Copy active parsers built from the candidate's pinned commits.
local function seed_parsers(active, paths, pins)
  if not active then
    return
  end
  local recorded = active.release and lazy.read_manifest(active.release)
  local artifacts = recorded and recorded.parsers or {}
  for _, pin in ipairs(pins) do
    if reusable_parser(active, pin, artifacts[pin.lang]) then
      copy_parser(active, paths, pin.lang)
    end
  end
end

---Build a complete, started release in an owned temporary directory.
---@param context table Lock, pins, origin, and Git version of the run.
---@param active IaraLazyPaths|nil Installation to reuse trees from.
---@return string work Temporary directory to remove after publication.
---@return string dir The candidate release inside it.
function M.build(context, active)
  local work = common.new_temporary(lazy.layout())
  local dir = work .. "/release"
  common.guarded(work, function()
    copy_config(dir .. "/config")
    local paths = lazy.release_paths(dir)
    seed_plugins(active, paths, context.lock)
    seed_parsers(active, paths, context.pins)
    provision.provision(paths, context.lock, context.pins, context.url_format)
    startup.check(work, dir, "the candidate release")
    manifest.write(dir, manifest.build(paths, context))
  end)
  return work, dir
end

---Move a built candidate under releases/; returns its new directory.
---@param layout IaraLayout
---@param work string
---@param dir string
---@return string release
function M.publish(layout, work, dir)
  vim.fn.mkdir(layout.releases, "p")
  local suffix = vim.fs.basename(work):sub(-6)
  local id = os.date("!%Y%m%dT%H%M%SZ") .. "-" .. suffix
  local release = layout.releases .. "/" .. id
  local ok, err = vim.uv.fs_rename(dir, release)
  vim.fn.delete(work, "rf")
  if not ok then
    common.abort("cannot publish " .. release .. ": " .. err)
  end
  return release
end

return M
