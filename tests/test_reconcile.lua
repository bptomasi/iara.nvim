local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = nil

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = helpers.new_child()
      child.lua([[
        _G.events, _G.shown = {}, {}
        vim.notify = function(message, level)
          table.insert(_G.shown, { message = message, level = level })
        end
        vim.api.nvim_create_autocmd("User", {
          pattern = "Iara*",
          callback = function(args)
            table.insert(_G.events, { name = args.match, data = args.data })
          end,
        })
        require("iara.core.reconcile").setup({})
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

---Write a file in a fresh directory and return its path.
local function new_file(content, name)
  local path = helpers.temp_dir() .. "/" .. (name or "notes.txt")
  helpers.write_file(path, content)
  return path
end

---Edit `path` in the child; `edit` replaces the first line when given.
local function open(path, edit)
  return child.lua(
    [[
    local path, edit = ...
    vim.cmd.edit(vim.fn.fnameescape(path))
    -- Let the check queued by BufEnter finish before the file changes.
    vim.wait(20)
    if edit then
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { edit })
    end
    return vim.api.nvim_get_current_buf()
  ]],
    { path, edit or false }
  )
end

---Run `trigger` in the child, then wait until `event` fired for `bufnr`.
local function wait_event(event, bufnr, trigger)
  return child.lua(
    [[
    local event, bufnr, trigger = ...
    local seen = #_G.events
    assert(loadstring(trigger))()
    return vim.wait(3000, function()
      for index = seen + 1, #_G.events do
        local entry = _G.events[index]
        if entry.name == event and entry.data.bufnr == bufnr then
          return true
        end
      end
      return false
    end, 10)
  ]],
    { event, bufnr, trigger }
  )
end

local CHECK = "require('iara.core.reconcile').check()"

local function check_until(event, bufnr)
  eq(wait_event(event, bufnr, CHECK), true)
end

local function lines(bufnr)
  return child.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function conflict(bufnr)
  return child.lua_get(
    "require('iara.core.reconcile').conflict(...)",
    { bufnr }
  )
end

local function call(name, ...)
  return child.lua(
    "local name = ...; local m = require('iara.core.reconcile')\n"
      .. "return { m[name](select(2, ...)) }",
    { name, ... }
  )
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function shown_text()
  local parts = {}
  for _, entry in ipairs(child.lua_get("_G.shown")) do
    table.insert(parts, entry.message)
  end
  return table.concat(parts, "\n")
end

T["unmodified buffer reloads from disk after an external write"] = function()
  local path = new_file("one\n")
  local bufnr = open(path)
  helpers.write_file(path, "two\nthree\n")
  check_until("IaraBufferReloaded", bufnr)
  eq(lines(bufnr), { "two", "three" })
  eq(conflict(bufnr), vim.NIL)
  eq(child.lua_get("#_G.shown"), 0)
end

T["unmodified buffer reloads with autoread off"] = function()
  child.o.autoread = false
  local path = new_file("one\n")
  local bufnr = open(path)
  helpers.write_file(path, "two\n")
  check_until("IaraBufferReloaded", bufnr)
  eq(lines(bufnr), { "two" })
end

T["recreated file reloads an unmodified buffer and clears it"] = function()
  local path = new_file("one\n")
  local bufnr = open(path)
  os.remove(path)
  check_until("IaraConflictDetected", bufnr)
  helpers.write_file(path, "back\n")
  check_until("IaraBufferReloaded", bufnr)
  eq(lines(bufnr), { "back" })
  eq(conflict(bufnr), vim.NIL)
end

T["entering a buffer checks it"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  child.cmd("enew")
  helpers.write_file(path, "agent text\n")
  local trigger = "vim.cmd.buffer(" .. bufnr .. ")"
  eq(wait_event("IaraConflictDetected", bufnr, trigger), true)
end

T["modified buffer keeps its text and shows a conflict"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  check_until("IaraConflictDetected", bufnr)
  eq(lines(bufnr), { "my edit" })
  eq(child.bo.modified, true)
  local found = conflict(bufnr)
  eq(found.snapshot, "available")
  eq(found.path, vim.fs.normalize(path))
  eq(found.disk.size, #"agent text\n")
  eq(call("statusline", bufnr)[1], "[disk: changed]")
  match(shown_text(), "changed on disk while modified")
  -- Nothing is saved automatically.
  eq(read_file(path), "agent text\n")
end

T["conflict indicator persists across later checks"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  check_until("IaraConflictDetected", bufnr)
  child.lua(CHECK .. "; vim.wait(100)")
  eq(conflict(bufnr).snapshot, "available")
  eq(#child.lua_get("require('iara.core.reconcile').conflicts()"), 1)
end

T["focus return detects external changes"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  local trigger = "vim.api.nvim_exec_autocmds('FocusGained', {})"
  eq(wait_event("IaraConflictDetected", bufnr, trigger), true)
end

T["compare opens a read-only diff against the disk snapshot"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\nsecond\n")
  check_until("IaraConflictDetected", bufnr)
  eq(call("compare", bufnr), { true })
  local view = child.lua([[
    local windows = vim.api.nvim_tabpage_list_wins(0)
    local result = { diff = {} }
    for _, win in ipairs(windows) do
      table.insert(result.diff, vim.wo[win].diff)
    end
    local buf = vim.api.nvim_get_current_buf()
    result.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    result.modifiable = vim.bo[buf].modifiable
    result.tabs = #vim.api.nvim_list_tabpages()
    return result
  ]])
  eq(view.lines, { "agent text", "second" })
  eq(view.modifiable, false)
  eq(view.diff, { true, true })
  eq(view.tabs, 2)
  eq(lines(bufnr), { "my edit" })
end

T["compare without a conflict reports no_conflict"] = function()
  local bufnr = open(new_file("text\n"))
  local result = call("compare", bufnr)
  eq(result[1], false)
  eq(result[2].code, "no_conflict")
end

T["keep_buffer clears the conflict and keeps the text"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  check_until("IaraConflictDetected", bufnr)
  eq(call("resolve", bufnr, "keep_buffer"), { true })
  eq(conflict(bufnr), vim.NIL)
  eq(lines(bufnr), { "my edit" })
  eq(child.bo.modified, true)
  eq(read_file(path), "agent text\n")
  local last = child.lua_get("_G.events[#_G.events]")
  eq(last.name, "IaraConflictResolved")
  eq(last.data.choice, "keep_buffer")
end

T["load_disk replaces the buffer with the disk text"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  check_until("IaraConflictDetected", bufnr)
  eq(call("resolve", bufnr, "load_disk"), { true })
  eq(lines(bufnr), { "agent text" })
  eq(child.bo.modified, false)
  eq(conflict(bufnr), vim.NIL)
end

T["an explicit write! resolves the conflict keeping the buffer"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  check_until("IaraConflictDetected", bufnr)
  child.cmd("write!")
  eq(conflict(bufnr), vim.NIL)
  eq(read_file(path), "my edit\n")
end

T["deleted file keeps a modified buffer and has no snapshot"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  os.remove(path)
  check_until("IaraConflictDetected", bufnr)
  eq(lines(bufnr), { "my edit" })
  eq(conflict(bufnr).snapshot, "unreadable")
  eq(call("statusline", bufnr)[1], "[disk: deleted]")
  eq(call("compare", bufnr)[2].code, "snapshot_unavailable")
  eq(call("resolve", bufnr, "load_disk")[2].code, "disk_unavailable")
  eq(lines(bufnr), { "my edit" })
  match(shown_text(), "deleted on disk")
end

T["deleted file keeps an unmodified buffer and its text"] = function()
  local path = new_file("original\n")
  local bufnr = open(path)
  os.remove(path)
  check_until("IaraConflictDetected", bufnr)
  eq(lines(bufnr), { "original" })
  eq(conflict(bufnr).snapshot, "unreadable")
end

T["oversized file is not read into a snapshot"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, ("x"):rep(1023) .. "\n" .. ("y\n"):rep(524288))
  check_until("IaraConflictDetected", bufnr)
  local found = conflict(bufnr)
  eq(found.snapshot, "oversized")
  eq(found.disk.size > 1024 * 1024, true)
  eq(lines(bufnr), { "my edit" })
  eq(call("compare", bufnr)[2].code, "snapshot_unavailable")
end

T["a line longer than 64 KiB makes the snapshot oversized"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, ("z"):rep(70 * 1024) .. "\n")
  check_until("IaraConflictDetected", bufnr)
  eq(conflict(bufnr).snapshot, "oversized")
end

T["more than 10000 lines makes the snapshot oversized"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, ("l\n"):rep(10000) .. "tail")
  check_until("IaraConflictDetected", bufnr)
  eq(conflict(bufnr).snapshot, "oversized")
end

T["a third unresolved snapshot is refused until one resolves"] = function()
  local buffers = {}
  for index = 1, 3 do
    local path = new_file("original\n", "file" .. index .. ".txt")
    buffers[index] = { path = path, bufnr = open(path, "edit") }
    helpers.write_file(path, "changed " .. index .. "\n")
  end
  check_until("IaraConflictDetected", buffers[3].bufnr)
  child.lua("vim.wait(200)")
  local by_state = {}
  for _, entry in ipairs(buffers) do
    local snapshot = conflict(entry.bufnr).snapshot
    by_state[snapshot] = by_state[snapshot] or {}
    table.insert(by_state[snapshot], entry)
  end
  eq(#by_state.available, 2)
  eq(#by_state.over_cap, 1)
  -- Resolving one frees room for the next detected change.
  local kept, refused = by_state.available[1], by_state.over_cap[1]
  eq(call("resolve", kept.bufnr, "keep_buffer"), { true })
  helpers.write_file(refused.path, "changed again\n")
  check_until("IaraConflictDetected", refused.bufnr)
  eq(conflict(refused.bufnr).snapshot, "available")
end

T["check rejects an invalid buffer handle"] = function()
  local result = child.lua([[
    return { pcall(require("iara.core.reconcile").check, 9999) }
  ]])
  eq(result[1], false)
  match(result[2], "invalid buffer")
end

-- M2: snapshot limits, streaming, and fallbacks ----------------------------

---`count` lines of `width` bytes each, newline included.
local function block(count, width)
  return (("x"):rep(width - 1) .. "\n"):rep(count)
end

---Wrap vim.uv.fs_fstat in the child so `change` runs on the file right
---after the snapshot read took its size, before any byte is read: once,
---or on every read when `change.always` is set (a writer that never
---stops).
local function change_during_read(path, change)
  child.lua(
    [[
    local path, change = ...
    local original = vim.uv.fs_fstat
    vim.uv.fs_fstat = function(fd, callback)
      return original(fd, function(err, stat)
        if not change.always then
          vim.uv.fs_fstat = original
        end
        local file = assert(io.open(path, change.mode))
        file:write(change.text)
        file:close()
        callback(err, stat)
      end)
    end
  ]],
    { path, change }
  )
end

---Start an excerpt in the child and wait for its outcome.
local function excerpt(bufnr, part)
  return child.lua(
    [[
    local bufnr, part = ...
    local outcome = nil
    local reconcile = require("iara.core.reconcile")
    local started, err = reconcile.excerpt(bufnr, part, function(ok, e)
      outcome = { ok = ok, err = e }
    end)
    if not started then
      return { started = false, err = err }
    end
    vim.wait(3000, function() return outcome ~= nil end, 10)
    local view = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(view, 0, -1, false)
    return {
      started = true,
      outcome = outcome,
      count = #lines,
      first = lines[1],
      last = lines[#lines],
      winbar = vim.wo.winbar,
      modifiable = vim.bo[view].modifiable,
    }
  ]],
    { bufnr, part }
  )
end

T["admits a file exactly at every snapshot limit"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  -- 10,000 lines, one of them 64 KiB long without its newline.
  local content = ("y"):rep(64 * 1024) .. "\n" .. ("l\n"):rep(9999)
  helpers.write_file(path, content)
  check_until("IaraConflictDetected", bufnr)
  eq(conflict(bufnr).snapshot, "available")
end

T["a file one byte above 1 MiB is oversized and says why"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, block(1024, 1024) .. "z")
  check_until("IaraConflictDetected", bufnr)
  local found = conflict(bufnr)
  eq(found.snapshot, "oversized")
  match(found.detail, "1%.0 MiB > 1 MiB")
  match(shown_text(), ":IaraDiskExcerpt shows part")
end

---Messages shown to the user so far.
local function shown_count()
  -- Let a notice queued with the event reach vim.notify first.
  return child.lua("vim.wait(20); return #_G.shown")
end

T["growth during the read within the caps is read again"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  change_during_read(path, { mode = "ab", text = "appended\n" })
  check_until("IaraConflictDetected", bufnr)
  local found = conflict(bufnr)
  eq(found.snapshot, "available")
  eq(found.detail, nil)
  eq(lines(bufnr), { "my edit" })
  eq(read_file(path), "agent text\nappended\n")
  eq(call("compare", bufnr), { true })
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), {
    "agent text",
    "appended",
  })
  -- Only the conflict itself was announced.
  eq(shown_count(), 1)
end

T["shrinking during the read never yields a mixed snapshot"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text, long version\n")
  change_during_read(path, { mode = "wb", text = "short\n" })
  check_until("IaraConflictDetected", bufnr)
  eq(conflict(bufnr).snapshot, "available")
  eq(call("compare", bufnr), { true })
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), {
    "short",
  })
end

T["growth beyond 1 MiB during the read makes it oversized"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  change_during_read(path, { mode = "ab", text = block(1100, 1000) })
  check_until("IaraConflictDetected", bufnr)
  local found = conflict(bufnr)
  eq(found.snapshot, "oversized")
  match(found.detail, "MiB > 1 MiB")
  eq(lines(bufnr), { "my edit" })
  -- The conflict, then its fallbacks, each once.
  eq(shown_count(), 2)
end

T["a writer that never stops leaves the snapshot unreadable"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  change_during_read(path, { mode = "ab", text = "more\n", always = true })
  check_until("IaraConflictDetected", bufnr)
  local found = conflict(bufnr)
  eq(found.snapshot, "unreadable")
  match(found.detail, "kept changing while it was read")
  eq(lines(bufnr), { "my edit" })
  eq(shown_count(), 1)
end

T["excerpts of an oversized file are partial and cut at lines"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  local content = block(1200, 1000)
  helpers.write_file(path, content)
  check_until("IaraConflictDetected", bufnr)
  eq(conflict(bufnr).snapshot, "oversized")
  local head = excerpt(bufnr, "head")
  eq(head.outcome, { ok = true })
  -- 65 complete 1000-byte lines fit in 64 KiB; the 66th is left out.
  eq(head.count, 65)
  eq(
    head.winbar,
    "Partial disk excerpt: bytes 1-65000 of 1200000;"
      .. " the rest of the file is not shown"
  )
  eq(head.modifiable, false)
  local tail = excerpt(bufnr, "tail")
  eq(tail.count, 65)
  match(tail.winbar, "bytes 1135001%-1200000 of 1200000")
  eq(lines(bufnr), { "my edit" })
  eq(child.api.nvim_buf_get_option(bufnr, "modified"), true)
  eq(read_file(path), content)
  eq(conflict(bufnr).snapshot, "oversized")
end

T["an excerpt inside one huge line says the line is cut"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, ("z"):rep(70 * 1024) .. "\n")
  check_until("IaraConflictDetected", bufnr)
  local head = excerpt(bufnr, "head")
  eq(head.outcome, { ok = true })
  eq(head.count, 1)
  eq(#head.first, 64 * 1024)
  match(head.winbar, "a line is cut")
end

T["an excerpt of a deleted file reports disk_unavailable"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  os.remove(path)
  check_until("IaraConflictDetected", bufnr)
  local result = excerpt(bufnr, "head")
  eq(result.outcome.ok, false)
  eq(result.outcome.err.code, "disk_unavailable")
  eq(lines(bufnr), { "my edit" })
end

T["save_copy writes the buffer to an unused path only"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, block(1100, 1000))
  check_until("IaraConflictDetected", bufnr)
  local copy = helpers.temp_dir() .. "/copy.txt"
  local result = call("save_copy", bufnr, copy)
  eq(result[1], true)
  eq(result[3], { "diff", "-u", "--", vim.fs.normalize(path), copy })
  eq(read_file(copy), "my edit\n")
  -- The buffer keeps its name, edits, and conflict; disk is untouched.
  eq(child.api.nvim_buf_get_name(bufnr), vim.fs.normalize(path))
  eq(child.api.nvim_buf_get_option(bufnr, "modified"), true)
  eq(conflict(bufnr).snapshot, "oversized")
  eq(#read_file(path), 1100000)
  helpers.write_file(copy, "precious\n")
  eq(call("save_copy", bufnr, copy)[2].code, "path_exists")
  eq(read_file(copy), "precious\n")
  eq(call("save_copy", bufnr, path)[2].code, "invalid_path")
end

T["writing the buffer to another file keeps the conflict"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, "agent text\n")
  check_until("IaraConflictDetected", bufnr)
  local other = helpers.temp_dir() .. "/other.txt"
  child.cmd("write " .. vim.fn.fnameescape(other))
  eq(conflict(bufnr).snapshot, "available")
  eq(read_file(path), "agent text\n")
end

T["views count against the 4 MiB session cap"] = function()
  local entries = {}
  for index = 1, 3 do
    local path = new_file("original\n", "big" .. index .. ".txt")
    entries[index] = { path = path, bufnr = open(path, "edit") }
    -- 1000 lines of 1048 bytes: snapshot plus view copy fill 4 MiB.
    helpers.write_file(path, block(1000, 1048))
  end
  check_until("IaraConflictDetected", entries[3].bufnr)
  child.lua("vim.wait(300)")
  local held, refused = {}, nil
  for _, entry in ipairs(entries) do
    local found = conflict(entry.bufnr)
    if found.snapshot == "available" then
      table.insert(held, entry)
    else
      eq(found.snapshot, "over_cap")
      eq(found.detail, "two disk snapshots are already held")
      refused = entry
    end
  end
  eq(#held, 2)
  eq(call("compare", held[1].bufnr), { true })
  eq(call("compare", held[2].bufnr), { true })
  local full = excerpt(refused.bufnr, "head")
  eq(full.started, false)
  eq(full.err.code, "over_cap")
  -- Closing one comparison releases its copy.
  child.cmd("tabclose")
  eq(excerpt(refused.bufnr, "head").outcome, { ok = true })
end

T["fallback commands show an excerpt and save a copy"] = function()
  local path = new_file("original\n")
  local bufnr = open(path, "my edit")
  helpers.write_file(path, block(1100, 1000))
  check_until("IaraConflictDetected", bufnr)
  local copy = helpers.temp_dir() .. "/saved.txt"
  child.cmd("IaraSaveCopy " .. vim.fn.fnameescape(copy))
  match(shown_text(), "compare externally with: 'diff' '%-u'")
  eq(read_file(copy), "my edit\n")
  child.cmd("IaraDiskExcerpt tail")
  child.lua("vim.wait(3000, function() return vim.wo.winbar ~= '' end)")
  match(child.wo.winbar, "^Partial disk excerpt")
end

return T
