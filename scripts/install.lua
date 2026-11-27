-- Install Iara as the `iara` application or as the default `nvim`, and
-- back up, restore, list, or uninstall the directories involved.
--
--   NVIM_LOG_FILE=/dev/null nvim --clean -l scripts/install.lua \
--     ACTION [options]
--
-- (Without NVIM_LOG_FILE, Neovim creates nvim.log in the `nvim` state
-- directory, which may be the one being backed up.)
--
-- Actions:
--   install    move existing Iara paths into a backup, then run this
--              checkout's bootstrap.lua with --launcher
--   default    install Iara when it is missing, move the `nvim` paths
--              (for example NvChad) into a backup, and link each of
--              them to the matching Iara path
--   restore    move a backup's paths back to where they were (the
--              latest backup not yet restored, or --backup)
--   backups    list the backups
--   uninstall  move Iara's paths, its launcher link, and `nvim` links
--              to Iara into a backup
--
-- Options:
--   --dry-run          print the actions; change nothing
--   --backup DIR       backup to restore: a path or a name
--   --launcher PATH    launcher link (default ~/.local/bin/iara)
--   --timestamp STAMP  backup name prefix (default: UTC now)
--
-- Nothing is deleted. Paths are renamed into
-- $XDG_DATA_HOME/iara-backups/<UTC time>-<action>/, whose MANIFEST
-- records, one tab-separated line each, the type (dir, link, file), the
-- original path, the backup path, and a link's target. A backup that
-- exists already is never reused. Restore verifies the MANIFEST first,
-- moves whatever occupies an original path into a new backup, then moves
-- the saved paths back and marks the backup RESTORED.
--
-- XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME are
-- honored when absolute. IARA_INSTALL_BOOTSTRAP replaces bootstrap.lua
-- (tests use a stub).
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local IARA_DIR = vim.fn.fnamemodify(source, ":p:h:h")

local KINDS = { "config", "data", "state", "cache" }
local XDG_DEFAULTS = {
  config = ".config",
  data = ".local/share",
  state = ".local/state",
  cache = ".cache",
}
local TYPES = { directory = "dir", link = "link", file = "file" }
local FORMAT = "iara-backup 1"
local RESTORED = "RESTORED"
local ACTIONS = { "install", "default", "restore", "backups", "uninstall" }
local USAGE = "usage: nvim --clean -l install.lua"
  .. " install|default|restore|backups|uninstall"
  .. " [--dry-run] [--backup DIR] [--launcher PATH] [--timestamp STAMP]"
local VALUE_OPTIONS = {
  ["--backup"] = "backup",
  ["--launcher"] = "launcher",
  ["--timestamp"] = "stamp",
}

---@class InstallEntry
---@field name string Name inside the backup directory.
---@field path string Path in the user's directories.
---@field target string? Link target, for links to create.

---@class InstallSetup
---@field roots table<string, string> XDG roots by kind, plus `home`.
---@field backups string Directory holding the backups.
---@field launcher string
---@field stamp string
---@field dry_run boolean

---Stop with a message for the user (not a defect in this script).
local function abort(message)
  error({ message = message }, 0)
end

local function describe(err)
  if type(err) == "table" and err.message then
    return err.message
  end
  return debug.traceback(tostring(err), 2)
end

local function say(text)
  io.stdout:write(text, "\n")
end

local function exists(path)
  -- lstat also sees dangling symlinks.
  return vim.uv.fs_lstat(path) ~= nil
end

local function is_absolute(path)
  return type(path) == "string" and path:sub(1, 1) == "/"
end

local function utc_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---"dir", "link", "file", another lstat type, or nil when absent.
local function type_of(path)
  local stat = vim.uv.fs_lstat(path)
  return stat and (TYPES[stat.type] or stat.type) or nil
end

local function append(path, line)
  local file = assert(io.open(path, "ab"))
  file:write(line, "\n")
  file:close()
end

-- Paths ----------------------------------------------------------------

---XDG base directories; unset or relative values fall back to $HOME,
---as the specification requires.
local function xdg_roots()
  local home = vim.env.HOME
  if not is_absolute(home) then
    abort("HOME must be an absolute path")
  end
  local roots = { home = home }
  for _, kind in ipairs(KINDS) do
    local value = vim.env["XDG_" .. kind:upper() .. "_HOME"]
    roots[kind] = is_absolute(value) and value
      or (home .. "/" .. XDG_DEFAULTS[kind])
  end
  return roots
end

