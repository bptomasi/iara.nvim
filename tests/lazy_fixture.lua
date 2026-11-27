--- Fixtures for provisioning tests: a local mirror of the pinned
--- plugins (cached by their pins, shared by all test files), plugin
--- repositories, and runners for the bootstrap script inside isolated
--- XDG directories.
local helpers = require("helpers")

local fixture = {}

local mirror_root = nil

local function git(args, cwd)
  local argv = vim.list_extend({
    "git",
    "-c",
    "user.name=Iara Test",
    "-c",
    "user.email=test@example.invalid",
    "-c",
    "init.defaultBranch=main",
  }, args)
  local result = vim.system(argv, { cwd = cwd, text = true }):wait(120000)
  if result.code ~= 0 then
    error(table.concat(argv, " ") .. " failed:\n" .. result.stderr, 2)
  end
  return vim.trim(result.stdout)
end
fixture.git = git

---Release lock entry of `name`.
---@param name string
---@return { branch: string, commit: string }
function fixture.release_entry(name)
  local path = helpers.iara_dir .. "/lazy-lock.json"
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))[name]
end

---Collect "owner/repo" names of a lazy.nvim spec and its dependencies.
local function collect_repos(spec, repos)
  if type(spec) == "string" then
    table.insert(repos, spec)
    return
  end
  if type(spec) ~= "table" then
    return
  end
  if type(spec[1]) == "string" then
    table.insert(repos, spec[1])
    collect_repos(spec.dependencies, repos)
    return
  end
  for _, item in ipairs(spec) do
    collect_repos(item, repos)
  end
end

---Repositories of lazy.nvim and of every spec in lua/iara/plugins/.
---@return string[] repos "owner/repo", deduplicated.
function fixture.pinned_repos()
  local repos = { "folke/lazy.nvim" }
  local pattern = helpers.iara_dir .. "/lua/iara/plugins/*.lua"
  for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
    collect_repos(dofile(path), repos)
  end
  local seen, unique = {}, {}
  for _, repo in ipairs(repos) do
    if not seen[repo] then
      seen[repo] = true
      table.insert(unique, repo)
    end
  end
  return unique
end

---Start fetching `entry.commit` of `repo` into a bare mirror.
---@param depth integer|nil Shallow depth; nil fetches full history.
local function fetch_mirror(root, repo, entry, depth)
  local path = root .. "/" .. repo .. ".git"
  vim.fn.mkdir(path, "p")
  git({ "init", "--quiet", "--bare", path })
  git({ "symbolic-ref", "HEAD", "refs/heads/" .. entry.branch }, path)
  local refspec = entry.commit .. ":refs/heads/" .. entry.branch
  local url = "https://github.com/" .. repo
  local argv = { "git", "fetch", "--quiet", url, refspec }
  if depth then
    table.insert(argv, 3, "--depth=" .. depth)
  end
  return vim.system(argv, { cwd = path, text = true })
end

---Start mirroring every grammar pinned in parsers-lock.txt (shallow:
---parsers.sh fetches one commit).
local function fetch_parser_mirrors(root, jobs)
  local pins = assert(require("iara.core.parsers").read_lock())
  for _, pin in ipairs(pins) do
    local entry = { branch = "main", commit = pin.commit }
    jobs[pin.repo] = fetch_mirror(root, pin.repo, entry, 1)
  end
end

-- Submodules that pinned plugins reference by relative URL, which the
-- clone resolves inside the mirror ("../../kmarius/jsregexp" for LuaSnip).
local SUBMODULE_REPOS = { "kmarius/jsregexp" }

---Start fetching every branch and tag of a submodule repository.
local function fetch_submodule_mirror(root, repo)
  local path = root .. "/" .. repo
  vim.fn.mkdir(path, "p")
  git({ "init", "--quiet", "--bare", path })
  local url = "https://github.com/" .. repo
  local argv = { "git", "fetch", "--quiet", "--tags", url }
  table.insert(argv, "+refs/heads/*:refs/heads/*")
  return vim.system(argv, { cwd = path, text = true })
end

---Fetch every pinned commit into bare mirrors below `root`, in parallel.
---@param root string
local function build_mirror(root)
  local jobs = {}
  for _, repo in ipairs(fixture.pinned_repos()) do
    local entry = fixture.release_entry(vim.fs.basename(repo))
    -- Full history: lazy.nvim's partial clones hang on a shallow source.
    jobs[repo] = fetch_mirror(root, repo, entry)
  end
  fetch_parser_mirrors(root, jobs)
  for _, repo in ipairs(SUBMODULE_REPOS) do
    jobs[repo] = fetch_submodule_mirror(root, repo)
  end
  for repo, job in pairs(jobs) do
    local result = job:wait(180000)
    if result.code ~= 0 then
      error("cannot mirror " .. repo .. ":\n" .. (result.stderr or ""))
    end
  end
end

local function mirror_key()
  local paths =
    { "lazy-lock.json", "parsers-lock.txt", "tests/lazy_fixture.lua" }
  local inputs = {}
  for _, path in ipairs(paths) do
    local data = vim.fn.readfile(helpers.iara_dir .. "/" .. path, "b")
    table.insert(inputs, vim.fn.sha256(table.concat(data, "\n")))
  end
  local repos = fixture.pinned_repos()
  table.sort(repos)
  return vim.fn.sha256(vim.json.encode({ inputs, repos }))
end

