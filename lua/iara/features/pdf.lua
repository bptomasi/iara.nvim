--- Register PDF entry points without loading the renderer on startup.
local M = {}
local did_setup = false

function M.matches(path)
  return vim.endswith(path:lower(), ".pdf")
end

local function edit(args)
  local path = vim.fn.fnamemodify(args.args, ":p")
  local info = vim.uv.fs_stat(path)
  if not M.matches(path) then
    vim.notify("Iara: choose a .pdf file", vim.log.levels.ERROR)
  elseif not info or info.type ~= "file" then
    vim.notify("Iara: cannot open PDF " .. path, vim.log.levels.ERROR)
  else
    vim.cmd.edit({ args = { path }, magic = { file = false, bar = false } })
  end
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  vim.api.nvim_create_user_command("IaraPDF", edit, {
    nargs = 1,
    complete = "file",
    desc = "Open a PDF in Iara",
  })
  local group = vim.api.nvim_create_augroup("IaraPDF", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*.[pP][dD][fF]",
    callback = function(args)
      require("iara.features.pdf.view").open(args.buf)
    end,
  })
end

return M
