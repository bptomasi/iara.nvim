local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local STYLUA = helpers.iara_dir .. "/.tools/bin/stylua"

local UNFORMATTED = { "local x  =  1", "if x then", "print( x )", "end" }
local FORMATTED = { "local x = 1", "if x then", "  print(x)", "end" }

local child = nil

---Write a personal configuration file and return its path.
local function personal_file(languages_lua)
  local path = helpers.temp_dir() .. "/user.lua"
  helpers.write_file(path, "return " .. vim.inspect({
    languages = {
      lua = languages_lua,
    },
  }))
  return path
end

---Load the configuration and set up the modules in the child, recording
---every notification in _G.messages.
local function start(languages_lua)
  child.lua(
    [[
    local personal = ...
    _G.messages = {}
    vim.notify = function(message) table.insert(_G.messages, message) end
    require("iara.config").load({ personal_path = personal })
    require("iara.core.eligibility").setup({})
    require("iara.features.format_lua").setup({})
  ]],
    { personal_file(languages_lua) }
  )
end

---Create a Git project with a StyLua configuration and a Lua file.
local function make_project(lines, with_config)
  local dir = helpers.temp_dir()
  vim.fn.mkdir(dir .. "/.git", "p")
  if with_config ~= false then
    helpers.write_file(
      dir .. "/stylua.toml",
      'indent_type = "Spaces"\n' .. "indent_width = 2\n"
    )
  end
  local path = dir .. "/src/main.lua"
  helpers.write_file(path, table.concat(lines, "\n") .. "\n")
  return path
end

---Edit `path` in the child and wait until eligibility settles.
local function edit(path)
  child.cmd("edit " .. vim.fn.fnameescape(path))
  return child.lua([[
    local eligibility = require("iara.core.eligibility")
    vim.wait(5000, function()
      return eligibility.check(0).state ~= "unknown"
    end)
    return eligibility.check(0).state
  ]])
end

---Wait until no formatter process is live; results are applied by then.
local function wait_idle()
  child.lua([[
    local proc = require("iara.core.proc")
    local tag = require("iara.features.format_lua").TAG
    vim.wait(10000, function() return proc.active_count(tag) == 0 end, 10)
  ]])
end

local function buffer_lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, true)
end

local function messages()
  return table.concat(child.lua_get("_G.messages"), "\n")
end

local function format_now()
  return child.lua([[
    local started, err = require("iara.features.format_lua").format(0)
    return { started = started, code = err and err.code }
  ]])
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["formats through :IaraFormat as a single undo step"] = function()
  start({ stylua = STYLUA })
  edit(make_project(UNFORMATTED))
  -- An earlier edit must stay a separate undo step.
  child.cmd("normal! Gofoo( )")
  local edited = buffer_lines()
  child.cmd("IaraFormat")
  wait_idle()
  local expected = vim.list_extend(vim.deepcopy(FORMATTED), { "foo()" })
  eq(buffer_lines(), expected)
  child.cmd("undo")
  eq(buffer_lines(), edited)
  child.cmd("undo")
  eq(buffer_lines(), UNFORMATTED)
end

T["discards the result when the buffer changes during formatting"] = function()
  start({ stylua = STYLUA })
  edit(make_project(UNFORMATTED))
  -- The edit runs before any process callback can reach the main loop.
  child.lua([[
    require("iara.features.format_lua").format(0)
    vim.api.nvim_buf_set_lines(0, 0, 1, true, { "local y  =  2" })
  ]])
  wait_idle()
  eq(buffer_lines()[1], "local y  =  2")
  eq(buffer_lines()[3], "print( x )")
  match(messages(), "changed while formatting")
end

T["leaves the buffer unchanged on a StyLua syntax error"] = function()
  start({ stylua = STYLUA })
  local broken = { "if x then y(", "local  z = 1" }
  edit(make_project(broken))
  local tick = child.api.nvim_buf_get_changedtick(0)
  eq(format_now().started, true)
  wait_idle()
  eq(buffer_lines(), broken)
  eq(child.api.nvim_buf_get_changedtick(0), tick)
  match(messages(), "StyLua failed: .*unexpected token")
end

T["reports a configured StyLua that does not exist"] = function()
  start({ stylua = "/nonexistent/bin/stylua" })
  edit(make_project(UNFORMATTED))
  eq(format_now(), { started = false, code = "not_found" })
  match(messages(), "not executable: /nonexistent/bin/stylua")
  eq(buffer_lines(), UNFORMATTED)
