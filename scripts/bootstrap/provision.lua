-- Provisioning one release: the manager, the plugins at their locked
-- commits, and the pinned parsers. Each is built in an owned temporary
-- directory and published only after it is verified; nothing here
-- replaces a tree found at another revision.
local common = require("bootstrap.common")
local lazy = require("iara.core.lazy")
local parsers = require("iara.core.parsers")

local abort, exists = common.abort, common.exists

local M = {}

local MANAGER_REPO = "folke/lazy.nvim"

---Clone into an owned temporary directory; publish only a verified tree.
local function clone_manager(paths, commit, url_format)
  vim.fn.mkdir(paths.root, "p")
  local work = common.new_temporary(lazy.layout())
  local checkout = work .. "/lazy.nvim"
  local ok, problem = xpcall(function()
    local url = url_format:format(MANAGER_REPO)
    local clone = { "clone", "--quiet", "--no-checkout" }
    common.git(vim.list_extend(clone, { url, checkout }))
    common.git({ "checkout", "--quiet", "--detach", commit }, checkout)
    if common.head(checkout) ~= commit then
      abort("lazy.nvim checkout does not match " .. commit)
    end
    assert(vim.uv.fs_rename(checkout, paths.manager))
  end, common.describe)
  vim.fn.delete(work, "rf")
  if not ok then
    abort(problem)
  end
end

---Reuse a verified manager tree; never replace an unknown one.
local function ensure_manager(paths, lock, url_format)
  local commit = lock[lazy.MANAGER].commit
  if not exists(paths.manager) then
    return clone_manager(paths, commit, url_format)
  end
  local ok, found = pcall(common.head, paths.manager)
  if not ok or found ~= commit then
    local text = "%s is not lazy.nvim at %s; move it away and retry"
    abort(text:format(paths.manager, commit))
  end
  if not common.clean_checkout(paths.manager) then
    abort(paths.manager .. " contains local changes; move it away and retry")
  end
end

---lazy.nvim options for provisioning `paths`: its state stays inside the
---release, and the runtimepath keeps this checkout first.
local function manager_options(paths, url_format)
  local options = lazy.options(require("iara.config").defaults(), paths)
  options.git = { url_format = url_format }
  options.performance = { rtp = { reset = false }, cache = { enabled = false } }
  if paths.release then
    local state = paths.release .. "/state/lazy"
    options.state = state .. "/state.json"
    options.readme = { root = state .. "/readme" }
    options.pkg = { cache = state .. "/pkg-cache.lua" }
  end
  return options
end

---Start the manager with Iara's specs and return the managed plugins.
local function start_manager(paths, url_format)
  -- `nvim -l` turns plugin loading off; lazy.nvim does nothing without it.
  vim.go.loadplugins = true
  vim.opt.runtimepath:prepend(paths.manager)
  require("lazy").setup(manager_options(paths, url_format))
  local plugins = {}
  for _, plugin in pairs(require("lazy.core.config").plugins) do
    if not plugin._.is_local then
      table.insert(plugins, plugin)
    end
  end
  table.sort(plugins, function(a, b)
    return a.name < b.name
  end)
  return plugins
end

local function check_pinned(plugins, lock)
  local unpinned = {}
  for _, plugin in ipairs(plugins) do
    if not lock[plugin.name] then
      table.insert(unpinned, plugin.name)
    end
  end
  if #unpinned > 0 then
    local names = table.concat(unpinned, ", ")
    abort("plugins without a release lock entry: " .. names)
  end
end

local function task_errors(plugin)
  local messages = {}
  for _, task in ipairs(plugin._.tasks or {}) do
    if task:has_errors() then
      table.insert(messages, task:output(vim.log.levels.ERROR))
    end
  end
  return messages
end

---Problems of one plugin after installation.
local function install_problems(plugin)
  local messages = task_errors(plugin)
  -- Headless lazy.nvim records no task error for a failed clone (a
  -- submodule, for example); only the `.cloning` marker it leaves remains,
  -- and lazy.nvim treats such a plugin as not installed.
  if exists(plugin.dir .. ".cloning") then
    table.insert(messages, "clone did not finish (" .. plugin.dir .. ")")
  end
  return messages
end

