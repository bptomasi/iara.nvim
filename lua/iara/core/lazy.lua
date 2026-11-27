--- Plugin manager setup (lazy.nvim) for ordinary startup.
---
--- Provisioning is a separate, explicit step (scripts/bootstrap.lua):
--- startup never clones, installs, updates, or checks for updates. The
--- release lock `iara/lazy-lock.json` is immutable; lazy.nvim records its
--- own state in a writable copy under stdpath("data"), seeded from the
--- release lock by the bootstrap. See contracts.md, section 13.
local M = {}

local source = debug.getinfo(1, "S").source:gsub("^@", "")

---The distribution directory (holds init.lua and the release lock).
local IARA_DIR = vim.fn.fnamemodify(source, ":p:h:h:h:h")

---lazy.nvim names its own lock entry after the repository.
M.MANAGER = "lazy.nvim"

---File describing a complete release (written last when it is built).
M.MANIFEST = "release.json"

local did_setup = false

---@class IaraLazyPaths
---@field iara string Distribution (configuration) directory.
---@field release_lock string Immutable lock shipped with the release.
---@field lock string Writable lock that lazy.nvim updates.
---@field root string Plugin installation root.
---@field manager string lazy.nvim checkout.
---@field parsers string Tree-sitter runtime directory.
---@field release string|nil Release directory; nil for an installation
---  made before releases existed (all of it directly in the data dir).

---@class IaraLayout
---@field data string stdpath("data").
---@field releases string Directory holding one directory per release.
---@field current string Link to the active release.
---@field previous string Link to the release kept for rollback.
---@field owner string Owner record of a running provisioning step.

---Locations of the release store for the current application name.
---@return IaraLayout
function M.layout()
  local data = vim.fn.stdpath("data")
  return {
    data = data,
    releases = data .. "/releases",
    current = data .. "/current",
    previous = data .. "/previous",
    owner = data .. "/iara-owner.json",
  }
end

---Real directory of the "current" or "previous" release, or nil.
---Resolving the link once keeps a running editor on its own release when
---another one is promoted.
---@param which "current"|"previous"
---@return string|nil
function M.release_dir(which)
  return vim.uv.fs_realpath(M.layout()[which])
end

---Paths of the release stored in `dir`.
---@param dir string Release directory.
---@return IaraLazyPaths
function M.release_paths(dir)
  local root = dir .. "/lazy"
  return {
    iara = dir .. "/config",
    release_lock = dir .. "/config/lazy-lock.json",
    lock = dir .. "/lazy-lock.json",
    root = root,
    manager = root .. "/" .. M.MANAGER,
    parsers = dir .. "/treesitter",
    release = dir,
  }
end

---Standard locations of the active installation: the current release,
---or the data directory itself for an installation without releases.
---The release lock is always the running distribution's.
---@return IaraLazyPaths
function M.paths()
  local release = M.release_dir("current")
  local paths
  if release then
    paths = M.release_paths(release)
  else
    local data = vim.fn.stdpath("data")
    paths = {
      lock = data .. "/lazy-lock.json",
      root = data .. "/lazy",
      manager = data .. "/lazy/" .. M.MANAGER,
      parsers = data .. "/treesitter",
    }
  end
  paths.iara = IARA_DIR
  paths.release_lock = IARA_DIR .. "/lazy-lock.json"
  return paths
end

---The bootstrap script that runs `mode`. Repair and rollback act on the
---installation, so they use the current release's own copy, reached
---through the data directory: it works when the configuration link is
---missing (R2-A). Install and update, and an installation without
---releases, use the running distribution's.
---@param mode "install"|"repair"|"update"|"rollback"
---@return string path
function M.bootstrap_script(mode)
  local stored = M.layout().current .. "/config/scripts/bootstrap.lua"
  local installed = mode == "repair" or mode == "rollback"
  if installed and vim.uv.fs_stat(stored) then
    return stored
  end
  return IARA_DIR .. "/scripts/bootstrap.lua"
end

---Shell command that runs a provisioning step on this installation.
---@param mode "install"|"repair"|"update"|"rollback"
---@return string
function M.provision_command(mode)
  local command = ("NVIM_APPNAME=%s nvim -l %s"):format(
    vim.env.NVIM_APPNAME or "iara",
    M.bootstrap_script(mode)
  )
  return mode == "install" and command or (command .. " --" .. mode)
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

