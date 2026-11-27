--- Message presentation (task V11 spike, design 09 section 3.9).
---
--- "native" (the default) keeps Neovim's message area. "ui2" opts in to
--- Neovim 0.12's experimental core message UI (`vim._core.ui2`): messages
--- appear in an ephemeral window styled as an Iara float, `:messages`
--- opens ui2's pager, and the history is kept. No plugin is involved.
local M = {}

local api = vim.api

---Accepted values of `ui.messages`.
M.MODES = { native = true, ui2 = true }

---Time an ephemeral message stays visible (design 3.9).
M.TIMEOUT_MS = 4000

---Window highlights of ui2's windows by their filetype: the message
---window is a float; the others keep ui2's own `MsgArea` look.
M.WINHIGHLIGHT = {
  msg = "Normal:NormalFloat,FloatBorder:FloatBorder,"
    .. "Search:,CurSearch:,IncSearch:",
}

---The configured mode, or "native" with a problem for a bad value.
---@param config table Composed configuration.
---@return "native"|"ui2" mode
---@return string|nil problem
function M.mode(config)
  local ui = type(config) == "table" and config.ui or nil
  local value = type(ui) == "table" and ui.messages or nil
  if value == nil or M.MODES[value] then
    return value or "native", nil
  end
  local text = 'ui.messages must be "native" or "ui2", not %s'
  return "native", text:format(vim.inspect(value))
end

local function style_windows()
  local group = api.nvim_create_augroup("IaraMessages", { clear = true })
  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = vim.tbl_keys(M.WINHIGHLIGHT),
    callback = function(args)
      local win = vim.fn.bufwinid(args.buf)
      if win ~= -1 then
        vim.wo[win].winhighlight = M.WINHIGHLIGHT[args.match]
      end
    end,
  })
end

---Enable ui2 when `ui.messages = "ui2"`; report a bad value or a Neovim
---without ui2 and keep the native messages.
---@param config table Composed configuration.
---@return "native"|"ui2" mode The mode in effect.
function M.setup(config)
  local mode, problem = M.mode(config)
  if problem then
    vim.notify("Iara: " .. problem, vim.log.levels.WARN)
  end
  if mode ~= "ui2" then
    return "native"
  end
  local loaded, ui2 = pcall(require, "vim._core.ui2")
  if not loaded then
    vim.notify("Iara: ui2 is not available; messages stay native")
    return "native"
  end
  style_windows()
  ui2.enable({
    msg = { targets = "msg", msg = { timeout = M.TIMEOUT_MS } },
  })
  return "ui2"
end

return M
