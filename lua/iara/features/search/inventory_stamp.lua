--- Filesystem dependencies of a complete inventory. Runs in a libuv
--- worker, before a cold walk or before admitting a cached result.
local uv = vim.uv
local M = {}

local MAX_DIRS = 1024
local MAX_ENTRIES = 70000
local MAX_POLICY_BYTES = 64 * 1024
local BUDGET_NS = 45 * 1e6
local RULES = { ".gitignore", ".ignore", ".rgignore" }
local MARKERS = {
  [".git"] = true,
  [".jj"] = true,
  [".gitignore"] = true,
  [".ignore"] = true,
  [".rgignore"] = true,
}

local function join(dir, name)
  return (dir == "/" and "" or dir) .. "/" .. name
end

local function absolute(dir, name)
  return name:sub(1, 1) == "/" and name or join(dir, name)
end

local function stat(path)
  local info, err, code = uv.fs_stat(path)
  if not info and code ~= "ENOENT" and code ~= "ENOTDIR" then
    error(err)
  end
  return info
end

local function signature(info)
  if not info then
    return false
  end
  return table.concat({
    info.dev,
    info.ino,
    info.mode,
    info.size,
    info.mtime.sec,
    info.mtime.nsec,
    info.ctime.sec,
    info.ctime.nsec,
  }, ":")
end

local function remember(snapshot, path)
  local info = stat(path)
  snapshot[path] = signature(info)
  return info
end

local function read_policy(snapshot, path)
  local info = remember(snapshot, path)
  if not info then
    return nil
  end
  assert(info.type == "file" and info.size <= MAX_POLICY_BYTES)
  local fd = assert(uv.fs_open(path, uv.constants.O_NONBLOCK, 0))
  local opened = uv.fs_fstat(fd)
  local bytes = opened
    and opened.type == "file"
    and uv.fs_read(fd, MAX_POLICY_BYTES + 1, 0)
  uv.fs_close(fd)
  assert(
    bytes and #bytes <= MAX_POLICY_BYTES and signature(opened) == snapshot[path]
  )
  return bytes
end

