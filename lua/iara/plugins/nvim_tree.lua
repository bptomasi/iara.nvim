-- File explorer. Dotfiles and Git-ignored files start hidden, matching the
-- search defaults; inside the tree `H` toggles dotfiles and `I` toggles
-- Git-ignored files. `.git` itself is never listed.
--
-- Look (V11, design 09 section 3.11): the root chip with the Iara mark
-- and the branch, folders in the tide color, opened files in the accent,
-- and one dot after the name colored by its Git state (`g?` lists them).

---One glyph for every Git state: the color tells the state.
local DOT = "\u{25cf}"

return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = { "NvimTreeToggle", "NvimTreeFocus", "NvimTreeFindFile" },
  keys = {
    { "<C-n>", "<cmd>NvimTreeToggle<CR>", desc = "Toggle file explorer" },
    { "<leader>e", "<cmd>NvimTreeFocus<CR>", desc = "Focus file explorer" },
  },
  config = function(_, opts)
    require("nvim-tree").setup(opts)
    require("iara.core.explorer").setup()
  end,
  opts = {
    hijack_cursor = true,
    sync_root_with_cwd = true,
    update_focused_file = { enable = true, update_root = false },
    filters = {
      dotfiles = true,
      git_ignored = true,
      custom = { "^\\.git$" },
    },
    view = {
      width = 30,
      preserve_window_proportions = true,
      signcolumn = "no",
    },
    renderer = {
      root_folder_label = function(path)
        return require("iara.core.explorer").root_label(path)
      end,
      -- Names keep their color; the dot after them carries the state.
      highlight_git = "none",
      highlight_opened_files = "name",
      indent_width = 2,
      indent_markers = { enable = true },
      icons = {
        git_placement = "after",
        glyphs = {
          default = "\u{f0214}",
          symlink = "\u{f0481}",
          folder = {
            default = "\u{f024b}",
            empty = "\u{f0256}",
            empty_open = "\u{f06e7}",
            open = "\u{f0770}",
            symlink = "\u{f0bd8}",
            arrow_open = "\u{f107}",
            arrow_closed = "\u{f105}",
          },
          git = {
            unstaged = DOT,
            staged = DOT,
            unmerged = DOT,
            renamed = DOT,
            untracked = DOT,
            deleted = DOT,
            ignored = DOT,
          },
        },
      },
    },
  },
}
