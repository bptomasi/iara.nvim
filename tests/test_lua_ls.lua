-- Lua LSP and completion while typing (F6, M2). The fake server runs in
-- every suite run. The real lua-language-server runs when
-- IARA_TEST_LUA_LS names its executable (for example a Mason artifact
-- installed into temporary roots).
local helpers = require("helpers")
local editor_fixture = require("editor_fixture")

local eq = MiniTest.expect.equality

local ATTACHED = "return #vim.lsp.get_clients({ bufnr = 0 }) > 0"
local CMP_VISIBLE = "return package.loaded.cmp ~= nil"
  .. " and require('cmp').visible()"

local env, editor = nil, nil

---Personal configuration that runs `cmd` as lua_ls.
local function personal_with(cmd)
  local path = helpers.temp_dir() .. "/user.lua"
  local source = "return { languages = { lua = { cmd = %s } } }"
  helpers.write_file(path, source:format(vim.inspect(cmd)))
  return path
end

---Open `source` as main.lua in a new project with `cmd` as lua_ls.
local function open_lua(cmd, source)
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.lua", source)
  local personal = personal_with(cmd)
  editor = editor_fixture.start(
    vim.tbl_extend("force", env, { IARA_PERSONAL = personal }),
    dir
  )
  editor:lua("vim.cmd.edit(...)", { dir .. "/main.lua" })
  eq(editor:wait(ATTACHED, 60000), true)
end

---Type `text` one key at a time, as a person would, in Insert mode.
local function type_slowly(text)
  for index = 1, #text do
    editor:input(text:sub(index, index))
    vim.wait(30)
  end
end

---Labels of the visible completion entries.
local function entry_labels()
  return editor:lua([[
    local labels = {}
    for _, entry in ipairs(require("cmp").get_entries()) do
      table.insert(labels, entry:get_completion_item().label)
    end
    return labels
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

T["the menu opens while typing, without an explicit request"] = function()
  local log = helpers.temp_dir() .. "/requests.log"
  local cmd = { vim.v.progpath, "-l", editor_fixture.FAKE_LSP, log }
  open_lua(cmd, "local function target() end\n")
  editor:input("G")
  editor:input("o")
  type_slowly("iara_f")
  eq(editor:wait(CMP_VISIBLE), true)
  eq(vim.tbl_contains(entry_labels(), "iara_fake_completion"), true)
  editor:input("<CR>")
  eq(editor:wait("return vim.fn.getline(2) == 'iara_fake_completion'"), true)
end

T["real lua_ls completes while typing and finds definitions"] = function()
  local server = vim.env.IARA_TEST_LUA_LS
  if not server or vim.fn.executable(server) == 0 then
    MiniTest.skip("IARA_TEST_LUA_LS does not name a lua-language-server")
  end
  local source = "local function iara_target(value)\n"
    .. "  return value\nend\n\niara_target(1)\n"
  open_lua({ server }, source)
  editor:lua("vim.api.nvim_win_set_cursor(0, { 5, 0 })")
  editor:input("gd")
  eq(editor:wait("return vim.api.nvim_win_get_cursor(0)[1] == 1", 30000), true)
  editor:input("G")
  editor:input("o")
  type_slowly("vim.api.nvim_buf_get_li")
  eq(editor:wait(CMP_VISIBLE, 30000), true)
  -- lua_ls labels carry the signature: "nvim_buf_get_lines(buf, ...)".
  local found = editor:wait(
    "for _, entry in ipairs(require('cmp').get_entries()) do"
      .. " local label = entry:get_completion_item().label"
      .. " if vim.startswith(label, 'nvim_buf_get_lines(') then"
      .. " return true end end return false",
    30000
  )
  eq(found, true)
  editor:input("<CR>")
  local accepted = "return vim.startswith(vim.fn.getline('.'),"
    .. " 'vim.api.nvim_buf_get_lines')"
  eq(editor:wait(accepted), true)
end

return T
