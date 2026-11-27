local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

---Child-side helpers. Terminals are real PTY jobs running short-lived
---commands through /bin/sh; nothing is ever shown in a window.
local CHILD_HELPERS = [[
vim.o.shell = "/bin/sh"
vim.notify = function() end
retention = require("iara.core.term_retention")
registry = require("iara.features.terminal.registry")
root_mod = require("iara.core.root")

_G.events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "IaraTerminalChanged",
  callback = function(args) table.insert(_G.events, args.data) end,
})

---Resolve the root of a file inside `dir`, which gets a `.git` marker.
function _G.project(dir)
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/file.txt"))
  return root_mod.resolve(0)
end

function _G.wait_status(id, status)
  vim.wait(5000, function()
    local record = registry.get(id)
    return record == nil or record.status == status
  end, 10)
  return registry.get(id)
end

function _G.lines(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function _G.wait_text(bufnr, pattern)
  vim.wait(5000, function() return lines(bufnr):find(pattern) ~= nil end, 10)
  return lines(bufnr)
end

function _G.sleeper(root)
  return assert(registry.create({
    root = root, role = "shell", argv = { "sh", "-c", "sleep 30" },
  }))
end

function _G.exiting(root, code)
  local record = assert(registry.create({
    root = root, role = "shell", argv = { "sh", "-c", "exit " .. code },
  }))
  return wait_status(record.id, "exited")
end
]]

local function run(code, ...)
  return child.lua(code, { ... })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
      child.lua(CHILD_HELPERS)
      run("retention.setup({}); _G.root = project(...)", helpers.temp_dir())
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["starts a hidden shell owned by the project root"] = function()
  local result = run([[
    local record = assert(registry.create({ root = root, role = "shell" }))
    local bufnr = record.bufnr
    return {
      record = record,
      windows = #vim.fn.win_findbuf(bufnr),
      buftype = vim.bo[bufnr].buftype,
      listed = vim.bo[bufnr].buflisted,
      scrollback = vim.bo[bufnr].scrollback,
      context = vim.b[bufnr].iara_context_root,
      resolved = root_mod.resolve(bufnr).worktree_id,
      root = root,
      events = _G.events,
    }
  ]])
  local record, root = result.record, result.root
  eq(record.status, "running")
  eq(record.project, root.worktree_id)
  eq(record.cwd, root.path)
  eq(record.argv, { "/bin/sh" })
  eq(record.instance, 1)
  eq(record.generation, 1)
  eq(record.label, root.label .. " shell 1")
  eq(result.windows, 0)
  eq(result.buftype, "terminal")
  eq(result.listed, false)
  eq(result.scrollback, 10000)
  eq(result.context, root.path)
  eq(result.resolved, root.worktree_id)
  eq(result.events, {
    {
      id = record.id,
      status = "running",
      previous = "starting",
      generation = 1,
    },
  })
end

