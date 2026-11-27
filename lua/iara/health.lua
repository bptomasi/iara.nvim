--- `:checkhealth iara`: installation state, plugins, and external tools.
--- Health runs only on request, so it may read files and run short
--- version commands synchronously.
local lazy = require("iara.core.lazy")
local parsers = require("iara.core.parsers")

local M = {}

local health = vim.health

---External tools: what each one enables and how bad its absence is.
local TOOLS = {
  { "git", "plugin provisioning (>= 2.19)", "error" },
  { "rg", "project content search", "error" },
  -- Formatting is optional and only runs on request.
  { "stylua", "the optional Lua formatting (:IaraFormat)", "info" },
  { "tree-sitter", "parser builds (>= 0.26.1)", "warn" },
  { "cc", "parser builds", "warn" },
  { "tar", "parser downloads", "warn" },
  { "curl", "parser downloads", "warn" },
  { "claude", "the optional Claude Code session", "info" },
  { "codex", "the optional Codex session", "info" },
}

local function report_mode()
  local mode = vim.g.iara_mode
  local status = require("iara").status()
  if mode == "safe" then
    local reason = status and status.reason or "unknown"
    health.warn(
      ("safe mode (%s): plugins and personal hooks are off"):format(reason),
      { "Fix the reported error and restart, or unset IARA_SAFE." }
    )
  elseif mode == "full" then
    health.ok("full mode")
  else
    health.warn("Iara did not start (no mode recorded)")
  end
  health.info("NVIM_APPNAME: " .. (vim.env.NVIM_APPNAME or "(unset)"))
end

local function report_manager(paths, lock)
  local repair = { "Run: " .. lazy.provision_command("repair") }
  local found = lazy.checkout_commit(paths.manager)
  if not vim.uv.fs_stat(paths.manager) then
    health.error("lazy.nvim is not installed at " .. paths.manager, repair)
  elseif found == lock[lazy.MANAGER].commit then
    health.ok("lazy.nvim at the release commit " .. found)
  else
    health.warn(
      ("lazy.nvim is at %s, the release pins %s"):format(
        found or "an unknown revision",
        lock[lazy.MANAGER].commit
      ),
      { "Restore it with :Lazy restore, then restart." }
    )
  end
end

local function report_plugins(paths, lock)
  local missing = {}
  for name in pairs(lock) do
    if not vim.uv.fs_stat(paths.root .. "/" .. name) then
      table.insert(missing, name)
    end
  end
  table.sort(missing)
  if #missing == 0 then
    health.ok(
      ("all %d locked plugins are installed"):format(#vim.tbl_keys(lock))
    )
    return
  end
  health.error("missing plugins: " .. table.concat(missing, ", "), {
    "They stay disabled until repaired. Run :IaraRepair, or: "
      .. lazy.provision_command("repair"),
  })
end

---Personal specs are not in the release lock, so repair skips them.
local function report_unlocked(lock)
  local loaded, config = pcall(require, "lazy.core.config")
  if not loaded or not config.plugins then
    return
  end
  for name, plugin in pairs(config.plugins) do
    if not lock[name] and not plugin._.installed then
      health.warn(
        "personal plugin " .. name .. " is not installed",
        { "Install it deliberately with :Lazy install " .. name }
      )
    end
  end
end

local function report_owner()
  local record, state = lazy.owner()
  if not record then
    return
  end
  local text = "provisioning run (pid %s, %s, started %s)"
  text = text:format(record.pid, record.mode, record.started)
  if state == "live" then
    health.warn(text .. " is in progress; restart when it finishes")
    return
  end
  health.error("an interrupted " .. text .. " left " .. lazy.layout().owner, {
    "Run: " .. lazy.provision_command("repair"),
  })
end

local function release_name(dir)
  local manifest = lazy.read_manifest(dir)
  local revision = manifest and manifest.config and manifest.config.revision
  local text = vim.fs.basename(dir)
  if type(revision) == "string" then
    text = text .. " (configuration " .. revision .. ")"
  end
  return text
end

local function report_releases()
  health.start("Releases")
  report_owner()
  local current = lazy.release_dir("current")
  if not current then
    health.info(
      "installation without releases: rollback is unavailable",
      { "Create a release with: " .. lazy.provision_command("update") }
    )
    return
  end
  health.ok("current release " .. release_name(current))
  local previous = lazy.release_dir("previous")
  if previous then
    health.ok("previous release kept for rollback " .. release_name(previous))
  else
    health.info("no previous release: rollback is unavailable")
  end
end

local function report_installation()
  health.start("Plugins")
  local paths = lazy.paths()
  local lock, err = lazy.read_lock(paths.release_lock)
  if not lock then
    health.error("release lock: " .. err.message)
    return
  end
  health.ok("release lock " .. paths.release_lock)
  report_manager(paths, lock)
  report_plugins(paths, lock)
  report_unlocked(lock)
end

---Where a pin's parser is found: the installation first, then a
---development build. Returns the directory and the commit found there.
local function locate_parser(lang)
  for _, dir in ipairs(parsers.runtime_dirs()) do
    local found = parsers.installed_commit(dir, lang)
    if found then
      return dir, found
    end
  end
end

local function report_parser(pin)
  local repair = { "Run: " .. lazy.provision_command("repair") }
  local dir, found = locate_parser(pin.lang)
  local path = dir and parsers.parser_path(dir, pin.lang)
  if not dir then
    local text = "%s parser is missing (pinned %s %s)"
    health.error(text:format(pin.lang, pin.repo, pin.commit), repair)
  elseif found == pin.commit then
    local text = "%s parser at the pinned commit %s (%s)"
    health.ok(text:format(pin.lang, found, path))
  else
    local text = "%s parser was built from %s, the release pins %s"
    health.warn(text:format(pin.lang, found, pin.commit), {
      ("Move %s away, then run: %s"):format(
        path,
        lazy.provision_command("repair")
      ),
    })
  end
end

local function report_parsers()
  health.start("Tree-sitter parsers")
  local pins, err = parsers.read_lock()
  if not pins then
    health.error("parser lock: " .. err.message)
    return
  end
  for _, pin in ipairs(pins) do
    report_parser(pin)
  end
end

local function report_tools()
  health.start("External tools")
  for _, tool in ipairs(TOOLS) do
    local name, purpose, level = tool[1], tool[2], tool[3]
    local path = vim.fn.exepath(name)
    if path ~= "" then
      health.ok(("%s: %s"):format(name, path))
    else
      local message = ("%s not found; needed for %s"):format(name, purpose)
      local advice = { "Install " .. name .. " and make it available on PATH." }
      health[level](message, level ~= "info" and advice or nil)
    end
  end
end

---Entry point of `:checkhealth iara`. Also gives the health buffer the
---Iara look (`iara.core.health_look`) once the checks are written.
function M.check()
  require("iara.core.health_look").attach()
  health.start("Mode")
  report_mode()
  report_releases()
  report_installation()
  report_parsers()
  report_tools()
end

return M
