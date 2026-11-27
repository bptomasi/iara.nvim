-- Agent terminals (A1). The real `claude` and `codex` are never started:
-- the child's PATH holds only fake executables that print their argv and
-- working directory, echo input lines, and exit on "exit N".
local editor_fixture = require("editor_fixture")
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

local FAKE_AGENT = [[#!/bin/sh
printf 'cwd=%s\n' "$(pwd -P)"
for arg in "$@"; do printf 'arg=[%s]\n' "$arg"; done
printf 'argc=%s\n' "$#"
while read -r line; do
  case "$line" in
    exit*) exit "${line#exit }" ;;
    *) printf 'got=%s\n' "$line" ;;
  esac
done
]]

---Child-side helpers. `vim.notify` messages are collected, and the
---clipboard is a fake so tests never touch the real one.
local CHILD_HELPERS = [[
local fake_bin, config = ...
vim.env.PATH = fake_bin
vim.o.shell = "/bin/sh"
vim.g.mapleader = " "
_G.messages = {}
vim.notify = function(message) table.insert(_G.messages, message) end
_G.copied = {}
vim.g.clipboard = {
  name = "test",
  copy = { ["+"] = function(lines) _G.copied["+"] = lines end,
    ["*"] = function(lines) _G.copied["*"] = lines end },
  paste = { ["+"] = function() return _G.copied["+"] or {} end,
    ["*"] = function() return {} end },
}
require("iara.core.term_retention").setup({})
terminal = require("iara.features.terminal")
terminal.setup({ keymaps = {} })
registry = require("iara.features.terminal.registry")
panel = require("iara.features.terminal.panel")
root_mod = require("iara.core.root")
ctx = require("iara.extras.agents.context")
agents = require("iara.extras.agents")
agents.setup(config)

---Edit `name` inside project `dir`, which gets a `.git` marker.
function _G.edit(dir, name, lines)
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. (name or "file.txt")))
  if lines then vim.api.nvim_buf_set_lines(0, 0, -1, true, lines) end
  return root_mod.resolve(0)
end

function _G.text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function _G.wait_text(bufnr, pattern)
  vim.wait(10000, function() return text(bufnr):find(pattern) ~= nil end, 20)
  return text(bufnr)
end

function _G.wait_status(id, status)
  vim.wait(10000, function()
    local record = registry.get(id)
    return record ~= nil and record.status == status
  end, 20)
  return registry.get(id)
end

function _G.alive(id)
  return vim.fn.jobwait({ registry.get(id).job }, 0)[1] == -1
end

function _G.send(id, line)
  vim.fn.chansend(registry.get(id).job, line .. "\n")
end

---Answer the next vim.ui.select with the item whose text matches.
function _G.pick(pattern)
  vim.ui.select = function(items, opts, on_choice)
    _G.offered = vim.tbl_map(opts.format_item, items)
    for _, item in ipairs(items) do
      if opts.format_item(item):find(pattern, 1, true) then
        return on_choice(item)
      end
    end
    on_choice(nil)
  end
end

function _G.wait_panel(bufnr)
  vim.wait(10000, function() return panel.agent:buffer() == bufnr end, 20)
  return panel.agent:buffer()
end
]]

local ENABLED = { extras = { agents = {} }, keymaps = {} }

---A directory with fake `claude` and `codex` executables.
local function fake_bin()
  local dir = helpers.temp_dir()
  for _, name in ipairs({ "claude", "codex" }) do
    helpers.write_file(dir .. "/" .. name, FAKE_AGENT)
    vim.uv.fs_chmod(dir .. "/" .. name, tonumber("755", 8))
  end
  return dir
end

---Load the module in the child with `config` and `bin` as the only PATH.
local function start(config, bin)
  bin = bin or fake_bin()
  child.lua(CHILD_HELPERS, { bin, config or ENABLED })
  -- Never reach the real CLIs: both names must resolve to fakes or fail.
  for _, name in ipairs({ "claude", "codex" }) do
    local path = child.fn.exepath(name)
    assert(path == "" or vim.startswith(path, bin), "real CLI on PATH")
  end
  return bin
end

local function run(code, ...)
  return child.lua(code, { ... })
end

local function wait_mode(expected)
  vim.wait(10000, function()
    return child.api.nvim_get_mode().mode == expected
  end, 20)
  return child.api.nvim_get_mode().mode
end

local function launch(name)
  return run("return { agents.launch(...) }", name)
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

