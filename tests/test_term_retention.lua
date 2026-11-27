local helpers = require("helpers")

local expect = MiniTest.expect
local eq = expect.equality
local match = helpers.expect_match

local child = nil

---Child-side helpers: real PTY terminals running the unadorned 'shell',
---which is exactly what the shipped TermClose handler deletes.
local CHILD_HELPERS = [[
vim.o.shell = "/bin/sh"
_G.shown = {}
vim.notify = function(message) table.insert(_G.shown, message) end
retention = require("iara.core.term_retention")

local exitmsg_ns = vim.api.nvim_create_namespace("nvim.terminal.exitmsg")

function _G.open_shell(hidden)
  local buf = vim.api.nvim_create_buf(true, false)
  local start = function()
    return vim.fn.jobstart({ vim.o.shell }, { term = true })
  end
  local job
  if hidden then
    job = vim.api.nvim_buf_call(buf, start)
  else
    vim.api.nvim_set_current_buf(buf)
    job = start()
  end
  assert(job > 0, "jobstart failed")
  return buf, job
end

function _G.exit_message(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    buf, exitmsg_ns, 0, -1, { details = true })
  local mark = marks[1]
  return mark and mark[4].virt_text[1][1] or nil
end

function _G.exit_shell(buf, job, status)
  vim.fn.chansend(job, ("exit %d\n"):format(status))
  vim.wait(5000, function()
    return not vim.api.nvim_buf_is_valid(buf) or exit_message(buf) ~= nil
  end, 10)
  return {
    valid = vim.api.nvim_buf_is_valid(buf),
    message = exit_message(buf),
  }
end

function _G.term_close_handlers()
  return vim.tbl_map(function(autocmd)
    return { id = autocmd.id, desc = autocmd.desc }
  end, vim.api.nvim_get_autocmds({
    group = "nvim.terminal", event = "TermClose" }))
end
]]

---Run `code` in the child after the helpers, returning its result.
local function run(code, args)
  return child.lua(code, args or {})
end

---Open a shell, optionally own it, exit with `status`, report the result.
local function exit_case(opts)
  return run(
    [[
    local opts = ...
    local buf, job = open_shell(opts.hidden)
    if opts.own then retention.own(buf) end
    return exit_shell(buf, job, opts.status)
  ]],
    { opts }
  )
end

local function available()
  return run("return { retention.available() }")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
      child.lua(CHILD_HELPERS)
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["installed wrapper"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      run("retention.setup({})")
    end,
  },
})

local installed = T["installed wrapper"]

installed["reports availability on the pinned runtime"] = function()
  eq(available(), { true })
  eq(run("return _G.shown"), {})
end

installed["keeps an owned visible shell after a successful exit"] = function()
  local result = exit_case({ own = true, status = 0 })
  eq(result, { valid = true, message = "[Process exited 0]" })
end

installed["keeps an owned hidden shell after a successful exit"] = function()
  local result = exit_case({ own = true, hidden = true, status = 0 })
  eq(result, { valid = true, message = "[Process exited 0]" })
end

installed["deletes an unowned shell after a successful exit"] = function()
  eq(exit_case({ status = 0 }).valid, false)
  eq(exit_case({ hidden = true, status = 0 }).valid, false)
end

installed["keeps unowned and owned shells after a failed exit"] = function()
  local expected = { valid = true, message = "[Process exited 3]" }
  eq(exit_case({ status = 3 }), expected)
  eq(exit_case({ own = true, hidden = true, status = 3 }), expected)
end

installed["runs autocmds nested inside the native deletion"] = function()
  local wiped = run([[
    local buf, job = open_shell(false)
    local wiped = false
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function() wiped = true end,
    })
    exit_shell(buf, job, 0)
    return wiped
  ]])
  eq(wiped, true)
end

installed["returns a disowned shell to native deletion"] = function()
  local result = run([[
    local buf, job = open_shell(false)
    retention.own(buf)
    retention.disown(buf)
    return { retention.is_owned(buf), exit_shell(buf, job, 0).valid }
  ]])
  eq(result, { false, false })
end

installed["treats buffer 0 as the current buffer"] = function()
  local result = run([[
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    retention.own(0)
    return retention.is_owned(buf)
  ]])
  eq(result, true)
end

installed["rejects owning an invalid buffer"] = function()
  local ok = run("return pcall(retention.own, 999999)")
  eq(ok, false)
  eq(run("return retention.is_owned(999999)"), false)
end

