-- The installer is available from startup and downloads on request.
return {
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
  lazy = false,
  config = function(plugin)
    local dir = require("iara.core.parsers").extra_runtime()
    -- Neovim caches existing runtime directories before the first install.
    vim.fn.mkdir(dir, "p")
    require("nvim-treesitter").setup({ install_dir = dir })
    -- Keep the baseline Neovim queries ahead of optional replacements.
    vim.opt.runtimepath:remove(dir)
    vim.opt.runtimepath:append(dir)
    -- Installed query links can point into a pruned Iara release.
    vim.opt.runtimepath:append(plugin.dir .. "/runtime")
  end,
}