---Commit of a packed or loose reference, read without running Git.
local function read_ref(git_dir, ref)
  local loose = read_file(git_dir .. "/" .. ref)
  if loose then
    return vim.trim(loose):match("^%x+$")
  end
  for line in vim.gsplit(read_file(git_dir .. "/packed-refs") or "", "\n") do
    local commit, name = line:match("^(%x+) (%S+)$")
    if name == ref then
      return commit
    end
  end
end

---Commit checked out in `dir`, read without running Git (so it works
---offline and without Git installed). Nil when it cannot be read.
---@param dir string
---@return string|nil
function M.checkout_commit(dir)
  local git_dir = dir .. "/.git"
  local head = read_file(git_dir .. "/HEAD")
  if not head then
    return nil
  end
  head = vim.trim(head)
  local ref = head:match("^ref: (%S+)$")
  if ref then
    return read_ref(git_dir, ref)
  end
  return head:match("^%x+$")
end

---@class IaraOwnerRecord
---@field pid integer
---@field host string
---@field mode string
---@field started string
---@field token string

---Whether the process of an owner record still runs a bootstrap. A
---record from another host cannot be checked and counts as live.
---@param record IaraOwnerRecord
---@return boolean
local function owner_alive(record)
  if record.host ~= vim.uv.os_gethostname() then
    return true
  end
  if type(record.pid) ~= "number" then
    return false
  end
  local cmdline = read_file("/proc/" .. record.pid .. "/cmdline")
  if cmdline then
    -- The pid may have been reused by an unrelated process.
    return cmdline:find("bootstrap.lua", 1, true) ~= nil
  end
  return vim.uv.kill(record.pid, 0) == 0
end

---The owner record of a provisioning step, if any, and whether its
---process still runs ("live") or was interrupted ("stale"). Reads files
---only; an unreadable record is stale.
---@return IaraOwnerRecord|nil record
---@return "live"|"stale"|nil state
function M.owner()
  local text = read_file(M.layout().owner)
  if not text then
    return nil
  end
  local ok, record = pcall(vim.json.decode, text)
  if not ok or type(record) ~= "table" then
    return { pid = -1, host = "?", mode = "?", started = "?", token = "" },
      "stale"
  end
  return record, owner_alive(record) and "live" or "stale"
end

---Read the manifest of the release in `dir`.
---@param dir string
---@return table|nil manifest
---@return IaraError|nil err Code "manifest_invalid".
function M.read_manifest(dir)
  local text = read_file(dir .. "/" .. M.MANIFEST)
  local ok, manifest = pcall(vim.json.decode, text or "")
  if not ok or type(manifest) ~= "table" or manifest.complete ~= true then
    local message = dir .. " has no complete release manifest"
    return nil, { code = "manifest_invalid", message = message }
  end
  return manifest
end

local function lock_error(message)
  return { code = "lock_invalid", message = message }
end

local function entry_problem(name, entry)
  if type(name) ~= "string" or type(entry) ~= "table" then
    return "malformed entry " .. vim.inspect(name)
  end
  if type(entry.commit) ~= "string" or not entry.commit:match("^%x+$") then
    return name .. " has no commit hash"
  end
  if #entry.commit ~= 40 then
    return name .. " commit is not a full 40-character hash"
  end
  if type(entry.branch) ~= "string" or entry.branch == "" then
    return name .. " has no branch"
  end
end

---Read and validate a lazy.nvim lockfile. Every entry needs a full
---commit hash and a branch, and the manager itself must be pinned.
---Error codes: "lock_missing", "lock_invalid".
---@param path string
---@return table<string, { branch: string, commit: string }>|nil lock
---@return IaraError|nil err
function M.read_lock(path)
  local file = io.open(path, "rb")
  if not file then
    return nil, { code = "lock_missing", message = "cannot read " .. path }
  end
  local text = file:read("*a")
  file:close()
  local ok, lock = pcall(vim.json.decode, text)
  if not ok or type(lock) ~= "table" or vim.islist(lock) then
    return nil, lock_error(path .. " is not a JSON object")
  end
  for name, entry in pairs(lock) do
    local problem = entry_problem(name, entry)
    if problem then
      return nil, lock_error(path .. ": " .. problem)
    end
  end
  if not lock[M.MANAGER] then
    return nil, lock_error(path .. " does not pin " .. M.MANAGER)
  end
  return lock
end

---Plugin specs in composition order: Iara's own, then personal ones.
---@param config table Composed configuration.
---@return table[]
function M.specs(config)
  local specs = {}
  -- lazy.nvim reports an error when an import finds no spec files.
  local own = vim.fn.glob(IARA_DIR .. "/lua/iara/plugins/*.lua", false, true)
  if #own > 0 then
    table.insert(specs, { import = "iara.plugins" })
  end
  vim.list_extend(specs, config.plugins or {})
  return specs
