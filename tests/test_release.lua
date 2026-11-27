-- Release acceptance (task R1): with AI disabled, the provisioned editor
-- still searches, opens terminals, and navigates files and JSON paths
-- through the user-facing mappings.
local helpers = require("helpers")
local editor_fixture = require("editor_fixture")

local eq = MiniTest.expect.equality

local JSON = '{\n  "server": {\n    "port": 8080\n  }\n}\n'

local env, editor, dir = nil, nil, nil

local function start(personal)
  local file = helpers.temp_dir() .. "/user.lua"
  helpers.write_file(file, personal)
  dir = editor_fixture.git_repo({
    ["needle.txt"] = "needle here\n",
    ["data.json"] = JSON,
  })
  local editor_env = vim.tbl_extend("force", env, { IARA_PERSONAL = file })
  editor = editor_fixture.start(editor_env, dir)
  editor:wait("return require('iara').status() ~= nil")
  editor:lua([[
    vim.o.shell = "/bin/sh"
    _G.notes = {}
    vim.notify = function(message) table.insert(_G.notes, message) end
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

-- Whether the open picker has at least `count` rows whose record
-- identity names `path`.
local ROWS_NAMING = [[
  local path, wanted = ...
  local picker = _G.Snacks and Snacks.picker.get()[1]
  if not picker then return false end
  local count = 0
  for row in picker:iter() do
    if tostring(row.text):find(path, 1, true) then count = count + 1 end
  end
  return count >= wanted
]]

---Search `needle` through a mapping and wait for `rows` rows naming
---needle.txt.
local function search_with(lhs, rows)
  editor:input(lhs)
  local opened = "return _G.Snacks ~= nil and #Snacks.picker.get() == 1"
  eq(editor:wait(opened), true)
  editor:input("needle")
  local found = vim.wait(20000, function()
    return editor:lua(ROWS_NAMING, { "needle.txt", rows }) == true
  end, 20)
  eq(found, true)
  editor:lua("Snacks.picker.get()[1]:close()")
  editor:input("<Esc>")
end

---Space ff finds the file by name; Space fw finds its content (a file
---header and an occurrence).
local function search_by_mapping()
  editor:lua("vim.cmd.edit('needle.txt')")
  search_with(" ff", 1)
  search_with(" fw", 2)
end

---Space yp: the JSON path at the cursor.
local function json_path_by_mapping()
  editor:lua("vim.cmd.edit('data.json')")
  editor:lua("vim.api.nvim_win_set_cursor(0, { 3, 4 })")
  editor:input(" yp")
  eq(editor:wait("return #_G.notes > 0"), true)
  eq(
    editor:lua("return _G.notes[#_G.notes]"),
    'Iara: server.port  doc[1]::$["server"]["port"]'
  )
end

T["without agents the mappings search, open terminals, navigate"] = function()
  start("return { extras = { agents = false } }")
  eq(editor:lua("return vim.fn.exists(':IaraAgent')"), 0)
  eq(editor:lua("return #require('iara').status().errors"), 0)
  search_by_mapping()
  json_path_by_mapping()

  -- Ctrl-n: the file explorer opens.
  editor:input("<C-n>")
  eq(editor:wait("return vim.bo.filetype == 'NvimTree'"), true)
  editor:input("<C-n>")

  -- F7: the main terminal of the project runs.
  editor:lua("vim.cmd.wincmd('p')")
  editor:input("<F7>")
  local running = [[
    local main = require("iara.features.terminal.registry").list()[1]
    return main ~= nil and main.status == "running"
  ]]
  eq(editor:wait(running), true)
end

T["Space d opens the parent directory before the mapping timeout"] = function()
  start("return {}")
  helpers.write_file(dir .. "/nested/sample.txt", "sample\n")
  editor:lua([[
    vim.cmd.edit("nested/sample.txt")
    vim.o.timeoutlen = 20000
  ]])
  eq(editor:lua("return package.loaded.oil == nil"), true)

  editor:input(" d")
  local opened = [[
    return package.loaded.oil ~= nil
      and vim.bo.filetype == "oil"
      and vim.fs.basename(vim.fs.normalize(require("oil").get_current_dir()))
        == "nested"
  ]]
  eq(editor:wait(opened, 5000), true)
  eq(editor:lua("return require('oil.config').delete_to_trash"), true)
end

T["Space sd sends diagnostics to the location list"] = function()
  start("return {}")
  editor:lua([[
    vim.cmd.edit("needle.txt")
    local ns = vim.api.nvim_create_namespace("release-diagnostics")
    vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, message = "fixture" } })
  ]])
  editor:input(" sd")
  local listed = [[
    local items = vim.fn.getloclist(0)
    return #items == 1 and items[1].text == "fixture"
  ]]
  eq(editor:wait(listed), true)
  eq(editor:lua("return package.loaded.oil == nil"), true)
end

return T
