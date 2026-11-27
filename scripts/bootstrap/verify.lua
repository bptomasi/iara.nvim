-- Verification of a retained release against its manifest, offline and
-- without Git: configuration files, plugin commits, parser checksums.
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")
local manifest_file = require("bootstrap.manifest")
local parsers = require("iara.core.parsers")

local M = {}

local function config_problems(paths, recorded)
  local found = manifest_file.config_files(paths.iara)
  local problems = {}
  for name, sum in pairs(recorded) do
    local path = paths.iara .. "/" .. name
    if not found[name] then
      table.insert(problems, path .. " is missing")
    elseif found[name] ~= sum then
      table.insert(problems, path .. " does not match its checksum")
    end
  end
  for name in pairs(found) do
    if not recorded[name] then
      table.insert(problems, paths.iara .. "/" .. name .. " is unexpected")
    end
  end
  return problems
end

local function plugin_problems(paths, plugins, contents)
  local problems = {}
  for name, commit in pairs(plugins or {}) do
    local plugin = paths.root .. "/" .. name
    local found = lazy.checkout_commit(plugin)
    if found ~= commit then
      local text = "%s is at %s, the release recorded %s"
      table.insert(problems, text:format(name, tostring(found), commit))
    elseif
      contents and manifest_file.plugin_content(plugin) ~= contents[name]
    then
      table.insert(problems, name .. " does not match its content checksum")
    end
  end
  return problems
end

local function parser_problems(paths, artifacts)
  local problems = {}
  for lang, artifact in pairs(artifacts or {}) do
    local path = parsers.parser_path(paths.parsers, lang)
    local ok, found = pcall(common.sha256, path)
    if not ok or found ~= artifact.sha256 then
      table.insert(problems, path .. " does not match its checksum")
    end
  end
  return problems
end

---Recorded configuration checksums; stops for a manifest without them.
local function recorded_files(dir, manifest)
  local files = manifest.config and manifest.config.files
  if type(files) ~= "table" then
    local text = "release %s has no checksums of its configuration (it was"
      .. " built before they were recorded), so it cannot be verified;"
      .. " nothing was changed. Build a verified release with --update."
    common.abort(text:format(dir))
  end
  return files
end

---Verify the release in `dir` against its manifest; stops with every
---difference found.
---@param dir string Release directory.
---@return table manifest
function M.release(dir)
  local manifest, err = lazy.read_manifest(dir)
  if not manifest then
    common.abort(err.message)
  end
  if manifest.plugin_contents and type(manifest.plugin_contents) ~= "table" then
    common.abort("release has invalid plugin content checksums: " .. dir)
  end
  local paths = lazy.release_paths(dir)
  local problems = config_problems(paths, recorded_files(dir, manifest))
  vim.list_extend(
    problems,
    plugin_problems(paths, manifest.plugins, manifest.plugin_contents)
  )
  vim.list_extend(problems, parser_problems(paths, manifest.parsers))
  if #problems > 0 then
    table.sort(problems)
    local text = "release %s is damaged:\n  %s"
    common.abort(text:format(dir, table.concat(problems, "\n  ")))
  end
  return manifest
end

return M