local function git_directory(snapshot, directory, marker)
  if marker.type == "directory" then
    return join(directory, ".git")
  end
  local gitfile = join(directory, ".git")
  local target = (read_policy(snapshot, gitfile) or ""):match(
    "^gitdir: (.-)%s*$"
  )
  assert(target and target ~= "" and #target <= 4096)
  local raw = absolute(directory, target)
  local gitdir = assert(uv.fs_realpath(raw))
  snapshot[raw] = signature(stat(raw))
  local common = read_policy(snapshot, join(gitdir, "commondir"))
  return common and absolute(gitdir, common:match("^%s*(.-)%s*$")) or gitdir
end

local function check_git(snapshot, dir, ignored)
  local git = join(dir, ".git")
  local marker = stat(git)
  -- Writes to refs or the index don't affect path eligibility.
  snapshot[git] = marker and marker.type or false
  if marker and marker.type ~= "directory" then
    remember(snapshot, git)
  end
  if marker and (not ignored or marker.type == "file") then
    local gitdir = git_directory(snapshot, dir, marker)
    if not ignored then
      remember(snapshot, join(gitdir, "info/exclude"))
    end
  end
end

local function policies(snapshot, dir, ignored, found)
  if not found or found[".git"] then
    check_git(snapshot, dir, ignored)
  end
  if ignored then
    return
  end
  local jj = join(dir, ".jj")
  if not found or found[".jj"] then
    snapshot[jj] = stat(jj) and "present" or false
  end
  for _, rule in ipairs(RULES) do
    if not found or found[rule] then
      remember(snapshot, join(dir, rule))
    end
  end
end

local ENV =
  { "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM" }
local function environment()
  local values = {}
  for index, key in ipairs(ENV) do
    values[index] = uv.os_getenv(key) or ""
  end
  return values
end

local function global_config(snapshot, root, path, home)
  if not path then
    return
  end
  local text = read_policy(snapshot, absolute(root, path)) or ""
  for line in text:gmatch("[^\n]+") do
    local lower = line:lower()
    -- An included config may introduce external paths outside this list.
    assert(not lower:match("^%s*%[include"))
    if lower:match("^%s*excludesfile%s*=") then
      local path_value = line:match('=%s*"?([^"%s]+)"?%s*$')
      assert(path_value and not path_value:find("\0", 1, true))
      local path_name = path_value:gsub("~", function()
        return home
      end)
      remember(snapshot, absolute(root, path_name))
    end
  end
end

local function global_rules(snapshot, root, env)
  local home, xdg, global, system = unpack(env)
  if home == "" then
    home = uv.os_homedir()
  end
  assert(home and home ~= "")
  if xdg == "" then
    xdg = join(home, ".config")
  end
  global_config(snapshot, root, join(home, ".gitconfig"), home)
  global_config(snapshot, root, join(xdg, "git/config"), home)
  global_config(snapshot, root, global ~= "" and global or nil, home)
  global_config(
    snapshot,
    root,
    system ~= "" and system or "/etc/gitconfig",
    home
  )
  remember(snapshot, absolute(root, join(xdg, "git/ignore")))
end

local function expired(start)
  return uv.hrtime() - start >= BUDGET_NS
end

local function visit_entry(queue, dir, hidden, entry, found)
  if not entry.type or entry.type == "unknown" then
    return false
  end
  local name = entry.name
  if MARKERS[name] then
    found[name] = true
  end
  if
    entry.type == "directory"
    and name ~= ".git"
    and (hidden or name:sub(1, 1) ~= ".")
  then
    queue[#queue + 1] = join(dir, name)
  end
  return #queue <= MAX_DIRS
end

local function visit_entries(queue, handle, dir, limits, found)
  while true do
    local entries, err = uv.fs_readdir(handle)
    if not entries then
      return not err
    end
    limits.entries = limits.entries + #entries
    if limits.entries > MAX_ENTRIES or expired(limits.started) then
      return false
    end
    for _, entry in ipairs(entries) do
      if not visit_entry(queue, dir, limits.hidden, entry, found) then
        return false
      end
    end
  end
end

local function tree(snapshot, root, hidden, ignored, started)
  local queue = { root }
  local limits = { hidden = hidden, entries = 0, started = started }
  for _, directory in ipairs(queue) do
    assert(not expired(started))
    local info = remember(snapshot, directory)
    assert(info and info.type == "directory")
    local found = {}
    local handle = assert(uv.fs_opendir(directory, nil, 128))
    local ok = visit_entries(queue, handle, directory, limits, found)
    uv.fs_closedir(handle)
    assert(ok)
    policies(snapshot, directory, ignored, found)
  end
end

local function ancestors(snapshot, root, ignored)
  local dir = root
  while dir ~= "/" do
    dir = dir:match("^(.*)/[^/]+$")
    dir = dir ~= "" and dir or "/"
    policies(snapshot, dir, ignored)
  end
end

local function current_stamp(path, old)
  local info = stat(path)
  if old == "present" then
    return info and "present" or false
  end
  if old == "directory" or path:sub(-4) == "/.git" and old == false then
    return info and info.type or false
  end
  return signature(info)
end

local function matches(entry, canonical, rg, env, started)
  if
    entry.root ~= canonical
    or entry.rg ~= rg
    or table.concat(entry.env, "\0") ~= table.concat(env, "\0")
  then
    return false
  end
  for path, old in pairs(entry.files) do
    if expired(started) or current_stamp(path, old) ~= old then
      return false
    end
  end
  return true
end

---Validate a token or capture dependencies before starting a new walk.
---@return boolean hit, string token
function M.check(root, hidden, ignored, rg, token)
  local started = uv.hrtime()
  local canonical = assert(uv.fs_realpath(root))
  local env = environment()
  if
    token ~= ""
    and matches(vim.mpack.decode(token), canonical, rg, env, started)
  then
    return true, token
  end
  local files = {}
  assert(remember(files, rg))
  if not ignored then
    global_rules(files, canonical, env)
  end
  ancestors(files, canonical, ignored)
  tree(files, canonical, hidden, ignored, started)
  return false,
    vim.mpack.encode({ root = canonical, rg = rg, env = env, files = files })
end

return M