end

T["reports StyLua missing from PATH"] = function()
  start({})
  edit(make_project(UNFORMATTED))
  child.lua("vim.env.PATH = ...", { helpers.temp_dir() })
  eq(format_now(), { started = false, code = "not_found" })
  match(messages(), "StyLua not found")
end

T["refuses without a StyLua configuration file"] = function()
  start({ stylua = STYLUA })
  edit(make_project(UNFORMATTED, false))
  eq(format_now(), { started = false, code = "not_found" })
  match(messages(), "no stylua%.toml")
  eq(buffer_lines(), UNFORMATTED)
end

T["uses the personal configuration file when the project has none"] = function()
  local config_path = helpers.temp_dir() .. "/stylua.toml"
  helpers.write_file(config_path, 'indent_type = "Spaces"\nindent_width = 4\n')
  start({ stylua = STYLUA, stylua_config = config_path })
  edit(make_project(UNFORMATTED, false))
  eq(format_now().started, true)
  wait_idle()
  eq(buffer_lines()[3], "    print(x)")
end

T["refuses a buffer in conservative mode"] = function()
  start({ stylua = STYLUA })
  local long = "local s = '" .. ("x"):rep(10000) .. "'"
  eq(edit(make_project({ long, "local  y = 1" })), "conservative")
  eq(format_now(), { started = false, code = "ineligible" })
  match(messages(), "conservative mode")
  eq(buffer_lines()[2], "local  y = 1")
end

T["preserves fileformat and a missing final newline"] = function()
  start({ stylua = STYLUA })
  local path = make_project({})
  local crlf = table.concat(UNFORMATTED, "\r\n")
  helpers.write_file(path, crlf)
  edit(path)
  eq(child.bo.fileformat, "dos")
  eq(child.bo.endofline, false)
  -- Otherwise writing restores the final newline whatever 'eol' says.
  child.bo.fixendofline = false
  format_now()
  wait_idle()
  child.cmd("write")
  local file = assert(io.open(path, "rb"))
  local written = file:read("*a")
  file:close()
  eq(written, table.concat(FORMATTED, "\r\n"))
end

---Attach an in-process language server that offers range formatting.
local function attach_fake_server()
  child.lua([[
    local function server()
      local closing = false
      return {
        request = function(method, _, callback)
          local result = nil
          if method == "initialize" then
            result = { capabilities = {
              documentFormattingProvider = true,
              documentRangeFormattingProvider = true,
            } }
          end
          vim.schedule(function() callback(nil, result) end)
          return true, 1
        end,
        notify = function() return true end,
        is_closing = function() return closing end,
        terminate = function() closing = true end,
      }
    end
    _G.attached = 0
    vim.api.nvim_create_autocmd("LspAttach", {
      callback = function() _G.attached = _G.attached + 1 end,
    })
    local config = { name = "fake", cmd = server, root_dir = vim.fn.getcwd() }
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      vim.lsp.start(config, { bufnr = buf })
    end
    local total = #vim.api.nvim_list_bufs()
    vim.wait(5000, function() return _G.attached == total end)
  ]])
end

T["owns formatexpr in Lua buffers instead of LSP"] = function()
  start({ stylua = STYLUA })
  local path = make_project(UNFORMATTED)
  child.cmd("edit " .. vim.fn.fnameescape(path))
  child.cmd("new")
  child.bo.filetype = "text"
  attach_fake_server()
  -- The non-Lua buffer shows the LSP default this module must remove.
  eq(child.bo.formatexpr, "v:lua.vim.lsp.formatexpr()")
  child.cmd("wincmd p")
  eq(child.bo.filetype, "lua")
  eq(child.bo.formatexpr, "")
  local mapped =
    child.lua_get("vim.fn.maparg('<leader>fm', 'n', false, true).buffer")
  eq(mapped, 1)
end

-- M2: admission caps, batched capture, and late guards ----------------------

---A StyLua wrapper that logs each start with its arguments, waits `delay`
---seconds, then runs the real StyLua. Returns its path and log path.
local function slow_stylua(delay, dir)
  dir = dir or helpers.temp_dir()
  local path = dir .. "/stylua"
  local log = helpers.temp_dir() .. "/starts.log"
  local script = table.concat({
    "#!/bin/sh",
    "echo start \"$*\" >> '%s'",
    "'%s' %s",
    "exec '%s' \"$@\"",
    "",
  }, "\n")
  helpers.write_file(
    path,
    script:format(log, vim.fn.exepath("sleep"), delay, STYLUA)
  )
  vim.uv.fs_chmod(path, tonumber("755", 8))
  return path, log
