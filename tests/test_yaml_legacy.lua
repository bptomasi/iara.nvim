-- yaml-revealer continuity (D1) in a provisioned editor: the NvChad
-- breadcrumb and `Space ys`, one owner for its handlers, and suspension
-- in conservative buffers without silent reactivation.
local helpers = require("helpers")
local editor_fixture = require("editor_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local YAML = table.concat({
  "server:",
  "  http:",
  "    host: localhost",
  "    port: 8080",
  "items:",
  "  - name: first",
  "  - name: second",
  "",
}, "\n")

local env, editor, dir = nil, nil, nil

-- Breadcrumb text of the plugin's namespace on the cursor line.
local BREADCRUMB = [[
local ns = vim.api.nvim_create_namespace("yaml_revealer")
local row = vim.api.nvim_win_get_cursor(0)[1] - 1
local marks = vim.api.nvim_buf_get_extmarks(0, ns, { row, 0 }, { row, -1 },
  { details = true })
local mark = marks[1]
return mark and mark[4].virt_text[1][1] or vim.NIL
]]

local MARK_COUNT = [[
local ns = vim.api.nvim_create_namespace("yaml_revealer")
return #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
]]

local STATUS = [[
return require("iara.features.structured.yaml_legacy").status(0)
]]

-- Display handlers on the current buffer, by owner augroup.
local HANDLERS = [[
local found = vim.api.nvim_get_autocmds({ buffer = 0,
  event = { "CursorMoved", "BufEnter" } })
local groups = {}
for _, autocmd in ipairs(found) do
  local name = autocmd.group_name or "none"
  groups[name] = (groups[name] or 0) + 1
end
return groups
]]

local SEARCH_MAPPED = [[
return vim.fn.maparg(" ys", "n", false, true).buffer == 1
]]

local function edit(name, content)
  local path = dir .. "/" .. name
  helpers.write_file(path, content)
  editor:lua("vim.cmd.edit(vim.fn.fnameescape(...))", { path })
end

local function move_to(line)
  editor:lua("vim.api.nvim_win_set_cursor(0, { ..., 0 })", { line })
  editor:lua("vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })")
end

local function breadcrumb_at(line)
  move_to(line)
  return editor:lua(BREADCRUMB)
end

local function wait_state(state)
  local code = (
    "return require('iara.features.structured.yaml_legacy')"
    .. ".status(0).state == %q"
  ):format(state)
  return editor:wait(code)
end

local function notes()
  return editor:lua("return _G.notes")
end

local function large_yaml()
  local line = ("key_%%d: %s\n"):format(("x"):rep(100))
  local parts = {}
  for index = 1, 11000 do
    parts[index] = line:format(index)
  end
  return table.concat(parts)
end

-- Append enough text to push the current buffer over 1 MiB.
local GROW = [[
local filler = {}
for index = 1, 11000 do
  filler[index] = ("filler_%d: %s"):format(index, ("y"):rep(100))
end
vim.api.nvim_buf_set_lines(0, -1, -1, true, filler)
]]

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      env = editor_fixture.provisioned()
    end,
    pre_case = function()
      dir = helpers.temp_dir()
      editor = editor_fixture.start(env, dir)
      editor:lua([[
        _G.notes = {}
        vim.notify = function(message) table.insert(_G.notes, message) end
      ]])
    end,
    post_case = function()
      if editor then
        editor:stop()
        editor = nil
      end
    end,
  },
})

T["shows the current key path as in NvChad"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  eq(breadcrumb_at(4), "  → server.http.port")
  eq(breadcrumb_at(2), "  → server.http")
  eq(breadcrumb_at(7), "  → items[].name")
  -- One mark at a time, moving with the cursor.
  eq(editor:lua(MARK_COUNT), 1)
end

T["owns the display handlers instead of the plugin"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  -- Let a replayed FileType re-source the ftplugin, then re-check.
  editor:lua("vim.cmd.doautocmd('FileType')")
  editor:wait("return true")
  eq(
    editor:wait([[
    return #vim.api.nvim_get_autocmds({ group = "YamlRevealer",
      buffer = 0 }) == 0
  ]]),
    true
  )
  eq(editor:lua(HANDLERS), { IaraYamlLegacy = 2 })
end

