-- Provision an Iara installation from the release lock. Run it explicitly;
-- ordinary startup never installs anything.
--
--   NVIM_APPNAME=iara nvim -l /abs/iara/scripts/bootstrap.lua \
--     [--launcher /abs/path/to/bin/iara]
--   NVIM_APPNAME=iara nvim -l /abs/iara/scripts/bootstrap.lua --update
--   NVIM_APPNAME=iara nvim -l "$DATA/current/config/scripts/bootstrap.lua" \
--     --rollback | --repair      (DATA: ~/.local/share/iara)
--
-- An installation is a set of complete releases below stdpath("data"):
--
--   releases/<id>/config        copy of the Iara checkout
--   releases/<id>/lazy          lazy.nvim and the plugin trees
--   releases/<id>/lazy-lock.json  lazy.nvim's writable lock
--   releases/<id>/treesitter    pinned parsers
--   releases/<id>/release.json  manifest (revisions, checksums, tools)
--   current, previous           links to the active and the kept release
--
-- stdpath("config") links to current/config. The steps live in modules
-- below scripts/bootstrap/, one guarantee each:
--
--   provision   manager, plugins, and parsers at their pinned revisions,
--               published only after they are verified
--   candidate   a complete release built and started apart from the
--               active one, then published under releases/
--   manifest    release.json, with a checksum of every configuration file
--   verify      a retained release against its manifest, offline
--   startup     Iara starts from a release in full mode, separate XDG roots
--   activate    links switch only to a verified (and, for a rollback,
--               started) release; a refusal changes no link
--   owner       one provisioning run at a time
--
-- Install and update promote a new release as a whole by switching the
-- "current" link; the release it replaces becomes "previous" and older
-- ones are removed. Restart Iara to activate a promoted release.
-- Rollback swaps current and previous, offline and without Git.
--
-- A record left by an interrupted run stops every step except --repair,
-- which removes that run's temporary files and takes over. Repair
-- completes the current release at its recorded revisions (missing
-- manager, plugins, parsers, configuration link); it never replaces a
-- tree at another revision. It runs the current release's own bootstrap,
-- which works without the configuration link.
--
-- IARA_GIT_URL_FORMAT overrides "https://github.com/%s.git", for example
-- to provision from a local mirror.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
-- Real path: a rollback switches the `current` link the script may run
-- through, and modules load after that.
local IARA_DIR = vim.uv.fs_realpath(vim.fn.fnamemodify(source, ":p:h:h"))
-- The active configuration must not shadow the checkout being installed.
vim.opt.runtimepath:remove(vim.fn.stdpath("config"))
vim.opt.runtimepath:prepend(IARA_DIR)
package.path = IARA_DIR .. "/scripts/?.lua;" .. package.path

local activate = require("bootstrap.activate")
local candidate = require("bootstrap.candidate")
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")
local manifest = require("bootstrap.manifest")
local owner = require("bootstrap.owner")
local parsers = require("iara.core.parsers")
local provision = require("bootstrap.provision")

local abort, exists, say = common.abort, common.exists, common.say

local MINIMUM_GIT = { 2, 19, 0 }
local USAGE = "usage: nvim -l bootstrap.lua"
  .. " [--launcher PATH | --update | --rollback | --repair]"
local MODE_FLAGS = {
  ["--repair"] = "repair",
  ["--update"] = "update",
  ["--rollback"] = "rollback",
}

local function parse_args(argv)
  local options = { mode = "install" }
  local index = 1
  while argv[index] do
    local value = argv[index]
    if MODE_FLAGS[value] and options.mode == "install" then
      options.mode = MODE_FLAGS[value]
    elseif value == "--launcher" and argv[index + 1] then
      options.launcher = argv[index + 1]
      index = index + 1
    else
      abort("unexpected argument " .. vim.inspect(value) .. "\n" .. USAGE)
    end
    index = index + 1
  end
  if options.launcher and options.mode ~= "install" then
    abort("only an install links a launcher\n" .. USAGE)
  end
  return options
end

---Writes must target an Iara application, never the default `nvim` one.
local function check_identity()
  local name = vim.env.NVIM_APPNAME or ""
  local valid = name == "iara" or name:match("^iara%-[%w_%-]+$") ~= nil
  if not valid then
    abort("NVIM_APPNAME must be 'iara' or 'iara-<suffix>', got '" .. name)
  end
  local config_dir = vim.fn.stdpath("config")
  if vim.fs.basename(config_dir) ~= name then
    abort("unexpected configuration directory " .. config_dir)
  end
end

local function check_git()
  local version = common.git({ "--version" })
  local major, minor = version:match("(%d+)%.(%d+)")
  local found = { tonumber(major) or 0, tonumber(minor) or 0, 0 }
  if vim.version.lt(found, MINIMUM_GIT) then
    abort("Git >= 2.19 is required, found: " .. version)
  end
  return version
end

local function check_launcher(path)
  if not vim.startswith(path, "/") then
    abort("the launcher destination must be absolute: " .. path)
  end
  if vim.fn.isdirectory(vim.fs.dirname(path)) == 0 then
    abort("the launcher directory does not exist: " .. vim.fs.dirname(path))
  end
end

-- Modes ----------------------------------------------------------------

---Paths an install must find unused (and an empty release store).
local function install_destinations(layout, options)
  local data = layout.data
  local paths = {
    vim.fn.stdpath("config"),
    layout.current,
    layout.previous,
    data .. "/lazy",
    data .. "/lazy-lock.json",
    data .. "/treesitter",
    options.launcher,
  }
  local releases = vim.fn.glob(layout.releases .. "/*", true, true)
  return vim.list_extend(paths, releases)
