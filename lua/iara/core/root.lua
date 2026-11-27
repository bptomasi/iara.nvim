--- Project root resolution.
---
--- Order: session-wide override, nearest ancestor containing `.git`
--- (directory or worktree file) of the invoking editing buffer, then the
--- directory captured at startup. Results are cached per buffer and never
--- change the working directory. See contracts.md, section
--- `iara.core.root`.
local M = {}

local uv = vim.uv

---@class IaraRoot
---@field path string Absolute canonical directory (realpath).
---@field provenance "override"|"git"|"startup"
---@field worktree_id string "git:<realpath>" or "dir:<realpath>".
---@field label string Short display text, for example "iara (git)".

---@type string|nil Canonical override directory.
local override_path = nil

---A cached root and the buffer's context root it was computed from.
---@class IaraRootCacheEntry
---@field root IaraRoot
---@field context string|nil Value of `vim.b.iara_context_root` at resolution.

---@type table<integer, IaraRootCacheEntry>
local cache = {}

local configured = false

local function is_directory(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Canonical form of the nearest existing directory at or above `path`,
---so new files in missing directories and removed directories still
---resolve through their surviving ancestors.
local function nearest_existing(path)
  local current = vim.fs.normalize(path)
  while true do
    local real = uv.fs_realpath(current)
    if real and is_directory(real) then
      return vim.fs.normalize(real)
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      return nil
    end
    current = parent
  end
end

local function has_git_marker(dir)
  return uv.fs_stat(vim.fs.joinpath(dir, ".git")) ~= nil
end

---Directories listed in $GIT_CEILING_DIRECTORIES, canonicalized.
---@return table<string, true>
local function ceiling_dirs()
  local ceilings = {}
  local value = vim.env.GIT_CEILING_DIRECTORIES or ""
  for entry in vim.gsplit(value, ":", { plain = true, trimempty = true }) do
    local real = uv.fs_realpath(entry)
    ceilings[vim.fs.normalize(real or entry)] = true
  end
  return ceilings
end

---Nearest directory at or above `dir` with a `.git` marker. Like Git's
---own discovery, the upward walk never enters a ceiling directory, so
---Iara and Git agree on which repository a file belongs to.
local function find_git_top(dir)
  if has_git_marker(dir) then
    return dir
  end
  local ceilings = ceiling_dirs()
  for parent in vim.fs.parents(dir) do
    if ceilings[parent] then
      return nil
    end
    if has_git_marker(parent) then
      return parent
    end
  end
  return nil
end

---@param path string Canonical directory.
---@param provenance "override"|"git"|"startup"
---@return IaraRoot
local function make_root(path, provenance)
  -- Identity follows the canonical path only, so aliases share it and
  -- separate worktrees of one repository never do.
  local kind = has_git_marker(path) and "git:" or "dir:"
  local name = vim.fs.basename(path)
  return {
    path = path,
    provenance = provenance,
    worktree_id = kind .. path,
    label = (name ~= "" and name or path) .. " (" .. provenance .. ")",
  }
end

local function startup_root()
  local dir = require("iara").startup_dir()
  local real = uv.fs_realpath(dir)
  return make_root(vim.fs.normalize(real or dir), "startup")
end

---Directory the search starts from, or nil when the buffer has no
---usable editing context.
local function context_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype == "" and name ~= "" then
    return nearest_existing(vim.fs.dirname(name))
  end
  local context = vim.b[bufnr].iara_context_root
  if type(context) == "string" and is_directory(context) then
    return vim.fs.normalize(uv.fs_realpath(context) or context)
  end
  return nil
end

local function compute(bufnr)
  if override_path then
    return make_root(override_path, "override")
  end
  local dir = context_dir(bufnr)
  local top = dir and find_git_top(dir)
  if top then
    return make_root(top, "git")
  end
  return startup_root()
end

---The buffer's context root as a comparable value (only strings count;
---reading a table from `vim.b` yields a new copy every time).
---@return string|nil
local function context_value(bufnr)
  local value = vim.b[bufnr].iara_context_root
  return type(value) == "string" and value or nil
end

---Cached root of `bufnr` if still valid: an owner may set or change the
---buffer's context root after it was first resolved, so a different
---context value invalidates the entry without polling.
---@return IaraRoot|nil
local function fresh_cached(bufnr)
  local entry = cache[bufnr]
  if not entry or entry.context ~= context_value(bufnr) then
    return nil
  end
  return entry.root
end