end

---Lines of the start log (empty when nothing started).
local function start_lines(log)
  local file = io.open(log, "rb")
  if not file then
    return {}
  end
  local text = file:read("*a")
  file:close()
  return vim.split(text, "\n", { plain = true, trimempty = true })
end

local function starts(log)
  return #start_lines(log)
end

---Whether a logged start formatted the file named `name`.
local function started(log, name)
  for _, line in ipairs(start_lines(log)) do
    if line:find("/" .. name, 1, true) then
      return true
    end
  end
  return false
end

---Wait until every request is idle and no formatter process is live,
---and return the largest number of live processes seen meanwhile.
local function wait_all_idle()
  return child.lua([[
    local proc = require("iara.core.proc")
    local format = require("iara.features.format_lua")
    local most = 0
    vim.wait(15000, function()
      most = math.max(most, proc.active_count(format.TAG))
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and format.status(buf) ~= "idle"
        then
          return false
        end
      end
      return proc.active_count(format.TAG) == 0
    end, 5)
    return most
  ]])
end

local function status(bufnr)
  return child.lua_get(
    "require('iara.features.format_lua').status(...)",
    { bufnr }
  )
end

---Reload the configuration with new `languages.lua` settings and extra
---top-level fields, as a later :source of the personal file would.
local function reload(languages_lua, extra)
  local path = helpers.temp_dir() .. "/user2.lua"
  local layer = vim.tbl_extend("force", extra or {}, {
    languages = { lua = languages_lua },
  })
  helpers.write_file(path, "return " .. vim.inspect(layer))
  child.lua("require('iara.config').load({ personal_path = ... })", { path })
end

---Open `count` unformatted Lua files of one project; return buffers.
local function open_buffers(count)
  local dir = vim.fs.dirname(make_project(UNFORMATTED))
  local buffers = {}
  for index = 1, count do
    local path = ("%s/file%d.lua"):format(dir, index)
    helpers.write_file(path, table.concat(UNFORMATTED, "\n") .. "\n")
    edit(path)
    buffers[index] = child.api.nvim_get_current_buf()
  end
  return buffers
end

T["a repeated request cancels the first and runs after cleanup"] = function()
  start({ stylua = slow_stylua("0.5") })
  edit(make_project(UNFORMATTED))
  eq(format_now().started, true)
  eq(status(0), "active")
  -- The cancelled job still counts until its cleanup, so this one waits.
  local second = child.lua([[
    local format = require("iara.features.format_lua")
    return { format.format(0), format.status(0) }
  ]])
  eq(second, { true, "pending" })
  wait_all_idle()
  eq(buffer_lines(), FORMATTED)
  eq(messages(), "")
  child.cmd("undo")
  eq(buffer_lines(), UNFORMATTED)
end

T["admits two active and two pending requests session-wide"] = function()
  local fake = slow_stylua("0.4")
  start({ stylua = fake })
  local buffers = open_buffers(5)
  local results = child.lua(
    [[
    local format = require("iara.features.format_lua")
    local results = {}
    for _, buf in ipairs(...) do
      local started, err = format.format(buf)
      table.insert(results, {
        started = started, code = err and err.code, status = format.status(buf),
      })
    end
    -- Pending requests capture only when they start: this edit counts.
    vim.api.nvim_buf_set_lines(select(1, ...)[3], 0, 1, true, { "y  =  2" })
    return results
  ]],
    { buffers }
  )
  eq(
    vim.tbl_map(function(r)
      return r.status
    end, results),
    { "active", "active", "pending", "pending", "idle" }
  )
  eq(results[5], { started = false, code = "busy", status = "idle" })
  eq(wait_all_idle() <= 2, true)
  for index = 1, 4 do
    local got = child.api.nvim_buf_get_lines(buffers[index], 0, 1, true)[1]
    eq(got, index == 3 and "y = 2" or "local x = 1")
  end
  eq(child.api.nvim_buf_get_lines(buffers[5], 0, 1, true)[1], UNFORMATTED[1])
  match(messages(), "already waiting")
end

