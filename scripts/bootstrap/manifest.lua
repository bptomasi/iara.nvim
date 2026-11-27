-- The release manifest (release.json): everything needed to verify and
-- reproduce a provisioned release. Format 2 (R2-A) records a checksum of
-- every distributed configuration file in `config.files`.
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")
local parsers = require("iara.core.parsers")

local M = {}

M.FORMAT = 2

---The user's own file inside a release's configuration: it is edited in
---place, so no checksum covers it.
M.PERSONAL = "lua/user.lua"

---Revision of the checkout a configuration is copied from, if known.
local function config_revision(dir)
  local owns_checkout = common.is_checkout_root(dir)
  local revision = owns_checkout
    and common.try_command({ "git", "rev-parse", "HEAD" }, dir)
  local status = owns_checkout
    and common.try_command(
      { "git", "--no-optional-locks", "status", "--porcelain", "--", "." },
      dir
    )
  return {
    source = dir,
    revision = revision or vim.NIL,
    dirty = type(status) == "string" and status ~= "",
  }
end

local function tree_files(dir, ignore)
  local files, names = {}, {}
  local options = {
    depth = math.huge,
    skip = function(path)
      return not ignore(path)
    end,
  }
  for name, kind in vim.fs.dir(dir, options) do
    if not ignore(name) then
      if kind == "link" then
        local target = assert(vim.uv.fs_readlink(dir .. "/" .. name))
        files[name] = "link:" .. target
      elseif kind == "file" then
        table.insert(names, name)
      end
    end
  end
  return vim.tbl_extend("error", files, common.sha256_all(dir, names))
end

---Checksum of release files, with the personal file excluded.
---@param dir string
---@param ignore? fun(path: string): boolean
---@return table<string, string>
function M.config_files(dir, ignore)
  return tree_files(dir, function(path)
    return path == M.PERSONAL or (ignore and ignore(path))
  end)
end

---Fingerprint a plugin's runtime tree independently of its Git metadata.
---@param dir string
---@return string
function M.plugin_content(dir)
  local files = tree_files(dir, function(path)
    return path == ".git" or vim.endswith(path, "/.git")
  end)
  local names = vim.tbl_keys(files)
  table.sort(names)
  local records = {}
  for _, name in ipairs(names) do
    records[#records + 1] = { name, files[name] }
  end
  return vim.fn.sha256(vim.json.encode(records))
end

local function parser_artifacts(paths, pins)
  local artifacts = {}
  for _, pin in ipairs(pins) do
    artifacts[pin.lang] = {
      repo = pin.repo,
      commit = pin.commit,
      sha256 = common.sha256(parsers.parser_path(paths.parsers, pin.lang)),
    }
  end
  return artifacts
end

local function tool_version(argv)
  return common.try_command(argv) or vim.NIL
end

---The manifest of the release at `paths`, provisioned from `context`.
---@param paths IaraLazyPaths
---@param context table Lock, pins, origin, and Git version of the run.
---@param config? table Configuration already recorded by an earlier build.
---@return table
function M.build(paths, context, config)
  local plugins, plugin_contents = {}, {}
  for name, entry in pairs(context.lock) do
    plugins[name] = entry.commit
    plugin_contents[name] = M.plugin_content(paths.root .. "/" .. name)
  end
  if not config then
    config = config_revision(common.IARA_DIR)
    config.files = M.config_files(paths.iara)
  end
  return {
    format = M.FORMAT,
    complete = true,
    created = common.utc_now(),
    app = vim.env.NVIM_APPNAME,
    origin = context.url_format,
    config = config,
    nvim = tostring(vim.version()),
    git = context.git_version,
    manager = context.lock[lazy.MANAGER].commit,
    plugins = plugins,
    plugin_contents = plugin_contents,
    parsers = parser_artifacts(paths, context.pins),
    tools = {
      ["tree-sitter"] = tool_version({ "tree-sitter", "--version" }),
      cc = tool_version({ "cc", "-dumpfullversion", "-dumpversion" }),
    },
  }
end

---Write `manifest` into release `dir` atomically.
---@param dir string
---@param manifest table
function M.write(dir, manifest)
  local path = dir .. "/" .. lazy.MANIFEST
  local temporary = path .. ".new"
  local file = assert(io.open(temporary, "wb"))
  file:write(vim.json.encode(manifest), "\n")
  file:close()
  assert(vim.uv.fs_rename(temporary, path))
end

---After a repair, record the restored artifacts; the configuration
---(with its checksums) and the origin stay as recorded at build time.
---@param paths IaraLazyPaths
---@param context table
function M.refresh(paths, context)
  local recorded = lazy.read_manifest(paths.release) or {}
  local fresh = M.build(paths, context, recorded.config)
  for name, sum in pairs(recorded.plugin_contents or {}) do
    if fresh.plugin_contents[name] ~= sum then
      common.abort(name .. " does not match its recorded content checksum")
    end
  end
  -- A repair never records checksums of a configuration it did not build.
  for _, key in ipairs({ "created", "origin", "format" }) do
    fresh[key] = recorded[key] or fresh[key]
  end
  fresh.repaired = common.utc_now()
  M.write(paths.release, fresh)
end

return M