T["launches claude with its native argv at the project root"] = function()
  start()
  local project = helpers.temp_dir()
  local root = run("return edit(...)", project, "sub/file.txt")
  run("vim.cmd.cd(...)", helpers.temp_dir())
  local record = launch("claude")[1]
  eq(record.role, "agent")
  eq(record.name, "claude")
  eq(record.argv, { "claude" })
  eq(record.env, {})
  eq(record.cwd, root.path)
  match(record.label, "claude 1$")
  match(record.label, vim.pesc(root.label))
  -- The agent panel is at the right (UX2), so long lines wrap.
  local transcript = run("return wait_text(...)", record.bufnr, "argc=")
  transcript = transcript:gsub("\n", "")
  match(transcript, "cwd=" .. vim.pesc(root.path))
  match(transcript, "argc=0")
  eq(run("return panel.agent:buffer()"), record.bufnr)
  eq(wait_mode("t"), "t")
end

T["passes a configured argv unchanged and refuses bypass flags"] = function()
  local config = vim.deepcopy(ENABLED)
  config.extras.agents = {
    claude = { argv = { "claude", "--settings", "a b.json" } },
    codex = { argv = { "codex", "--yolo" } },
  }
  start(config)
  run("edit(...)", helpers.temp_dir())
  local messages = run("return _G.messages")
  match(table.concat(messages, "\n"), "codex.*bypass argument %-%-yolo")
  local claude = launch("claude")[1]
  eq(claude.argv, { "claude", "--settings", "a b.json" })
  local transcript = run("return wait_text(...)", claude.bufnr, "argc=")
  match(transcript, "arg=%[%-%-settings%]\r?\narg=%[a b%.json%]")
  match(transcript, "argc=2")
  local codex = launch("codex")[1]
  eq(codex.argv, { "codex" })
  match(run("return wait_text(...)", codex.bufnr, "argc="), "argc=0")
end

T["keeps one independent session per agent and refocuses it"] = function()
  start()
  run("edit(...)", helpers.temp_dir())
  local claude = launch("claude")[1]
  local codex = launch("codex")[1]
  eq(claude.id ~= codex.id and claude.bufnr ~= codex.bufnr, true)
  match(codex.label, "codex 1$")
  eq(run("return panel.agent:buffer()"), codex.bufnr)
  run("send(...)", claude.id, "hello claude")
  match(run("return wait_text(...)", claude.bufnr, "got="), "got=hello claude")
  run("wait_text(...)", codex.bufnr, "argc=")
  eq(run("return text(...)", codex.bufnr):find("got=") == nil, true)
  local again = launch("claude")[1]
  eq(again.id, claude.id)
  eq(run("return panel.agent:buffer()"), claude.bufnr)
  eq(run("return #registry.list({ role = 'agent' })"), 2)
  eq(run("return alive(...) and alive(...)", claude.id, codex.id), true)
end

