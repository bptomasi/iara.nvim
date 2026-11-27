-- Baseline editing environment (F6) in a provisioned editor: LSP,
-- completion, snippets, Tree-sitter, Gitsigns, the explorer, Mason, and
-- their conservative-mode suspension.
local helpers = require("helpers")
local editor_fixture = require("editor_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local LUA_SOURCE = "local function target() end\ntarget()\n"

local ATTACHED = "return #vim.lsp.get_clients({ bufnr = ... }) > 0"
local HIGHLIGHTED = "return vim.treesitter.highlighter.active[...] ~= nil"
-- get_hunks() is nil only for buffers Gitsigns is not attached to.
local GIT_ATTACHED = "return require('gitsigns').get_hunks(...) ~= nil"
local DETACHED = "return #vim.lsp.get_clients({ bufnr = ... }) == 0"
local GIT_DETACHED = "return require('gitsigns').get_hunks(...) == nil"

local env, editor = nil, nil

local function current_buffer()
  return editor:lua("return vim.api.nvim_get_current_buf()")
end

local function edit(path)
  editor:lua("vim.cmd.edit(vim.fn.fnameescape(...))", { path })
  return current_buffer()
end

local function wait_for(code, bufnr)
  local chunk = code:gsub("%.%.%.", tostring(bufnr))
  return editor:wait(chunk)
end

local function holds(code, bufnr)
  return editor:lua(code, { bufnr })
end

---Start an editor whose lua_ls is the fake server; returns its log path.
local function start_with_fake_server(cwd)
  local log = helpers.temp_dir() .. "/requests.log"
  local personal = editor_fixture.fake_server_personal(log)
  local editor_env = vim.tbl_extend("force", env, { IARA_PERSONAL = personal })
  editor = editor_fixture.start(editor_env, cwd)
  return log
end

---Type `keys` in Insert mode, then request completion explicitly.
local function type_then_complete(keys)
  editor:input(keys)
  local typed = keys:sub(3)
  editor:wait(("return vim.fn.getline('.') == %q"):format(typed))
  editor:input("<C-Space>")
end

local function large_lua()
  local line = ("local value = %q\n"):format(("x"):rep(100))
  return line:rep(12000)
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

T["Oil keeps the parent entry visible with hidden files off"] = function()
  local dir = helpers.temp_dir()
  local subdir = dir .. "/nested"
  vim.fn.mkdir(subdir, "p")
  helpers.write_file(subdir .. "/visible.txt", "")
  helpers.write_file(subdir .. "/.hidden", "")
  editor = editor_fixture.start(env, dir)
  edit(subdir .. "/visible.txt")
  editor:input(" d")
  eq(
    editor:wait([[
    return vim.bo.filetype == 'oil'
      and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
        :find('visible.txt', 1, true) ~= nil
  ]]),
    true
  )
  eq(
    editor:lua([[
    local oil = require('oil')
    local names = {}
    for line = 1, vim.api.nvim_buf_line_count(0) do
      local entry = oil.get_entry_on_line(0, line)
      names[line] = entry and entry.name
    end
    return names
  ]]),
    { "..", "visible.txt" }
  )
  editor:lua("vim.api.nvim_win_set_cursor(0, { 1, 0 })")
  editor:input("<CR>")
  local in_parent = "return require('oil').get_current_dir() == %q"
  eq(editor:wait(in_parent:format(dir .. "/")), true)
end

T["the Tree-sitter installer offers the requested languages"] = function()
  editor = editor_fixture.start(env, helpers.temp_dir())
  eq(editor:lua("return vim.fn.exists(':TSInstall')"), 2)
  eq(editor:lua("return vim.fn.exists(':TSUpdate')"), 2)
  eq(
    editor:lua([[
    local dir = require("iara.core.parsers").extra_runtime()
    return vim.tbl_contains(vim.api.nvim_list_runtime_paths(), dir)
      and vim.uv.fs_stat(dir .. "/parser") == nil
  ]]),
    true
  )
  local available =
    editor:lua("return vim.fn.getcompletion('TSInstall ', 'cmdline')")
  local requested = {
    "hcl",
    "terraform",
    "bash",
    "go",
    "c",
    "cpp",
    "java",
    "javascript",
    "typescript",
    "tsx",
    "rust",
  }
  for _, lang in ipairs(requested) do
    eq(vim.tbl_contains(available, lang), true)
  end
end

T["highlights C with the bundled Tree-sitter parser"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.c", "int main(void) { return 0; }\n")
  editor = editor_fixture.start(env, dir)
  local bufnr = edit(dir .. "/main.c")
  eq(wait_for(HIGHLIGHTED, bufnr), true)
  eq(holds("return vim.treesitter.get_parser(...):lang()", bufnr), "c")
end

T["goes to definition and completes from the server in Lua"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.lua", LUA_SOURCE)
  local log = start_with_fake_server(dir)
  local bufnr = edit(dir .. "/main.lua")
  eq(wait_for(ATTACHED, bufnr), true)
  editor:lua("vim.api.nvim_win_set_cursor(0, { 2, 0 })")
  editor:input("gd")
  eq(editor:wait("return vim.api.nvim_win_get_cursor(0)[2] == 15"), true)
  eq(editor:lua("return vim.api.nvim_win_get_cursor(0)"), { 1, 15 })
  type_then_complete("Goiara_f")
  eq(editor:wait("return require('cmp').visible()"), true)
  editor:input("<CR>")
  eq(editor:wait("return vim.fn.getline(3) == 'iara_fake_completion'"), true)
  editor:input("<Esc>")
  type_then_complete("oiara_sn")
  eq(editor:wait("return require('cmp').visible()"), true)
  editor:input("<CR>")
  eq(editor:wait("return vim.fn.getline(4) == 'iara_snippet(argument)'"), true)
  editor:input("<Esc>:write<CR>")
  eq(editor:wait("return not vim.bo.modified"), true)
  local saved = vim.fn.readfile(dir .. "/main.lua")
  eq(saved[3], "iara_fake_completion")
  local methods = vim.fn.readfile(log)
  eq(vim.tbl_contains(methods, "textDocument/semanticTokens/full"), false)
  eq(vim.tbl_contains(methods, "textDocument/documentColor"), false)
end

T["highlights eligible Lua with Tree-sitter"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.lua", LUA_SOURCE)
  editor = editor_fixture.start(env, dir)
  local bufnr = edit(dir .. "/main.lua")
  eq(wait_for(HIGHLIGHTED, bufnr), true)
end

T["shows Git hunks for a changed tracked file"] = function()
  local repo = editor_fixture.git_repo({ ["main.lua"] = LUA_SOURCE })
  editor = editor_fixture.start(env, repo)
  local bufnr = edit(repo .. "/main.lua")
  eq(wait_for(GIT_ATTACHED, bufnr), true)
  editor:lua("vim.api.nvim_buf_set_lines(0, 1, 2, true, { 'changed()' })")
  local hunks = "return #(require('gitsigns').get_hunks(...) or {}) == 1"
  eq(wait_for(hunks, bufnr), true)
end

T["a large file attaches no server, parser, or Git work"] = function()
  local repo = editor_fixture.git_repo({
    ["large.lua"] = large_lua(),
    ["small.lua"] = LUA_SOURCE,
  })
  start_with_fake_server(repo)
  local large = edit(repo .. "/large.lua")
  local small = edit(repo .. "/small.lua")
  -- The small file proves activation ran; the large one must stay out.
  eq(wait_for(ATTACHED, small), true)
  eq(wait_for(GIT_ATTACHED, small), true)
  eq(holds(ATTACHED, large), false)
  eq(holds(HIGHLIGHTED, large), false)
  eq(holds(GIT_ATTACHED, large), false)
  editor:lua("vim.cmd.buffer(...)", { large })
  local statusline =
    editor:lua("return require('iara.core.statusline').render()")
  match(statusline, "conservative: large file")
end

T["a buffer that becomes conservative stops its services"] = function()
  local repo = editor_fixture.git_repo({ ["main.lua"] = LUA_SOURCE })
  start_with_fake_server(repo)
  local bufnr = edit(repo .. "/main.lua")
  eq(wait_for(ATTACHED, bufnr), true)
  eq(wait_for(GIT_ATTACHED, bufnr), true)
  eq(wait_for(HIGHLIGHTED, bufnr), true)
  editor:lua(
    "vim.api.nvim_buf_set_lines(0, -1, -1, true, { ('y'):rep(12000) })"
  )
  eq(wait_for(DETACHED, bufnr), true)
  eq(wait_for(GIT_DETACHED, bufnr), true)
  eq(holds(HIGHLIGHTED, bufnr), false)
end

T["resolves the server from Mason without changing PATH"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.lua", LUA_SOURCE)
  local data = env.XDG_DATA_HOME .. "/" .. env.NVIM_APPNAME
  local server = data .. "/mason/bin/lua-language-server"
  local script = "#!/bin/sh\nexec %q -l %q %q\n"
  local log = helpers.temp_dir() .. "/requests.log"
  helpers.write_file(
    server,
    script:format(vim.v.progpath, editor_fixture.FAKE_LSP, log)
  )
  vim.uv.fs_chmod(server, 493)
  editor = editor_fixture.start(env, dir)
  local bufnr = edit(dir .. "/main.lua")
  local attached = wait_for(ATTACHED, bufnr)
  local cmd = "local client = vim.lsp.get_clients({ bufnr = ... })[1]"
    .. " return client and client.config.cmd[1]"
  local used = holds(cmd, bufnr)
  local path = editor:lua("return vim.env.PATH")
  -- Later cases expect no Lua server in this shared installation.
  vim.fn.delete(data .. "/mason", "rf")
  eq(attached, true)
  eq(used, server)
  eq(path:find("mason", 1, true), nil)
end

T["a missing Lua server is reported and editing continues"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/main.lua", LUA_SOURCE)
  editor = editor_fixture.start(env, dir)
  edit(dir .. "/main.lua")
  local messages = editor:lua("return vim.fn.execute('messages')")
  match(messages, "lua_ls disabled: lua%-language%-server not found")
  editor:input("ox<Esc>")
  eq(editor:wait("return vim.fn.getline(2) == 'x'"), true)
end

T["the explorer hides dotfiles until toggled"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/visible.txt", "")
  helpers.write_file(dir .. "/.hidden_file", "")
  editor = editor_fixture.start(env, dir)
  editor:lua("vim.cmd('NvimTreeToggle')")
  local listed = "return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1,"
    .. " false), '\\n'):find(%q, 1, true) ~= nil"
  eq(editor:wait(listed:format("visible.txt")), true)
  eq(editor:lua(listed:format(".hidden_file")), false)
  editor:input("H")
  eq(editor:wait(listed:format(".hidden_file")), true)
end

return T