T["captures in batches and discards on an edit before spawning"] = function()
  local fake, log = slow_stylua("0")
  start({ stylua = fake })
  local many = {}
  for index = 1, 2500 do
    many[index] = ("local v%d  =  %d"):format(index, index)
  end
  edit(make_project(many))
  child.lua([[
    require("iara.features.format_lua").format(0)
    vim.api.nvim_buf_set_lines(0, 0, 1, true, { "local first  =  0" })
  ]])
  wait_all_idle()
  eq(starts(log), 0)
  eq(buffer_lines()[2], "local v2  =  2")
  match(messages(), "changed while formatting")
end

---Start a slow format, run `change` in the child, and wait.
local function change_while_formatting(change)
  eq(format_now().started, true)
  child.lua(change)
  wait_all_idle()
end

T["discards the result when the project loses trust"] = function()
  local project_file = make_project(UNFORMATTED)
  local project = vim.fs.dirname(vim.fs.dirname(project_file))
  local tools = project .. "/.tools/bin"
  vim.fn.mkdir(tools, "p")
  slow_stylua("0.4", tools)
  local personal = helpers.temp_dir() .. "/trusted.lua"
  helpers.write_file(personal, "return " .. vim.inspect({
    trusted_projects = { project },
  }))
  child.lua(
    [[
    _G.messages = {}
    vim.notify = function(message) table.insert(_G.messages, message) end
    require("iara.config").load({ personal_path = ... })
    require("iara.core.eligibility").setup({})
    require("iara.features.format_lua").setup({})
  ]],
    { personal }
  )
  edit(project_file)
  child.lua("vim.env.PATH = ...", { helpers.temp_dir() })
  change_while_formatting("")
  eq(buffer_lines(), FORMATTED)
  child.cmd("undo")
  -- Without trust the project tool is not even considered.
  reload({})
  eq(format_now(), { started = false, code = "not_found" })
  reload({}, { trusted_projects = { project } })
  eq(format_now().started, true)
  reload({})
  wait_all_idle()
  eq(buffer_lines(), UNFORMATTED)
  match(messages(), "result discarded: the project trust changed")
end

T["discards the result when formatting is disabled meanwhile"] = function()
  local fake = slow_stylua("0.4")
  start({ stylua = fake })
  edit(make_project(UNFORMATTED))
  local tick = child.api.nvim_buf_get_changedtick(0)
  eq(format_now().started, true)
  reload(false)
  wait_all_idle()
  eq(buffer_lines(), UNFORMATTED)
  eq(child.api.nvim_buf_get_changedtick(0), tick)
  match(messages(), "StyLua formatting was disabled")
end

T["discards the result when guarded options change"] = function()
  local fake = slow_stylua("0.4")
  start({ stylua = fake })
  edit(make_project(UNFORMATTED))
  change_while_formatting("vim.bo.fileformat = 'dos'")
  eq(buffer_lines(), UNFORMATTED)
  match(messages(), "'fileformat' changed while formatting")
  change_while_formatting("vim.bo.filetype = 'text'")
  eq(buffer_lines(), UNFORMATTED)
  match(messages(), "'filetype' changed while formatting")
end

T["discards the result outside Normal mode with a retry hint"] = function()
  local fake = slow_stylua("0.4")
  start({ stylua = fake })
  edit(make_project(UNFORMATTED))
  eq(format_now().started, true)
  child.type_keys("G", "A")
  wait_all_idle()
  child.type_keys("<Esc>")
  eq(buffer_lines(), UNFORMATTED)
  match(messages(), "not in Normal mode; retry")
end

T["wiping buffers cancels active and pending requests"] = function()
  local fake, log = slow_stylua("0.6")
  start({ stylua = fake })
  local buffers = open_buffers(3)
  local before = child.lua(
    [[
    local format = require("iara.features.format_lua")
    local buffers = ...
    for _, buf in ipairs(buffers) do format.format(buf) end
    local states = { format.status(buffers[1]), format.status(buffers[3]) }
    vim.cmd("bwipeout! " .. buffers[1])
    vim.cmd("bwipeout! " .. buffers[3])
    return states
  ]],
    { buffers }
  )
  eq(before, { "active", "pending" })
  wait_all_idle()
  -- The pending third request never started; the second one ran. The
  -- first may be stopped before its wrapper logs anything.
  eq(started(log, "file3.lua"), false)
  eq(started(log, "file2.lua"), true)
  eq(starts(log) <= 2, true)
  eq(child.api.nvim_buf_get_lines(buffers[2], 0, 1, true)[1], "local x = 1")
  eq(messages(), "")
end

return T