installed["replaces only the shipped handler"] = function()
  local descs = run([[
    return vim.tbl_map(function(handler)
      return handler.desc
    end, term_close_handlers())
  ]])
  eq(#descs, 2)
  eq(descs[1], 'Displays the "[Process exited]" virtual text')
  match(descs[2], "^Iara: Automatically close terminal buffers")
end

installed["leaves handlers unchanged on repeated setup"] = function()
  local before = run("return term_close_handlers()")
  run("retention.setup({}); retention.setup({})")
  eq(run("return term_close_handlers()"), before)
  eq(available(), { true })
  eq(exit_case({ own = true, status = 0 }).valid, true)
end

installed["disables creation when the wrapper was removed"] = function()
  run([[
    local handlers = term_close_handlers()
    vim.api.nvim_del_autocmd(handlers[#handlers].id)
    retention.setup({})
  ]])
  local result = available()
  eq(result[1], false)
  match(result[2], "wrapper is no longer registered")
  match(run("return _G.shown[1]"), "^Iara terminals disabled")
  eq(exit_case({ status = 0 }).valid, false)
end

---Expect setup to be refused with `pattern` while every TermClose
---handler present before setup stays registered unchanged.
local function expect_refused(pattern)
  local before = run("return term_close_handlers()")
  run("retention.setup({})")
  local result = available()
  eq(result[1], false)
  match(result[2], pattern)
  match(run("return _G.shown[1]"), "incompatible runtime")
  eq(run("return term_close_handlers()"), before)
end

T["refused setup"] = MiniTest.new_set()

local refused = T["refused setup"]

refused["reports unavailable before setup ran"] = function()
  eq(available(), { false, "term_retention.setup() has not run" })
end

refused["keeps native handlers when the checksum differs"] = function()
  local runtime = helpers.temp_dir()
  run(
    [[
    local runtime = ...
    local source = vim.env.VIMRUNTIME .. "/lua/vim/_core/defaults.lua"
    local target = runtime .. "/lua/vim/_core/defaults.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    local lines = vim.fn.readfile(source, "b")
    table.insert(lines, "-- patched")
    vim.fn.writefile(lines, target, "b")
    vim.env.VIMRUNTIME = runtime
  ]],
    { runtime }
  )
  expect_refused("has SHA%-256 %x+, expected 59c5279b")
  eq(exit_case({ own = true, status = 0 }).valid, false)
end

refused["keeps native handlers when the handler is ambiguous"] = function()
  run([[
    local shipped = vim.api.nvim_get_autocmds({
      group = "nvim.terminal", event = "TermClose" })[1]
    vim.api.nvim_create_autocmd("TermClose", {
      group = "nvim.terminal", pattern = "*", nested = true,
      desc = shipped.desc, callback = shipped.callback,
    })
  ]])
  expect_refused("found 2$")
end

refused["keeps native handlers when the description differs"] = function()
  run([[
    local shipped = vim.api.nvim_get_autocmds({
      group = "nvim.terminal", event = "TermClose" })[1]
    vim.api.nvim_del_autocmd(shipped.id)
    vim.api.nvim_create_autocmd("TermClose", {
      group = "nvim.terminal", pattern = "*", nested = true,
      desc = "Something else", callback = shipped.callback,
    })
  ]])
  expect_refused("found 0$")
end

refused["refuses a handler defined elsewhere"] = function()
  run([[
    local shipped = vim.api.nvim_get_autocmds({
      group = "nvim.terminal", event = "TermClose" })[1]
    vim.api.nvim_del_autocmd(shipped.id)
    vim.api.nvim_create_autocmd("TermClose", {
      group = "nvim.terminal", pattern = "*", nested = true,
      desc = shipped.desc, callback = function() end,
    })
  ]])
  expect_refused("found 0$")
end

refused["refuses a missing terminal group"] = function()
  run('vim.api.nvim_del_augroup_by_name("nvim.terminal")')
  run("retention.setup({})")
  local result = available()
  eq(result[1], false)
  match(result[2], "group nvim.terminal is missing")
end

refused["restores native handlers when replacement fails"] = function()
  run([[
    local original = vim.api.nvim_get_autocmds({
      group = "nvim.terminal", event = "TermClose" })[1].id
    local delete = vim.api.nvim_del_autocmd
    vim.api.nvim_del_autocmd = function(id)
      if id == original then error("injected failure") end
      return delete(id)
    end
  ]])
  expect_refused("cannot delete shipped handler: .*injected failure")
  eq(exit_case({ own = true, status = 0 }).valid, false)
end

return T