T["Space ys jumps to a dotted key path"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  eq(editor:lua(SEARCH_MAPPED), true)
  editor:input(" ysserver.http.port<CR>")
  eq(editor:wait("return vim.fn.line('.') == 4"), true)
  eq(editor:lua(BREADCRUMB), "  → server.http.port")
end

T["Space ys jumps through sequence indexes and mixed indentation"] = function()
  edit("config.yaml", YAML .. "mixed:\n    child:\n      leaf: example\n")
  eq(wait_state("active"), true)
  editor:input(" ysitems[1].name<CR>")
  eq(editor:wait("return vim.fn.line('.') == 7"), true)
  editor:input(" ysmixed.child.leaf<CR>")
  eq(editor:wait("return vim.fn.line('.') == 10"), true)
end

T["Space ys finds exact names and quoted keys in flow maps"] = function()
  edit(
    "config.yml",
    [[
leaf: top
config: { "app.port": 8080, nested: [{ leaf: inside }] }
]]
  )
  eq(wait_state("active"), true)
  editor:input([[ ysconfig."app.port"<CR>]])
  eq(
    editor:wait("return vim.fn.line('.') == 2 and vim.fn.col('.') == 11"),
    true
  )
  editor:input(" ysconfig.nested[0].leaf<CR>")
  eq(editor:wait("return vim.fn.col('.') == 40"), true)
  editor:input(" ysleaf<CR>")
  eq(editor:wait("return vim.fn.line('.') == 1"), true)
end

T["Space ys leaves the cursor on a missing path"] = function()
  edit("config.yaml", YAML .. "staging:\n  http:\n    host: staged\n")
  eq(wait_state("active"), true)
  move_to(2)
  editor:input(" ysstaging.http.port<CR>")
  eq(editor:wait("return #_G.notes == 1"), true)
  match(notes()[1], "YAML key not found: staging%.http%.port")
  eq(editor:lua("return vim.fn.line('.')"), 2)
end

T["Space ys ignores an empty search silently"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  editor:input(" ys<CR>")
  editor:wait("return vim.fn.mode() == 'n'")
  eq(editor:lua("return vim.api.nvim_get_mode().blocking"), false)
  eq(notes(), {})
end

T["suspends a large YAML file with a visible reason"] = function()
  edit("large.yaml", large_yaml())
  eq(wait_state("suspended"), true)
  match(editor:lua(STATUS).message, "large file")
  match(notes()[1], "^Iara: yaml%-revealer suspended.*large file")
  eq(editor:lua(HANDLERS), vim.empty_dict())
  move_to(3)
  eq(editor:lua(MARK_COUNT), 0)
end

T["refuses Space ys in a suspended buffer and says why"] = function()
  edit("large.yaml", large_yaml())
  eq(wait_state("suspended"), true)
  move_to(5)
  editor:input(" yskey_1<CR>")
  eq(editor:wait("return #_G.notes >= 2"), true)
  match(notes()[2], "suspended: large file")
  eq(editor:lua("return vim.fn.line('.')"), 5)
end

T["growing past the size limit suspends the breadcrumb"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  eq(breadcrumb_at(4), "  → server.http.port")
  editor:lua(GROW)
  eq(wait_state("suspended"), true)
  match(editor:lua(STATUS).message, "large file")
  eq(editor:lua(MARK_COUNT), 0)
  eq(editor:lua(HANDLERS), vim.empty_dict())
end

T["stays suspended when eligible again until resumed"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  editor:lua(GROW)
  eq(wait_state("suspended"), true)
  editor:lua("vim.api.nvim_buf_set_lines(0, 7, -1, true, {})")
  eq(
    editor:wait([[return require("iara.core.eligibility")
    .is_eligible(0)]]),
    true
  )
  editor:wait("return #_G.notes >= 2")
  eq(editor:lua(STATUS).state, "suspended")
  match(editor:lua(STATUS).message, ":IaraYamlResume")
  eq(breadcrumb_at(4), vim.NIL)
  editor:lua("vim.cmd('IaraYamlResume')")
  eq(editor:lua(STATUS).state, "active")
  eq(breadcrumb_at(4), "  → server.http.port")
end

T["refuses to resume a buffer that is still large"] = function()
  edit("large.yaml", large_yaml())
  eq(wait_state("suspended"), true)
  editor:lua("vim.cmd('IaraYamlResume')")
  match(notes()[#notes()], "cannot resume yaml%-revealer: large file")
  eq(editor:lua(STATUS).state, "suspended")
end

T["leaves other filetypes untouched"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  edit("data.json", '{ "server": { "port": 8080 } }\n')
  move_to(1)
  eq(editor:lua("return vim.bo.filetype"), "json")
  eq(editor:lua(STATUS).state, "unmanaged")
  eq(editor:lua(SEARCH_MAPPED), false)
  eq(editor:lua(MARK_COUNT), 0)
  eq(editor:lua(HANDLERS).IaraYamlLegacy, nil)
end

T["releases a buffer whose filetype changes away from YAML"] = function()
  edit("config.yaml", YAML)
  eq(wait_state("active"), true)
  eq(breadcrumb_at(4), "  → server.http.port")
  editor:lua("vim.bo.filetype = 'text'")
  eq(editor:lua(STATUS).state, "unmanaged")
  eq(editor:lua(SEARCH_MAPPED), false)
  eq(editor:lua(MARK_COUNT), 0)
  eq(editor:lua(HANDLERS).IaraYamlLegacy, nil)
end

return T
