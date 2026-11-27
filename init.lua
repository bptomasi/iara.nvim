-- Iara entry point. It works both as the configuration directory
-- (NVIM_APPNAME=iara) and through `nvim -u /path/to/iara/init.lua`, so the
-- directory holding this file is added to 'runtimepath' when missing.
vim.g.iara_startup_hrtime = vim.uv.hrtime() -- start screen startup time
-- Byte-compiled module cache. lazy.nvim enables it too, but only after
-- the options, theme, and core steps have loaded about 30 modules from
-- source; enabling it first saves about 1 ms per start (FU-V12-PERF).
vim.loader.enable()
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local iara_dir = vim.fn.fnamemodify(source, ":p:h")
local real_dir = vim.uv.fs_realpath(iara_dir) or iara_dir

local function on_runtimepath()
  for _, entry in ipairs(vim.opt.runtimepath:get()) do
    if (vim.uv.fs_realpath(entry) or entry) == real_dir then
      return true
    end
  end
  return false
end

if not on_runtimepath() then
  vim.opt.runtimepath:prepend(iara_dir)
end

-- A defect in composition itself must still leave native editing usable.
local ok, problem = xpcall(function()
  require("iara").setup()
end, debug.traceback)
if not ok then
  vim.g.iara_mode = "safe"
  vim.notify(
    "Iara: startup failed; using native editing:\n" .. problem,
    vim.log.levels.ERROR
  )
end