T["switches sessions and starts new instances from the picker"] = function()
  start()
  run("edit(...)", helpers.temp_dir())
  local claude = launch("claude")[1]
  local codex = launch("codex")[1]
  run("pick('claude 1') agents.select()")
  eq(run("return wait_panel(...)", claude.bufnr), claude.bufnr)
  local offered = run("return _G.offered")
  eq(#offered, 4)
  match(offered[2], "codex 1")
  match(offered[3], "^New Claude Code session in ")
  match(offered[4], "^New Codex session in ")
  run("pick('New Codex') agents.select()")
  local second = run([[
    vim.wait(10000, function()
      return #registry.list({ role = "agent" }) == 3
    end, 20)
    return registry.list({ role = "agent" })[3]
  ]])
  match(second.label, "codex 2$")
  eq(run("return wait_panel(...)", second.bufnr), second.bufnr)
  eq(run("return alive(...)", codex.id), true)
end

T["hiding the panel leaves the agent running"] = function()
  start()
  run("edit(...)", helpers.temp_dir())
  local record = launch("claude")[1]
  eq(wait_mode("t"), "t")
  child.type_keys("<F7>")
  eq(wait_mode("n"), "n")
  eq(run("return panel.agent:window()"), vim.NIL)
  run("send(...)", record.id, "while hidden")
  local transcript = run("return wait_text(...)", record.bufnr, "got=")
  match(transcript, "got=while hidden")
  eq(run("return registry.get(...).status", record.id), "running")
end

T["reports the exit status and shows the exited session again"] = function()
  start()
  run("edit(...)", helpers.temp_dir())
  local record = launch("codex")[1]
  run("wait_text(...)", record.bufnr, "argc=")
  run("send(...)", record.id, "exit 7")
  local exited = run("return wait_status(...)", record.id, "exited")
  eq(exited.exit_code, 7)
  local messages = table.concat(run("return _G.messages"), "\n")
  match(messages, "codex 1 exited with status 7")
  run("panel.agent:hide()")
  local again = launch("codex")[1]
  eq(again.id, record.id)
  eq(again.status, "exited")
  eq(run("return panel.agent:buffer()"), record.bufnr)
end

---Wait until the record is disposed; true when it is gone.
local function wait_gone(id)
  return run(
    [[
    local id = ...
    vim.wait(10000, function() return registry.get(id) == nil end, 20)
    return registry.get(id) == nil
  ]],
    id
  )
end

T["a successful exit closes the session and its panel"] = function()
  start()
  run("edit(...)", helpers.temp_dir())
  local editor = run("return vim.api.nvim_get_current_win()")
  local record = launch("claude")[1]
  run("wait_text(...)", record.bufnr, "argc=")
  run("send(...)", record.id, "exit 0")
  eq(wait_gone(record.id), true)
  eq(run("return panel.agent:window()"), vim.NIL)
  eq(run("return vim.api.nvim_get_current_win()"), editor)
  eq(run("return vim.api.nvim_buf_is_valid(...)", record.bufnr), false)
end

T["close_on_exit false keeps even a successful transcript"] = function()
  start({ extras = { agents = { close_on_exit = false } }, keymaps = {} })
  run("edit(...)", helpers.temp_dir())
  local record = launch("codex")[1]
  run("wait_text(...)", record.bufnr, "argc=")
  run("send(...)", record.id, "exit 0")
  eq(run("return wait_status(...)", record.id, "exited").exit_code, 0)
  -- Give a wrongly scheduled close the chance to run.
  run("vim.wait(100)")
  eq(run("return registry.get(...).status", record.id), "exited")
  eq(run("return panel.agent:buffer()"), record.bufnr)
end

T["close_on_exit true closes a failed session too"] = function()
  start({ extras = { agents = { close_on_exit = true } }, keymaps = {} })
  run("edit(...)", helpers.temp_dir())
  local record = launch("codex")[1]
  run("wait_text(...)", record.bufnr, "argc=")
  run("send(...)", record.id, "exit 3")
  eq(wait_gone(record.id), true)
  eq(run("return panel.agent:window()"), vim.NIL)
end

T["an invalid close_on_exit is reported and keeps failures"] = function()
  start({ extras = { agents = { close_on_exit = "always" } }, keymaps = {} })
  local messages = table.concat(run("return _G.messages"), "\n")
  match(messages, "close_on_exit must be")
  eq(messages:find("unknown agent"), nil)
  run("edit(...)", helpers.temp_dir())
  local record = launch("claude")[1]
  run("wait_text(...)", record.bufnr, "argc=")
  run("send(...)", record.id, "exit 2")
  run("wait_status(...); vim.wait(100)", record.id, "exited")
  eq(run("return registry.get(...).status", record.id), "exited")
end

T["a missing CLI is reported and changes nothing"] = function()
  start(ENABLED, helpers.temp_dir())
  run("edit(...)", helpers.temp_dir())
  local before = run([[return { bufs = #vim.api.nvim_list_bufs(),
    wins = #vim.api.nvim_list_wins() }]])
  local result = launch("codex")
  eq(result[1], vim.NIL)
  eq(result[2].code, "not_found")
  local after = run([[return { bufs = #vim.api.nvim_list_bufs(),
    wins = #vim.api.nvim_list_wins() }]])
  eq(after, before)
  eq(run("return #registry.list()"), 0)
  match(table.concat(run("return _G.messages"), "\n"), "Codex is not installed")
end

---Preview window content, after the preview took focus.
local function preview_text()
  return run([[
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_config(win).relative == "" then return nil end
    return text(vim.api.nvim_get_current_buf())
  ]])
end

---The context module retains at most four snapshots, so four captures
---succeed only when every earlier snapshot was released.
local function all_released()
  return run([[
    for _ = 1, 4 do
      local snapshot = ctx.capture({ mode = "reference" })
      if not snapshot then return false end
    end
    return true
  ]])
end

T["previews a live block to the line end, copies, and releases"] = function()
  start()
  run("edit(...)", helpers.temp_dir(), "a.txt", { "ab", "cdefgh", "ij" })
  child.type_keys("gg", "l", "<C-v>", "j", "$", " as")
  local shown = preview_text()
  match(shown, "unsaved")
  match(shown, "\nb\ndefgh\n")
  child.type_keys("y")
  local copied = run("return _G.copied['+']")
  eq(table.concat(copied, "\n"), shown)
  child.type_keys("q")
  eq(run("return vim.api.nvim_win_get_config(0).relative"), "")
  eq(child.api.nvim_get_mode().mode, "n")
  eq(all_released(), true)
end

T["previews a disk reference without unsaved text"] = function()
  start()
  local dir = helpers.temp_dir()
  run("edit(...)", dir, "b.txt", { "unsaved secret" })
  child.type_keys(" af")
  local shown = preview_text()
  match(shown, vim.pesc(vim.uv.fs_realpath(dir)) .. "/b%.txt")
  eq(shown:find("unsaved secret", 1, true), nil)
  child.type_keys("q")
  eq(all_released(), true)
end

T["a disabled module registers nothing; terminals still work"] = function()
  start({ extras = { agents = false }, keymaps = {} })
  run("edit(...)", helpers.temp_dir())
  eq(run("return vim.fn.exists(':IaraAgent')"), 0)
  eq(run("return vim.fn.maparg(' aa', 'n')"), "")
  eq(run("return vim.fn.maparg(' as', 'x')"), "")
  child.type_keys("<F7>")
  eq(wait_mode("t"), "t")
  eq(run("return registry.list()[1].role"), "main")
end

-- Full startup in a provisioned editor ------------------------------------

local provisioned_env, editor = nil, nil

local startup = MiniTest.new_set({
  hooks = {
    pre_once = function()
      provisioned_env = editor_fixture.provisioned()
    end,
    post_case = function()
      if editor then
        editor:stop()
        editor = nil
      end
    end,
  },
})
T["full startup"] = startup

---Content search through the grep lane; returns the result state.
local SEARCH = [[
  local root = ...
  local state = nil
  require("iara.features.search.grep").run({
    root = root, files = { "notes.txt" }, query = "needle",
    regex = false, case = "smart", generation = 1,
  }, { on_file = function() end,
    on_done = function(result) state = result.state end })
  vim.wait(15000, function() return state ~= nil end, 20)
  return state
]]

local TERMINAL = [[
  vim.o.shell = "/bin/sh"
  vim.cmd("IaraTermToggle")
  local main = require("iara.features.terminal.registry").list()[1]
  return main and main.status
]]

local function start_editor(personal)
  local dir = editor_fixture.git_repo({ ["notes.txt"] = "needle here\n" })
  local env = provisioned_env
  if personal then
    local path = helpers.temp_dir() .. "/user.lua"
    helpers.write_file(path, personal)
    env = vim.tbl_extend("force", env, { IARA_PERSONAL = path })
  end
  editor = editor_fixture.start(env, dir)
  editor:wait("return require('iara').status() ~= nil")
  return dir
end

startup["disabled agents leave editing, search, and terminals"] = function()
  local dir = start_editor("return { extras = { agents = false } }")
  eq(editor:lua("return package.loaded['iara.extras.agents'] == nil"), true)
  eq(editor:lua("return vim.fn.exists(':IaraAgent')"), 0)
  editor:lua("vim.cmd.edit('notes.txt')")
  editor:input("ggIedited <Esc>")
  eq(editor:wait("return vim.fn.getline(1) == 'edited needle here'"), true)
  eq(editor:lua(SEARCH, { vim.uv.fs_realpath(dir) }), "complete")
  eq(editor:lua(TERMINAL), "running")
end

startup["registers agents by default without launching a CLI"] = function()
  start_editor(nil)
  eq(editor:lua("return vim.fn.exists(':IaraAgent')"), 2)
  local desc = "return vim.fn.maparg(vim.g.mapleader .. 'as', 'x', 0, 1).desc"
  eq(editor:lua(desc), "Preview selection for agent")
  local agents = [[return #require("iara.features.terminal.registry")
    .list({ role = "agent" })]]
  eq(editor:lua(agents), 0)
  eq(editor:lua("return #require('iara').status().errors"), 0)
end

return T
