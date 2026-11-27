local helpers = require("helpers")
local proc = require("iara.core.proc")

local expect = MiniTest.expect
local eq = expect.equality

local dir = nil
local script_count = 0
---Pids of escaped descendants that a test must reap afterwards.
local orphans = {}
---The real signal function; a test may replace it to simulate a process
---that SIGKILL cannot end (uninterruptible sleep).
local real_kill = vim.uv.kill

---Write an executable shell script and return its absolute path.
local function script(body)
  script_count = script_count + 1
  local path = ("%s/helper%d"):format(dir, script_count)
  helpers.write_file(path, "#!/bin/sh\n" .. body)
  assert(vim.uv.fs_chmod(path, 448))
  return path
end

---Spawn with test defaults; `done` collects every on_complete result.
local function start(argv, opts)
  local done = {}
  opts = vim.tbl_extend("keep", opts or {}, { cwd = dir })
  if not opts.long_lived then
    opts.timeout_ms = opts.timeout_ms or 5000
  end
  opts.on_complete = function(result)
    table.insert(done, result)
  end
  return proc.spawn(argv, opts), done
end

local function wait_done(done)
  vim.wait(5000, function()
    return #done > 0
  end, 5)
  return done[1]
end

local function run(argv, opts)
  local _, done = start(argv, opts)
  return wait_done(done)
end

local function wait_until(predicate)
  return vim.wait(5000, predicate, 5)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = helpers.temp_dir()
    end,
    post_case = function()
      vim.uv.kill = real_kill
      proc.cancel_all()
      for _, pid in ipairs(orphans) do
        vim.uv.kill(pid, "sigkill")
      end
      orphans = {}
      -- Retiring handles keep admission slots; start each case clean.
      vim.wait(5000, function()
        return proc.active_count() == 0
      end, 5)
    end,
  },
})

T["spawn"] = MiniTest.new_set()

T["spawn"]["collects output and reports a nonzero exit as exited"] = function()
  local path = script("printf out; printf err >&2; exit 3")
  local result = run({ path })
  eq(result.status, "exited")
  eq(result.code, 3)
  eq(result.signal, 0)
  eq(result.stdout, "out")
  eq(result.stderr, "err")
  eq(result.eof, { stdout = true, stderr = true })
  eq(result.pipes_forced, false)
  eq(result.error, nil)
end

T["spawn"]["passes arguments verbatim without a shell"] = function()
  local result = run({ "printf", "%s|", "alpha -- beta", "$HOME", "*" })
  eq(result.stdout, "alpha -- beta|$HOME|*|")
end

T["spawn"]["runs in cwd with env merged or cleared"] = function()
  local path = script('printf "%s:%s:%s" "$(pwd)" "$IARA_X" "$HOME"')
  local merged = run({ path }, { env = { IARA_X = "1" } })
  eq(merged.stdout, ("%s:1:%s"):format(dir, vim.env.HOME))
  local cleared = run({ path }, { env = { IARA_X = "2" }, clear_env = true })
  eq(cleared.stdout, dir .. ":2:")
end

T["spawn"]["writes stdin and closes it"] = function()
  local input = string.rep("line of formatter input\n", 20000)
  eq(run({ "cat" }, { stdin = input }).stdout, input)
end

T["spawn"]["closes stdin at spawn when no input is given"] = function()
  local result = run({ "cat" })
  eq(result.status, "exited")
  eq(result.stdout, "")
end

T["spawn"]["tolerates a child that exits without reading stdin"] = function()
  local result = run({ "true" }, { stdin = string.rep("x", 1048576) })
  eq(result.status, "exited")
  eq(result.code, 0)
end

T["spawn"]["reports exit through on_exit before on_complete"] = function()
  local order = {}
  local _, done = start({ script("exit 4") }, {
    on_exit = function(code, signal)
      table.insert(order, { "exit", code, signal })
    end,
  })
  eq(wait_done(done).code, 4)
  table.insert(order, "complete")
  eq(order, { { "exit", 4, 0 }, "complete" })
end

