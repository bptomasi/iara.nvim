-- snacks.nvim, used only for its picker as the search presentation
-- (tasks S6 and UX1, iara.features.search.ui). It loads when the search
-- UI first requires it, with nvim-web-devicons for the file icons of
-- search rows; every other Snacks module stays disabled, and the picker
-- does not replace vim.ui.select.
return {
  "folke/snacks.nvim",
  lazy = true,
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = { picker = { enabled = true, ui_select = false } },
}
