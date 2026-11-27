--- Eligibility inventory for search (task S2).
---
--- `E` comes from `rg --no-config --files -0` at the root with the hidden
--- and ignored switches; ripgrep owns ignore precedence. Hidden-off also
--- rejects every dot-prefixed component, because ignore negations can
--- whitelist hidden paths without `--hidden`. A path glob builds `G` with
--- `--hidden --no-ignore` and the eligible set is `E ∩ G`, so a positive
--- glob can never widen eligibility. `.git` and worktree administration
--- paths are excluded last, then the scope narrows the result.
---
--- A path is admitted once it passed every check of its walk and, with a
--- glob, appeared in both walks; admitted paths are reported as they
--- stream, so the filename lane can rank them before the barrier. The
--- complete inventory, which content search waits for, is reported once.
---
--- Limits (M2): each walk stops at five seconds from spawn, 100,000
--- retained paths, 16 MiB of retained path bytes, or a retained path
--- above 4 KiB; the first limit hit stops both walks and the result is
--- "incomplete" with what was admitted so far. Paths outside the scope
--- are framed and checked but take no retention slot. A complete `E`
--- (`result.base`) can seed a later build of the same root, scope, and
--- visibility, so a glob change walks only `G`.
--- See contracts.md, section 9.2.
local slots = require("iara.features.search.slots")

local M = {}

local uv = vim.uv
local find, sub = string.find, string.sub

---Per-walk limits for path eligibility.
M.LIMITS = {
  deadline_ms = 5000,
  paths = 100000,
  bytes = 16 * 1024 * 1024,
  path_bytes = 4096,
  -- Raw walk output, retained or not: out-of-scope paths cost streaming
  -- work only, but a runaway walk must still stop.
  stream_bytes = 256 * 1024 * 1024,
}
local MAX_GLOB_BYTES = 1024
---An unterminated walk output tail above this is no retainable path.
local MAX_FRAME_BYTES = 64 * 1024
---A `.git` file larger than this is not a gitfile worth parsing.
local MAX_GITFILE_BYTES = 4096
local PROC_TAG = "iara-search-inventory"
local SCOPE_KINDS = { root = true, directory = true, file = true }

-- These checks run for every walked path; they avoid building strings.

local function is_hidden(path)
  return path:byte(1) == 0x2E or path:find("/.", 1, true) ~= nil
end

local function is_git_metadata(path)
  if not path:find(".git", 1, true) then
    return false
  end
  return ("/" .. path .. "/"):find("/.git/", 1, true) ~= nil
end

local function is_under(path, prefix)
  return path == prefix or vim.startswith(path, prefix .. "/")
end

