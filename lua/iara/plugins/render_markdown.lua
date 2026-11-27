-- render-markdown.nvim: Obsidian-like rendering of Markdown buffers
-- (task MD1). Loaded on the first Markdown buffer only; the bundled
-- markdown and markdown_inline parsers of Neovim are all it needs.
-- iara.features.markdown owns its options, eligibility handling, the
-- toggle, and `:IaraMarkdownToggle`.
local function toggle()
  require("iara.features.markdown").toggle()
end

return {
  "MeanderingProgrammer/render-markdown.nvim",
  ft = "markdown",
  cmd = "IaraMarkdownToggle",
  keys = {
    {
      "<leader>mr",
      toggle,
      ft = "markdown",
      desc = "Markdown render toggle",
    },
  },
  config = function()
    require("iara.features.markdown").setup()
  end,
}
