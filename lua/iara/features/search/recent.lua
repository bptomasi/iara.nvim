--- Recently used file buffers of a project (task UX1b), so Find files
--- with an empty query lists the files the user is working on first.
---
--- Read once per search session from the buffer list: listed, named
--- file buffers (empty 'buftype') under the root, most recently used
--- first. Neovim stores `lastused` in seconds, so ties fall back to the
--- newer buffer number. The current buffer goes last among them: it is
--- already on screen, and the one before it is the likelier target.
--- The result only orders paths the inventory admits; it never adds a
--- path, so eligibility is unchanged.
local M = {}

---Recent paths considered; older buffers rank like any other file.
M.LIMIT = 100

---True when entry `a` was used more recently than `b`.
local function newer(a, b)
  if a.current ~= b.current then
    return b.current
  end
  if a.lastused ~= b.lastused then
    return a.lastused > b.lastused
  end
  return a.bufnr > b.bufnr
end

---Root-relative path of a file buffer under `root`, or nil.
local function relative(info, root)
  if info.name == "" or vim.bo[info.bufnr].buftype ~= "" then
    return nil
  end
  local path = vim.fs.relpath(root, info.name)
  if path == nil or path == "." then
    return nil
  end
  return path
end

---Listed file buffers under `root`, with their recency.
local function entries(root)
  local current = vim.api.nvim_get_current_buf()
  local found = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local path = relative(info, root)
    if path then
      table.insert(found, {
        path = path,
        bufnr = info.bufnr,
        lastused = info.lastused,
        current = info.bufnr == current,
      })
    end
  end
  return found
end

---Rank of each recently used file under `root`: 1 is the most recent.
---@param root string Absolute project root.
---@return table<string, integer> ranks Root-relative path to rank.
function M.ranks(root)
  local found = entries(root)
  table.sort(found, newer)
  local ranks = {}
  for index = 1, math.min(#found, M.LIMIT) do
    ranks[found[index].path] = index
  end
  return ranks
end

return M
