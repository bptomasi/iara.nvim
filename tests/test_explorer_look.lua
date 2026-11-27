-- Look of the file explorer (V11): root chip with the mark and branch,
-- Git state as one colored dot, and readable tree groups in every theme.
local eq = MiniTest.expect.equality

local explorer = require("iara.core.explorer")
local spec = require("iara.plugins.nvim_tree")

local DOT = "\u{25cf}"

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.g.gitsigns_head = nil
    end,
  },
})

T["every Git state is the same dot after the name"] = function()
  local renderer = spec.opts.renderer
  for state, glyph in pairs(renderer.icons.glyphs.git) do
    eq({ state, glyph }, { state, DOT })
  end
  eq(renderer.icons.git_placement, "after")
  eq(renderer.highlight_git, "none")
  eq(renderer.highlight_opened_files, "name")
end

T["root label is a chip with the mark, then the branch when known"] = function()
  local label = spec.opts.renderer.root_folder_label
  eq(label("/work/demo"), " \u{223f} demo ")
  eq(label("/work/demo/"), " \u{223f} demo ")
  vim.g.gitsigns_head = "main"
  eq(label("/work/demo"), " \u{223f} demo   \u{e725} main")
  vim.g.gitsigns_head = ""
  eq(label("/work/demo"), " \u{223f} demo ")
end

T["the branch part of the label gets the muted group"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.g.gitsigns_head = "feature/x"
  local line = explorer.root_label("/work/demo")
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, { line, "  src" })
  explorer.mark_branch(buf)
  explorer.mark_branch(buf)
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    explorer.NAMESPACE,
    0,
    -1,
    { details = true }
  )
  eq(#marks, 1)
  eq(marks[1][3], #" \u{223f} demo ")
  eq(marks[1][4].end_col, #line)
  eq(marks[1][4].hl_group, explorer.BRANCH_GROUP)
  vim.g.gitsigns_head = nil
  vim.api.nvim_buf_set_lines(buf, 0, 1, true, { explorer.root_label("/a") })
  explorer.mark_branch(buf)
  eq(#vim.api.nvim_buf_get_extmarks(buf, explorer.NAMESPACE, 0, -1, {}), 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function resolved(name)
  local palette = require("iara.theme").palette(name)
  local groups = require("iara.theme.highlights").resolve(palette)
  return groups, require("iara.theme.roles").resolve(palette)
end

T["Git dots take their state's role"] = function()
  local groups, roles = resolved("chocolate")
  local states = {
    NvimTreeGitDirtyIcon = "warn",
    NvimTreeGitStagedIcon = "ok",
    NvimTreeGitNewIcon = "ok",
    NvimTreeGitRenamedIcon = "ok",
    NvimTreeGitDeletedIcon = "error",
    NvimTreeGitMergeIcon = "error",
    NvimTreeGitIgnoredIcon = "subtle",
  }
  for group, role in pairs(states) do
    eq({ group, groups[group].fg }, { group, roles[role] })
  end
  eq(groups.NvimTreeFolderName.fg, roles.tide)
  -- The accent readable on the cursor line too (V12).
  eq(groups.NvimTreeOpenedHL.fg, roles.accent_row)
end

T["names are readable and dots visible on the tree in every theme"] = function()
  local contrast = require("iara.theme.highlights").contrast
  local text = {
    "NvimTreeNormal",
    "NvimTreeFolderName",
    "NvimTreeOpenedFolderName",
    "NvimTreeOpenedHL",
    "IaraTreeBranch",
  }
  local glyphs = { "NvimTreeGitDirtyIcon", "NvimTreeGitStagedIcon" }
  vim.list_extend(
    glyphs,
    { "NvimTreeGitDeletedIcon", "NvimTreeGitIgnoredIcon" }
  )
  for _, name in ipairs(require("iara.theme").THEMES) do
    local groups, roles = resolved(name)
    for _, group in ipairs(text) do
      local ratio = contrast(groups[group].fg, roles.mantle)
      eq({ name, group, ratio >= 4.5 }, { name, group, true })
    end
    for _, group in ipairs(glyphs) do
      local ratio = contrast(groups[group].fg, roles.mantle)
      eq({ name, group, ratio >= 3 }, { name, group, true })
    end
    local root = groups.NvimTreeRootFolder
    eq({ name, contrast(root.fg, root.bg) >= 4.5 }, { name, true })
  end
end

return T
