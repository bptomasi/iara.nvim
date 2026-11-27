--- Presentation of the file explorer (task V11, design 09 section 3.11):
--- the root chip with the Iara mark, and the branch beside it in the
--- muted color. nvim-tree draws the whole root label in one group, so
--- the branch is recolored by an extmark after each render.
local M = {}

local api = vim.api

---The Iara mark (sine wave), shown in the root chip.
M.MARK = "\u{223f}"

---Git branch glyph, as in the status line.
M.BRANCH_ICON = "\u{e725}"

---Between the root chip and the branch.
M.SEPARATOR = "  "

---Group of the branch text beside the root chip.
M.BRANCH_GROUP = "IaraTreeBranch"

M.NAMESPACE = api.nvim_create_namespace("iara.explorer")

---Branch of the current buffer as Gitsigns last reported it; nil when
---unknown. Reads a variable only: rendering the tree runs no Git.
---@return string|nil
function M.branch()
  local head = vim.g.gitsigns_head
  if type(head) == "string" and head ~= "" then
    return head
  end
  return nil
end

---Root label of the tree: ` ∿ name ` as a rectangular chip, then the
---branch when known.
---@param path string Absolute root directory.
---@return string
function M.root_label(path)
  local name = vim.fn.fnamemodify((path:gsub("/+$", "")), ":t")
  if name == "" then
    name = path
  end
  local label = (" %s %s "):format(M.MARK, name)
  local branch = M.branch()
  if branch then
    label = label .. M.SEPARATOR .. M.BRANCH_ICON .. " " .. branch
  end
  return label
end

---Recolor the branch part of the root label on the tree's first line.
---Lines without a branch get no mark.
---@param bufnr integer Tree buffer.
function M.mark_branch(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, M.NAMESPACE, 0, 1)
  local line = api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local start = line:find(M.SEPARATOR .. M.BRANCH_ICON, 1, true)
  if not start then
    return
  end
  api.nvim_buf_set_extmark(bufnr, M.NAMESPACE, 0, start - 1, {
    end_col = #line,
    hl_group = M.BRANCH_GROUP,
    -- Above nvim-tree's own highlights (vim.hl.range, priority 200).
    priority = 250,
  })
end

---Subscribe to nvim-tree's render event. Called from the plugin's
---`config` after `nvim-tree.setup`.
function M.setup()
  api.nvim_set_hl(0, M.BRANCH_GROUP, { link = "Comment", default = true })
  local tree = require("nvim-tree.api")
  tree.events.subscribe(tree.events.Event.TreeRendered, function(data)
    M.mark_branch(data.bufnr)
  end)
end

return M