local function buffer_handle(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    error("iara.core.root: invalid buffer " .. tostring(bufnr), 3)
  end
  return bufnr
end

---Resolve the root for an editing buffer: session override, then the
---nearest ancestor containing `.git`, then the startup directory. Never
---changes the working directory and runs no subprocess. A change of
---`vim.b[bufnr].iara_context_root` since the cached resolution makes it
---resolve again.
---@param bufnr integer? 0 or nil for the current buffer.
---@return IaraRoot
function M.resolve(bufnr)
  bufnr = buffer_handle(bufnr)
  local cached = fresh_cached(bufnr)
  if cached and is_directory(cached.path) then
    return cached
  end
  local root = compute(bufnr)
  cache[bufnr] = { root = root, context = context_value(bufnr) }
  return root
end

local function notify_change(bufnr, cause, previous, root)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "IaraRootChanged",
    data = { bufnr = bufnr, cause = cause, root = root, previous = previous },
    modeline = false,
  })
end

---Drop cached roots and announce the change. `bufnr` nil means every
---buffer (a session-wide cause).
local function invalidate(bufnr, cause)
  local subject = bufnr or vim.api.nvim_get_current_buf()
  local previous = cache[subject] and cache[subject].root
  if bufnr then
    cache[bufnr] = nil
  else
    cache = {}
  end
  if vim.api.nvim_buf_is_valid(subject) then
    notify_change(bufnr, cause, previous, M.resolve(subject))
  end
end

local function absolute_from_startup(path)
  local expanded = vim.fs.normalize(path)
  if vim.fn.isabsolutepath(expanded) == 1 then
    return expanded
  end
  local base = require("iara").startup_dir()
  return vim.fs.normalize(vim.fs.joinpath(base, expanded))
end

---Session-wide override. Relative paths resolve against the startup
---directory. Error codes: "not_directory".
---@param path string
---@return IaraRoot|nil root
---@return IaraError|nil err
function M.set_override(path)
  if type(path) ~= "string" then
    error("iara.core.root: path must be a string", 2)
  end
  local absolute = absolute_from_startup(path)
  local real = uv.fs_realpath(absolute)
  if not real or not is_directory(real) then
    return nil,
      { code = "not_directory", message = "not a directory: " .. absolute }
  end
  override_path = vim.fs.normalize(real)
  invalidate(nil, "override")
  return M.resolve(0), nil
end

---Remove the session override; does nothing when none is set.
function M.clear_override()
  if not override_path then
    return
  end
  override_path = nil
  invalidate(nil, "reset")
end

---@return string|nil path Current override, if any.
function M.override()
  return override_path
end

---Re-resolve after repository-marker changes (explicit refresh).
---@param bufnr integer? A buffer (0 for the current one), or nil for all.
function M.refresh(bufnr)
  if bufnr ~= nil then
    bufnr = buffer_handle(bufnr)
  end
  invalidate(bufnr, "refresh")
end

---@return string text For the statusline, for example "iara (git)".
function M.statusline()
  -- Redraws happen while typing; reuse the cache without touching disk.
  local cached = fresh_cached(vim.api.nvim_get_current_buf())
  return (cached or M.resolve(0)).label
end

local function show_root()
  local root = M.resolve(0)
  local text = ("Iara: root %s (%s)"):format(root.path, root.provenance)
  vim.notify(text, vim.log.levels.INFO)
end

local function set_from_command(args)
  local _, err = M.set_override(args.args)
  if err then
    vim.notify("Iara: " .. err.message, vim.log.levels.ERROR)
    return
  end
  show_root()
end

local function create_commands()
  local command = vim.api.nvim_create_user_command
  command("IaraRoot", show_root, { desc = "Show the project root" })
  command("IaraRootSet", set_from_command, {
    nargs = 1,
    complete = "dir",
    desc = "Override the project root for this session",
  })
  command("IaraRootReset", M.clear_override, {
    desc = "Remove the project root override",
  })
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup("IaraRoot", { clear = true })
  local autocmd = vim.api.nvim_create_autocmd
  autocmd("BufFilePost", {
    group = group,
    callback = function(args)
      invalidate(args.buf, "rename")
    end,
  })
  autocmd("DirChanged", {
    group = group,
    callback = function()
      invalidate(nil, "dirchange")
    end,
  })
  autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      cache[args.buf] = nil
    end,
  })
end

---Register commands and cache invalidation. Idempotent.
---@param _ table? Composed configuration (unused).
function M.setup(_)
  if configured then
    return
  end
  configured = true
  create_commands()
  create_autocmds()
end

return M
