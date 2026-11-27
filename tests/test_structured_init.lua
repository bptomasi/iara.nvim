-- The `features.structured` step (task D4) in a provisioned editor: JSON
-- actions behind `Space y`, YAML still served by yaml-revealer, and a
-- disabled capability that leaves nothing behind.
local helpers = require("helpers")
local editor_fixture = require("editor_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local JSON = '{\n  "server": {\n    "port": 8080\n  }\n}\n'
local YAML = "server:\n  http:\n    host: localhost\n    port: 8080\n"

local env, editor, dir = nil, nil, nil

local function start(personal)
  local editor_env = env
  if personal then
    local file = helpers.temp_dir() .. "/user.lua"
    helpers.write_file(file, personal)
    editor_env = vim.tbl_extend("force", env, { IARA_PERSONAL = file })
  end
  dir = helpers.temp_dir()
  editor = editor_fixture.start(editor_env, dir)
  editor:lua([[
    _G.notes = {}
    vim.notify = function(message) table.insert(_G.notes, message) end
  ]])
end

local function edit(name, content)
  local file = dir .. "/" .. name
  helpers.write_file(file, content)
  editor:lua("vim.cmd.edit(vim.fn.fnameescape(...))", { file })
end

local function move_to(line, col)
  editor:lua("vim.api.nvim_win_set_cursor(0, ...)", { { line, col } })
  editor:lua("vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })")
end

local function step_state()
  return editor:lua([[
    for _, step in ipairs(require("iara").status().steps) do
      if step.name == "iara.features.structured" then return step.state end
    end
  ]])
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      env = editor_fixture.provisioned()
    end,
    post_case = function()
      if editor then
        editor:stop()
        editor = nil
      end
    end,
  },
})

T["JSON gets the breadcrumb, path, and key search"] = function()
  start()
  eq(step_state(), "loaded")
  edit("data.json", JSON)
  move_to(3, 4)
  local crumb = [[
    local shown = require("iara.features.structured.ui").breadcrumb()
    return shown ~= nil and shown.text == "  → server.port"
  ]]
  eq(editor:wait(crumb), true)
  editor:input(" yp")
  eq(editor:wait("return #_G.notes > 0"), true)
  eq(
    editor:lua("return _G.notes[1]"),
    'Iara: server.port  doc[1]::$["server"]["port"]'
  )
  editor:input(" ys")
  local opened = "return _G.Snacks ~= nil and #Snacks.picker.get() == 1"
  eq(editor:wait(opened), true)
end

T["YAML keeps yaml-revealer's Space ys"] = function()
  start()
  edit("config.yaml", YAML)
  local active = [[return require("iara.features.structured.yaml_legacy")
    .status(0).state == "active"]]
  eq(editor:wait(active), true)
  editor:input(" ysserver.http.port<CR>")
  eq(editor:wait("return vim.fn.line('.') == 4"), true)
  -- The command routes the same way.
  move_to(1, 0)
  editor:input(":IaraStructuredSearch<CR>server.http.host<CR>")
  eq(editor:wait("return vim.fn.line('.') == 3"), true)
  -- No JSON breadcrumb or picker in a YAML buffer.
  local ui = "require('iara.features.structured.ui')"
  eq(editor:lua("return " .. ui .. ".breadcrumb() == nil"), true)
  eq(editor:lua("return _G.Snacks == nil or #Snacks.picker.get() == 0"), true)
end

T["disabled features.structured leaves nothing behind"] = function()
  start("return { features = { structured = false } }")
  eq(step_state(), "disabled")
  edit("data.json", JSON)
  move_to(3, 4)
  edit("config.yaml", YAML)
  move_to(4, 4)
  vim.wait(200)
  local leftovers = editor:lua([[
    local commands = vim.api.nvim_get_commands({})
    local function mapped(lhs)
      return vim.fn.maparg(lhs, "n") ~= ""
    end
    return {
      group = pcall(vim.api.nvim_get_autocmds, { group = "IaraStructured" }),
      commands = commands.IaraStructuredPath ~= nil
        or commands.IaraYamlResume ~= nil,
      maps = mapped(" ys") or mapped(" yc") or mapped(" yp"),
      ui = package.loaded["iara.features.structured.ui"] ~= nil,
      revealer = vim.fn.exists("*DisplayYamlPath") == 1,
      marks = #vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}),
    }
  ]])
  eq(leftovers, {
    group = false,
    commands = false,
    maps = false,
    ui = false,
    revealer = false,
    marks = 0,
  })
  match(vim.inspect(editor:lua("return _G.notes")), "^{}$")
end

return T