---Root-relative form of the absolute `path`, "" for the root itself, nil
---when `path` lies outside the root.
local function relative_to(root, path)
  path = vim.fs.normalize(path)
  if path == root then
    return ""
  end
  local prefix = root == "/" and "/" or root .. "/"
  if vim.startswith(path, prefix) then
    return path:sub(#prefix + 1)
  end
end

local function read_small_file(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > MAX_GITFILE_BYTES then
    return nil
  end
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

---Root-relative administration directories of the root's own worktree
---that live inside the root without a `.git` component, for example a
---`--separate-git-dir` target named by a `.git` gitfile.
local function admin_dirs(root)
  local content = read_small_file(root .. "/.git")
  local target = content and content:match("^gitdir:%s*(.-)%s*$")
  if not target or target == "" then
    return {}
  end
  if target:sub(1, 1) ~= "/" then
    target = root .. "/" .. target
  end
  local real = uv.fs_realpath(target)
  local relative = real and relative_to(root, real)
  if not relative or relative == "" then
    return {}
  end
  return { relative }
end

---Predicate accepting root-relative paths inside the scope. Scope
---narrows root eligibility; it never establishes eligibility itself.
local function scope_filter(root, scope)
  if scope.kind == "root" then
    return function()
      return true
    end
  end
  local relative = relative_to(root, scope.path)
  if relative == nil then
    return function()
      return false
    end
  end
  if scope.kind == "file" then
    return function(path)
      return path == relative
    end
  end
  return function(path)
    return relative == "" or is_under(path, relative)
  end
end

local function validate_fields(spec)
  if spec.glob ~= nil and type(spec.glob) ~= "string" then
    error("inventory.build: spec.glob must be a string", 4)
  end
  if type(spec.generation) ~= "number" then
    error("inventory.build: spec.generation must be an integer", 4)
  end
  if spec.base ~= nil and type(spec.base) ~= "table" then
    error("inventory.build: spec.base must be an inventory base", 4)
  end
end

local function validate(spec, on_done, on_progress)
  if type(spec) ~= "table" then
    error("inventory.build: spec must be a table", 3)
  end
  if type(on_done) ~= "function" then
    error("inventory.build: on_done must be a function", 3)
  end
  if on_progress ~= nil and type(on_progress) ~= "function" then
    error("inventory.build: on_progress must be a function", 3)
  end
  if type(spec.root) ~= "string" or spec.root:sub(1, 1) ~= "/" then
    error("inventory.build: spec.root must be an absolute path", 3)
  end
  local scope = spec.scope
  if type(scope) ~= "table" or not SCOPE_KINDS[scope.kind] then
    error("inventory.build: invalid spec.scope", 3)
  end
  local scoped = scope.kind ~= "root"
  if
    scoped and (type(scope.path) ~= "string" or scope.path:sub(1, 1) ~= "/")
  then
    error("inventory.build: scope.path must be an absolute path", 3)
  end
  validate_fields(spec)
end

---Filter error for a glob that cannot reach ripgrep, or nil.
local function glob_error(glob)
  if #glob > MAX_GLOB_BYTES then
    return {
      code = "glob",
      message = ("path glob exceeds %d bytes"):format(MAX_GLOB_BYTES),
    }
  end
  if glob:find("\0", 1, true) then
    return { code = "glob", message = "path glob contains a NUL byte" }
  end
end

---Whether `path` from the `E` walk is eligible for this build.
local function accepts(build, path)
  if not build.hidden and is_hidden(path) then
    return false
  end
  if is_git_metadata(path) then
    return false
  end
  for _, dir in ipairs(build.admin) do
    if is_under(path, dir) then
      return false
    end
  end
  return build.in_scope(path)
end

---Publish once, asynchronously, and stop every walk still running.
local function finish(build, result)
  if build.done then
    return
  end
  build.done = true
  for _, walk in pairs(build.walks) do
    if walk.handle then
      walk.handle:cancel("inventory finished")
    end
  end
  result.generation = build.generation
  result.paths = result.paths or {}
  vim.schedule(function()
    build.on_done(result)
  end)
end

---Report the paths admitted since the last report.
local function report_progress(build)
  local admitted = build.admitted
  if build.done or build.reported == #admitted then
    return
  end
  local fresh = vim.list_slice(admitted, build.reported + 1)
  build.reported = #admitted
  if build.on_progress then
    build.on_progress(fresh)
  end
end

---A limit stops both walks. Admitted paths passed both walks so far, so
---they are eligible, but the inventory is incomplete.
local function stop_incomplete(build, reason)
  report_progress(build)
  finish(build, {
    state = "incomplete",
    reason = reason,
    paths = build.admitted,
  })
end

local function first_line(text)
  local line = (text or ""):match("[^\n]+") or ""
  return line:gsub("^rg: ", "")
end

local function walk_error(walk, result)
  if result.status == "not_found" then
    return { code = "not_found", message = result.error.message }
  end
  if result.status == "spawn_failed" then
    local err = result.error
    return { code = "spawn", message = err.message, uv_error = err.uv_error }
  end
  if result.status == "refused" then
    return { code = "refused", message = result.error.message }
  end
  local message = first_line(result.stderr)
  if walk.name == "g" and message:find("glob", 1, true) then
    return { code = "glob", message = message }
  end
  if message == "" then
    message = ("ripgrep exited with code %d"):format(result.code or -1)
  end
  return { code = "rg", message = message }
end

---Incomplete reason for a walk stopped by its process limits, or nil.
local function limit_reason(result)
  if result.status == "timeout" then
    return "deadline"
  end
  if result.status == "overflow" then
    return "bytes"
  end
end

---Count one retained path against the walk limits. False once a limit
---stopped the build.
local function retain(build, walk, path)
  local limits = M.LIMITS
  if #path > limits.path_bytes then
    stop_incomplete(build, "path_length")
    return false
  end
  walk.count = walk.count + 1
  walk.bytes = walk.bytes + #path
  if walk.count > limits.paths then
    stop_incomplete(build, "paths")
    return false
  end
  if walk.bytes > limits.bytes then
    stop_incomplete(build, "bytes")
    return false
  end
  return true
end

local function admit(build, path)
  local admitted = build.admitted
  admitted[#admitted + 1] = path
end

---`E` paths that pass every check; with a glob, admitted once `G` has
---them too. Without a glob, `walk.list` is `build.admitted`.
local function keep_eligible(build, walk, path)
  if not accepts(build, path) or not retain(build, walk, path) then
    return
  end
  local globbed = build.walks.g
  if not globbed then
    return admit(build, path)
  end
  walk.list[#walk.list + 1] = path
  walk.set[path] = true
  if globbed.set[path] then
    admit(build, path)
  end
end

---`G` paths inside the scope, admitted once `E` accepted them too.
local function keep_in_scope(build, walk, path)
  if is_git_metadata(path) or not build.in_scope(path) then
    return
  end
  if not retain(build, walk, path) then
    return
  end
  walk.set[path] = true
  if build.walks.e.set[path] then
    admit(build, path)
  end
end

---Hold the unterminated tail of a chunk. A tail this long is no path
---the inventory could retain, whatever its scope.
local function hold_partial(build, walk, tail)
  if #tail > MAX_FRAME_BYTES then
    return stop_incomplete(build, "path_length")
  end
  walk.partial = tail
end

---Feed one chunk of NUL-terminated walk output to the walk's checks.
local function on_chunk(build, walk, data)
  local start = 1
  if walk.partial ~= "" then
    local stop = find(data, "\0", 1, true)
    if not stop then
      return hold_partial(build, walk, walk.partial .. data)
    end
    walk.keep(build, walk, walk.partial .. sub(data, 1, stop - 1))
    walk.partial, start = "", stop + 1
  end
  while not build.done do
    local stop = find(data, "\0", start, true)
    if not stop then
      return hold_partial(build, walk, sub(data, start))
    end
    walk.keep(build, walk, sub(data, start, stop - 1))
    start = stop + 1
  end
end

local function all_walks_complete(build)
  for _, walk in pairs(build.walks) do
    if not walk.result then
      return false
    end
  end
  return true
end

---Publish the complete inventory once every walk has finished.
local function complete_if_done(build)
  report_progress(build)
  if build.done or not all_walks_complete(build) then
    return
  end
  local e = build.walks.e
  finish(build, {
    state = "complete",
    paths = build.admitted,
    base = { identity = build.identity, paths = e.list },
  })
end

local function on_walk_complete(build, walk, result)
  walk.result = result
  if build.done then
    return
  end
  if result.status == "cancelled" then
    -- Cancelled from outside the handle (for example proc.cancel_all);
    -- on_done must still run exactly once.
    return finish(build, { state = "cancelled" })
  end
  local reason = limit_reason(result)
  if reason then
    return stop_incomplete(build, reason)
  end
  local succeeded = result.status == "exited"
    and (result.code == 0 or result.code == 1)
  if not succeeded then
    return finish(build, { state = "error", error = walk_error(walk, result) })
  end
  if walk.partial ~= "" then
    walk.keep(build, walk, walk.partial)
    walk.partial = ""
  end
  complete_if_done(build)
end

---Start one `rg --files` walk; `walk.keep` sees each root-relative path.
local function start_walk(build, walk, flags)
  local argv = { "rg", "--no-config", "--files", "-0" }
  vim.list_extend(argv, flags)
  walk.handle = slots.spawn(argv, {
    cwd = build.root,
    timeout_ms = M.LIMITS.deadline_ms,
    tag = PROC_TAG,
    stdout = {
      mode = "chunks",
      max_bytes = M.LIMITS.stream_bytes,
      on_data = function(chunks)
        for _, data in ipairs(chunks) do
          if build.done then
            return
          end
          on_chunk(build, walk, data)
        end
        report_progress(build)
      end,
    },
    on_complete = function(result)
      on_walk_complete(build, walk, result)
    end,
  })
end

local function eligibility_flags(spec)
  local flags = {}
  if spec.hidden then
    table.insert(flags, "--hidden")
  end
  if spec.ignored then
    table.insert(flags, "--no-ignore")
  end
  return flags
end

local function new_walk(name, keep)
  return {
    name = name,
    keep = keep,
    list = {},
    set = {},
    count = 0,
    bytes = 0,
    partial = "",
  }
end

local function new_build(spec, glob, on_done, on_progress)
  local root = vim.fs.normalize(spec.root)
  local build = {
    root = root,
    hidden = spec.hidden == true,
    generation = spec.generation,
    in_scope = scope_filter(root, spec.scope),
    admin = admin_dirs(root),
    on_done = on_done,
    on_progress = on_progress,
    admitted = {},
    reported = 0,
    done = false,
    identity = table.concat({
      root,
      spec.scope.kind,
      spec.scope.path or "",
      tostring(spec.hidden == true),
      tostring(spec.ignored == true),
    }, "\0"),
  }
  -- Both walks exist before either spawns, so each sees the other.
  build.walks = { e = new_walk("e", keep_eligible) }
  if glob then
    build.walks.g = new_walk("g", keep_in_scope)
  else
    build.walks.e.list = build.admitted
  end
  return build
end

---Seed `E` from an earlier complete build with the same identity.
local function reuse_base(build, base)
  local walk = build.walks.e
  walk.result = { status = "exited", code = 0 }
  walk.list = base.paths
  if not build.walks.g then
    build.admitted = base.paths
    return
  end
  for _, path in ipairs(base.paths) do
    walk.set[path] = true
  end
end

---Build the eligible path inventory for `spec`. `on_done` runs exactly
---once, never synchronously; after `cancel()` it reports "cancelled"
---with no paths, so a superseded walk can never publish. An empty glob
---means no glob. `on_progress`, when given, receives each newly
---admitted eligible path once, in arrival order, while the walks run;
---it never runs synchronously, after `on_done` was scheduled, or after
---`cancel()`. `spec.base`, the `base` of an earlier complete result,
---replaces the `E` walk when its root, scope, and switches match.
---Result lists are shared and must not be modified. Raises for a
---malformed spec or a missing `on_done`.
---@param spec IaraInventorySpec
---@param on_done fun(result: IaraInventory)
---@param on_progress fun(paths: string[])?
---@return { cancel: fun(self) } handle
function M.build(spec, on_done, on_progress)
  validate(spec, on_done, on_progress)
  local glob = spec.glob ~= "" and spec.glob or nil
  local build = new_build(spec, glob, on_done, on_progress)
  local handle = {
    cancel = function()
      finish(build, { state = "cancelled" })
    end,
  }
  local invalid = glob and glob_error(glob)
  if invalid then
    finish(build, { state = "error", error = invalid })
    return handle
  end
  local base = spec.base
  if base and base.identity == build.identity then
    reuse_base(build, base)
  else
    start_walk(build, build.walks.e, eligibility_flags(spec))
  end
  if glob then
    local flags = { "--hidden", "--no-ignore", "--glob=" .. glob }
    start_walk(build, build.walks.g, flags)
  elseif build.walks.e.result then
    vim.schedule(function()
      complete_if_done(build)
    end)
  end
  return handle
end

return M
