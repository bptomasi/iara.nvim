-- Minimal init for the test runner and for child Neovim processes.
-- It puts the distribution and the pinned mini.nvim on 'runtimepath'
-- without running Iara's own startup.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local iara_dir = vim.fn.fnamemodify(source, ":p:h:h")

vim.opt.runtimepath:prepend(iara_dir .. "/.tools/mini.nvim")
vim.opt.runtimepath:prepend(iara_dir)
package.path = iara_dir .. "/tests/?.lua;" .. package.path

vim.o.swapfile = false
vim.o.shadafile = "NONE"

require("mini.test").setup()
