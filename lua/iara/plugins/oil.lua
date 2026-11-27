-- Open the current file's directory as an editable buffer on demand.
return {
  "stevearc/oil.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = "Oil",
  keys = {
    { "<leader>d", "<cmd>Oil<CR>", desc = "Open directory in Oil" },
  },
  opts = {
    default_file_explorer = false,
    delete_to_trash = true,
    view_options = {
      is_hidden_file = function(name)
        return name ~= ".." and name:sub(1, 1) == "."
      end,
    },
  },
}
