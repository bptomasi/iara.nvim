-- Optional tool installer. Set up at startup as Mason recommends, but it
-- never edits PATH (language files resolve its artifacts explicitly) and
-- never installs anything unless asked through its commands.
return {
  "mason-org/mason.nvim",
  lazy = false,
  opts = { PATH = "skip", ui = { border = require("iara.core.ui").BORDER } },
}