local function cached_mirror(dir)
  local cache = vim.env.IARA_TEST_MIRROR_CACHE
    or helpers.iara_dir .. "/.tools/test-mirrors"
  local path = require("mirror_cache").get(cache, mirror_key(), build_mirror)
  helpers.write_file(dir .. "/location", path)
end

---URL format of a read-only local mirror at the test suite's pins.
---@return string
function fixture.url_format()
  if not mirror_root then
    local shared = helpers.shared("lazy-mirror", cached_mirror)
    mirror_root = assert(vim.fn.readfile(shared .. "/location")[1])
  end
  return "file://" .. mirror_root .. "/%s.git"
end

---Create a repository with two commits on main.
---@return { path: string, first: string, second: string }
function fixture.plugin_repo()
  local path = helpers.temp_dir() .. "/fixture-plugin"
  vim.fn.mkdir(path .. "/lua/fixture_plugin", "p")
  git({ "init", "--quiet", path })
  local module = path .. "/lua/fixture_plugin/init.lua"
  helpers.write_file(module, "return { version = 1 }\n")
  git({ "add", "." }, path)
  git({ "commit", "--quiet", "-m", "first" }, path)
  local first = git({ "rev-parse", "HEAD" }, path)
  helpers.write_file(module, "return { version = 2 }\n")
  git({ "commit", "--quiet", "-am", "second" }, path)
  return {
    path = path,
    first = first,
    second = git({ "rev-parse", "HEAD" }, path),
  }
end

---Copy of the distribution that can receive extra specs and lock entries.
---@param specs string|nil Source of lua/iara/plugins/fixture.lua.
---@param lock_entries table|nil Entries added to the release lock.
---@return string iara_dir
function fixture.checkout(specs, lock_entries)
  local dir = helpers.temp_dir() .. "/iara"
  vim.fn.mkdir(dir, "p")
  local files =
    { "init.lua", "lua", "colors", "scripts", "bin", "parsers-lock.txt" }
  for _, name in ipairs(files) do
    vim.fn.system({ "cp", "-R", helpers.iara_dir .. "/" .. name, dir })
  end
  local lock = vim.json.decode(
    table.concat(vim.fn.readfile(helpers.iara_dir .. "/lazy-lock.json"), "\n")
  )
  lock = vim.tbl_extend("force", lock, lock_entries or {})
  helpers.write_file(dir .. "/lazy-lock.json", vim.json.encode(lock))
  if specs then
    helpers.write_file(dir .. "/lua/iara/plugins/fixture.lua", specs)
  end
  return dir
end

---Run the bootstrap script of `iara_dir` with `env`.
---@param env table<string, string>
---@param args string[]|nil
---@param iara_dir string|nil Defaults to the repository's distribution.
---@return HelpersRunResult
function fixture.bootstrap(env, args, iara_dir)
  local script = (iara_dir or helpers.iara_dir) .. "/scripts/bootstrap.lua"
  local argv = vim.list_extend({ vim.v.progpath, "-l", script }, args or {})
  env = vim.tbl_extend("keep", env, {
    IARA_GIT_URL_FORMAT = fixture.url_format(),
    -- Git refuses file:// submodules by default; the mirror needs them.
    GIT_CONFIG_COUNT = "1",
    GIT_CONFIG_KEY_0 = "protocol.file.allow",
    GIT_CONFIG_VALUE_0 = "always",
  })
  local process = vim.system(argv, {
    env = env,
    cwd = helpers.temp_dir(),
    text = true,
  })
  -- A full install clones every plugin and starts the candidate once.
  local result = process:wait(120000)
  if result.signal ~= 0 then
    error("bootstrap timed out or was killed", 2)
  end
  return { code = result.code, stdout = result.stdout, stderr = result.stderr }
end

---Provision a copied checkout into a fresh isolated environment.
---@param specs string|nil See fixture.checkout().
---@param lock_entries table|nil
---@return table<string, string> env
---@return string iara_dir
function fixture.provisioned(specs, lock_entries)
  local checkout = fixture.checkout(specs, lock_entries)
  local env = helpers.isolated_env()
  local result = fixture.bootstrap(env, {}, checkout)
  if result.code ~= 0 then
    error("bootstrap failed:\n" .. result.stderr)
  end
  return env, checkout
end

---Start Neovim headless, run `commands`, and quit.
---@param env table<string, string>
---@param commands string[] Ex commands run after startup.
---@param opts { init: string|nil, cwd: string|nil }|nil
---@return HelpersRunResult
function fixture.start(env, commands, opts)
  opts = opts or {}
  local argv = { vim.v.progpath, "--headless" }
  if opts.init then
    vim.list_extend(argv, { "-u", opts.init })
  end
  for _, command in ipairs(commands) do
    table.insert(argv, "+" .. command)
  end
  table.insert(argv, "+qa!")
  return helpers.run(argv, { env = env, cwd = opts.cwd or helpers.temp_dir() })
end

---Absolute standard paths of an isolated environment; `current` and
---`previous` are the release links in the data directory.
---@param env table<string, string>
---@return { config: string, data: string, current: string, previous: string }
function fixture.std_paths(env)
  local data = env.XDG_DATA_HOME .. "/" .. env.NVIM_APPNAME
  return {
    config = env.XDG_CONFIG_HOME .. "/" .. env.NVIM_APPNAME,
    data = data,
    current = data .. "/current",
    previous = data .. "/previous",
  }
end

return fixture