T["records exit codes of hidden terminals"] = function()
  local result = run([[
    local failed = exiting(root, 3)
    local ok = exiting(root, 0)
    return {
      failed = failed,
      ok = ok,
      kept = vim.api.nvim_buf_is_valid(failed.bufnr),
      last = _G.events[#_G.events],
    }
  ]])
  eq(result.failed.status, "exited")
  eq(result.failed.exit_code, 3)
  eq(result.ok.exit_code, 0)
  eq(result.kept, true)
  eq(result.last.status, "exited")
  eq(result.last.previous, "running")
end

T["keeps the transcript of a shell that exits successfully"] = function()
  local result = run([[
    local record = registry.create({ root = root, role = "shell" })
    vim.fn.chansend(record.job, "echo transcript-marker; exit 0\n")
    local exited = wait_status(record.id, "exited")
    return {
      exited = exited,
      valid = vim.api.nvim_buf_is_valid(record.bufnr),
      text = lines(record.bufnr),
    }
  ]])
  eq(result.exited.exit_code, 0)
  eq(result.valid, true)
  match(result.text, "transcript%-marker")
end

T["refuses a missing executable and leaves no buffer"] = function()
  local result = run([[
    local before = #vim.api.nvim_list_bufs()
    local record, err = registry.create({
      root = root, role = "agent", name = "iara-missing-cli-t2",
    })
    return {
      record = record,
      err = err,
      buffers = #vim.api.nvim_list_bufs() - before,
      listed = #registry.list(),
      events = #_G.events,
    }
  ]])
  eq(result.record, nil)
  eq(result.err.code, "spawn")
  match(result.err.message, "iara%-missing%-cli%-t2")
  eq(result.buffers, 0)
  eq(result.listed, 0)
  eq(result.events, 0)
end

T["refuses launch directories that do not exist"] = function()
  local codes = run([[
    local _, missing = registry.create({
      root = root, role = "shell", cwd = root.path .. "/gone",
    })
    local _, relative = registry.create({
      root = root, role = "shell", cwd = "relative/dir",
    })
    return { missing.code, relative.code, #registry.list() }
  ]])
  eq(codes, { "no_directory", "no_directory", 0 })
end

T["refuses creation when retention is unavailable"] = function()
  local result = run([[
    package.loaded["iara.core.term_retention"].available = function()
      return false, "incompatible runtime"
    end
    local before = #vim.api.nvim_list_bufs()
    local _, err = registry.create({ root = root, role = "shell" })
    return { err = err, buffers = #vim.api.nvim_list_bufs() - before }
  ]])
  eq(result.err.code, "retention_unavailable")
  match(result.err.message, "incompatible runtime")
  eq(result.buffers, 0)
end

T["refuses a ninth running terminal until one exits"] = function()
  local result = run([[
    local first = sleeper(root)
    for _ = 2, 8 do sleeper(root) end
    local _, refused = registry.create({ root = root, role = "shell" })
    registry.stop(first.id)
    wait_status(first.id, "exited")
    local ninth = registry.create({ root = root, role = "shell" })
    return { refused = refused, ninth = ninth ~= nil }
  ]])
  eq(result.refused.code, "cap")
  eq(result.ninth, true)
end

T["refuses new jobs while four exited records are kept"] = function()
  local result = run([[
    local exited = {}
    for code = 1, 4 do table.insert(exited, exiting(root, code)) end
    local _, refused = registry.create({ root = root, role = "shell" })
    local disposed = registry.dispose(exited[1].id)
    local created = registry.create({ root = root, role = "shell" })
    return { refused = refused, disposed = disposed, created = created }
  ]])
  eq(result.refused.code, "cap")
  eq(result.disposed, true)
  eq(result.created.status, "running")
end

T["stops asynchronously and reports the exit"] = function()
  local result = run([[
    local record = sleeper(root)
    registry.stop(record.id)
    local immediate = registry.get(record.id).status
    local final = wait_status(record.id, "exited")
    registry.stop(record.id)
    return { immediate = immediate, final = final.status }
  ]])
  eq(result, { immediate = "stopping", final = "exited" })
end

T["restarts into a new generation and keeps the old transcript"] = function()
  local result = run([[
    local record = registry.create({ root = root, role = "shell" })
    vim.fn.chansend(record.job, "echo first-generation\n")
    wait_text(record.bufnr, "first%-generation")
    local restarted = assert(registry.restart(record.id))
    vim.wait(300)
    local current = registry.get(record.id)
    return {
      old = record,
      new = current,
      old_valid = vim.api.nvim_buf_is_valid(record.bufnr),
      old_text = lines(record.bufnr),
    }
  ]])
  eq(result.new.generation, 2)
  eq(result.new.id, result.old.id)
  eq(result.new.status, "running")
  eq(result.new.bufnr ~= result.old.bufnr, true)
  eq(result.new.job ~= result.old.job, true)
  eq(result.old_valid, true)
  match(result.old_text, "first%-generation")
end

T["marks a record failed when its restart cannot spawn"] = function()
  local result = run([[
    local script = root.path .. "/tool.sh"
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, script)
    vim.fn.setfperm(script, "rwx------")
    local record = registry.create({
      root = root, role = "agent", name = "tool", argv = { script },
    })
    wait_status(record.id, "exited")
    os.remove(script)
    local restarted, err = registry.restart(record.id)
    local after = registry.get(record.id)
    vim.fn.delete(root.path, "rf")
    local _, gone = registry.restart(record.id)
    return {
      restarted = restarted,
      err = err.code,
      after = after,
      kept = vim.api.nvim_buf_is_valid(record.bufnr),
      gone = gone.code,
      disposed = registry.dispose(record.id),
    }
  ]])
  eq(result.restarted, nil)
  eq(result.err, "spawn")
  eq(result.after.status, "failed")
  eq(result.after.error.code, "spawn")
  eq(result.kept, true)
  eq(result.gone, "no_directory")
  eq(result.disposed, true)
end

T["disposes a record with its transcripts after exit"] = function()
  local result = run([[
    local record = registry.create({ root = root, role = "shell" })
    local current = assert(registry.restart(record.id))
    local ok_running, running_err = registry.dispose(record.id)
    vim.fn.chansend(current.job, "exit 0\n")
    wait_status(record.id, "exited")
    local ok = registry.dispose(record.id)
    return {
      ok_running = ok_running,
      running_code = running_err.code,
      ok = ok,
      record = registry.get(record.id),
      old_valid = vim.api.nvim_buf_is_valid(record.bufnr),
      new_valid = vim.api.nvim_buf_is_valid(current.bufnr),
      last = _G.events[#_G.events].status,
    }
  ]])
  eq(result.ok_running, false)
  eq(result.running_code, "running")
  eq(result.ok, true)
  eq(result.record, nil)
  eq(result.old_valid, false)
  eq(result.new_valid, false)
  eq(result.last, "disposed")
end

T["keeps identity when the shell changes directory"] = function()
  local result = run([[
    local record = registry.create({ root = root, role = "shell" })
    vim.fn.chansend(record.job, "cd / && echo moved-away\n")
    wait_text(record.bufnr, "moved%-away")
    local after = registry.get(record.id)
    return {
      before = record,
      after = after,
      root = root_mod.resolve(record.bufnr).worktree_id,
      main = registry.main_for(root),
    }
  ]])
  eq(result.after.cwd, result.before.cwd)
  eq(result.after.project, result.before.project)
  eq(result.after.label, result.before.label)
  eq(result.root, result.before.project)
end

T["numbers instances per project, role, and agent name"] = function()
  local result = run(
    [[
    local other = project(...)
    local function make(at, role, name)
      local argv = { "sh", "-c", "sleep 30" }
      return registry.create({
        root = at, role = role, name = name, argv = argv,
      }).instance
    end
    return {
      make(root, "shell"), make(root, "shell"),
      make(root, "agent", "claude"), make(root, "agent", "codex"),
      make(root, "agent", "claude"), make(other, "shell"),
    }
  ]],
    helpers.temp_dir()
  )
  eq(result, { 1, 2, 1, 1, 2, 1 })
end

T["allows one main terminal per project"] = function()
  local result = run([[
    local main = registry.create({ root = root, role = "main" })
    local ok = pcall(registry.create, { root = root, role = "main" })
    return { main = main, found = registry.main_for(root), ok = ok }
  ]])
  eq(result.found.id, result.main.id)
  eq(result.main.label, result.found.label)
  match(result.main.label, " main$")
  eq(result.ok, false)
end

T["passes environment overrides without exposing them"] = function()
  local result = run([[
    local record = registry.create({
      root = root, role = "agent", name = "probe",
      argv = { "sh", "-c", 'printf "value=%s" "$IARA_T2_SECRET"' },
      env = { IARA_T2_SECRET = "s3cr3t" },
    })
    wait_status(record.id, "exited")
    return { text = wait_text(record.bufnr, "value="), label = record.label }
  ]])
  match(result.text, "value=s3cr3t")
  eq(result.label:find("s3cr3t", 1, true), nil)
end

T["labels terminals launched below the project root"] = function()
  local label = run([[
    vim.fn.mkdir(root.path .. "/src/lib", "p")
    return registry.create({
      root = root, role = "shell", cwd = root.path .. "/src/lib",
    }).label
  ]])
  match(label, " shell 1 in src/lib$")
end

T["forgets a record whose live buffer is wiped"] = function()
  local result = run([[
    local record = sleeper(root)
    vim.api.nvim_buf_delete(record.bufnr, { force = true })
    return {
      record = registry.get(record.id),
      last = _G.events[#_G.events].status,
    }
  ]])
  eq(result, { last = "disposed" })
end

T["rejects malformed specs"] = function()
  local result = run([[
    local function fails(spec) return not pcall(registry.create, spec) end
    return {
      fails({ root = root, role = "agent" }),
      fails({ root = root, role = "shell", name = "x" }),
      fails({ root = root, role = "helper" }),
      fails({ root = root, role = "shell", argv = {} }),
      fails({ root = root, role = "shell", env = { X = 1 } }),
      fails({ role = "shell" }),
    }
  ]])
  eq(result, { true, true, true, true, true, true })
end

return T