---The config, data, state, and cache paths of application `app`.
---@return InstallEntry[]
local function app_entries(setup, app)
  local entries = {}
  for _, kind in ipairs(KINDS) do
    local path = setup.roots[kind] .. "/" .. app
    table.insert(entries, { name = kind .. "-" .. app, path = path })
  end
  return entries
end

---The `nvim` paths, each to be linked to the matching Iara path.
---@return InstallEntry[]
local function default_links(setup)
  local links = app_entries(setup, "nvim")
  for _, link in ipairs(links) do
    link.target = vim.fs.dirname(link.path) .. "/iara"
  end
  return links
end

local function is_default_link(link)
  return vim.uv.fs_readlink(link.path) == link.target
end

-- Backups --------------------------------------------------------------

---Refuse paths that cannot be moved or recorded, before changing
---anything.
local function check_movable(entries)
  for _, entry in ipairs(entries) do
    local kind = type_of(entry.path)
    if kind ~= "dir" and kind ~= "link" and kind ~= "file" then
      abort(("cannot back up %s (%s)"):format(entry.path, tostring(kind)))
    end
    if entry.path:find("[\t\n]") then
      abort("cannot record a path with a tab or newline: " .. entry.path)
    end
  end
end

---Create a new backup directory with its MANIFEST header.
local function new_backup(setup, action)
  local dir = setup.backups .. "/" .. setup.stamp .. "-" .. action
  if exists(dir) then
    abort(("backup %s exists already; nothing was changed"):format(dir))
  end
  if setup.dry_run then
    return { dir = dir, dry_run = true }
  end
  vim.fn.mkdir(setup.backups, "p")
  local ok, err = vim.uv.fs_mkdir(dir, 448)
  if not ok then
    abort(("cannot create backup %s: %s"):format(dir, tostring(err)))
  end
  local manifest = dir .. "/MANIFEST"
  append(manifest, FORMAT)
  append(manifest, "action\t" .. action)
  append(manifest, "created\t" .. utc_now())
  return { dir = dir }
end

---Rename `entry.path` into the backup; record it once it moved.
local function move_into(backup, entry)
  local destination = backup.dir .. "/" .. entry.name
  if backup.dry_run then
    say(("would move %s -> %s"):format(entry.path, destination))
    return
  end
  local kind = type_of(entry.path)
  local target = kind == "link" and vim.uv.fs_readlink(entry.path) or nil
  local ok, err = vim.uv.fs_rename(entry.path, destination)
  if not ok then
    local text = "cannot move %s to %s: %s (earlier moves are in the"
      .. " MANIFEST)"
    abort(text:format(entry.path, destination, tostring(err)))
  end
  local fields = { "entry", kind, entry.path, destination, target }
  append(backup.dir .. "/MANIFEST", table.concat(fields, "\t"))
  say(("moved %s -> %s"):format(entry.path, destination))
end

---Move the existing paths of `entries` into a new backup.
---@return table|nil backup Nil when none of the paths exists.
local function back_up(setup, action, entries)
  local present = vim.tbl_filter(function(entry)
    return exists(entry.path)
  end, entries)
  if #present == 0 then
    return nil
  end
  check_movable(present)
  local backup = new_backup(setup, action)
  for _, entry in ipairs(present) do
    move_into(backup, entry)
  end
  return backup
end

local function parse_manifest(dir, text)
  local lines = vim.split(text, "\n", { trimempty = true })
  if lines[1] ~= FORMAT then
    return nil
  end
  local manifest = { dir = dir, entries = {} }
  for index = 2, #lines do
    local fields = vim.split(lines[index], "\t")
    if fields[1] == "entry" then
      table.insert(manifest.entries, {
        type = fields[2],
        original = fields[3],
        backup = fields[4],
        target = fields[5],
      })
    else
      manifest[fields[1]] = fields[2]
    end
  end
  manifest.restored = exists(dir .. "/" .. RESTORED)
  return manifest
end

