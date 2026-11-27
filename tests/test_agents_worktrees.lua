-- G6 (M2-A): two agents in two Git worktrees writing in bursts while the
-- user holds modified buffers. The real `claude` and `codex` are never
-- started: the child's PATH holds only a fake agent under both names. On
-- "burst N" it rewrites its worktree's file.txt and notes.txt N times and
-- creates N new files, pausing 20 ms every ten writes so the editor
-- checks in between, then prints "burst-done".
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

local FAKE_AGENT = [[#!/bin/sh
printf 'cwd=%s\n' "$(pwd -P)"
name=${0##*/}
while read -r line; do
  case "$line" in
    burst*)
      count=${line#burst }
      i=0
      while [ "$i" -lt "$count" ]; do
        [ $((i % 10)) -eq 0 ] && sleep 0.02
        printf '%s write %s\n' "$name" "$i" > file.txt
        printf '%s note %s\n' "$name" "$i" > notes.txt
        printf 'x\n' > "gen/$name-$i.txt"
        i=$((i + 1))
      done
      printf 'burst-done\n' ;;
    exit*) exit "${line#exit }" ;;
  esac
done
]]

local CHILD_SETUP = [[
local bin = ...
vim.env.PATH = bin
vim.o.shell = "/bin/sh"
_G.messages = {}
vim.notify = function(message) table.insert(_G.messages, message) end
require("iara.core.term_retention").setup({})
require("iara.features.terminal").setup({ keymaps = {} })
require("iara.core.reconcile").setup({})
require("iara.extras.agents").setup({ extras = { agents = {} }, keymaps = {} })
registry = require("iara.features.terminal.registry")
reconcile = require("iara.core.reconcile")

function _G.text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---Edit `path`; with `edit`, replace its first line (a modified buffer).
function _G.open(path, edit)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.wait(20)
  if edit then
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { edit })
  end
  return vim.api.nvim_get_current_buf()
end

---Disk text held by a conflict's snapshot, read through its compare view.
function _G.snapshot_text(bufnr)
  local ok = reconcile.compare(bufnr)
  if not ok then
    return nil
  end
  local view = _G.text(vim.api.nvim_get_current_buf())
  vim.cmd.tabclose()
  return view
end
]]

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

local function git(args, cwd)
  local argv = { "git", "-c", "user.name=Iara", "-c", "user.email=i@a" }
  local result = helpers.run(vim.list_extend(argv, args), { cwd = cwd })
  assert(result.code == 0, result.stderr)
end

---A repository with a second worktree; both hold file.txt and notes.txt.
local function make_worktrees()
  local main = helpers.temp_dir() .. "/repo"
  helpers.write_file(main .. "/file.txt", "base\n")
  helpers.write_file(main .. "/notes.txt", "notes\n")
  git({ "init", "-q", main })
  git({ "add", "." }, main)
  git({ "commit", "-q", "-m", "base" }, main)
  local second = vim.fs.dirname(main) .. "/second"
  git({ "worktree", "add", "-q", "-b", "agent", second }, main)
  vim.fn.mkdir(main .. "/gen", "p")
  vim.fn.mkdir(second .. "/gen", "p")
  return vim.uv.fs_realpath(main), vim.uv.fs_realpath(second)
end

local function start()
  local bin = helpers.temp_dir()
  vim.uv.fs_symlink(vim.fn.exepath("sleep"), bin .. "/sleep")
  for _, name in ipairs({ "claude", "codex" }) do
    helpers.write_file(bin .. "/" .. name, FAKE_AGENT)
    vim.uv.fs_chmod(bin .. "/" .. name, tonumber("755", 8))
  end
  child.lua(CHILD_SETUP, { bin })
  for _, name in ipairs({ "claude", "codex" }) do
    local path = child.fn.exepath(name)
    assert(vim.startswith(path, bin), "real CLI on PATH")
  end
end

---Launch `name` from a modified buffer of `dir`/file.txt.
local function launch_in(dir, name)
  return child.lua(
    [[
    local dir, name = ...
    local bufnr = open(dir .. "/file.txt", "human edit in " .. name)
    open(dir .. "/notes.txt")
    vim.cmd.buffer(bufnr)
    local record = require("iara.extras.agents").launch(name)
    vim.cmd.stopinsert()
    vim.cmd.wincmd("p")
    return { record = record, bufnr = bufnr }
  ]],
    { dir, name }
  )
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Send "burst N" to both agents and run focus checks until both finish.
local function burst_with_checks(sessions, count)
  return child.lua(
    [[
    local sessions, count = ...
    for _, session in ipairs(sessions) do
      vim.fn.chansend(registry.get(session.id).job, "burst " .. count .. "\n")
    end
    local checks = 0
    local function done()
      for _, session in ipairs(sessions) do
        local transcript = text(session.bufnr)
        if not transcript:find("burst-done", 1, true) then return false end
      end
      return true
    end
    while not done() and checks < 400 do
      vim.api.nvim_exec_autocmds("FocusGained", {})
      vim.wait(25)
      checks = checks + 1
    end
    return { done = done(), checks = checks }
  ]],
    { sessions, count }
  )
