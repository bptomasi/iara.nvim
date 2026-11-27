---Publish a complete mirror atomically so later suites can use it offline.
local M = {}

---@param root string Cache directory.
---@param key string Content fingerprint for the inputs to build.
---@param build fun(dir: string)
---@return string
function M.get(root, key, build)
  local target = vim.fs.joinpath(root, key)
  if vim.uv.fs_stat(target) then
    return target
  end
  pcall(vim.fn.mkdir, root, "p")
  local stage = assert(vim.uv.fs_mkdtemp(root .. "/building-XXXXXX"))
  local ok, problem = pcall(build, stage)
  if ok then
    local published, err = vim.uv.fs_rename(stage, target)
    if published then
      return target
    end
    problem = err
  end
  vim.fn.delete(stage, "rf")
  if ok and vim.uv.fs_stat(target) then
    return target
  end
  error(problem, 0)
end

return M