end

---Pinned plugins found missing from the installation at setup.
---@type table<string, true>
local missing = {}

---Pinned plugins of the release lock whose directory is missing from
---the installation: one stat per pinned plugin. The manager is checked
---on its own. An unreadable lock yields none (health reports it).
---@param paths IaraLazyPaths
---@return string[] names Sorted.
function M.find_missing(paths)
  local names = {}
  for name in pairs(M.read_lock(paths.release_lock) or {}) do
    local path = paths.root .. "/" .. name
    if name ~= M.MANAGER and not vim.uv.fs_stat(path) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

---Pinned plugins that setup found missing, sorted.
---@return string[]
function M.missing()
  local names = vim.tbl_keys(missing)
  table.sort(names)
  return names
end

---Whether `name` or a plugin it depends on, at any depth, is missing.
---lazy.nvim evaluates `cond` while it resolves the specs being parsed,
---which its configuration holds as `spec` (the pinned manager's
---internals; dependencies are plugin names there).
local function needs_missing(name, seen)
  if missing[name] then
    return true
  end
  if seen[name] then
    return false
  end
  seen[name] = true
  local plugin = require("lazy.core.config").spec.plugins[name]
  for _, dependency in ipairs(plugin and plugin.dependencies or {}) do
    if needs_missing(dependency, seen) then
      return true
    end
  end
  return false
end

---Iara's default `cond`: false for a pinned plugin missing from the
---installation and for every plugin that needs one, so their triggers
---never load them (lazy.nvim lists them as disabled and keeps their
---lock entries). A spec with its own `cond` must call it too.
---@param plugin { name: string }
---@return boolean
function M.available(plugin)
  return next(missing) == nil or not needs_missing(plugin.name, {})
end

---lazy.nvim options that keep startup free of installs and updates.
---@param config table Composed configuration.
---@param paths IaraLazyPaths|nil Defaults to M.paths().
---@return table
function M.options(config, paths)
  paths = paths or M.paths()
  return {
    root = paths.root,
    lockfile = paths.lock,
    spec = M.specs(config),
    defaults = { cond = M.available },
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    -- Project `.lazy.lua` files would run code from any opened project.
    local_spec = false,
    rocks = { enabled = false },
    -- The plugin manager window has the frame of every Iara float.
    ui = { border = require("iara.core.ui").BORDER },
    -- The runtimepath reset keeps stdpath("config") only; keep this
    -- distribution reachable when started with `nvim -u`.
    performance = { rtp = { paths = { paths.iara } } },
  }
end

local function warn_on_ui(message)
  -- A notification during startup would block a headless run or appear
  -- before the screen exists; show it once the UI is up instead.
  vim.api.nvim_create_autocmd("UIEnter", {
    group = vim.api.nvim_create_augroup("IaraLazy", { clear = true }),
    once = true,
    callback = function()
      vim.notify("Iara: " .. message, vim.log.levels.WARN)
    end,
  })
end

---One line naming the missing pinned plugins and the repair command.
local function missing_notice()
  local names = M.missing()
  local text = #names == 1 and "%d pinned plugin is missing (%s)"
    or "%d pinned plugins are missing (%s)"
  return text:format(#names, table.concat(names, ", ")) .. "; run :IaraRepair"
end

local function create_repair_command()
  vim.api.nvim_create_user_command("IaraRepair", function()
    require("iara.core.repair").run()
  end, { desc = "Repair the installation (missing plugins, parsers)" })
end

---Initialize the installed manager with Iara's specs, then
---`config.plugins`. Without an installed manager, native editing stays
---available and the repair command is shown; nothing is installed.
---Pinned plugins missing from the installation are disabled (see
---`available`) and named once after startup. Defines `:IaraRepair`.
---@param config table Composed configuration.
function M.setup(config)
  if did_setup then
    return
  end
  did_setup = true
  create_repair_command()
  local paths = M.paths()
  if not vim.uv.fs_stat(paths.manager .. "/lua/lazy/init.lua") then
    warn_on_ui(
      ("lazy.nvim is not installed; plugins are disabled. %s%s"):format(
        "Run :IaraRepair or: ",
        M.provision_command("repair")
      )
    )
    return
  end
  vim.opt.runtimepath:prepend(paths.manager)
  for _, name in ipairs(M.find_missing(paths)) do
    missing[name] = true
  end
  require("lazy").setup(M.options(config, paths))
  if next(missing) then
    warn_on_ui(missing_notice())
  end
end

return M
