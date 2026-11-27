--- Search entry points: open a search and resume the last one.
---
--- The root of the invoking buffer is snapshotted before any UI opens, so
--- focusing the picker cannot change it. One search is live at a time:
--- opening another closes the previous session. Presentation belongs to
--- `iara.features.search.ui` (task S6), which receives the session.
--- See contracts.md, section 9.1.
local root = require("iara.core.root")
local session_module = require("iara.features.search.session")

local M = {}

local UI_MODULE = "iara.features.search.ui"

---@type table|nil Session opened last, kept after close for resume.
local last = nil
local leave_registered = false

local function close_on_leave()
  if leave_registered then
    return
  end
  leave_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("IaraSearch", { clear = true }),
    callback = function()
      if last then
        last:close()
      end
    end,
  })
end

local function present(session)
  local ok, ui = pcall(require, UI_MODULE)
  if not ok or type(ui) ~= "table" or type(ui.open) ~= "function" then
    local detail = ok and "no open function" or tostring(ui)
    vim.notify(
      "Iara: search UI is unavailable: " .. detail,
      vim.log.levels.WARN
    )
    return
  end
  ui.open(session)
end

local function start(request, search_root)
  local session = session_module.new(request, search_root, true)
  if last then
    last:close()
  end
  last = session
  close_on_leave()
  present(session)
  return session
end

---Open a search for the root of the invoking buffer, which is
---snapshotted before any UI opens. `Space ff` = open({ mode = "files" }),
---`Space fw` = open({ mode = "content" }), `Space fa` = open({ mode =
---"files", hidden = true, ignored = true }). Without `mode`, both lanes
---run (the combined search of the session API).
---@param opts IaraSearchRequest?
---@return table session The new search session (see session.new).
function M.open(opts)
  local search_root = root.resolve(0)
  return start(opts or {}, search_root)
end

---Restore the previous request controls and root, then rerun in a new
---session (results are never reused). Notifies when there is nothing to
---resume.
---@return table|nil session
function M.resume()
  if not last then
    vim.notify("Iara: no search to resume", vim.log.levels.INFO)
    return nil
  end
  local previous = last:snapshot()
  return start(previous.request, previous.root)
end

return M