---The backup in `dir`, or nil when it has no readable MANIFEST.
local function read_manifest(dir)
  local file = io.open(dir .. "/MANIFEST", "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return parse_manifest(dir, text)
end

---Why `entry` cannot be restored from `dir`, or nil.
local function entry_problem(dir, entry)
  local inside = is_absolute(entry.backup)
    and vim.fs.dirname(entry.backup) == dir
  if not is_absolute(entry.original) or not inside then
    return "invalid entry for " .. tostring(entry.original)
  end
  local found = type_of(entry.backup)
  if found ~= entry.type then
    local text = "%s is %s, the MANIFEST records %s"
    return text:format(entry.backup, tostring(found), tostring(entry.type))
  end
  if entry.type == "link" then
    local target = vim.uv.fs_readlink(entry.backup)
    if target ~= entry.target then
      return ("%s points to %s, not %s"):format(
        entry.backup,
        target,
        entry.target
      )
    end
  end
end

local function verify(manifest)
  local problems = {}
  if not manifest.action then
    table.insert(problems, "the MANIFEST names no action")
  end
  for _, entry in ipairs(manifest.entries) do
    local problem = entry_problem(manifest.dir, entry)
    if problem then
      table.insert(problems, problem)
    end
  end
  return problems
end

---Every backup with a readable MANIFEST, oldest first.
local function list_backups(setup)
  local found = {}
  if type_of(setup.backups) ~= "dir" then
    return found
  end
  local names = {}
  for name, kind in vim.fs.dir(setup.backups) do
    if kind == "directory" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(found, read_manifest(setup.backups .. "/" .. name))
  end
  return found
end

---The newest backup not yet restored, optionally of one action.
local function latest_unrestored(setup, action)
  local backups = list_backups(setup)
  for index = #backups, 1, -1 do
    local backup = backups[index]
    if not backup.restored and (not action or backup.action == action) then
      return backup
    end
  end
end

-- Actions --------------------------------------------------------------

local function forward(stream)
  return function(_, data)
    if data then
      stream:write(data)
    end
  end
end

---Run bootstrap.lua as the `iara` application with `args`.
local function run_bootstrap(setup, args)
  local script = vim.env.IARA_INSTALL_BOOTSTRAP
    or (IARA_DIR .. "/scripts/bootstrap.lua")
  local argv = vim.list_extend({ vim.v.progpath, "-l", script }, args)
  if setup.dry_run then
    say("would run: NVIM_APPNAME=iara " .. table.concat(argv, " "))
    return
  end
  -- The bootstrap must see the roots resolved here: Neovim would take an
  -- empty or relative XDG variable as a relative path.
  local env = { NVIM_APPNAME = "iara" }
  for _, kind in ipairs(KINDS) do
    env["XDG_" .. kind:upper() .. "_HOME"] = setup.roots[kind]
  end
  local options = {
    env = env,
    stdout = forward(io.stdout),
    stderr = forward(io.stderr),
  }
  local result = vim.system(argv, options):wait()
  if result.code ~= 0 then
    abort(("bootstrap failed (exit %d)"):format(result.code))
  end
end

local function iara_entries(setup)
  local entries = app_entries(setup, "iara")
  local launcher = { name = "launcher-iara", path = setup.launcher }
  return vim.list_extend(entries, { launcher })
end

local function install(setup)
  local backup = back_up(setup, "install", iara_entries(setup))
  if not setup.dry_run then
    vim.fn.mkdir(vim.fs.dirname(setup.launcher), "p")
  end
  local ok, problem = pcall(run_bootstrap, setup, {
    "--launcher",
    setup.launcher,
  })
  if not ok and backup then
    local text = "%s\nThe previous Iara paths are in %s; restore them with:"
      .. " make restore BACKUP=%s"
    abort(text:format(describe(problem), backup.dir, backup.dir))
  elseif not ok then
    error(problem, 0)
  end
end

local function create_link(setup, link)
  if setup.dry_run then
    say(("would link %s -> %s"):format(link.path, link.target))
    return
  end
  -- A dangling link would stop Neovim from creating its directory.
  vim.fn.mkdir(link.target, "p")
  vim.fn.mkdir(vim.fs.dirname(link.path), "p")
  assert(vim.uv.fs_symlink(link.target, link.path))
  say(("linked %s -> %s"):format(link.path, link.target))
end

local function make_default(setup)
  if not exists(setup.roots.config .. "/iara") then
    say("Iara is not installed; installing it first")
    install(setup)
  end
  local pending = vim.tbl_filter(function(link)
    return not is_default_link(link)
  end, default_links(setup))
  if #pending == 0 then
    say("nvim opens Iara already; nothing was changed")
    return
  end
  local backup = back_up(setup, "install-default", pending)
  for _, link in ipairs(pending) do
    create_link(setup, link)
  end
  if backup then
    say("the previous nvim setup is in " .. backup.dir)
    say("bring it back with: make restore BACKUP=" .. backup.dir)
  end
end

---The backup to restore: the one named, or the newest unrestored one.
local function select_backup(setup, name)
  if not name then
    return latest_unrestored(setup)
      or abort("no backup to restore in " .. setup.backups)
  end
  local dir = is_absolute(name) and name or (setup.backups .. "/" .. name)
  dir = vim.fs.normalize(dir)
  local manifest = read_manifest(dir)
    or abort(dir .. " is not a backup (no valid MANIFEST)")
  if manifest.restored then
    abort(dir .. " was restored already; nothing was changed")
  end
  return manifest
end

local function move_back(setup, entry)
  if setup.dry_run then
    say(("would move %s -> %s"):format(entry.backup, entry.original))
    return
  end
  vim.fn.mkdir(vim.fs.dirname(entry.original), "p")
  local ok, err = vim.uv.fs_rename(entry.backup, entry.original)
  if not ok then
    local text = "cannot move %s back to %s: %s"
    abort(text:format(entry.backup, entry.original, tostring(err)))
  end
  say(("restored %s"):format(entry.original))
end

local function restore(setup, options)
  local manifest = select_backup(setup, options.backup)
  local problems = verify(manifest)
  if #problems > 0 then
    local text = "%s does not match its MANIFEST; nothing was changed:\n  %s"
    abort(text:format(manifest.dir, table.concat(problems, "\n  ")))
  end
  local displaced = {}
  for _, entry in ipairs(manifest.entries) do
    local name = vim.fs.basename(entry.backup)
    table.insert(displaced, { name = name, path = entry.original })
  end
  back_up(setup, "restore", displaced)
  for _, entry in ipairs(manifest.entries) do
    move_back(setup, entry)
  end
  if not setup.dry_run then
    append(manifest.dir .. "/" .. RESTORED, "restored\t" .. utc_now())
  end
  local verb = setup.dry_run and "would restore" or "restored"
  say(("%s %s backup %s"):format(verb, manifest.action, manifest.dir))
end

local function show_backups(setup)
  local backups = list_backups(setup)
  if #backups == 0 then
    say("no backups in " .. setup.backups)
  end
  for _, backup in ipairs(backups) do
    local state = backup.restored and "restored" or "not restored"
    local text = "%s  %s, %d path(s), %s"
    say(text:format(backup.dir, backup.action, #backup.entries, state))
  end
end

local function uninstall(setup)
  local entries = app_entries(setup, "iara")
  if type_of(setup.launcher) == "link" then
    table.insert(entries, { name = "launcher-iara", path = setup.launcher })
  end
  vim.list_extend(
    entries,
    vim.tbl_filter(is_default_link, default_links(setup))
  )
  local backup = back_up(setup, "uninstall", entries)
  if not backup then
    say("nothing to uninstall")
    return
  end
  local previous = latest_unrestored(setup, "install-default")
  if previous then
    say("your nvim setup from before Iara is in " .. previous.dir)
    say("bring it back with: make restore BACKUP=" .. previous.dir)
  end
end

-- Entry point ----------------------------------------------------------

local function parse_args(argv)
  local options = { action = argv[1] }
  if not vim.tbl_contains(ACTIONS, options.action) then
    abort(USAGE)
  end
  local index = 2
  while argv[index] do
    local key = VALUE_OPTIONS[argv[index]]
    if argv[index] == "--dry-run" then
      options.dry_run = true
    elseif key and argv[index + 1] then
      options[key] = argv[index + 1]
      index = index + 1
    else
      abort("unexpected argument " .. vim.inspect(argv[index]) .. "\n" .. USAGE)
    end
    index = index + 1
  end
  return options
end

---@return InstallSetup
local function new_setup(options)
  local roots = xdg_roots()
  local launcher = options.launcher or (roots.home .. "/.local/bin/iara")
  if not is_absolute(launcher) then
    abort("the launcher path must be absolute: " .. launcher)
  end
  local stamp = options.stamp or os.date("!%Y%m%dT%H%M%SZ")
  if not stamp:match("^[%w_.-]+$") then
    abort("invalid timestamp " .. vim.inspect(stamp))
  end
  return {
    roots = roots,
    backups = roots.data .. "/iara-backups",
    launcher = launcher,
    stamp = stamp,
    dry_run = options.dry_run == true,
  }
end

local RUN = {
  install = install,
  default = make_default,
  restore = restore,
  backups = show_backups,
  uninstall = uninstall,
}

local function main(argv)
  local options = parse_args(argv)
  local setup = new_setup(options)
  if setup.dry_run then
    say("dry run: nothing will be changed")
  end
  RUN[options.action](setup, options)
end

local ok, problem = xpcall(main, describe, _G.arg or {})
if not ok then
  io.stderr:write("iara install: " .. problem .. "\n")
  os.exit(1)
end
os.exit(0)
