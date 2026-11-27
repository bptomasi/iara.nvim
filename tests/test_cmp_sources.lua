-- Tests for the nvim-cmp buffer source filter in plugins/cmp.lua: the
-- source indexes only visible, eligible file buffers.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

---A stand-in for `require("cmp")` and LuaSnip: every field is a callable
---no-op, so the spec's options can be built without the plugins.
local function stub_cmp()
  local stub
  stub = setmetatable({}, {
    __index = function()
      return stub
    end,
    __call = function()
      return stub
    end,
  })
  return stub
end

---The buffer source's `get_bufnrs` from the spec's options.
local function buffer_source_bufnrs()
  package.loaded.cmp = stub_cmp()
  package.loaded.luasnip = stub_cmp()
  local spec = dofile(helpers.iara_dir .. "/lua/iara/plugins/cmp.lua")
  for _, source in ipairs(spec.opts().sources) do
    if source.name == "buffer" then
      return source.option.get_bufnrs
    end
  end
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      package.loaded.cmp = nil
      package.loaded.luasnip = nil
      vim.cmd("silent! only")
    end,
  },
})

T["indexes visible file buffers but not terminals"] = function()
  local file = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(file)
  vim.cmd("botright split")
  vim.cmd.terminal()
  local terminal = vim.api.nvim_get_current_buf()
  eq(vim.bo[terminal].buftype, "terminal")
  local bufnrs = buffer_source_bufnrs()()
  eq(vim.list_contains(bufnrs, file), true)
  eq(vim.list_contains(bufnrs, terminal), false)
  vim.fn.jobstop(vim.bo[terminal].channel)
end

return T