T["spawn"]["completes asynchronously and exactly once"] = function()
  local handle, done = start({ "true" })
  eq(#done, 0)
  eq(handle.is_active(handle), true)
  wait_done(done)
  vim.wait(100)
  eq(#done, 1)
  eq(handle:is_active(), false)
  expect.no_error(function()
    handle:cancel("late")
  end)
end

T["streams"] = MiniTest.new_set()

T["streams"]["frames lines across chunks and flushes the tail"] = function()
  local lines = {}
  local path = script("printf 'a\\r\\nb'; sleep 0.05; printf 'c\\n\\nd'")
  local result = run({ path }, {
    stdout = {
      mode = "lines",
      on_data = function(items)
        vim.list_extend(lines, items)
      end,
    },
  })
  eq(lines, { "a\r", "bc", "", "d" })
  eq(result.stdout, nil)
end

T["streams"]["frames NUL-delimited records"] = function()
  local records = {}
  run({ "printf", "one\\0two words\\0" }, {
    stdout = {
      mode = "lines",
      delimiter = "\0",
      on_data = function(items)
        vim.list_extend(records, items)
      end,
    },
  })
  eq(records, { "one", "two words" })
end

T["streams"]["delivers raw chunks in order"] = function()
  local chunks = {}
  local path = script("printf 'ab'; sleep 0.05; printf 'cd'")
  run({ path }, {
    stdout = {
      mode = "chunks",
      on_data = function(items)
        vim.list_extend(chunks, items)
      end,
    },
  })
  eq(table.concat(chunks), "abcd")
end

T["streams"]["discards output in discard mode"] = function()
  local result = run({ "printf", "ignored" }, { stdout = { mode = "discard" } })
  eq(result.status, "exited")
  eq(result.stdout, nil)
  eq(result.eof.stdout, true)
end

T["streams"]["a stdout flood overflows and terminates the job"] = function()
  local result = run({ "yes" }, { stdout = { max_bytes = 100000 } })
  -- One comparison, so a failure on a loaded machine shows every field.
  -- The time bound proves the job did not hang, not timing precision.
  eq({
    status = result.status,
    overflow = result.overflow,
    code = result.error and result.error.code,
    stdout_eof = result.eof.stdout,
    signalled = result.signal ~= 0,
    within_cap = #result.stdout <= 100000,
    no_hang = result.elapsed_ms < 3000,
  }, {
    status = "overflow",
    overflow = "stdout",
    code = "overflow",
    stdout_eof = false,
    signalled = true,
    within_cap = true,
    no_hang = true,
  })
end

T["streams"]["a stderr flood overflows with the stderr cap"] = function()
  local path = script("exec yes >&2")
  local result = run({ path }, { stderr = { max_bytes = 1000 } })
  eq(result.status, "overflow")
  eq(result.overflow, "stderr")
end

T["streams"]["a line longer than max_line_bytes overflows"] = function()
  local path = script("printf '%0200d' 0; sleep 5")
  local result = run({ path }, {
    stdout = { mode = "lines", max_line_bytes = 100 },
  })
  eq(result.status, "overflow")
  eq(result.overflow, "stdout")
  eq(result.elapsed_ms < 1000, true)
end

T["failures"] = MiniTest.new_set()

T["failures"]["a missing executable is not_found"] = function()
  local handle, done = start({ "iara-missing-executable-xyz", "-v" })
  eq(handle.pid, nil)
  eq(#done, 0)
  local result = wait_done(done)
  eq(result.status, "not_found")
  eq(result.error.code, "not_found")
  eq(result.code, nil)
  eq(proc.active_count(), 0)
end

T["failures"]["a non-executable file is spawn_failed"] = function()
  local path = dir .. "/plain.txt"
  helpers.write_file(path, "data")
  local result = run({ path })
  eq(result.status, "spawn_failed")
  eq(result.error.code, "spawn_failed")
  eq(result.error.uv_error, "EACCES")
end

T["failures"]["a missing cwd is spawn_failed, not not_found"] = function()
  local result = run({ "true" }, { cwd = dir .. "/absent" })
  eq(result.status, "spawn_failed")
end

---Expect proc.spawn(argv, opts) to raise an error matching `pattern`.
local function expect_spawn_error(pattern, argv, opts)
  expect.error(function()
    proc.spawn(argv, opts)
  end, pattern)
end

T["failures"]["rejects invalid arguments as programmer errors"] = function()
  local ok = { cwd = dir, timeout_ms = 10, on_complete = function() end }
  local function with(key, value)
    local copy = vim.tbl_extend("force", {}, ok)
    copy[key] = value
    return copy
  end
  expect_spawn_error("non%-empty", {}, ok)
  expect_spawn_error("not a string", { "echo", 1 }, ok)
  expect_spawn_error("NUL", { "echo", "a\0b" }, ok)
  expect_spawn_error("on_complete", { "true" }, with("on_complete", nil))
  expect_spawn_error("cwd", { "true" }, with("cwd", nil))
  expect_spawn_error("cwd", { "true" }, with("cwd", "relative"))
  expect_spawn_error("timeout_ms", { "true" }, with("timeout_ms", nil))
  eq(proc.active_count(), 0)
end

T["termination"] = MiniTest.new_set()

T["spawn"] = T["spawn"] or MiniTest.new_set()

T["spawn"]["passes more arguments than unpack can hold"] = function()
  local argv = { "sh", "-c", 'echo "$#"', "sh" }
  for index = 1, 9000 do
    argv[#argv + 1] = "a" .. index
  end
  local result = run(argv, {})
  eq(result.status, "exited")
  eq(vim.trim(result.stdout), "9000")
end

T["termination"]["a deadline terminates with status timeout"] = function()
  local result = run({ "sleep", "5" }, { timeout_ms = 100 })
  eq(result.status, "timeout")
  eq(result.error.code, "timeout")
  eq(result.signal, 15)
  -- Generous upper bound: proves no hang under a loaded machine.
  eq(result.elapsed_ms >= 100 and result.elapsed_ms < 3000, true)
end

T["termination"]["long-lived jobs need no deadline"] = function()
  local handle, done = start({ "sleep", "5" }, { long_lived = true })
  vim.wait(150)
  eq(handle:is_active(), true)
  handle:cancel()
  eq(wait_done(done).status, "cancelled")
end

---Start `path` and wait until it printed "ready" on stdout.
local function start_ready(path, opts)
  local lines = {}
  opts = vim.tbl_extend("keep", opts or {}, {
    stdout = {
      mode = "lines",
      on_data = function(items)
        vim.list_extend(lines, items)
      end,
    },
  })
  local handle, done = start({ path }, opts)
  assert(wait_until(function()
    return vim.tbl_contains(lines, "ready")
  end))
  return handle, done, lines
end

T["termination"]["SIGKILL follows 200 ms after an ignored SIGTERM"] = function()
  local path = script("trap '' TERM; echo ready; exec sleep 5")
  local handle, done = start_ready(path)
  handle:cancel("superseded")
  local result = wait_done(done)
  local steps = result.escalation
  -- Timers never fire early (1 ms for libuv's millisecond clock); the
  -- upper bounds only prove the stage was not skipped or hung.
  eq({
    status = result.status,
    reason = result.reason,
    signal = result.signal,
    term_at_once = steps.term < 50,
    kill_after_200 = steps.kill >= 199 and steps.kill < 2000,
    close = steps.close,
    report = steps.report,
    pipes_forced = result.pipes_forced,
    cleanup_failed = result.cleanup_failed,
  }, {
    status = "cancelled",
    reason = "superseded",
    signal = 9,
    term_at_once = true,
    kill_after_200 = true,
    pipes_forced = false,
    cleanup_failed = false,
  })
end

T["termination"]["a process that obeys SIGTERM is never killed"] = function()
  local handle, done = start_ready(script("echo ready; exec sleep 5"))
  handle:cancel()
  local result = wait_done(done)
  eq(result.signal, 15)
  eq(vim.tbl_keys(result.escalation), { "term" })
  eq(result.elapsed_ms < 1000, true)
end

T["termination"]["a natural exit reports no escalation"] = function()
  local result = run({ "true" })
  eq(result.escalation, nil)
  eq(result.cleanup_failed, false)
end

T["termination"]["no data is delivered after cancel returns"] = function()
  local path = script("echo ready; while :; do echo tick; done")
  local handle, done, lines = start_ready(path)
  handle:cancel()
  local seen = #lines
  local result = wait_done(done)
  eq(#lines, seen)
  eq(result.status, "cancelled")
  eq(result.error, nil)
  eq(#done, 1)
end

T["termination"]["cancel is idempotent and keeps the first cause"] = function()
  local handle, done = start({ "sleep", "5" }, { timeout_ms = 5000 })
  handle:cancel("first")
  handle:cancel("second")
  local result = wait_done(done)
  eq(result.status, "cancelled")
  eq(result.reason, "first")
  vim.wait(50)
  eq(#done, 1)
end

T["pipes"] = MiniTest.new_set()

T["pipes"]["inherited pipes are force-closed 500 ms after exit"] = function()
  local path = script("sleep 5 & echo $!")
  local result = run({ path })
  table.insert(orphans, tonumber(vim.trim(result.stdout)))
  eq(result.status, "exited")
  eq(result.code, 0)
  eq(result.pipes_forced, true)
  eq(result.eof.stdout, false)
  eq(result.elapsed_ms >= 500 and result.elapsed_ms < 1000, true)
end

T["pipes"]["cancellation reaches descendants in the process group"] = function()
  local path = script("sleep 5 & echo ready; wait")
  local handle, done = start_ready(path)
  handle:cancel()
  local result = wait_done(done)
  eq(result.status, "cancelled")
  eq(result.pipes_forced, false)
  eq(result.eof.stdout, true)
  eq(result.elapsed_ms < 200, true)
end

T["pipes"]["pipes held by an escaped descendant close at 500 ms"] = function()
  local helper = dir .. "/escape.py"
  helpers.write_file(
    helper,
    table.concat({
      "import os, sys, time",
      "if os.fork() == 0:",
      "    os.setsid()",
      "    print(os.getpid(), flush=True)",
      "    time.sleep(5)",
      "    sys.exit(0)",
      "time.sleep(0.2)",
      "print('ready', flush=True)",
      "time.sleep(5)",
    }, "\n")
  )
  local lines = {}
  local handle, done = start({ "python3", helper }, {
    stdout = {
      mode = "lines",
      on_data = function(items)
        vim.list_extend(lines, items)
      end,
    },
  })
  assert(wait_until(function()
    return vim.tbl_contains(lines, "ready")
  end))
  table.insert(orphans, tonumber(lines[1]))
  handle:cancel()
  local result = wait_done(done)
  local close = result.escalation.close
  eq(result.status, "cancelled")
  eq(result.pipes_forced, true)
  -- The leader died of SIGTERM, so no SIGKILL was needed.
  eq(result.escalation.kill, nil)
  eq(close >= 499 and close < 2500, true)
  eq(result.escalation.report, nil)
  eq(result.cleanup_failed, false)
end

T["session"] = MiniTest.new_set()

T["session"]["counts live handles per tag and cancels by tag"] = function()
  local a1, done_a1 = start({ "sleep", "5" }, { tag = "a" })
  local _, done_a2 = start({ "sleep", "5" }, { tag = "a" })
  local b, done_b = start({ "sleep", "5" }, { tag = "b" })
  eq(proc.active_count("a"), 2)
  eq(proc.active_count("b"), 1)
  eq(proc.active_count(), 3)
  proc.cancel_all("a")
  -- Retiring handles still count until cleanup finishes.
  eq(proc.active_count("a"), 2)
  wait_done(done_a1)
  wait_done(done_a2)
  eq(proc.active_count("a"), 0)
  eq(a1:is_active(), false)
  eq(b:is_active(), true)
  eq(proc.active_count(), 1)
  proc.cancel_all()
  eq(wait_done(done_b).status, "cancelled")
  eq(proc.active_count(), 0)
end

T["session"]["the handle keeps argv even if the caller edits it"] = function()
  local argv = { "printf", "%s", "kept" }
  local handle, done = start(argv)
  argv[3] = "changed"
  eq(handle.argv, { "printf", "%s", "kept" })
  eq(wait_done(done).stdout, "kept")
end

T["session"]["handles have unique ids and expose the pid"] = function()
  local first, done1 = start({ "true" })
  local second, done2 = start({ "true" })
  expect.no_equality(first.id, second.id)
  eq(type(first.pid), "number")
  eq(first.argv, { "true" })
  wait_done(done1)
  wait_done(done2)
end

T["admission"] = MiniTest.new_set()

local SEARCH = { group = "search", max = 4 }

---Start `count` long sleeps admitted in the search group.
local function fill_search(count)
  local started = {}
  for index = 1, count do
    local handle, done = start({ "sleep", "5" }, { admission = SEARCH })
    started[index] = { handle = handle, done = done }
  end
  return started
end

T["admission"]["refuses a fifth live process in a group of four"] = function()
  fill_search(4)
  local outsider = start({ "sleep", "5" })
  eq(outsider:is_active(), true)
  local admitted, refusal = proc.admits(SEARCH)
  eq(admitted, false)
  eq(refusal.code, "cap")
  eq(refusal.message, "search: 4 live processes (cap 4)")
  local handle, done = start({ "sleep", "5" }, { admission = SEARCH })
  eq(handle.refused, "cap")
  eq(handle.pid, nil)
  eq(#done, 0)
  local result = wait_done(done)
  eq(result.status, "refused")
  eq(result.refused, "cap")
  eq(result.error.code, "refused")
  eq(handle:is_active(), false)
  eq(proc.active_count(), 5)
  eq(proc.admits({ group = "other", max = 1 }), true)
end

T["admission"]["retiring processes hold their slot until reaped"] = function()
  local path = script("trap '' TERM; echo ready; exec sleep 5")
  local retiring, retired = start_ready(path, { admission = SEARCH })
  fill_search(3)
  retiring:cancel()
  eq(proc.admits(SEARCH), false)
  eq(wait_done(retired).signal, 9)
  eq(proc.admits(SEARCH), true)
  local _, done = start({ "true" }, { admission = SEARCH })
  eq(wait_done(done).status, "exited")
end

T["admission"]["rejects a malformed admission"] = function()
  local opts = { cwd = dir, timeout_ms = 10, on_complete = function() end }
  opts.admission = { group = "search", max = 0 }
  expect_spawn_error("admission", { "true" }, opts)
  opts.admission = { max = 2 }
  expect_spawn_error("admission", { "true" }, opts)
  expect.error(function()
    proc.admits(nil)
  end, "admission")
  eq(proc.active_count(), 0)
end

---Make SIGKILL a no-op, as for a process in uninterruptible sleep: the
---only deterministic way to keep a child alive past the 1 s stage.
local function make_sigkill_ineffective()
  vim.uv.kill = function(pid, signame)
    if signame == "sigkill" then
      return 0
    end
    return real_kill(pid, signame)
  end
end

T["cleanup failure"] = MiniTest.new_set()

local failure = T["cleanup failure"]
failure["is reported once at 1 s and blocks the group"] = function()
  make_sigkill_ineffective()
  local reports = {}
  local path = script("trap '' TERM; echo ready; exec sleep 30")
  local handle, done = start_ready(path, {
    admission = SEARCH,
    on_cleanup_failure = function(failed)
      table.insert(reports, { id = failed.id, at = vim.uv.hrtime() })
    end,
  })
  table.insert(orphans, handle.pid)
  local cancelled_at = vim.uv.hrtime()
  handle:cancel()
  assert(wait_until(function()
    return #reports > 0
  end))
  local waited_ms = (reports[1].at - cancelled_at) / 1e6
  eq(reports[1].id, handle.id)
  eq(waited_ms >= 999 and waited_ms < 4000, true)
  -- Ownership is kept: the handle stays live and counted, and the whole
  -- group refuses new work even below its cap.
  eq(#done, 0)
  eq(handle:is_active(), true)
  eq(proc.active_count(), 1)
  local admitted, refusal = proc.admits(SEARCH)
  eq({ admitted, refusal.code }, { false, "cleanup_failed" })
  local _, refused = start({ "true" }, { admission = SEARCH })
  eq(wait_done(refused).refused, "cleanup_failed")
  eq(proc.admits({ group = "other", max = 4 }), true)
  vim.wait(200)
  eq(#reports, 1)
end

failure["lifts the refusal once the process is reaped"] = function()
  make_sigkill_ineffective()
  local failed = false
  local path = script("trap '' TERM; echo ready; exec sleep 30")
  local handle, done = start_ready(path, {
    admission = SEARCH,
    on_cleanup_failure = function()
      failed = true
    end,
  })
  table.insert(orphans, handle.pid)
  handle:cancel()
  assert(wait_until(function()
    return failed
  end))
  vim.uv.kill = real_kill
  vim.uv.kill(handle.pid, "sigkill")
  local result = wait_done(done)
  local steps = result.escalation
  eq({
    status = result.status,
    signal = result.signal,
    cleanup_failed = result.cleanup_failed,
    pipes_forced = result.pipes_forced,
    kill_tried = steps.kill >= 199 and steps.kill < steps.close,
    close_at_500 = steps.close >= 499 and steps.close < steps.report,
    report_at_1000 = steps.report >= 999,
  }, {
    status = "cancelled",
    signal = 9,
    cleanup_failed = true,
    pipes_forced = true,
    kill_tried = true,
    close_at_500 = true,
    report_at_1000 = true,
  })
  eq(proc.admits(SEARCH), true)
end

return T