local function install_plugins(plugins)
  -- Lock-aware install: new clones check out the locked commit, not the
  -- branch head (an install without `lockfile` ignores the pins).
  local manage = require("lazy.manage")
  manage.install({ lockfile = true, wait = true, show = false })
  local failures = {}
  for _, plugin in ipairs(plugins) do
    local messages = install_problems(plugin)
    if #messages > 0 then
      local text = plugin.name .. ": " .. table.concat(messages, "\n")
      table.insert(failures, text)
    end
  end
  if #failures > 0 then
    abort("plugin installation failed:\n" .. table.concat(failures, "\n"))
  end
end

---Waiting for the manager proves nothing; compare every resulting commit.
local function verify_commits(plugins, lock)
  local wrong = {}
  for _, plugin in ipairs(plugins) do
    local expected = lock[plugin.name].commit
    local ok, found = pcall(common.head, plugin.dir)
    if not ok or found ~= expected then
      found = ok and found or "no checkout"
      local text = "%s: expected %s, found %s"
      table.insert(wrong, text:format(plugin.name, expected, found))
    elseif not common.clean_checkout(plugin.dir) then
      table.insert(wrong, plugin.name .. " contains local changes")
    end
  end
  if #wrong > 0 then
    abort("unexpected plugin revisions:\n" .. table.concat(wrong, "\n"))
  end
end

---Pins whose parser is missing; a parser built from another commit stops
---the run instead of being replaced.
local function missing_parsers(pins, dir)
  local missing = {}
  for _, pin in ipairs(pins) do
    local found = parsers.installed_commit(dir, pin.lang)
    if found == nil then
      table.insert(missing, pin)
    elseif found ~= pin.commit then
      local text = "%s was built from %s, the release pins %s; move it"
        .. " away and retry"
      abort(text:format(parsers.parser_path(dir, pin.lang), found, pin.commit))
    end
  end
  return missing
end

---A built parser must carry the pinned stamp and load into this Neovim.
local function validate_parser(dir, pin)
  local found = parsers.installed_commit(dir, pin.lang)
  if found ~= pin.commit then
    local text = "%s parser was built from %s, expected %s"
    abort(text:format(pin.lang, tostring(found), pin.commit))
  end
  -- A private language name keeps the check apart from real buffers.
  local path = parsers.parser_path(dir, pin.lang)
  local options = { path = path, symbol_name = pin.lang }
  local ok, loaded =
    pcall(vim.treesitter.language.add, "iara_check_" .. pin.lang, options)
  if not ok or not loaded then
    abort(("%s parser does not load: %s"):format(pin.lang, tostring(loaded)))
  end
end

---Move a validated parser and its stamp into the runtime directory.
local function publish_parser(work, dir, pin)
  vim.fn.mkdir(dir .. "/parser", "p")
  vim.fn.mkdir(dir .. "/stamps", "p")
  local stamp = "/stamps/" .. pin.lang
  local built = parsers.parser_path(work, pin.lang)
  assert(vim.uv.fs_rename(built, parsers.parser_path(dir, pin.lang)))
  assert(vim.uv.fs_rename(work .. stamp, dir .. stamp))
end

---Build missing parsers in an owned temporary directory with the
---release's scripts/parsers.sh; publish only validated ones.
local function provision_parsers(paths, pins, url_format)
  local missing = missing_parsers(pins, paths.parsers)
  if #missing == 0 then
    return
  end
  local work = common.new_temporary(lazy.layout())
  local ok, problem = xpcall(function()
    local script = paths.iara .. "/scripts/parsers.sh"
    local env = { IARA_GIT_URL_FORMAT = url_format }
    common.say(common.run_command({ "sh", script, work }, nil, env))
    for _, pin in ipairs(missing) do
      validate_parser(work, pin)
    end
    for _, pin in ipairs(missing) do
      publish_parser(work, paths.parsers, pin)
    end
  end, common.describe)
  vim.fn.delete(work, "rf")
  if not ok then
    abort(problem)
  end
end

---Install everything `paths` lacks at the revisions of its lock.
---@param paths IaraLazyPaths
---@param lock table Release lock.
---@param pins IaraParserPin[]
---@param url_format string
function M.provision(paths, lock, pins, url_format)
  ensure_manager(paths, lock, url_format)
  -- lazy.nvim rewrites its lockfile; the release lock must stay unchanged.
  assert(vim.uv.fs_copyfile(paths.release_lock, paths.lock))
  local plugins = start_manager(paths, url_format)
  check_pinned(plugins, lock)
  install_plugins(plugins)
  verify_commits(plugins, lock)
  provision_parsers(paths, pins, url_format)
end

return M
