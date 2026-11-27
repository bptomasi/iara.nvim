-- Helpers shared by the bootstrap modules: user-facing errors, progress,
-- external commands, and checksums. See scripts/bootstrap.lua.
local M = {}

local source = debug.getinfo(1, "S").source:gsub("^@", "")

---The distribution the running bootstrap belongs to, as a real path:
---a rollback switches the `current` link the script may run through.
M.IARA_DIR = vim.uv.fs_realpath(vim.fn.fnamemodify(source, ":p:h:h:h"))

---Stop with a message for the user (not a defect in the script).
---@param message string
function M.abort(message)
  error({ message = message }, 0)
end

---Message for an error: user-facing text, or a traceback for a defect.
---@param err any
---@return string
function M.describe(err)
  if type(err) == "table" and err.message then
    return err.message
  end
  return debug.traceback(tostring(err), 2)
end

---Run `body`; on failure remove `work` and stop with its message.
---@param work string Owned temporary directory.
---@param body fun()
function M.guarded(work, body)
  local ok, problem = xpcall(body, M.describe)
  if not ok then
    vim.fn.delete(work, "rf")
    M.abort(problem)
  end
end

---Progress for the user on stdout (`print` writes to stderr under -l).
---@param text string
function M.say(text)
  io.stdout:write(text, "\n")
end

---The path exists; lstat also sees dangling symlinks.
---@param path string
---@return boolean
function M.exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

---@return string
function M.utc_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---Run `argv`, stop on failure, and return its trimmed output.
---@param argv string[]
---@param cwd string|nil
---@param env table<string, string>|nil
---@return string
function M.run_command(argv, cwd, env)
  local options = { cwd = cwd, env = env, text = true }
  local ok, process = pcall(vim.system, argv, options)
  if not ok then
    M.abort("cannot run " .. argv[1] .. ": " .. tostring(process))
  end
  local result = process:wait()
  if result.code ~= 0 then
    local text = "command failed (exit %d): %s\n%s"
    M.abort(text:format(result.code, table.concat(argv, " "), result.stderr))
  end
  return vim.trim(result.stdout)
end

---Output of `argv`, or nil when it cannot run or fails.
---@param argv string[]
---@param cwd string|nil
---@return string|nil
function M.try_command(argv, cwd)
  local ok, output = pcall(M.run_command, argv, cwd)
  return ok and output or nil
end

---@param args string[]
---@param cwd string|nil
---@return string
function M.git(args, cwd)
  return M.run_command(vim.list_extend({ "git" }, args), cwd)
end

---Whether Git identifies `dir` as the root of its own checkout.
---@param dir string
---@return boolean
function M.is_checkout_root(dir)
  if not M.exists(dir .. "/.git") then
    return false
  end
  local top = M.try_command({ "git", "rev-parse", "--show-toplevel" }, dir)
  return top ~= nil and vim.uv.fs_realpath(top) == vim.uv.fs_realpath(dir)
end

---Commit checked out in `dir`, which must be a checkout of its own.
---@param dir string
---@return string
function M.head(dir)
  -- Without its own .git, git would report an enclosing repository.
  if not M.exists(dir .. "/.git") then
    M.abort(dir .. " is not a Git checkout")
  end
  return M.git({ "rev-parse", "HEAD" }, dir)
end

---Whether a checkout has local source changes or untracked files.
---@param dir string
---@return boolean
function M.clean_checkout(dir)
  local args = {
    "git",
    "--no-optional-locks",
    "status",
    "--porcelain",
    "--untracked-files=all",
    "--ignore-submodules=none",
  }
  return M.try_command(args, dir) == ""
end

---@param path string
---@return string
function M.sha256(path)
  return M.run_command({ "sha256sum", path }):match("^(%x+)")
end

---Checksums of `names` (relative to `dir`), in one `sha256sum` call per
---batch; output lines follow the argument order.
---@param dir string
---@param names string[]
---@return table<string, string> sums By name.
function M.sha256_all(dir, names)
  local sums, batch = {}, 200
  for first = 1, #names, batch do
    local slice = vim.list_slice(names, first, first + batch - 1)
    local argv = vim.list_extend({ "sha256sum", "--" }, slice)
    local lines = vim.split(M.run_command(argv, dir), "\n")
    for index, name in ipairs(slice) do
      sums[name] = lines[index]:match("^\\?(%x+)")
    end
  end
  return sums
end

---A new owned temporary directory inside the data directory.
---@param layout IaraLayout
---@return string
function M.new_temporary(layout)
  vim.fn.mkdir(layout.data, "p")
  return assert(vim.uv.fs_mkdtemp(layout.data .. "/iara-tmp-XXXXXX"))
end

return M
