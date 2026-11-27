-- Server definitions (lsp/*.lua) for native vim.lsp.config/enable. The
-- legacy require("lspconfig") framework is not used. Loaded before the
-- first file buffer so definitions and capabilities exist before
-- activation; language files decide which servers run.
return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = { "hrsh7th/cmp-nvim-lsp" },
  config = function()
    local config = require("iara.config")
    require("iara.core.lsp").setup()
    if config.enabled("languages.lua") then
      require("iara.languages.lua").setup(config.get("languages.lua"))
    end
  end,
}