end

---After the writers stopped, check once more and wait for snapshots.
local function settle(buffers)
  return child.lua(
    [[
    local buffers = ...
    vim.wait(50)
    reconcile.check()
    -- Let the queued check run before waiting on its snapshots.
    vim.wait(200)
    vim.wait(5000, function()
      for _, bufnr in ipairs(buffers) do
        local found = reconcile.conflict(bufnr)
        if not found or found.snapshot == "pending" then return false end
      end
      return true
    end, 10)
  ]],
    { buffers }
  )
end

---Text, conflict, and disk snapshot of each buffer.
local function buffer_states(buffers)
  return child.lua(
    [[
    local out = {}
    for _, bufnr in ipairs(...) do
      table.insert(out, {
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        modified = vim.bo[bufnr].modified,
        status = reconcile.statusline(bufnr),
        snapshot = reconcile.conflict(bufnr).snapshot,
        disk = snapshot_text(bufnr),
      })
    end
    return out
  ]],
    { buffers }
  )
end

T["two agents in two worktrees keep separate roots and sessions"] = function()
  start()
  local main, second = make_worktrees()
  local claude = launch_in(main, "claude")
  local codex = launch_in(second, "codex")
  eq(claude.record.cwd, main)
  eq(codex.record.cwd, second)
  eq(claude.record.project ~= codex.record.project, true)
  local transcripts = child.lua(
    [[
    local ids = ...
    local out = {}
    for _, id in ipairs(ids) do
      local bufnr = registry.get(id).bufnr
      vim.wait(5000, function() return text(bufnr):find("cwd=") end, 20)
      -- The agent panel opens at the right (UX2): long lines wrap.
      table.insert(out, (text(bufnr):gsub("\n", "")))
    end
    return out
  ]],
    { { claude.record.id, codex.record.id } }
  )
  match(transcripts[1], "cwd=" .. vim.pesc(main))
  match(transcripts[2], "cwd=" .. vim.pesc(second))
end

T["burst writes keep modified buffers and visible conflicts"] = function()
  start()
  local main, second = make_worktrees()
  local claude = launch_in(main, "claude")
  local codex = launch_in(second, "codex")
  local sessions = {
    { id = claude.record.id, bufnr = claude.record.bufnr },
    { id = codex.record.id, bufnr = codex.record.bufnr },
  }
  local run = burst_with_checks(sessions, 200)
  eq(run.done, true)
  settle({ claude.bufnr, codex.bufnr })
  local state = buffer_states({ claude.bufnr, codex.bufnr })
  -- No data loss: the buffers keep the human text, disk keeps the agents'.
  eq(state[1].lines, { "human edit in claude" })
  eq(state[2].lines, { "human edit in codex" })
  eq(read_file(main .. "/file.txt"), "claude write 199\n")
  eq(read_file(second .. "/file.txt"), "codex write 199\n")
  for index, entry in ipairs(state) do
    eq(entry.modified, true)
    eq(entry.status, "[disk: changed]")
    eq(entry.snapshot, "available")
    local name = index == 1 and "claude" or "codex"
    eq(entry.disk, name .. " write 199")
  end
  eq(#vim.fn.readdir(main .. "/gen"), 200)
end

T["unmodified buffers follow the burst without prompts"] = function()
  start()
  local main = make_worktrees()
  local claude = launch_in(main, "claude")
  local notes = child.lua("return vim.fn.bufnr(...)", { main .. "/notes.txt" })
  local sessions = { { id = claude.record.id, bufnr = claude.record.bufnr } }
  local run = burst_with_checks(sessions, 150)
  eq(run.done, true)
  settle({ claude.bufnr })
  eq(child.lua("return text(...)", { notes }), "claude note 149")
  eq(child.lua("return vim.bo[...].modified", { notes }), false)
  -- Detections are coalesced: far fewer messages than checks.
  local messages = child.lua_get("_G.messages")
  eq(run.checks > 5, true)
  -- One message for the conflict, none per later detection or reload.
  eq(#messages, 1)
  for _, message in ipairs(messages) do
    match(message, "^Iara: ")
  end
end

return T
