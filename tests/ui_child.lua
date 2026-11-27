--- A child `nvim --embed` with a linegrid UI attached, for tests that
--- need a real screen: full-screen terminal programs see the size of the
--- window they are drawn in, and the screen shows what a user would see.
---
local helpers = require("helpers")
local grid_model = require("ui_grid")
local rpc = require("ui_rpc")

local M = {}

local TIMEOUT_MS = 10000

---@class UiChild
---@field client ui.RpcClient
---@field grid ui.Grid
---@field exited boolean
local UiChild = {}
UiChild.__index = UiChild

---Send a request and wait for its response.
---@return any result
function UiChild:request(method, params)
  local done, err, result = false, nil, nil
  self.client:request(method, params, function(e, r)
    done, err, result = true, e, r
  end)
  if not vim.wait(TIMEOUT_MS, function()
    return done
  end, 5) then
    error(("ui child: no response to %s"):format(method), 2)
  end
  if err ~= nil and err ~= vim.NIL then
    error(("ui child: %s failed: %s"):format(method, vim.inspect(err)), 2)
  end
  return result
end

---Run Lua in the child with `...` bound to `args`.
---@param code string
---@param args any[]?
---@return any
function UiChild:lua(code, args)
  return self:request("nvim_exec_lua", { code, args or {} })
end

---Queue keys as typed input (`nvim_input` notation).
---@param keys string
function UiChild:input(keys)
  self:request("nvim_input", { keys })
end

---@return string screen The whole grid, one row per line.
function UiChild:screen()
  return self.grid:screen_text()
end

---Wait until `predicate(self)` holds; return whether it did.
---@param predicate fun(child: UiChild): boolean
---@return boolean
function UiChild:wait(predicate)
  -- A predicate that waits itself (a request to the child) keeps
  -- vim.wait from ever reaching its own timeout, so check a deadline.
  local deadline = vim.uv.hrtime() + TIMEOUT_MS * 1e6
  local held = false
  vim.wait(TIMEOUT_MS, function()
    held = predicate(self)
    return held or vim.uv.hrtime() > deadline
  end, 10)
  return held
end

---Wait for a literal text on the screen; return the screen.
---@param text string
---@return string
function UiChild:wait_screen(text)
  self:wait(function(child)
    return child:screen():find(text, 1, true) ~= nil
  end)
  return self:screen()
end

---Ask the UI for a new grid size, as a resized emulator would.
function UiChild:resize(width, height)
  self:request("nvim_ui_try_resize", { width, height })
end

function UiChild:stop()
  self.client:kill()
  vim.wait(TIMEOUT_MS, function()
    return self.exited
  end, 10)
end

---Start a child with the test init (or `opts.init`) and `opts.args`, and
---attach a `width` x `height` UI.
---@param width integer
---@param height integer
---@param opts { init: string?, args: string[]? }|nil
---@return UiChild
function M.start(width, height, opts)
  opts = opts or {}
  local child =
    setmetatable({ grid = grid_model.new(), exited = false }, UiChild)
  local init = opts.init or helpers.minimal_init
  local argv = { vim.v.progpath, "--embed", "-n", "-u", init }
  vim.list_extend(argv, opts.args or {})
  local client = assert(rpc.spawn(argv, vim.uv.os_environ(), {
    on_notification = function(method, params)
      if method == "redraw" then
        child.grid:apply(params, function() end)
      end
    end,
    on_exit = function()
      child.exited = true
    end,
  }))
  child.client = client
  child:request("nvim_ui_attach", { width, height, { ext_linegrid = true } })
  return child
end

return M