end

local function check_unused(layout, options)
  local taken = vim.tbl_filter(exists, install_destinations(layout, options))
  if #taken > 0 then
    abort(
      "refusing to install over existing paths (nothing was changed):\n  "
        .. table.concat(taken, "\n  ")
        .. "\nTo complete an existing installation use --repair."
    )
  end
end

local function install(context, layout)
  activate.current(layout)
  check_unused(layout, context.options)
  local launcher = context.options.launcher
  local ok, problem = xpcall(function()
    local release = candidate.publish(layout, candidate.build(context, nil))
    activate.promote(layout, release)
  end, common.describe)
  if not ok then
    -- These paths were verified absent above, so this run created them.
    vim.fn.delete(layout.current)
    vim.fn.delete(layout.releases, "rf")
    abort(problem)
  end
  if launcher then
    activate.link(layout.current .. "/config/bin/iara", launcher)
  end
end

---The installation an update starts from: a release, or an installation
---made before releases existed. Its configuration must be a link.
local function check_updatable()
  local paths = lazy.paths()
  if not exists(paths.manager) then
    abort("no installation to update; install first")
  end
  local config_dir = vim.fn.stdpath("config")
  local stat = vim.uv.fs_lstat(config_dir)
  if stat and stat.type ~= "link" then
    abort(config_dir .. " is not a link; move it away and retry")
  end
  return paths
end

local function show_source()
  local own = common.is_checkout_root(IARA_DIR)
  local branch = own
    and common.try_command(
      { "git", "rev-parse", "--abbrev-ref", "HEAD" },
      IARA_DIR
    )
  local revision = own
    and common.try_command({ "git", "rev-parse", "HEAD" }, IARA_DIR)
  say(
    ("checkout %s (%s, %s)"):format(
      IARA_DIR,
      branch or "unknown branch",
      revision or "unknown revision"
    )
  )
end

local function update(context, layout)
  activate.current(layout)
  local active = check_updatable()
  show_source()
  if candidate.unchanged(active) then
    activate.ensure_config_link(layout)
    say("current release already matches the checkout")
    return
  end
  local work, dir = candidate.build(context, active)
  local release = candidate.publish(layout, work, dir)
  local ok, problem = xpcall(activate.promote, common.describe, layout, release)
  if not ok then
    vim.fn.delete(release, "rf")
    abort(problem)
  end
  if not active.release then
    local text = "the previous trees stay in %s (lazy, lazy-lock.json,"
      .. " treesitter); remove them once the new release works"
    say(text:format(layout.data))
  end
  say("restart Iara to use the new release")
end

local function rollback(_, layout)
  local previous, recorded = activate.rollback(layout)
  local revision = recorded.config and recorded.config.revision
  local source = type(revision) == "string" and revision or "unknown revision"
  local text = "rolled back to release %s (configuration %s);"
    .. " restart Iara to use it"
  say(text:format(vim.fs.basename(previous), source))
end

---Repair must use the installed release's own bootstrap and locks: the
---current release's configuration, or for an installation without
---releases the configuration link.
local function check_repairable(layout)
  local installed = vim.uv.fs_realpath(layout.current .. "/config")
    or vim.uv.fs_realpath(vim.fn.stdpath("config"))
  if installed and installed ~= IARA_DIR then
    abort(
      "repair runs the installed release's bootstrap:\n"
        .. lazy.provision_command("repair")
    )
  end
  local data = layout.data
  local markers = { layout.current, data .. "/lazy", data .. "/treesitter" }
  if #vim.tbl_filter(exists, markers) == 0 then
    abort("no installation to repair; install first")
  end
end

local function repair(context, layout)
  activate.current(layout)
  check_repairable(layout)
  local paths = lazy.paths()
  provision.provision(paths, context.lock, context.pins, context.url_format)
  if paths.release then
    manifest.refresh(paths, context)
    activate.ensure_config_link(layout)
  end
end

local MODES =
  { install = install, update = update, rollback = rollback, repair = repair }

---Validate everything a step reads before it writes anything.
local function prepare(options)
  check_identity()
  if options.mode == "rollback" then
    return { options = options }
  end
  local lock, err = lazy.read_lock(IARA_DIR .. "/lazy-lock.json")
  if not lock then
    abort(err.message)
  end
  local pins, pin_err = parsers.read_lock(IARA_DIR .. "/parsers-lock.txt")
  if not pins then
    abort(pin_err.message)
  end
  if options.launcher then
    check_launcher(options.launcher)
  end
  local context = { options = options, lock = lock, pins = pins }
  context.url_format = vim.env.IARA_GIT_URL_FORMAT
    or "https://github.com/%s.git"
  context.git_version = check_git()
  return context
end

local function run(options)
  local context = prepare(options)
  local layout = lazy.layout()
  if options.mode == "install" then
    -- Checked before the owner record exists, so a refusal writes nothing.
    check_unused(layout, options)
  end
  owner.acquire(layout, options.mode)
  local ok, problem =
    xpcall(MODES[options.mode], common.describe, context, layout)
  owner.release(layout)
  if not ok then
    abort(problem)
  end
end

local function main(argv)
  local options = parse_args(argv)
  local ok, problem = xpcall(run, common.describe, options)
  if not ok then
    local retry = lazy.provision_command(options.mode)
    abort(problem .. "\nRetry with: " .. retry)
  end
  say(options.mode .. " complete")
end

local ok, problem = xpcall(main, common.describe, _G.arg or {})
if not ok then
  io.stderr:write("iara bootstrap: " .. problem .. "\n")
  os.exit(1)
end
os.exit(0)
