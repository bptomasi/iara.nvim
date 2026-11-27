# Iara module contracts

This file documents the public interfaces and resource limits of Iara's
modules. Functions outside these interfaces are private to their module.
Types use LuaCATS notation. A `?` marks an optional field.

## 1. Conventions for every module

### Setup and ownership

- A module listed in `iara.STEPS` (section 2) exports `setup(config)`,
  where `config` is the composed configuration (section 3). Setup is
  idempotent: a second call does nothing. It must not block, spawn
  processes, or scan files; it registers commands, mappings, and autocmds.
- Each owner creates its autocmds in one augroup named `Iara<Owner>`
  (for example `IaraRoot`) with `clear = true`, and its user commands with
  the `Iara` prefix. Owners never clear another owner's group.
- A feature reads its own sub-table, for example
  `config.features.search`, and validates its own fields. An invalid
  field is reported once and replaced by the feature's default.
- Owners stop their own timers, jobs, and state when disabled, on buffer
  wipeout, and on `VimLeavePre`, without synchronous waits.

### Error reporting

- **Programmer errors** (wrong argument types, invalid buffer handles,
  calling an API with an empty query where the contract forbids it) raise
  a Lua error with `error(message, 2)`.
- **Runtime failures** (missing executables, invalid user input, I/O
  errors, caps, stale state) are values, never raised:
  synchronous functions return `nil, err` (or `false, err`) where `err`
  is an `IaraError`; asynchronous results carry `state = "error"` and an
  `error` field of the same type.
- Library modules never call `vim.notify`. Only user-facing owners
  (commands, mappings, UI, setup failures) notify, prefixed with `Iara:`.

```lua
---@class IaraError
---@field code string Stable machine-readable code, listed per module.
---@field message string English text suitable for display.
---@field uv_error string? libuv error name when one caused the failure,
---  for example "E2BIG" or "ENOENT".
```

### Events

Broadcast state changes use `User` autocmds whose pattern starts with
`Iara`. The payload is in `args.data`: a table of plain values (no
functions, no handles other than integers). Owners fire them with:

```lua
vim.api.nvim_exec_autocmds("User", {
  pattern = "IaraRootChanged",
  data = payload,
  modeline = false,
})
```

- Owners update their state first, then fire, so a listener that queries
  the owner sees the new state.
- Events fire on the main loop, never from a fast (libuv) context.
- Listeners must not raise; they must not assume an order relative to
  other events and must re-query state instead of caching payloads.
- Request/response work (processes, searches, parses) uses callbacks
  passed by the caller instead of events. Section 14 lists every event.

### Threading and callbacks

- Every public function must be called from the main loop. Code running
  in a libuv callback must `vim.schedule` before calling Iara APIs.
- Every callback passed to an Iara API runs on the main loop and never
  synchronously inside the call that received it (at least one
  `vim.schedule` later), so callers can finish storing handles first.
- A completion callback (`on_done`, `on_complete`) runs exactly once.
  Data callbacks never run after their completion callback, and never
  after `cancel()` returned.
- Owners that publish results keep a monotonically increasing integer
  generation and drop every callback whose generation is stale.

### Units and paths

- Rows and byte columns are zero-based and ranges are half-open
  `{start_row, start_col, end_row, end_col}`, end exclusive, in bytes.
  One-based lines and screen columns appear only at API boundaries
  (quickfix, cursor, display).
- Paths are absolute and normalized with `vim.fs.normalize`, without a
  trailing slash, unless a field says "root-relative". Root-relative
  paths have no `./` prefix and keep their raw bytes; display escaping is
  a separate field.
- Durations are milliseconds; sizes are bytes.

## 2. `iara` (F1): ordered composition

File: `lua/iara/init.lua`. Entry point `iara/init.lua` calls `setup()`.

```lua
---@class IaraStepResult
---@field name string Module name, or "hooks.early" / "hooks.late".
---@field state "loaded"|"missing"|"failed"|"skipped"|"disabled"
---@field error string? Message with traceback when state is "failed".

---@class IaraStatus
---@field mode "full"|"safe"
---@field reason "requested"|"config_error"|"incompatible"|nil
---@field startup_dir string Working directory captured by setup().
---@field errors IaraConfigError[]
---@field steps IaraStepResult[]

---Check Neovim >= 0.12, capture the startup directory, compose the
---configuration, then run every step in order once.
---@param opts IaraLoadOptions? `safe` defaults to $IARA_SAFE == "1".
---@return IaraStatus
function M.setup(opts) end

---@return IaraStatus|nil status Nil before setup() ran.
function M.status() end

---The directory captured at setup (root fallback for F3).
---@return string
function M.startup_dir() end
```

`vim.g.iara_mode` mirrors `status.mode` for statuslines and health.

Steps run in this order. "Safe" steps also run in safe mode and must work
without plugins. A failing step is reported with its traceback and the
remaining steps still run. A step whose module does not exist yet is
recorded as `missing`.

| Order | Step | Owner | Safe | Capability |
| --- | --- | --- | --- | --- |
| 1 | `iara.core.options` (leaders first) | F6 | yes | |
| 1a | `iara.theme` (colors) | U1 | yes | |
| 1b | `iara.core.select` (`vim.ui.select` presenter) | V10 | yes | |
| 1c | `iara.core.messages` (ui2 opt-in) | V11 | no | |
| 2 | personal hook `early` | user | no | |
| 3 | `iara.core.root` | F3 | yes | |
| 4 | `iara.core.eligibility` | F5 | yes | |
| 5 | `iara.core.reconcile` | A3 | yes | |
| 6 | `iara.core.term_retention` | T1 | no | |
| 7 | `iara.core.lazy` (plugins, specs) | F2 | no | |
| 8 | `iara.core.keymaps` | F6 | no | |
| 8a | `iara.features.format_lua` | L1 | no | `formatters.lua` |
| 9 | `iara.features.search.keymaps` | S7 | no | `features.search` |
| 10 | `iara.features.terminal` | T3 | no | `features.terminal` |
| 11 | `iara.features.structured` | D4 | no | `features.structured` |
| 11a | `iara.extras.agents` | A1 | no | `extras.agents` |
| 11b | `iara.core.start` (start screen) | UX3 | no | |
| 12 | personal hook `late` | user | no | |

Safe mode starts when `IARA_SAFE=1`, when Neovim is older than 0.12, or
when the configuration fails to load or has an invalid global structure.
It uses the defaults, skips personal and project layers, hooks, plugins,
and every non-safe step.

## 3. `iara.config` (F1): composition

File: `lua/iara/config.lua`.

Layers apply in order: defaults, personal configuration, then the policy
of an explicitly trusted project.

- Maps merge recursively. Lists replace: the later list wins entirely
  (`formatters.python = { "ruff_format" }`). An empty table `{}` replaces
  a list but leaves a map unchanged.
- `false` removes an optional capability; `true` is shorthand for `{}`.
- Every `false` in the personal layer wins over the project policy.
- Personal configuration: a Lua file returning a table, at
  `$IARA_PERSONAL` or `stdpath("config")/lua/user.lua` (gitignored). A
  missing file means defaults; a file returning nothing is empty.
- Project policy: `<dir>/.iara.lua`, read only when the personal
  `trusted_projects` lists `<dir>` (compared after `realpath`). `<dir>`
  is the startup directory. A project may not set `trusted_projects` or
  `hooks`.
- A load error (syntax or runtime, reported with its traceback) or an
  invalid global structure (non-table, unknown top-level key, top-level
  value that is not a table, invalid `trusted_projects` or `hooks`)
  yields safe mode with the defaults. (R2-B) The personal structure is
  validated before `trusted_projects` is read, and `setup()` turns an
  error raised while loading into a "load" error: safe mode and
  `status()` survive any malformed value.
- A malformed capability entry (in `features`, `languages`, `extras`,
  `formatters`) disables only that capability and records an error.
- A formatter list with more than one entry names a second formatting
  owner; it is a pre-activation error that disables that formatter entry.

Top-level keys and their owners:

| Key | Shape | Read by |
| --- | --- | --- |
| `options` | map option name -> value | F6 |
| `keymaps` | map `"<mode> <lhs>"` -> `false` or `{ rhs, desc = s }` | F6 |
| `plugins` | list of lazy.nvim specs, appended last | F2 |
| `features` | map name -> table or `false` | owners |
| `languages` | map filetype -> table or `false` | F6, L1 |
| `formatters` | map filetype -> `{ name }` or `false` | L1 |
| `extras` | map name -> table or `false` | A1, AI1, L2 |
| `ui` | See the settings below. | U1, UX3, V11, V15, V17 |
| `trusted_projects` | list of directories (personal only) | config |
| `hooks` | `{ early = fn(config), late = fn(config) }` | init |

Defaults: every table above is empty except `features = { search = {},
terminal = {}, structured = {} }`, `languages = { lua = {} }`,
`formatters = { lua = { "stylua" } }`,
`extras = { agents = true, ai = true }`, and
`ui` defaults to `theme = "chocolate"`, `start_screen = true`,
`messages = "native"`, `terminal_background = true`, and
`wave_animation = true`.
Agents and Ask AI
are on by default; the modules only register commands and mappings, and
launch a CLI on request. Set `extras = { agents = false }` or
`extras = { ai = false }` to disable them.

`ui.messages` (V11 spike) is "native" (Neovim's message area) or "ui2"
(Neovim 0.12's experimental `vim._core.ui2`: notices in an ephemeral
float for 4 s, `:messages` in ui2's pager, history kept). Any other
value is reported and stays native. `iara.core.messages`:
`mode(config) -> mode, problem?`, `setup(config) -> mode`, `MODES`,
`TIMEOUT_MS`, `WINHIGHLIGHT`.

Plugin specs are customized through lazy.nvim's own composition in
`plugins`, for example `{ "<leader>ff", false, mode = "n" }` inside a
spec's `keys` removes a deferred mapping. Buffer-local options and
mappings are customized at their FileType/LspAttach owner.

```lua
---@class IaraConfigError
---@field kind "load"|"structure"|"capability"
---@field source "personal"|"project"
---@field path string? Dotted path, for example "languages.python".
---@field message string Includes the traceback for load errors.

---@class IaraLoadOptions
---@field personal_path string?
---@field project_dir string? Defaults to the current directory.
---@field safe boolean? Skip the personal and project layers.

---@class IaraLoadResult
---@field config table
---@field mode "full"|"safe"
---@field errors IaraConfigError[]
---@field sources { personal: string?, project: string? }

---@return table defaults Fresh copy.
function M.defaults() end

---Pure composition of already-loaded layers.
---@return table|nil config Nil when a layer's global structure is invalid.
---@return IaraConfigError[] errors
function M.compose(personal, project) end

---Read the layers, compose, and make the result current.
---@param opts IaraLoadOptions?
---@return IaraLoadResult
function M.load(opts) end

---Current composed configuration or a value at a dotted path. Shared
---table: callers must not mutate it.
---@param path string?
function M.get(path) end

---True when the value at `path` exists and neither it nor an ancestor is
---`false`.
---@param path string
---@return boolean
function M.enabled(path) end

---True when the personal layer or the trusted project policy of the last
---load sets a value at `path`; defaults never count. False in safe mode.
---@param path string
---@return boolean
function M.is_explicit(path) end
```

## 4. `iara.core.root` (F3): project root

```lua
---@class IaraRoot
---@field path string Absolute canonical directory (realpath).
---@field provenance "override"|"git"|"startup"
---@field worktree_id string "git:<realpath of worktree top>" or
---  "dir:<realpath>". Separate worktrees never share an identity; aliases
---  of the same directory do.
---@field label string Short display text, for example "iara (git)".

---Resolve the root for an editing buffer: session override, then the
---nearest ancestor containing `.git` (directory or file), then the
---startup directory. Never raises for valid buffers; never changes the
---working directory; runs no subprocess. Cached per buffer.
---For special buffers (terminal, picker, unnamed) it uses
---`vim.b[bufnr].iara_context_root` when an owner set it (an absolute
---directory); if that directory vanished, the startup fallback is
---returned. Setting or changing that variable after the buffer's root
---was cached makes the next call resolve again (the cache remembers the
---value it was computed from; no polling, no event).
---@param bufnr integer? 0 or nil for the current buffer.
---@return IaraRoot
function M.resolve(bufnr) end

---Session-wide override. Relative paths resolve against the startup
---directory. Error codes: "not_directory".
---@param path string
---@return IaraRoot|nil root
---@return IaraError|nil err
function M.set_override(path) end

function M.clear_override() end

---@return string|nil path Current override, if any.
function M.override() end

---Re-resolve after repository-marker changes (explicit refresh).
---nil refreshes every buffer; 0 refreshes only the current buffer.
---@param bufnr integer?
function M.refresh(bufnr) end

---@return string text For the statusline, for example "iara (git)".
function M.statusline() end
```

Commands: `:IaraRoot` (show path and provenance), `:IaraRootSet {path}`,
`:IaraRootReset`. The cache is invalidated on `BufFilePost` (rename and
save-as), override changes, and `DirChanged`. Event `IaraRootChanged`,
data `{ bufnr = integer|nil, cause = "override"|"reset"|"rename"|
"dirchange"|"refresh", root = IaraRoot|nil, previous = IaraRoot|nil }`;
`bufnr` is nil for session-wide causes. The event fires on every
invalidation, even when the root did not change; `previous` is the cached
root and may be nil. Consumers snapshot the root when an action starts;
existing terminals keep their owner.

The ancestor search honours `$GIT_CEILING_DIRECTORIES`, so Iara selects
the same repository as Git. A missing directory resolves through its
nearest existing parent.

## 5. `iara.core.proc` (F4): owned processes

Direct argv only (no shell), built on libuv handles available in Neovim
0.12.3 (no `SystemObj:close()`).

```lua
---@class IaraProcStream
---@field mode "lines"|"chunks"|"collect"|"discard"
---@field max_bytes integer? Total bytes accepted; exceeding it ends the
---  job with status "overflow". Default 1 MiB (stdout), 64 KiB (stderr).
---@field max_line_bytes integer? "lines" only; default 64 KiB. A longer
---  line is an overflow.
---@field on_data fun(items: string[])? "lines": complete lines without
---  "\n" (a trailing "\r" is kept), the final unterminated line at EOF;
---  "chunks": raw chunks. Called in stream order, in batches.
---@field delimiter string? "lines" only; one byte, default "\n". Use
---  "\0" for NUL-separated output such as `rg --files -0`.
---
---"discard" mode drops data without counting it, so it has no byte cap.
---The child runs in its own process group: cancellation signals reach
---its descendants that stay in that group.

---@class IaraProcAdmission
---@field group string Session-wide admission group, for example "search"
---  (shared by every lane, unlike `tag`).
---@field max integer >= 1. Live handles of the group, retiring ones
---  included, above which a spawn is refused.

---@class IaraProcOpts
---@field cwd string Absolute; required.
---@field env table<string, string>? Merged over the editor environment.
---@field clear_env boolean? Use only `env`.
---@field stdin string? Written, then closed. Nil closes stdin at spawn.
---@field timeout_ms integer? Wall deadline from spawn. Required unless
---  `long_lived` is true.
---@field long_lived boolean? No deadline (shell-like jobs only).
---@field tag string? Group name for active_count() and cancel_all().
---@field admission IaraProcAdmission? Refuse instead of spawning when
---  the group is at `max` or holds a handle whose cleanup failed.
---@field stdout IaraProcStream? Default { mode = "collect" }.
---@field stderr IaraProcStream? Default { mode = "collect" }.
---@field on_exit fun(code: integer, signal: integer)? Process exit was
---  observed; streams may still be open.
---@field on_complete fun(result: IaraProcResult) Required. Runs once,
---  after exit, EOF or forced pipe closure, and handle cleanup.
---@field on_cleanup_failure fun(handle: IaraProcHandle)? Cleanup is
---  still unfinished 1 s after cancellation, deadline, or overflow.
---  Called once; the handle stays live.

---@class IaraProcResult
---@field status "exited"|"cancelled"|"timeout"|"overflow"|
---  "not_found"|"spawn_failed"|"refused" The first cause that ended
---  the job. "refused": admission refused it; nothing was started.
---  "exited" includes nonzero codes; callers interpret `code`.
---@field code integer? Exit code when the process exited.
---@field signal integer? Terminating signal, 0 if none.
---@field stdout string? Collected bytes in "collect" mode.
---@field stderr string?
---@field eof { stdout: boolean, stderr: boolean } Natural EOF reached.
---@field pipes_forced boolean Pipes were closed by escalation.
---@field overflow "stdout"|"stderr"|nil
---@field reason string? Reason given to cancel().
---@field refused "cap"|"cleanup_failed"|nil Why admission refused it.
---@field escalation IaraProcEscalation? Set once the job began ending
---  (cancel, deadline, overflow); nil after a natural exit.
---@field cleanup_failed boolean The 1 s stage was reached.
---@field error IaraError? Codes: "not_found", "spawn_failed",
---  "overflow", "timeout", "refused".
---@field elapsed_ms number

---Milliseconds from the moment the job began ending to each step that
---acted; a step that was not needed is nil.
---@class IaraProcEscalation
---@field term number? SIGTERM sent to the process group (about 0).
---@field kill number? SIGKILL sent (the process had not exited).
---@field close number? Owned pipes force-closed (EOF had not arrived).
---@field report number? Cleanup failure reported.

---@class IaraProcHandle
---@field id integer Unique per session.
---@field pid integer|nil Nil when spawning failed or was refused.
---@field refused "cap"|"cleanup_failed"|nil Set at once on refusal.
---@field argv string[]
---@field cancel fun(self: IaraProcHandle, reason: string?) Idempotent.
---@field is_active fun(self: IaraProcHandle): boolean True until
---  on_complete has run.

---Spawn `argv` (argv[1] resolved through PATH). Always returns a handle;
---spawn failures and refusals arrive through on_complete. Raises for an
---empty argv, non-string items, NUL bytes, a missing `on_complete`/`cwd`,
---or a malformed `admission`.
---@param argv string[]
---@param opts IaraProcOpts
---@return IaraProcHandle
function M.spawn(argv, opts) end

---Whether a spawn with `admission` would start now. Retiring handles
---count toward the cap; a live handle whose cleanup failed blocks its
---whole group until it is finally reaped.
---@param admission IaraProcAdmission
---@return boolean admitted
---@return IaraError|nil refusal Codes "cap" and "cleanup_failed".
function M.admits(admission) end

---Live handles (not yet completed), optionally for one tag. Callers use
---it to enforce their own concurrency caps; retiring handles count.
---@param tag string?
---@return integer
function M.active_count(tag) end

---@param tag string? Cancel every live handle, or those with `tag`.
function M.cancel_all(tag) end
```

Cancellation, deadline, and overflow share one escalation measured from
the triggering moment: SIGTERM at once; SIGKILL after 200 ms if the
process has not exited; force-close owned pipes after 500 ms if EOF has
not arrived; after 1 s, if cleanup is unfinished, call
`on_cleanup_failure` once. The handle stays live (and counted) until
cleanup finishes. After a natural exit, pipes still open after 500 ms
(inherited by descendants) are force-closed and `pipes_forced` is set.
Data after `cancel()` is discarded. `VimLeavePre` cancels every live
handle without waiting. Overflow signals the process before it closes
the overflowing pipe.

Admission. At most four search-related processes run session-wide.
Search lanes pass the same group, for example
`admission = { group = "search", max = 4 }` alongside their own `tag`;
a refused spawn starts nothing, sets `handle.refused`, and completes
asynchronously with status "refused". Callers that queue the latest
request check `admits()` first and retry when a handle of the group
completes. After a cleanup failure (1 s), the failed handle keeps its
slot and the group refuses new work ("cleanup_failed") until the
process is reaped; other groups are unaffected. Library code never
notifies: owners surface `on_cleanup_failure` or the refusal.

`argv` is copied once (shallow; items are strings) together with the
libuv operand list; `handle.argv` is that copy.

## 6. `iara.core.eligibility` (F5): conservative mode

```lua
M.LIMITS = { max_bytes = 1048576, max_line_bytes = 10000 }

---@class IaraEligibility
---@field state "eligible"|"conservative"|"unknown"
---@field reason "size"|"long_line"|"pending"|"invalid"|nil Nil when
---  eligible. "pending": the budgeted line check has not finished.
---@field message string? For example "large file: 2.3 MiB > 1 MiB".
---@field bytes integer? Buffer size from byte offsets.

---Cheap query: returns cached state and schedules a budgeted recheck
---when stale. Never scans a whole buffer synchronously.
---Conservative when bytes > max_bytes or any line has >= max_line_bytes
---bytes.
---@param bufnr integer? 0 or nil for the current buffer.
---@return IaraEligibility
function M.check(bufnr) end

---True only for state "eligible". Unknown counts as suspended.
---@return boolean
function M.is_eligible(bufnr) end

---Force a recheck (text change, paste, reload trigger one too).
function M.recheck(bufnr) end

---@return string text "" when eligible, else a short reason.
function M.statusline(bufnr) end
```

Event `IaraEligibilityChanged`, data `{ bufnr, state, previous, reason }`.
Features suspend their own work on any state other than "eligible" and
decide themselves whether to resume when a buffer becomes eligible again
(legacy YAML handlers never resume silently).

Rechecks (M2-P proofs). Every text change (`nvim_buf_attach`
`on_lines`, including undo, `p` from a register, and bracketed
`vim.paste`) schedules a recheck; reloads (`:edit!`, `:checktime` with
'autoread') recheck the whole buffer. The size check is synchronous on
every query, so `check()` never reports a stale "eligible" after
growth past `max_bytes`; only long-line detection may be "unknown"
("pending") across main-loop iterations, and never above `max_bytes`.
Events are delivered on a later iteration: handlers must act on the
current `is_eligible()`, not on `data.state`, which may already be
outdated.

## 7. `iara.core.reconcile` (A3): external changes

```lua
---@class IaraConflict
---@field bufnr integer
---@field path string
---@field detected_at integer `vim.uv.now()` at detection.
---@field snapshot "available"|"pending"|"oversized"|"over_cap"|
---  "unreadable" Disk snapshot state within the limits below.
---@field disk { size: integer, mtime: integer }?
---@field detail string? Why no complete snapshot exists, for example
---  "1.3 MiB > 1 MiB", "the file grew while it was read", or "two disk
---  snapshots are already held".

---Check now (asynchronous, bounded). Nil checks every loaded file
---buffer. Unmodified buffers reload; modified ones become conflicts.
---@param bufnr integer?
function M.check(bufnr) end

---@return IaraConflict|nil
function M.conflict(bufnr) end

---@return IaraConflict[] conflicts Sorted by bufnr.
function M.conflicts() end

---Open a read-only diff of the buffer against the disk snapshot. The
---view's copy counts against the session cap until it is closed.
---Error codes: "no_conflict", "snapshot_unavailable", "over_cap".
---@return boolean ok
---@return IaraError|nil err
function M.compare(bufnr) end

---Fallback for any conflict, including "oversized" and "over_cap": an
---explicitly partial, read-only excerpt (at most 64 KiB from the start
---or end of the file, cut at line boundaries, labeled with its byte
---range) beside the buffer. Asynchronous; returns whether it started.
---Error codes: "no_conflict", "over_cap" (no 64 KiB left in the
---session cap), and through `on_done` "disk_unavailable" or
---"no_conflict" (the conflict changed meanwhile).
---@param part "head"|"tail"|nil Default "head".
---@param on_done fun(ok: boolean, err: IaraError|nil)?
---@return boolean started
---@return IaraError|nil err
function M.excerpt(bufnr, part, on_done) end

---Fallback: user-directed save-as of the buffer text to `path`, which
---must not exist (exclusive creation). The buffer keeps its name,
---'modified', and conflict; the conflicted file is untouched.
---Error codes: "no_conflict", "invalid_path" (the file itself),
---"path_exists", "write_failed".
---@return boolean ok
---@return IaraError|nil err
---@return string[]|nil diff_argv `{ "diff", "-u", "--", disk, copy }`
---  for an external comparison; never run by Iara.
function M.save_copy(bufnr, path) end

---Explicit user choice: "keep_buffer" clears the conflict and keeps the
---text; "load_disk" reloads from disk. Never called automatically.
---Error codes: "no_conflict", "disk_unavailable" (load from a deleted
---or unreadable file).
---@param choice "keep_buffer"|"load_disk"
---@return boolean ok
---@return IaraError|nil err
function M.resolve(bufnr, choice) end

---@return string text "" without a conflict.
function M.statusline(bufnr) end
```

Commands: `:IaraCheckDisk`, `:IaraCompareDisk`, `:IaraKeepBuffer`,
`:IaraLoadDisk`, `:IaraDiskExcerpt [head|tail]`, and
`:IaraSaveCopy {path}` (reports the external diff command). Events:
`IaraConflictDetected` `{ bufnr, path, snapshot }`,
`IaraConflictResolved` `{ bufnr, path, choice }`, `IaraBufferReloaded`
`{ bufnr, path }`. Checks run on focus return and explicit command
only; never on terminal output. `compare`, `excerpt`, `save_copy`,
`resolve`, and `statusline` default to the current buffer. A deleted
file becomes a conflict with snapshot "unreadable" even when the buffer
is unmodified.
`:w!` or a manual reload clears the conflict as `keep_buffer` or
`load_disk`; writing the buffer to another file (`:w other`) resolves
nothing. With `autoread`, Neovim reloads without FileChangedShell;
`IaraBufferReloaded` is then fired from FileChangedShellPost. The
statusline owner (F6) includes `reconcile.statusline()`.

Snapshot limits are 1 MiB, 10,000 lines, and 64 KiB per
line, enforced while streaming 64 KiB chunks after an `fstat`. A file
that grows past or shrinks below the admitted size during the read is
being written: the partial read is dropped (never a mix of versions)
and read again after 50 ms, at most three times, silently; admission of
the new size decides "oversized", and a writer still active after the
retries leaves "unreadable". At most two
snapshots and 4 MiB session-wide, counting comparison views and
excerpts; unresolved snapshots are never evicted. A refused or
oversized snapshot keeps buffer and disk untouched and the indicator
visible. A conflict is announced once; later detections during a burst
of writes refresh its snapshot silently, and the fallbacks (excerpt
and save copy) are announced at most once per conflict.

## 8. `iara.core.term_retention` (T1)

```lua
---Install the wrapper around the shipped `nvim.terminal` TermClose
---handler. Mismatch or ambiguity leaves native defaults and makes
---available() false.
function M.setup(config) end

---@return boolean ok
---@return string|nil reason Why Iara terminal creation is disabled.
function M.available() end

---Owned buffers survive a successful exit; unowned behave natively.
function M.own(bufnr) end
function M.disown(bufnr) end
---@return boolean
function M.is_owned(bufnr) end
```

The wrapper still keeps every owned buffer at exit; since T4, closing an
exited Iara terminal is a decision of `iara.features.terminal` (10.2)
and `iara.extras.agents` (12.2), which dispose the record explicitly.

## 9. Search

### 9.1 `iara.features.search` (S5): entry points

```lua
---@class IaraSearchRequest
---@field query string? At most 256 bytes, no NUL. Default "".
---@field glob string? One ripgrep glob, at most 1 KiB.
---@field hidden boolean? Default false.
---@field ignored boolean? Default false.
---@field regex boolean? Content interpretation. Default false (literal).
---@field case "smart"|"sensitive"|"insensitive"|nil Default "smart".
---@field scope { kind: "root"|"directory"|"file", path: string? }?
---@field focus "files"|"content"|nil Combined search only (legacy):
---  initially focused group; the UX1 UI ignores it.
---@field mode "files"|"content"|nil (UX1) Run one lane only: "files"
---  finds files by name, "content" finds text in files. Nil runs both
---  lanes (the combined search of the session API).
---@field within string[]|false|nil (UX1) Root-relative paths that
---  narrow both lanes after eligibility and the glob (a chained filter
---  step); `false` clears it in update().

---Open a search for the root of the invoking buffer, which is
---snapshotted before any UI opens. `Space ff` = open({ mode = "files" }),
---`Space fw` = open({ mode = "content" }), `Space fa` = open({ mode =
---"files", hidden = true, ignored = true }).
---@param opts IaraSearchRequest?
function M.open(opts) end

---Restore the previous request controls, chain, and selection intent,
---then rerun (results are never reused). `Space fr`.
function M.resume() end
```

`Space ff` and `Space fw` open distinct search modes. Chain steps to
search inside files found by name (section 9.8). API callers can use
both filename and content search in the same session.

### 9.2 `iara.features.search.inventory` (S2): eligibility

```lua
---@class IaraInventorySpec
---@field root string Absolute root.
---@field scope { kind: "root"|"directory"|"file", path: string? }
---@field hidden boolean
---@field ignored boolean
---@field glob string?
---@field generation integer Inventory generation (not query).
---@field base IaraInventoryBase? (M2-S) `E` of an earlier complete
---  result; used instead of the `E` walk when root, scope, hidden, and
---  ignored match, ignored otherwise.

---@class IaraInventoryBase Opaque; `paths` must not be modified.
---@field identity string Root, scope, hidden, and ignored.
---@field paths string[] The scoped `E`, in admission order.

---@class IaraInventory
---@field generation integer
---@field state "complete"|"incomplete"|"error"|"cancelled"
---@field paths string[] Root-relative eligible paths: E, or E ∩ G with a
---  glob, after `.git`/worktree exclusion and scope narrowing, in
---  admission order (unspecified; not sorted).
---@field reason "deadline"|"paths"|"bytes"|"path_length"|nil Why
---  incomplete (5 s, 100,000 paths, 16 MiB, 4 KiB path).
---@field base IaraInventoryBase? Complete results only: their `E`.
---@field error IaraError? Codes: "glob", "not_found", "spawn", "rg",
---  "refused" (the "search" admission group refused a walk).

---`on_progress` (S8) receives each path once, as soon as it is known to
---be eligible (every check of its walk passed and, with a glob, both
---walks listed it), while the walks run. It never runs synchronously,
---after `on_done` was scheduled, or after `cancel()`. For a complete or
---incomplete result, the reported paths are exactly `paths`, in order.
---@param spec IaraInventorySpec
---@param on_done fun(result: IaraInventory)
---@param on_progress fun(paths: string[])?
---@return { cancel: fun(self) } handle
function M.build(spec, on_done, on_progress) end
```

Each walk stops at 5 s from its spawn, 100,000
retained paths, 16 MiB of retained path bytes, or a retained path
above 4 KiB; out-of-scope paths are framed and checked but retain
nothing (raw walk output is capped at 256 MiB, reported as "bytes",
and an unterminated output tail above 64 KiB as "path_length"). The
first limit stops both walks; the result is "incomplete" with the
paths admitted so far and no `base`. Result lists are shared and must
not be modified.

### 9.3 `iara.features.search.grep` (S3): content lane

```lua
---@class IaraOccurrence
---@field path string Root-relative raw path.
---@field row integer Zero-based line.
---@field byte_start integer Zero-based byte column in the line.
---@field byte_end integer Exclusive; equal to byte_start when zero-width.
---@field text string Bounded, escaped display text of the line; a tab
---  is shown as one space (UX1).
---@field text_exact boolean (UX1) Nothing was escaped, so the byte
---  range also indexes `text`.

---@class IaraGrepSpec
---@field root string
---@field files string[] Root-relative eligible paths (may be empty).
---@field query string Non-empty; raises on "" or NUL.
---@field regex boolean
---@field case "smart"|"sensitive"|"insensitive"
---@field generation integer Query generation.

---@class IaraGrepResult
---@field generation integer
---@field state "complete"|"no_match"|"error"|"cancelled"|"partial"
---@field error IaraError? Codes: "regex", "not_found", "spawn", "rg",
---  "overflow".
---@field binary_files integer Files discarded by the binary policy.

---Run ripgrep with literal argv. `on_file` receives every occurrence of
---one completed, non-binary file at once, in file arrival order. With an
---empty `files` list, only validates the regex.
---@param spec IaraGrepSpec
---@param callbacks { on_file: fun(path: string, items: IaraOccurrence[]),
---  on_done: fun(result: IaraGrepResult) }
---@return { cancel: fun(self) } handle
function M.run(spec, callbacks) end
```

Bounds (M2-S). Occurrences held until their file's `end` frame are
decoded work: all batches together hold at most 2 MiB (text plus 64
bytes per occurrence), checked before they are kept; above that the
run ends "partial" with code "overflow". A batch refused by process
admission ends the run with code "refused".

Ripgrep uses its default thread count, with at most two concurrent
batches per run and four live search processes session-wide
(section 9.7).

### 9.4 `iara.features.search.fuzzy` (S4): filename lane

```lua
---@class IaraFuzzyMatch
---@field path string
---@field score number Higher is better.
---@field positions integer[] Zero-based byte offsets of matched bytes.

---Pure, bounded linear score. Nil when `path` does not match or exceeds
---4 KiB. (S9) An optional `positions` table receives the zero-based
---offsets of the matched bytes.
---@return number|nil
function M.score(query, path, positions) end

---Rank candidates in cancellable batches (<= 128 candidates or 2 ms).
---`on_done` receives at most `limit` (default 200) matches sorted by
---score, ties by byte-wise path order; `complete` is false if cancelled
---or superseded, and partial matches are still delivered. `total`
---(UX1) counts every matching candidate scanned, also those beyond the
---limit. Matching uses smart case (ASCII): an uppercase query byte
---makes it case sensitive. An empty query (UX1b) ranks a listing:
---paths in `opts.recent` (path to rank, 1 first) before the others,
---then fewer path components, then byte-wise path order. Only the
---latest `match` runs: starting one supersedes the previous call
---module-wide. With `path_cap`, the callback also receives all matched
---paths in input order when the run completes within that cap.
---A cancelled or over-cap run supplies nil as the fourth argument.
---@param opts { limit: integer?, recent: table<string, integer>?,
---  path_cap: integer?,
---  on_done: fun(matches: IaraFuzzyMatch[], complete: boolean,
---  total: integer, paths: string[]?) }
---@return { cancel: fun(self) } handle
function M.match(query, candidates, opts) end
```

### 9.5 `iara.features.search.session` (S5): result model for UI (S6)

```lua
---@class IaraSearchRecord
---@field id string Stable identity: kind, path, and byte range.
---@field generation integer
---@field root string
---@field kind "file"|"occurrence"
---@field path string Root-relative raw path.
---@field row integer? Occurrences only (zero-based).
---@field byte_start integer?
---@field byte_end integer?
---@field text string? Escaped display text.
---@field text_exact boolean? Occurrences: `text` keeps the byte offsets.
---@field score number? File records only.
---@field positions integer[]? File records: zero-based matched bytes.

---@class IaraLaneState
---@field state "idle"|"loading"|"complete"|"truncated"|"incomplete"|
---  "error"|"cancelled"
---@field error IaraError?
---@field count integer
---@field total integer (UX1) File names: every match found, also those
---  beyond the quota; occurrences: equal to `count`.
---@field limit integer 200 file names, 1,000 occurrences.

---@class IaraSearchSnapshot
---@field request IaraSearchRequest
---@field root IaraRoot
---@field generation integer
---@field files { lane: IaraLaneState, records: IaraSearchRecord[] }
---@field content { lane: IaraLaneState, groups: { path: string,
---  records: IaraSearchRecord[] }[] }

---@return table session With methods: update(changes: IaraSearchRequest),
---  snapshot(): IaraSearchSnapshot, on_change(fn(snapshot)) (one
---  subscriber, coalesced), to_quickfix(records, title): integer (list
---  id), tree(on_done) (S9, below), refresh() (S10, below), close().
---  Picker entry points pass shared_inventory to enable validated reuse.
function M.new(request, root, shared_inventory?) end

---(S9) Eligible paths of the whole root under the current hidden and
---ignored switches, without scope, glob, or `within`: the source of the
---directory step. `on_done` runs once, never synchronously, and not
---after close() or `handle:cancel()`.
---@param on_done fun(result: IaraInventory)
---@return { cancel: fun(self) } handle
function Session:tree(on_done) end

---(S10) Files changed on disk: forget every cached inventory and run
---the request again (a new generation). Nothing after close().
function Session:refresh() end
```

The tree is served from a complete `E` of the root scope already cached
(the current inventory, or the base behind a glob) without a walk;
otherwise one root walk joins the session's inventory cache (still at
most two inventories), so asking again, or returning to the root
scope, walks nothing. The directory step reuses its index while the
same immutable path list is retained.

A new picker session revalidates one shared, complete root inventory
without a path glob. It matches root, hidden and ignored flags, the
ripgrep executable, and the recorded directory and ignore metadata
before using those paths. Content matches and rankings are recomputed.
Explicit refresh drops shared reuse. A changed dependency, incomplete
walk, unsupported dependency, or exceeded cache budget uses the
ordinary ripgrep walk. In-flight checks never publish to a cancelled
session.

Bounds (M2-S). Retained records of both lanes are accounted (path,
id, and text bytes plus 200 per record); a content record that would
take the session above 8 MiB stops the content lane as "truncated"
with error code "memory", like a full quota. A session keeps at most
two inventories; a change of the glob alone reuses the complete `E`
of the same scope and switches, so only `G` is walked.

Modes and narrowing (UX1). With `mode = "files"` the content lane stays
"idle"; with `mode = "content"` the filename lane does. The filename
lane runs for a non-empty query, a glob, a `within` list, or `mode =
"files"` (an empty query then lists the eligible files, UX1b); content
never runs for an empty query. A listing ranks recently used listed file
buffers under the root first (most recent first, the current buffer last
of them; read once per session), then fewer path components, then
byte-wise path order; it keeps the 200 quota (state "truncated" above
it) and `total` counts every listed file. `within` keeps only listed
paths that are eligible under the current switches, scope, and glob, so
it never widens eligibility; update({ within = false }) clears it, like
glob = "".

While the filename lane is `loading`, its records are provisional (S8):
each is an eligible path ranked among the paths admitted so far, and
better matches may still arrive. The lane leaves `loading` once the
complete inventory is ranked. Content search still starts only after
the complete scoped inventory and the debounce.

### 9.6 `iara.features.picker.open` and `.preview` (S8): shared helpers

Record opening and previewing, extracted from the search UI so other
Snacks pickers (D4's key search) present locations the same way.

```lua
---@class IaraPickerLocation
---@field path string? Absolute file path, taken literally.
---@field bufnr integer? Buffer to show instead of `path`.
---@field row integer? Zero-based line; nil leaves the cursor alone (a
---  file name has no location).
---@field col integer? Zero-based byte column; default 0.
---@field disk_bytes boolean? `col` counts a UTF-8 BOM on line 0 (ripgrep
---  `--encoding none`); the BOM Neovim strips is subtracted.

-- iara.features.picker.open
---Show the location in the current window after an optional window
---command ("split", "vsplit", "tabnew"), recording the jump; with a
---`row`, place the cursor there (line clamped to the buffer).
---@param location IaraPickerLocation
---@param command string?
---@return integer bufnr
function M.jump(location, command) end

---(R2-B) Byte column of `location` (or of `col` on its line) in the
---text Neovim shows: a `disk_bytes` column on line 0 loses the BOM
---Neovim strips (not when a loaded buffer kept it, as `++bin` does).
---The jump and the search quickfix export (9.5) both use it, so
---quickfix `:cfirst` lands where the picker does.
---@param location IaraPickerLocation
---@param col integer?
---@return integer column Zero-based, never negative.
function M.buffer_column(location, col) end

---@class IaraPreviewTarget
---@field path string? Absolute file to read from disk.
---@field lines string[]? Lines to show at once instead of reading.
---@field filetype string? Highlighting; by default detected from `path`.
---@field row integer? Zero-based line to mark and center.
---@field byte_start integer? Marked byte range on `row`.
---@field byte_end integer? Exclusive.

-- iara.features.picker.preview
---One previewer per picker. Methods take the Snacks preview (`ctx.preview`):
---show(preview, target) supersedes earlier requests; `lines` show at
---once, a `path` is read on the next event loop turn (S11), or after
---a 25 ms debounce while requests repeat less than 100 ms apart (a held
---key), asynchronously, at most 256 KiB around `row`
---(M2-S), abandoned after 250 ms, binary (NUL) refused, lines cut at
---1,000 bytes (a file whose first chunk holds no newline shows the
---start of its first line). A window that starts inside the file says
---how many lines it skips. A window read earlier for the same file
---and row is shown once an asynchronous stat confirms the file's size,
---modification time, and inode. Repeated moves inside the cached window
---already shown move the mark immediately and defer one check until
---SETTLE_MS after the last move. A changed file is read again.
---The marked line and range use `IaraSearchPreviewLine` and
---`IaraSearchPreviewMatch`, and publishing keeps the title the caller
---set (UX1). clear(preview) empties it (title included) and drops
---pending reads; close() stops all publication and deletes the
---previewer's buffers.
---@return IaraPreviewer
function M.new() end
```

Scrolling (S10, S11): the list never waits for the preview, and the
preview is always highlighted. Content is shown in buffers of
`iara.features.picker.pool` (swapped into the Snacks preview window
with events ignored; no filetype, so no FileType event or ftplugin
runs), never by resetting and refilling one buffer: `SIZE` (3)
complete windows and `SCREENS` (8) first screens per previewer, each
list least recently used out first, a reused buffer preferably one
highlighted for the same filetype (its highlighter is kept). A window
or first screen shown recently comes back from its buffer with its
highlighting. Every new publish first shows the first screen (the
lines one window height above and below the marked row), parsed with
its injections before it is drawn, so its first frame is highlighted
(`iara.features.picker.highlight`: `filetype(target, lines)` from the
path and first lines, `lang(filetype)` when a parser and a highlight
query exist, `attach(entry, filetype, lang)`, `parse(entry, first,
last, on_done?)`). When the screen is not the whole window, the
complete window follows: at once for an isolated request, or when no
request came for `SETTLE_MS` (100 ms) while requests come less than
`REPEAT_MS` (100 ms) apart (a held key); it replaces the screen only
once the screen's rows are parsed, so the colors stay; a newer request
or clear() cancels it. Highlighting is Tree-sitter's for languages
with a highlight query (Markdown with MD2's `drop_conceal_lines()`, no
Snacks image or render pass), else the filetype's regex syntax, also
for cut content (lines are at most 1,000 bytes). The marked line,
range, skipped-lines note, centering (winrestview, no mode change:
FU-P3-1), and title are unchanged.

`iara.features.picker.read` (M2-S) holds the bounded reads and the
cache: `window(path, row, on_done)` reads at most 256 KiB starting a
quarter window before the row, scanning (counting lines, NUL refused)
up to 64 MiB to find it; `cached(path, row)`, `store(window)`,
`fresh(window, on_done)`, `forget(path?)`, `usage()`. The cache is
editor-wide, at most 16 MiB and 32 windows,
least recently used out first, one window per file.

### 9.7 `iara.features.search.slots` (M2-S): search processes

```lua
---Spawn like `iara.core.proc.spawn`, in the admission group
---{ group = "search", max = 4 }. A start refused for the cap waits, in
---arrival order, until a search process completes; cancelling a waiting
---start completes it as { status = "cancelled" } without spawning. Other
---refusals ("cleanup_failed") complete as "refused" at once.
---@return { cancel: fun(self, reason: string?) } handle
function M.spawn(argv, opts) end

---@return integer live, integer waiting
function M.count() end

---Cancel every waiting start and every live search process.
function M.cancel_all() end
```

Walks, regex validation, and grep batches share four process slots
session-wide, including processes that are still shutting down.

### 9.8 `iara.features.search.chain` and `.view` (UX1): picker steps

`chain` is pure data: a stack of steps, each a full request.
`hand_off(snapshot)` builds the next step from the current one: a file
name step hands its collected records (at most 200, disclosed when the
lane was truncated) as `within` to a content step; without a query (a
listing) it hands its glob and `within` unchanged, with `handed` = the
lane's `total`, so no listing limit applies (with neither, the whole
eligible set). A
content step hands the files of its groups to a file name step. A
loading, failed, cancelled, or empty step is refused with a reason.
`push`, `pop` (the previous request, for going back), `changes`
(request changes that clear unset optional fields), and `crumbs`
(breadcrumb labels) complete it.

`view` turns snapshots into picker rows (a notice, file names or
content groups, or a placeholder; a listing above the quota ends with a
calm `N more; type to narrow` row and shows `1,284 files`, no truncation
notice), row text with highlights, the
prompt status (`37 files`, `128 matches in 12 files`, a spinner while
loading), notices (errors, truncation), chips of switches that are not
at their defaults, the title or breadcrumb, and footer key hints
(`footer(mode, depth, width, normal)`: Insert mode hints, or with
`normal` (UX4) `j/k move · i insert · ⏎ open · q close` and then the chain,
select, and preview keys that fit). It defines the `IaraSearch*` groups
as default links to semantic groups; Iara themes set them explicitly.
V10, V13: `title(labels, request, root_path, focused?)` returns plain
title chunks padded by one space at each end (`layout.title_group`):
the current step focused unless `focused` is false, earlier steps idle,
` › ` between them, then ` · chip` per switch;
`preview_title(record, width, focused?)` is idle title text with the icon,
the path cut at the left, and `:line` for occurrences; the status
count uses `IaraSearchCountBusy` (tide) while a lane loads; file
headers carry the count as an `IaraSearchGroupCount` chip; notices add
a `line_hl_group` and lead with their state's glyph
(`icons.DIAGNOSTICS.WARN` or `.ERROR`, FU-V12-11; files without
devicons get `icons.FILE`); an empty list's placeholder is centered and "No
matches" / "No files match" add `A-h hidden` / `A-i ignored` hints for
the switches that are off. Rows are formatted `BAR_WIDTH` narrower than
the list window. Opening (`Enter`, splits, tab) shows the record under
the cursor in the current window (after the split command); selected
records' files only become listed buffers. Only `Ctrl-q` writes a
quickfix list.

### 9.9 `iara.features.picker.modal` and `.layout` (UX4): modes, panes

Every Iara picker (Find files, Find in files, chained steps, the key
search of D4) opens in Insert mode in its prompt. `Esc` leaves Insert
mode without closing; the prompt's Normal mode drives the list. Keys of
Normal mode (also bound in the list window): `j`/`k` and arrows with
counts (wrapping), `gg`/`G`, `Ctrl-d`/`Ctrl-u` half a page (both
modes), `Ctrl-f`/`Ctrl-b` a page (Insert mode keeps them for preview
scrolling), `H`/`M`/`L`, `Enter`/`o`/`l` open, `v`/`s` vertical and
horizontal split, `p` toggles the preview, `q` or a second `Esc`
close, `i` returns to Insert mode at the column it was left, `a`, `A`,
and `/` at the end of the query, `I` at its start. Every other picker
key (`Tab`, `Ctrl-q`, `Ctrl-g`, `Ctrl-o`, `Alt-*`, `Ctrl-v`, `Ctrl-s`)
works in both modes. Movement skips rows the owner reports as not
selectable (notices, placeholders, file group headers) and renders the
list, so a Normal mode move is a user move for X2's cursor retention.

```lua
-- iara.features.picker.modal
---@param opts { selectable: (fun(item: table?): boolean)?,
---  on_mode: fun(normal: boolean)? }?
---@return IaraPickerModal modal Fields `normal`, `insert_col`; methods
---  actions() (Snacks actions: movement replacing Snacks' own names, and
---  the `iara_*` mode actions), attach(picker, reopened) (follow the
---  prompt's mode, calling `on_mode` on each change; `reopened`: a
---  picker was closed just before, so Insert mode is taken back when the
---  stop Snacks issued on that close lands within 200 ms),
---  step(picker, delta), go(picker, index, direction).
function M.new(opts) end
---Normal mode keys of the "input" or "list" window (Snacks `keys`).
function M.keys(window) end
---`❯` (IaraSearchPrompt) in Insert mode, `❮` (IaraSearchPromptNormal)
---in Normal mode; `M.CHIP` (" NORMAL ", IaraSearchModeChip) is shown on
---the prompt line in Normal mode.
function M.prompt_column(normal) end
function M.draw_prompt(input, normal) end
---Footer chunks of `{ key, description }` hints that fit in `width`:
---`iara.core.float.footer(hints, width - 2, { key =
---"IaraSearchFooterKey", text = "IaraSearchFooter", max = math.huge })`
---(V13: hints separated by ` · `).
function M.footer(hints, width) end
function M.normal_hints(extra) end
---(UX5) Footer hints of the mode (`hints.insert` or `hints.normal`),
---prompt glyph, and NORMAL chip (namespace "iara.picker.mode") of a
---picker in an `iara.features.picker.layout` frame.
function M.draw_mode(picker, normal, hints) end
---(UX5) Method `modal:decorate(picker, hints)`: keep `draw_mode` and
---the picker's plain title (`layout.set_title(picker, picker.title)`)
---drawn after Snacks redraws titles or the prompt status and on every
---mode change; replaces `on_mode`. Used by the structured key search
---and the theme picker; the search pickers draw their own.

-- iara.features.picker.layout
---Results frame (titled prompt and list, with a footer) and preview as
---two equal flex panes: side by side at 120 columns or more (root 90%
---of the columns rounded down to even, 85% of the lines), stacked
---below that (root 95% of the columns, 90% of the lines rounded down to
---even). The odd column or line goes to the outer margin, never to a
---pane; without the preview, the results frame takes the whole root.
---(UX5) Rounded frames from `iara.core.ui`: the prompt window draws
---the top edge, title, and a separator joined to the sides (`ui.TOP`,
---`├──┤`), the list window the sides, bottom edge, and footer
---(`ui.BOTTOM`); the preview is `ui.BORDER` with a blank `eob`.
function M.layout() end
---(UX5) The results frame alone, centered, `width` columns inside and
---`count` rows tall (capped by the editor), no backdrop, no preview.
function M.compact(count, width) end
---(UX5) Inside width of the results frame (the list window), or nil.
function M.results_width(picker) end
---(UX5, V13) Title inline on the top edge, one dash after the corner
---(`ui.left_title`, the dash in the results frame's border group); a
---string becomes `title_chunks(text, focused)`. Also paints the frames
---for the focus (`paint_focus`).
function M.set_title(picker, title) end
function M.set_footer(picker, chunks) end
```

UX5 removed `results_box(picker)`: the frame is no longer a Snacks
box window. Callers use `set_title`, `set_footer`, and
`results_width`.

V10 and V13 add to `layout`: `title_chunks(text, focused)` (one chunk,
the padded text in `IaraSearchTitle` (focused: `accent` on `mantle`)
or `IaraSearchCrumb` (idle: `muted` on `mantle`)), `title_group(focused)`
and `border_group(focused)` (`IaraSearchBorderFocus`, `border_focus`,
or `IaraSearchBorder`, `border`), `paint_focus(picker)` (the results
frame's border cells in the focused group unless the preview has the
focus, the preview's in the focused group only then; Snacks keeps the
`{ char, group }` border table until a layout update, whose title
redraw paints again), `set_title` draws a string as title text
(focused unless the preview has the focus), `preview_focused(picker)`,
`set_preview_title(picker, chunks)` (left on the preview's top edge),
`BAR` (a pure Vim script 'statuscolumn': `▎` in
`IaraSearchSelectionBar` on the cursor row while 'cursorline' is on,
else a blank in `IaraSearchSelectionGap`), `BAR_WIDTH` (1),
`list_wo()` (`{ statuscolumn = BAR, conceallevel = 0 }` for a list
window; S11: conceal made every drawn row call Tree-sitter), and
`HIGHLIGHTS` / `define_highlights()` (fallback links). The preview box
is `title_pos = "left"`; the search pickers redraw their titles and
frame colors on `WinEnter`. V13 removed `CAPS` and `pill`. Focus is the
border color (design 09, section 7).

### 9.10 `iara.features.search.dirs` and `.dir_step` (S9): scope

`Alt-d` in Find files or Find in files (both modes) turns the same
frame into a directory step starting at the current scope's directory
(a file scope starts at its directory). Rows: `.` (`search here`, with
the count of searchable files), `..` (absent at the root: the step
never goes above the project root, and there is no override), then the
tree (S10): subdirectories with `├`/`└` branches and count chips
(`dir:PATH`), then the directory's eligible files (`entry:PATH`); an
expanded directory (open icon `󰝰`) is followed by its own rows,
indented with `│ `. At most 200 rows per directory, then a count. The
title is the search's idle title, `›`, and the focused breadcrumb step
`󰉋 root/lua/iara`. Keys: `Enter` on a directory expands or collapses
it in place (with typed text it goes into the row, as in S9), on a file
closes the picker and edits it, on `.` confirms, on `..` goes up; `l`
(Normal mode) goes into the row; `h`, `-` (Normal mode) and `Backspace`
on an empty prompt go up, typing filters every directory below
fuzzily, text up to
the last `/` names a directory to list (`../tests/`), `Enter` on a
typed path jumps there or shows an inline notice ("Outside the project
root", "No such directory", "No searchable files in"), `Tab` completes
the last segment (else takes the row under the cursor), `Alt-d`
confirms the shown or typed directory, `Alt-x` clears the scope back
to the root (also from the search), `Ctrl-o` cancels, `Alt-h`/`Alt-i`
toggle the switches and relist. Search-only keys do nothing in the
step. In Normal mode, `E` closes the picker and opens Oil at the
selected directory, the parent of the selected file, or the directory
shown. The `..` row opens the parent. If Oil is unavailable, the
picker displays a notice and stays open. Footer (Normal mode):
`⏎ expand`, `l open`, `h up`, `E Oil`, `A-d search here`, `q close`, as many as
fit. Confirming sets `scope = { kind = "directory", path }` (`root`
for the root itself), restores the query, and the title shows the
scope chip `· lua/iara/core/`; chained steps copy the scope.

```lua
-- iara.features.search.dirs (pure; reads the disk only in resolve)
---Directories of eligible root-relative `paths`: `dirs[path]` with
---`name`, `files` (eligible files below), `children` (byte order);
---`list` (all but the root, byte order); `complete`.
function M.index(paths, complete) end
function M.parent(path) end            -- nil for the root ("")
---Lexical: `.`/`..` segments, a leading `/` is absolute; nil outside.
function M.normalize(root, from, text) end
---The directory for typed `text`, or nil and a message. A directory
---missing from a complete tree is refused even when it exists.
function M.resolve(tree, root, from, text) end
---Children of `from` (or of the typed head), or every directory below
---matching the last segment fuzzily (at most `LIMIT` 200, `total`).
function M.list(tree, root, from, query) end
function M.complete(tree, root, from, query) end
function M.crumb(root, path) end

-- iara.features.search.dir_step (driven by the search UI)
function M.new(session, host) end      -- host: render, set_prompt,
                                       -- redraw, leave(path|false|nil),
                                       -- open(path) (S10)
function M.is_selectable(row) end
function M.format(data) end
function M.footer(normal, width) end
-- Methods: load, close, busy, rows, show, go, up, on_query, confirm,
-- search_here, complete, title, status, preview; (S10) toggle(path),
-- enter(row), oil_directory(row), notify(message, level).
-- dirs.index also keeps `names` (file names) per directory.
-- dirs.add_dir(tree, path) adds a directory to the index.
```

The tree comes from `Session:tree`, so hidden and ignored directories
follow the switches, `.git` never appears, and the scope still narrows
after eligibility; keystrokes filter the indexed tree (no walk).

### 9.11 `iara.features.search.collect` (FU-V12-PERF): idle collection

```lua
---Run LuaJIT collector steps (`STEP_KB` each, every `INTERVAL_MS`)
---until one collection cycle ends or `MAX_STEPS` ran. Called when a
---search picker closes; a call while running keeps the current run.
function M.start() end

---Stop the steps; the collector goes back to its own pace.
function M.stop() end

---@return boolean running
function M.running() end
```

A closed search leaves a few MiB of garbage; collecting it in steps
under 1 ms while idle keeps a 10-20 ms collection cycle out of the next
search's first result.

## 10. Terminal

### 10.1 `iara.features.terminal.registry` (T2)

```lua
---@class IaraTerminalRecord
---@field id integer Unique per session.
---@field project string `worktree_id` of the owning root.
---@field root_path string
---@field role "main"|"shell"|"agent"
---@field name string? Agent name ("claude", "codex") for role "agent".
---@field instance integer One-based per project, role, and name.
---@field generation integer Increments on restart.
---@field argv string[]
---@field cwd string Launch directory; immutable (`cd` changes nothing).
---@field env table<string, string> Explicit overrides only.
---@field bufnr integer?
---@field job integer?
---@field status "starting"|"running"|"stopping"|"exited"|"failed"
---@field exit_code integer?
---@field error IaraError?
---@field label string Display label, without secrets.

---Create a record and start its job in a new buffer without opening a
---window. Error codes: "cap" (8 running), "retention_unavailable",
---"spawn", "no_directory".
---@param spec { root: IaraRoot, role: string, name: string?,
---  argv: string[]?, cwd: string?, env: table<string, string>? }
---@return IaraTerminalRecord|nil
---@return IaraError|nil
function M.create(spec) end

---`get` and `list` return copies; mutating them changes nothing.
function M.get(id) end
---@param filter { project: string?, role: string?, status: string? }?
---@return IaraTerminalRecord[]
function M.list(filter) end
---@return IaraTerminalRecord|nil record The main terminal of the root.
function M.main_for(root) end
---Asynchronous stop; never waits.
function M.stop(id) end
---New generation and buffer; the old transcript stays until disposal.
---Error codes: "not_found", plus the `create` codes.
---@return IaraTerminalRecord|nil, IaraError|nil
function M.restart(id) end
---Remove an exited or failed record. Codes: "running", "not_found".
---`stop` ignores unknown ids.
---@return boolean, IaraError|nil
function M.dispose(id) end
```

Event `IaraTerminalChanged`, data `{ id, status, previous, generation }`.
`status` may also be "disposed" (on `dispose()` or when the live buffer
is wiped). The first event after `create` has `previous = "starting"`.
Limits: 10,000 lines of scrollback; 8 running and 4 exited records.
Retained old transcripts count toward the 4 exited records; `create`
and `restart` are refused with "cap" at either limit. A second main
terminal for one project is a programming error and raises. The
registry itself never disposes an exited record; the close-on-exit
policies of 10.2 and 12.2 call `dispose` (T4).

### 10.2 `iara.features.terminal` (T3): panel and actions

```lua
function M.setup(config) end
---F7 / Space tt: main terminal of the invoking buffer's project.
function M.toggle_main() end
---Idempotent focus without toggling visibility.
function M.focus_main() end
---Space tn, Space t. (current file directory), Space tl.
function M.new() end
function M.new_here() end
function M.select() end
---:IaraTermExit, leave terminal input mode.
function M.exit_input() end
---Show and focus a registry record in the panel of its role (used by
---A1); `opts.position` moves that panel there first (UX2).
---@param opts { position: IaraPanelPosition? }?
function M.show(id, opts) end
---Close the panel showing an exited or failed record (any tab) and
---dispose the record; focus returns to the previous editing window when
---the panel had it. `generation` limits it to that generation (T4).
---@return boolean closed
function M.close(id, generation) end
---:IaraTermPosition {side}: the shell panel; a visible panel moves
---without restarting.
---@param side IaraPanelPosition
---@return boolean ok False (and reported) for an unknown side.
function M.set_position(side) end
---Whether `side` is a position; reports an unknown one (UX2).
---@param what string "terminal" or "agent", for the message.
---@return boolean
function M.check_position(side, what) end
---Space tv, :IaraTermPosition: the next position of `ORDER` (UX2); a
---hidden panel shows the main terminal there.
function M.toggle_position() end
---Space ts: the main terminal in a panel at the right.
function M.show_side() end
```

Commands: `:IaraTermToggle`, `:IaraTermFocus`, `:IaraTermNew`,
`:IaraTermHere`, `:IaraTermSelect`, `:IaraTermExit`, `:IaraTermStop`,
`:IaraTermRestart`, `:IaraTermDispose`, `:IaraTermPosition [side]`.
Toggling from outside a panel that shows another project's terminal
moves the caller's main terminal into the panel; F7 in a focused agent
panel hides that panel. Since UX2 there are two panels per session
(10.3): shells (roles main and shell) in the shell panel, agent
sessions in the agent panel, each with its own position and sizes.

Settings `features.terminal`: `position` (an `IaraPanelPosition`,
default "bottom") and `close_on_exit` (default true). With `close_on_exit`, a
shell (roles main and shell) that exits for any reason, including
Ctrl+D and nonzero statuses, is disposed at once and its panel closes.
With `false`, the panel shows the exited terminal. Invalid values
are reported and replaced by the defaults.

### 10.3 `iara.features.terminal.panel` and `.title` (UX2)

```lua
---@alias IaraPanelPosition "bottom"|"top"|"left"|"right"|"float"
M.POSITIONS -- set of positions
M.ORDER -- { "bottom", "right", "top", "left", "float" }
M.shell -- IaraPanel of shells; opens at "bottom"
M.agent -- IaraPanel of agent sessions; opens at "right"
---@return IaraPanel
function M.for_role(role) end
---@return IaraPanel|nil
function M.containing(win) end
---@return IaraPanelPosition
function M.next_position(side) end
---Label provider of panel headers (the terminal feature sets
---`title.title`).
function M.set_title_provider(provider) end

-- IaraPanel methods; window and buffer refer to the current tab.
function Panel:window() end -- integer|nil
function Panel:buffer() end -- integer|nil
function Panel:position() end -- where it opens next
---Raises for an unknown side; a visible panel moves at once.
function Panel:set_position(side) end
---Raises when no window can be opened (command-line window).
function Panel:show(bufnr) end -- integer win
function Panel:hide() end -- boolean
function Panel:close_buffer(bufnr) end -- boolean, any tab
```

`bottom` and `top` span the tab's width (a third of the lines), `left`
and `right` its height (40% of the columns); `float` is centered over
the editor (80% of the columns and of the lines above the status line)
with a straight border and `zindex` 40. Each
panel remembers the last size per position (width and height for
`float`), moves between tabs without duplicating, and never stops,
restarts, or chooses a job; the only split of a tab is never moved or
closed (it shows an editing buffer instead).

`iara.features.terminal.header` (V7): the look of panel windows.
`decorate(win)` puts a window showing a terminal on the panel
surface ('winhighlight' `Normal`, `NormalNC`, `NormalFloat` to
`IaraPanel`, `WinBar`/`WinBarNC` to `IaraPanelHeader`, buffer-local
scope only) and gives it a header: docked, a winbar (`winbar(bufnr,
width, focused)`: `▎` bar, icon and label, launch directory, state,
right-aligned hints; `docked_chunks(description, width, focused) ->
left, right` drops the directory first, then hints from the end);
floating, a left title (`float_title(description, width, focused)`:
`iara.core.float.title` (accent when focused, muted when idle), a
`float.rule` filler in the frame's color, the state chip, never wider
than `width`), footer hints (`float_footer( description, width)`,
`iara.core.float.footer`), and a straight frame whose color shows the
focus (V13: 'winhighlight' maps `FloatBorder` and `FloatTitle` to
`IaraFloatBorderFocus` and `IaraFloatTitleFocus` while focused, to
themselves otherwise). `clear(win)`
removes all of it;
`refresh()` redecorates the panels of the current tab. `hints(kind)`
lists `HINTS[kind]` whose normal-mode mapping exists (leader shown,
Space as `␣`); `state(state) -> text, group`. The window variable
`w:iara_panel` (`MARK`) marks decorated windows. Headers are rebuilt
only on `WinEnter`, `WinResized`, `VimResized`, `IaraTerminalChanged`,
and `BufWinEnter` of a marked window (a window showing another buffer
loses the look); terminal output and typing never rebuild them. The
autocommands are created by the first `decorate`. `FALLBACK_LINKS`
are linked (`default`) under a foreign colorscheme. Panels call it on
open, show, and move.

`iara.features.terminal.title`: `describe(bufnr) ->
IaraTerminalDescription|nil` (`kind` "terminal" | "agent", `title`,
`state` "running", "stopping", "exited N", or "failed", `cwd` the
launch directory, V7) for any
terminal buffer, owned or native; `title(bufnr) -> string` ("" for
other buffers); `name_agent(name, title)` (called by 12.2). Titles:
"Terminal · sh" (main), "Terminal N · sh" (extra shells, N =
instance + 1, plus " in <dir>" outside the root), "Claude Code",
"Codex 2" (instances after the first). They never contain the
`term://` name, argv arguments, or environment.

## 11. Structured data

### 11.1 `iara.features.structured.path` (D2)

```lua
---@class IaraPathSegment
---@field kind "key"|"index"
---@field value string|integer Decoded key, or zero-based index.

---@class IaraStructuredTarget
---@field bufnr integer
---@field changedtick integer
---@field parser_generation integer
---@field document integer? One-based document ordinal. JSON targets
---  carry 1; nil means unknown and makes render refuse ("incomplete").
---@field recovery_root integer? One-based value when the grammar
---  recovered several top-level values (`{} {}`).
---@field segments IaraPathSegment[]
---@field key_range integer[]? {start_row, start_col, end_row, end_col}.
---@field value_range integer[]?
---@field certainty { complete: boolean, decoded: boolean,
---  unique: "yes"|"no"|"unverified" }

---Canonical Iara path, for example `doc[2]::$["server.port"][0][""]`.
---With a recovery root it renders as `doc[1]/root[N]::$...`. A target
---whose uniqueness is "unverified" still renders; callers disclose it.
---Error codes: "incomplete", "ambiguous", "too_long", "source_only".
---@return string|nil, IaraError|nil
function M.render(target) end

---Display breadcrumb, clipped to `max_cells` (default 160).
---@return string
function M.breadcrumb(target, max_cells) end

---Strict bounded decoding of a JSON string literal including quotes.
---Error codes: "escape" (also malformed quoting), "control",
---"surrogate", "too_long". Invalid UTF-8 bytes pass through unchanged.
---@return string|nil, IaraError|nil
function M.decode_json_string(raw, max_bytes) end
```

### 11.2 `iara.features.structured.json` (D3)

```lua
---Target under a position, from the latest parse of the buffer text.
---`on_done(nil, err)` codes: "ineligible", "stale", "watchdog",
---"no_parser", "no_target".
---@param on_done fun(target: IaraStructuredTarget|nil, err: IaraError|nil)
---@return { cancel: fun(self) } handle
function M.target_at(bufnr, row, col, on_done) end

---Explicit bounded index of all key targets (10,000 entries, 8 MiB).
---@param on_done fun(result: { state: "complete"|"partial"|"error"|
---  "cancelled", targets: IaraStructuredTarget[], error: IaraError? })
---@return { cancel: fun(self) } handle
function M.index(bufnr, on_done) end

---Lift a watchdog suspension; the next request makes one more parse
---attempt, itself bounded by the watchdog. False when not suspended.
---@return boolean lifted
function M.retry(bufnr) end

---Owned state of a buffer, nil when nothing is held.
---@return { parsing: boolean, watchdog: boolean, suspended: string|nil,
---  waiting: string[], indexing: boolean }|nil
function M.status(bufnr) end
```

A parse whose callback has not arrived 250 ms after it started, or that
reports a Tree-sitter "TIMEOUT", is abandoned and suspends the buffer:
every later `target_at` and `index` completes with "watchdog" (message
naming `:IaraStructuredRetry`) without parsing, until `retry`. A late
callback of an abandoned parse is ignored. Cancelling every request of a
parse abandons it and stops its watchdog without suspending. Unload,
wipeout, a filetype change, and leaving the "eligible" state
(`IaraEligibilityChanged`) release the buffer's timer, requests ("stale"),
and suspension without waiting for any callback.

### 11.3 `iara.features.structured` (D4) and YAML (D1)

```lua
function M.setup(config) end
function M.show_path() end
function M.copy_path() end
function M.search_keys() end
function M.toggle_breadcrumb() end
---Deliberate bounded retry after a watchdog: `json.retry` on the current
---JSON buffer, then one path request under the cursor.
function M.retry() end
---Jump to a recorded location; never reparses a display path.
---Returns false when the buffer changed since the target was recorded.
---@return boolean
function M.jump(target) end
```

Commands `:IaraStructuredPath`, `:IaraStructuredCopy`,
`:IaraStructuredSearch`, `:IaraStructuredBreadcrumb`,
`:IaraStructuredRetry`; setting
`features.structured.breadcrumb` (default on). Normal-mode mappings:
`Space ys` key search, `Space yc`
copy path, `Space yp` show path, `Space yt` toggle breadcrumb. Copy
refuses incomplete, ambiguous, source-only, or too-long paths with the
reason and offers `file:line:col` instead. After a watchdog the
breadcrumb pauses and show, copy, and search refuse with the reason
until `:IaraStructuredRetry`; turning the breadcrumb off cancels its
request. YAML show/copy point to the
yaml-revealer breadcrumb until a YAML adapter exists.

D1 keeps yaml-revealer and `Space ys` under one owner and suspends its
handlers on any eligibility state other than "eligible".
`iara.features.structured.yaml_legacy` exposes `setup`, `status(bufnr)`,
`resume(bufnr)`, `search_keys()`, and `plugin_handlers(bufnr)`. A buffer
suspended for being conservative stays suspended after it becomes
eligible until `:IaraYamlResume`, which refuses while still ineligible.
YAML search uses the pinned Tree-sitter parser in an eligible buffer.
The prompt accepts a key name or a dotted path, including zero-based
sequence indexes and double-quoted path components. Unmatched paths
leave the cursor in place and report a notice.

## 12. Agents

### 12.1 `iara.extras.agents.context` (A2)

```lua
---@class IaraContextSnapshot
---@field id integer
---@field bufnr integer
---@field changedtick integer
---@field path string? Nil for unnamed buffers.
---@field buffer_label string Stable label, also for unnamed buffers.
---@field worktree_id string
---@field unsaved boolean
---@field mode "charwise"|"linewise"|"blockwise"|"reference"
---@field range integer[]? Normalized {start_row, start_col, end_row,
---  end_col}, end exclusive.
---@field text string? Exact buffer text; nil for disk references.
---@field diagnostics table[]? Only when requested.
---@field notes string[] Disclosures (LF line breaks, partial cells).
---@field filetype string
---@field columns integer[]? Blockwise virtual-column interval.
---@field to_line_end boolean? Blockwise `$` selection.

---Capture before focus changes. Error codes: "too_large", "changed",
---"retention_cap", "no_selection", "no_path" (a disk reference to an
---unnamed buffer), "diagnostics_unavailable".
---A `$` block is detected only while Visual mode is live, so mappings
---call capture from Visual mode. Callers must `release` snapshots: at
---most four are retained, and a fifth capture is refused.
---@param opts { bufnr: integer?, mode: string?, diagnostics: boolean? }
---@return IaraContextSnapshot|nil, IaraError|nil
function M.capture(opts) end

---Final payload exactly as copied. Code: "too_large" (128 KiB).
---@return string|nil, IaraError|nil
function M.format(snapshot) end

---Scratch float; `y` copies, `q` closes. Refuses a changed tick.
---The buffer holds exactly the payload; the window (V11,
---`iara.extras.agents.preview`) adds the "Agent context" title
---(`iara.core.float.title`, idle groups lit by `float.focus` while the
---preview has the focus), a size chip against 128 KiB (warning
---color above 80%), the footer "y copy · q close · (nothing is sent)"
---(`float.footer`), and summary rows (selection or
---reference, diagnostics when captured) as virtual lines above it.
---@return boolean, IaraError|nil
function M.preview(snapshot) end
---Copies to "+" when a clipboard exists, else the unnamed register.
---@return boolean ok, IaraError|nil err, string|nil register
function M.copy(snapshot, register) end
function M.release(id) end
```

### 12.2 `iara.extras.agents` (A1)

```lua
---Open (or focus) a named agent terminal for the invoking project.
---`position` (UX2) is remembered for this agent. Error codes:
---"not_found" when the CLI is missing, "position" for an unknown
---position (reported); nothing else happens.
---@param name "claude"|"codex"
---@param position IaraPanelPosition?
---@return IaraTerminalRecord|nil, IaraError|nil
function M.launch(name, position) end
function M.select() end
---Space at: hide a visible agent panel, else show the invoking
---project's newest session (live first); without one, `select()`.
function M.toggle() end
---:IaraAgentPosition {side}: every agent, overriding per-agent settings.
---@return boolean ok False (and reported) for an unknown side.
function M.set_position(side) end
---Space ap: the next position; a hidden panel is shown as `toggle`.
function M.cycle_position() end
---No-op unless `extras.agents` is enabled.
function M.setup(config) end
```

Commands `:IaraAgent [name [position]]`, `:IaraAgentToggle`,
`:IaraAgentPosition [position]` (no argument: next position), and
`:IaraAgentFile`; mappings under `<leader>a`: `aa` choose, `at` toggle
the agent panel, `ap` next position, `ac` Claude Code, `ax` Codex,
Visual `as` selection context, `af` file reference. Sessions show in
the agent panel (10.3) at `extras.agents.position` (default "right")
or `extras.agents.<name>.position`; invalid values are reported and
replaced by "right" (or the agents' default). `launch` reuses the project's
newest session of that agent and shows an exited one without restarting
it. The optional `extras.agents.<name>.argv` replaces the command and is
refused when it contains a known permission-bypass argument. Iara adds no
environment, credentials, or model switches. `extras.agents.close_on_exit`
(T4) is "success" (default: a session exiting with status 0 closes and
is disposed; a nonzero exit keeps its transcript), `true` (always
close), or `false` (always keep); other values are reported and replaced
by "success". Every exit is still reported with its status.

### 12.3 `iara.extras.ai` (AI1): Ask AI about a selection

```lua
---Open the Ask AI popup for the live Visual selection, else the last
---one, or the lines `opts.range` (linewise); with `opts.question`, ask
---it at once. A previous popup is closed first. A refused capture is
---reported and opens nothing. Error codes: those of `context.capture`.
---@param opts { range: integer[]?, question: string? }?
---@return IaraAiPopup|nil, IaraError|nil
function M.ask(opts) end
---@return IaraAiPopup|nil The open popup.
function M.current() end
---Close the popup and cancel its request.
function M.close() end
---No-op unless `extras.ai` is enabled. Starts no process.
function M.setup(config) end
```

`iara.extras.ai.backend`: `argv(name, command?)` returns `command`
(default the executable) followed by the one-shot arguments;
`unsafe_argument(argv)` returns the first refused argument (a superset of
`iara.extras.agents.BYPASS_ARGUMENTS`); `decoder(name)` maps stdout lines
to `{ text?, error? }`. The one-shot argv:

- Claude: `claude -p --output-format stream-json --verbose
  --include-partial-messages --tools "" --strict-mcp-config
  --disable-slash-commands --no-session-persistence`: no tools, no MCP
  servers, no slash commands, no session written.
- Codex: `codex exec --sandbox read-only -c approval_policy="never"
  --ephemeral --skip-git-repo-check --color never --json -`: commands
  only in the read-only sandbox, escalations refused, no session files.

Visual `<leader>ai` and `:[range]IaraAsk [question]` use the configured
backend, or try Codex then Claude. Visual `<leader>ac` selects Claude
directly and reports when it is unavailable. The selection is
captured with A2 (its caps refuse) and formatted once; the snapshot is
retained until the popup closes. Each question runs the CLI once through
`iara.core.proc` (tag "iara-ai", deadline `extras.ai.timeout_ms`,
default 180 s; stdout 4 MiB, 1 MiB per line) with stdin = instructions,
the A2 payload, the finished turns, and the question. Limits refuse:
question 16 KiB, request 256 KiB, 8 questions per popup, answer 256 KiB
(stops the process). `extras.ai.backend` is "claude" or "codex".
`extras.ai.argv` replaces the command for that backend before the
one-shot arguments, needs `backend`, and is refused (reported, ignored)
when `unsafe_argument` finds anything.
Escape closes from either pane, Tab switches panes, and a left mouse
drag from the top border moves both panes together within the editor.
(R2-B) A run that exits 0 with a blank answer fails the turn with "No
answer received from <CLI> (exit status 0)" and the stderr tail, never
an empty "done" answer.

Pressing Enter sends the visible question and excerpt to a separate
one-shot process. The popup owns this process and the response buffer.
Press `y` to copy the answer.

## 13. Tooling and baseline

- `iara.features.format_lua` (L1): `format(bufnr?)` formats once through
  StyLua stdin; result applied as one undoable edit or discarded.
  Command `:IaraFormat`. Error codes reported to the user: "not_found",
  "stale", "ineligible", "stylua", "overflow", "timeout", "busy".
  `format` returns `started, err` (started also when queued as
  pending); "not_found" also covers a missing StyLua config file.
  Settings `languages.lua.stylua` and `languages.lua.stylua_config`
  take absolute paths. Admission: one active and one pending request
  per buffer, two active and two pending session-wide (`LIMITS.active`,
  `LIMITS.pending`); a cancelled job counts as active until its cleanup
  finishes. A new request on a buffer cancels its active one and waits
  as that buffer's pending request (replacing an older pending one); a
  third pending buffer is refused with "busy". Pending requests keep
  only the buffer number; text is captured on activation in batches of
  `LIMITS.capture_batch_lines` per main-loop tick, and an edit between
  batches discards the request before StyLua starts. Just before
  applying, the result is discarded unless tick, name, modifiability,
  'fileformat', 'endofline', 'fixendofline', 'filetype', StyLua
  ownership (`languages.lua`, `formatters.lua`), project trust, project
  root, eligibility, and Normal mode are unchanged. `status(bufnr?)`
  returns "idle", "pending", or "active".
- `iara.core.lazy` (F2): `setup(config)` initializes the pinned manager,
  imports `iara.plugins` specs, then `config.plugins`. No installs or
  updates at startup. Also `MANAGER`, `MANIFEST` ("release.json"),
  `read_lock(path)` (error codes "lock_missing", "lock_invalid"),
  `specs(config)`, `options(config, paths?)`, and
  `provision_command(mode)` (modes "install", "repair", "update",
  "rollback") running `bootstrap_script(mode) -> path` (R2-A: repair
  and rollback use `<layout().current>/config/scripts/bootstrap.lua`
  when it exists, which works without the configuration link; else,
  and for install and update, the running distribution's). Tasks that
  add a plugin add its spec under `lua/iara/plugins/` and its pinned
  commit to `lazy-lock.json`;
  lazy.nvim writes only to the release's own copy of the lock.
  Releases (F2, M2): `layout() -> {data, releases, current, previous,
  owner}` (stdpath("data"), `releases/`, the `current` and `previous`
  links, `iara-owner.json`); `release_dir(which) -> string|nil` (real
  path of "current" or "previous", resolved once so a running editor
  stays on its release); `release_paths(dir) -> IaraLazyPaths` for a
  release directory (`config/`, `lazy/`, `lazy-lock.json`,
  `treesitter/`); `paths()` (the current release, or for an
  installation made before releases the data directory itself:
  `lazy/`, `lazy-lock.json`, `treesitter/`; `iara` and `release_lock`
  are always the running distribution's; fields `iara, release_lock,
  lock, root, manager, parsers, release?`); `checkout_commit(dir)`
  (HEAD of a checkout read without Git, nil when unreadable);
  `owner() -> record|nil, "live"|"stale"|nil` (the provisioning owner
  record `{pid, host, mode, started, token}`; a record whose process no
  longer runs a bootstrap is stale; reads files only);
  `read_manifest(dir) -> manifest|nil, err` (code "manifest_invalid"
  unless `complete` is true).
  Missing plugins (X3): `find_missing(paths) -> string[]` (pinned
  names, manager excluded, whose `paths.root/<name>` does not exist;
  one stat each; none for an unreadable lock); `missing() -> string[]`
  (what setup found, sorted); `available(plugin) -> boolean`, the
  default `cond` in `options()` (`defaults.cond`): false for a missing
  pinned plugin and for any plugin depending on one at any depth, so
  lazy.nvim lists it as disabled, keeps its lock entry, and never loads
  it. A spec with its own `cond` must call `available(plugin)` (the
  yaml-revealer and cmp-nvim-lsp specs do). After setup with missing
  plugins, one WARN notice on UIEnter per session: "Iara: N pinned
  plugin(s) is/are missing (a, b); run :IaraRepair". `setup` defines
  `:IaraRepair` (also without an installed manager).
- `iara.core.repair` (X3): `command() -> argv, env` (`{progpath, "-l",
  bootstrap_script("repair"), "--repair"}`, `{NVIM_APPNAME}`
  as in `provision_command("repair")`); `run() -> job|nil` opens a
  15-line window at the bottom and runs the command there in a terminal;
  on exit it notifies `result_message(code) -> message, level` (INFO
  "repair complete; restart Iara ..." or ERROR "repair failed (exit
  N) ..."). The running editor keeps its plugins until restarted.
- `scripts/bootstrap.lua` (F2): `--launcher PATH` (install), `--update`,
  `--rollback`, `--repair`, one at a time, each under an exclusive owner
  record created with O_EXCL in stdpath("data"); a live record refuses
  the run, a stale one refuses every mode except repair, which removes
  `iara-tmp-*` and link temporaries and takes over. Install and update
  build a candidate in `iara-tmp-*/release` (configuration copied from
  the script's checkout without `.tools/`, personal `lua/user.lua`
  carried from the active configuration; plugin trees at the locked
  commit and parsers at the pinned commit copied from the active
  installation; the rest provisioned with lazy.nvim state inside the
  release), require a full-mode startup of the candidate from separate
  XDG roots, write the manifest (`format` 2; configuration
  source/revision/dirty and `config.files`, the sha256 of every
  configuration file by relative path except the personal
  `lua/user.lua`, a link as `link:<target>`; Neovim and Git versions,
  origin, manager, plugin commits, parser repo/commit/sha256,
  tree-sitter and cc versions), publish it as
  `releases/<UTC time>-<suffix>`, verify it against the manifest, and
  remove releases that are neither current nor previous after activation.
  Activation stages the new `current` link before changing `previous`.
  If replacing `current` fails, it restores the old `previous` link or
  reports its original target if the restore also fails. Install refuses any
  existing configuration path, `current`, `previous`, release, legacy
  tree, or launcher; update needs an installation and a linked (or
  absent) configuration path. Rollback swaps `current` and `previous`
  only after the previous release passes the same checks (R2-A):
  configuration file checksums, plugin commits, and parser checksums
  against its manifest, without Git or network, then a full-mode
  startup from separate XDG roots in an `iara-tmp-*` directory; any
  failure changes no link and names the cause. A manifest without
  `config.files` (format 1) cannot be verified and is refused. Repair
  runs only from the current release's configuration (or, without
  releases, the configuration link), restores it at its locks,
  re-records the artifacts in the manifest (keeping the recorded
  configuration and its checksums), and recreates a missing
  configuration link. The steps live in `scripts/bootstrap/` modules:
  `common`, `owner`, `provision`, `candidate`, `manifest`, `verify`,
  `startup`, `activate`.
- `iara.health` (F2): `check()` for `:checkhealth iara`. Reports the
  current and previous release (or that rollback is unavailable), a
  live or interrupted owner record (interrupted: error with the repair
  command), the manager, plugins, and each pinned Tree-sitter parser: at
  the pinned commit, missing (with the repair command; missing plugins
  also name `:IaraRepair`, X3), or built from
  another commit. Missing `stylua` is informational (formatting is
  optional).
- Tree-sitter parsers (F2, X1): `iara/parsers-lock.txt` pins the
  grammars Neovim does not bundle (json, yaml) by GitHub repository and
  full commit. `scripts/parsers.sh [DEST]` builds them with the local C
  compiler into `DEST/parser/<lang>.so` plus `DEST/stamps/<lang>` (the
  commit), default `iara/.tools/treesitter`, skipping current ones. The
  bootstrap builds missing ones into a temporary directory through the
  release's copy of that script, loads each one, and only then
  publishes it into the release's `treesitter/`; repair never replaces
  a parser built from another commit. A plugin left with a lazy.nvim
  `.cloning` marker after install fails the run.
- `iara.core.parsers` (X1): `LOCK`, `DEV_RUNTIME`,
  `read_lock(path?) -> IaraParserPin[]|nil, err` (`{lang, repo, commit,
  tag?}`, error codes "lock_missing", "lock_invalid"), `runtime_dir()`
  (the installation's directory: `paths().parsers` of
  `iara.core.lazy`), `runtime_dirs()` (installation, then
  development), `parser_path(dir, lang)`, and `installed_commit(dir,
  lang)` (nil when missing, "unknown" without a stamp). Runs no process.
- `iara.core.options` (F6, safe step): `setup(config)` sets the leaders,
  disables unused remote providers, applies `DEFAULTS` then
  `config.options` (option name -> value; invalid entries reported and
  skipped), and runs `iara.core.statusline.setup()`,
  `iara.core.tabline.setup()`, and `iara.core.treesitter.setup()`.
  Window chrome defaults (UX3): 'fillchars' (blank `eob`, diagonal diff
  filler, fold glyphs), 'winborder' `iara.core.ui.BORDER` ("single"),
  'pumborder' the same and 'pummaxwidth' 60 (V3), 'pumheight' 12,
  'shortmess' adds `c`. `apply(values) -> string[] problems`
  sets options in name order without raising. Also `LEADER`,
  `LOCAL_LEADER`. Then (V8) `iara.core.guides.setup(manage)`, with
  `manage` false when `config.options` sets 'list' or 'listchars'.
- `iara.core.guides` (V8): native indent guides through window-local
  'list' and 'listchars' (no decoration provider, no extmarks).
  `listchars(width, expandtab) -> string` (`tab:  `, `leadtab:│ `,
  `nbsp:+`, and with `expandtab` `leadmultispace:│` plus `width - 1`
  spaces); `wanted(win)` (a normal, non-floating window showing a
  buffer with 'buftype' "" that `iara.core.eligibility` finds
  eligible); `update(win)` (guides when wanted, else the global 'list'
  and 'listchars'); `setup(manage)` updates on `BufWinEnter`,
  `WinNew`, `TermOpen`, `OptionSet` of `OPTIONS` ('shiftwidth',
  'tabstop', 'expandtab'; width is 'tabstop' when 'shiftwidth' is 0)
  and `IaraEligibilityChanged`. Also `GUIDE` ("│"). Guides use
  `Whitespace` (the `faint` role). The scope highlight of design 09
  3.2 is not implemented.
- `iara.core.keymaps` (F6): `setup(config)` maps `DEFAULTS` merged with
  `config.keymaps` ("<mode> <lhs>" -> `false` or `{ rhs, desc? }`).
  `resolve(user) -> IaraResolvedKeymap[], string[] problems` is the pure
  merge (`{mode, lhs, rhs, opts}`, sorted by key).
- `iara.core.statusline` (F6, UX3, V4): `setup()` installs the global
  statusline, redraws it on the events of section 14, `GitSignsUpdate`,
  and `ModeChanged`, and runs `iara.core.winbar.setup()`; diagnostic
  counts are cached per buffer and refreshed on `DiagnosticChanged`,
  the file segment per buffer until its name, flags, or icon source
  change, `trusted(bufnr)` until `IaraRootChanged`. `render() -> string`
  for a file buffer: the mode block (`IaraStatusMode<Mode>`, labels in
  `MODES`, ` LABEL ` on the mode's fill), the file segment (icon, name
  or `b:iara_status_title`, or for a focused Snacks picker prompt or
  list the picker's title after the search glyph `icons.ACTIONS.grep`,
  `picker_title(bufnr)` (FU-V12-8; Snacks read only when loaded),
  modified dot, read-only lock;
  `IaraStatusFile`, `IaraStatusModified`), the Gitsigns branch and
  nonzero counts (`git_text(bufnr)`, from `b:gitsigns_status_dict`;
  counts only when 'columns' >= `WIDTH_GIT_COUNTS`), centered between
  two `%=` the `iara.core.progress.statusline()` segment (V5; redrawn
  on `IaraProgressChanged`; a failure shows "?"), then right-aligned
  `eligibility.statusline` and `reconcile.statusline` with icons,
  diagnostic counts (`diagnostics_text(bufnr)`), LSP client names
  (`lsp_text(bufnr)`, only when 'columns' >= `WIDTH_LSP`), `[safe]`,
  the root segment (`root.statusline`, only for named buffers or ones with
  `iara_context_root`, and 'columns' >= `WIDTH_ROOT`; it leads with
  `MARK` "∿" in `IaraStatusMark` when `trusted(bufnr)`: the buffer's
  root is listed in the personal `trusted_projects`, else a folder icon
  in `IaraStatusRootIcon`), and the position (file buffers only).
  Widths: `WIDTH_LSP` 100, `WIDTH_GIT_COUNTS` 80, `WIDTH_ROOT` 70.
  V13: segments are flat text on the bar (`mantle`), set apart by
  spacing and color; only the mode is a filled block; no caps or arrows
  (`CAP_LEFT`, `CAP_RIGHT`, `flat()`, the `...Cap` groups, and
  `vim.g.iara_ascii` were removed). A failing part shows "?". For a terminal
  buffer (UX2) it shows instead
  the clean title of `iara.features.terminal.title` in
  `IaraStatusTerminal` or `IaraStatusAgent`, the state in
  `IaraStatusRunning` or `IaraStatusExited`, `[safe]`, and the root
  segment; never the `term://` name. `terminal_of(bufnr)` is that
  description or nil. `tabline() -> string` returns
  `iara.core.tabline.render()`; `iara.core.options` sets 'tabline' to
  it by default.
- `iara.core.progress` (V5): LSP progress for the status line, from
  the native `LspProgress` event (no plugin). `setup()` (idempotent;
  `statusline()` calls it) tracks begin/report/end per client and
  token, drops tokens of stopped clients on `LspDetach`, and follows
  core progress messages (`Progress`). `statusline() -> string` is a
  cached segment with highlight items, "%" escaped, "" when idle: the
  most recent token of any client as spinner (`SPINNER`, one frame per
  event, no timer), client, title (cut to `TITLE_WIDTH` cells with
  "…"), percent at >= `WIDTH_PERCENT` columns (100), and a
  `BAR_WIDTH`-cell bar at >= `WIDTH_BAR` (120); when the last token
  ends, "✓ <client> ready" for `DONE_MS` (2000, one `vim.defer_fn`);
  with no LSP progress, `vim.ui.progress_status()` after a spinner.
  `state() -> {client, title?, message?, percent?, done}|nil`. Changes
  fire `User IaraProgressChanged` (`EVENT`) at most once per
  `INTERVAL_MS` (100, 10 Hz); the status line redraws on it. Groups
  `IaraProgress{Spinner,Client,Title,Bar,BarTrack,Done}`
  (`iara.theme.groups.progress`), linked to StatusLine under a foreign
  colorscheme (`FALLBACK_LINKS`, set by this module).
- `iara.core.tabline` (UX3, V4): `render()`: with one tab page a buffer
  bar of `buffers()` (listed buffers naming a file, plus the current
  buffer), clickable (`click(bufnr)`); with several tab pages one label
  per tab, named by its current window's terminal or agent title (UX2)
  or file name. Labels are " icon name " (`IaraTabActive`,
  `IaraTabInactive`) with a modified dot (`IaraTabModified` on the
  current label, `IaraTabModifiedInactive` otherwise); the current one
  has `BAR` "▎" (`IaraTabActiveBar`) before its icon.
  `fit(items, current, columns)` keeps the current label visible when
  they do not fit. `setup(manage)` (called by `iara.core.options`
  unless `config.options.showtabline` is set) keeps 'showtabline' at 2
  while `wanted_showtabline()` sees two or more files or tab pages,
  else 1.
- `iara.core.winbar` (V4): `setup()` (from `iara.core.statusline`)
  manages split winbars unless `config.options.winbar` is set, and the
  cursor line of inactive windows. While `normal_windows()` (windows of
  the current tab page for which `is_normal(win)`: not floating, empty
  'buftype') counts two or more, each normal window at least
  `MIN_ROWS` (6) rows tall gets the literal winbar `text(win,
  current)`: icon, path relative to the working directory, name,
  modified dot; the current window leads with `BAR` (`IaraWinbarBar`,
  `IaraWinbarIcon`, `IaraWinbarPath`, `IaraWinbarName`,
  `IaraWinbarModified`), others are `IaraWinbarInactive`. Built on
  window, buffer, size, directory, and 'buftype' events (coalesced,
  `update()`), never per keystroke. Only empty winbars or ones starting
  with `PREFIX` ("%#IaraWinbar") are changed: another owner's winbar
  (A3's conflict view, V7's panels) is kept. `focus(win)`, on
  `WinEnter` of a normal window, turns 'cursorline' off in the other
  normal windows (marking `w:iara_cursorline_off`) and back on in `win`
  where it was turned off; floats are not focus changes.
- `iara.core.ui` (UX5, V13): the one border of every Iara float. `BORDER`
  ("single": thin straight lines, design 09 section 7; for `nvim_open_win` and
  plugin options: LSP and
  diagnostic floats via 'winborder' and `vim.diagnostic.config`, cmp
  menu and docs, which-key, Gitsigns preview, Mason, lazy.nvim, the
  terminal float, the agent context preview), `CHARS` (its characters),
  `TOP` and `BOTTOM` (a frame split by a joined separator, for the
  pickers), `label(text)` (" text ", or "" when blank),
  `left_title(chunks, group?)` (prepends a `─` in `group`, default
  FloatBorder, so a left title reads `┌─ Title ──┐`), `colored(chars,
  group)` (`{ char, group }` cells for a frame colored apart from the
  window's `FloatBorder`), and `float(config)` (adds `BORDER` unless set
  and pads string titles and footers with `label`). Colors come from
  the theme: FloatBorder, FloatTitle, FloatFooter (styled by V3, see
  `iara.core.float`); Snacks, which-key, and cmp border and title groups
  link to or match them.
- `iara.core.float` (V3, V13; design 09 2.4-2.5 and 7): the float
  language. Focus is the border color. `groups(focused?)` ->
  `GROUPS.focused` (`IaraFloatBorderFocus`, `IaraFloatTitleFocus`) or
  `GROUPS.idle` (`FloatBorder`, `FloatTitle`). `title(text, focused?,
  width?) -> chunks` (a dash in the border group, then ` text ` in the
  title group; text trimmed and cut with an ellipsis to `width`; `{}`
  when blank or nothing fits), `wrap_title(chunks, focused?) -> chunks`
  (the dash before chunks that carry their own padding, such as
  which-key's prefix trail; empty or non-list input is returned
  unchanged), `border(chars, focused?)` (`ui.colored` in the border
  group, for floats that hold the focus while open: select,
  confirmation, Ask AI), `rule(count, focused?) -> chunk` (dashes in the
  border group, title fillers), `footer(hints, width, opts?) -> chunks`
  (`{ key, desc }` hints, at most `opts.max` or `MAX_HINTS` 5, keys in
  `opts.key` or `IaraFloatFooterKey`, the rest in `opts.text` or
  `FloatFooter`, `HINT_SEPARATOR` " · " between hints, one space of
  padding at each end; hints that do not fit are dropped from the
  right; `{}` when none fits), `width(chunks)`, `truncate(text, max)`,
  `FOOTER`. Idle chunks are remapped by a window's 'winhighlight', so a
  float drawn with idle groups lights up with `focus(win)`. V13 removed
  `CAPS`, `caps()`, the `...Cap` groups, and `vim.g.iara_ascii`. `setup()`
  (from `iara.core.options`, safe step): on WinEnter
  a float whose 'winhighlight' maps neither `FloatBorder` nor
  `FloatTitle` itself gets
  `FOCUS_WINHIGHLIGHT` (`FloatBorder:IaraFloatBorderFocus,FloatTitle:
  IaraFloatTitleFocus`; `focus(win)`, idempotent), removed on WinLeave
  (`blur(win)`, other entries kept); on ColorScheme
  `link_fallbacks()` links `FALLBACK_LINKS` (default links). In palette
  mode (V3, V13), `NormalFloat` uses `fg` on `mantle`. The idle
  `FloatBorder` uses `border` on `mantle` and `PmenuBorder` links to it.
  `IaraFloatBorderFocus` `border_focus` (>= 3:1) on `mantle`;
  `FloatTitle` `muted` bold on `mantle`; `IaraFloatTitleFocus` `accent`
  bold on `mantle`; `FloatFooter` `muted`; every border-line cell has
  the float's background;
  `IaraFloatFooterKey` accent bold; `Pmenu` on `mantle`, `PmenuSel`
  `fg_strong` bold on `overlay`, `PmenuKind` `muted`, `PmenuExtra`
  `subtle`, `PmenuMatch` accent bold, `PmenuMatchSel` `accent_row`
  bold (V12); `WinSeparator`
  `crust` on `mantle` (a gap, not a line).
- `iara.core.icons` (UX3): Nerd Font glyphs shared by the status and
  tab lines, start screen, diagnostics (`DIAGNOSTICS`), Gitsigns
  (`GIT_SIGNS`), completion kinds (`KINDS`), and the tree; `START`
  (V6: the `∿` mark, the `▎` selection bar, the `─` rule);
  `MARKDOWN` (MD1: heading numbers, bullets, checkbox and custom task
  glyphs, the quote bar, the straight table frame, the link icon);
  `FOLDER_OPEN` (V12: an expanded directory, as in nvim-tree);
  `file(name)` uses nvim-web-devicons only when it is already loaded
  (the statusline loads it on the first `CursorHold`).
- `iara.core.start` (UX3, step 11b; V6): `setup(config)` defines
  `:IaraRecent` (Snacks recent-files picker, else `:browse oldfiles`)
  and `:IaraToggleWaveAnimation`, which toggles motion for the session.
  Unless `ui.start_screen` is false or Iara got file arguments,
  shows the start screen at VimEnter when `wanted()` (no arguments, no
  standard input, an attached UI, an empty unnamed buffer). With file
  arguments `setup` returns after the argument check. `open()` shows it
  in the current window: a scratch buffer (filetype `FILETYPE` =
  "iara-start", wiped when replaced) with a Braille wave, `TAGLINE`,
  the `ACTIONS` whose command exists (`available()`),
  up to `RECENT_LIMIT` (5) "Recent in <project>" files, and a footer:
  the mark, project,
  branch when HEAD names one, Neovim version, and startup time (from
  `vim.g.iara_startup_hrtime`, set by `init.lua`, to VimEnter; left out
  when unset). Keys: each action's key, digits for recent files, `j`/`k`
  and arrows between rows (the cursor row gets an accent bar), `<CR>`
  runs the row, `i`/`a` edit a new buffer; window options are
  buffer-local. `layout(info, width, height) -> rows` picks the richest
  fitting layout (blank rows shrink, then recent files, then the
  tagline go). The wave matches the menu width and uses a taller
  drawing when there is space. The wave and tagline are hidden
  individually when there is too little space for them.
  The wave animates by default. `ui.wave_animation = false` starts
  with a still wave. Animation paints the header's virtual text while
  the screen is displayed in the current tab of a focused, attached UI.
  Moving focus to a panel in that tab keeps the animation running,
  including while Which-key waits for the next key. The wave also
  keeps moving while editing the command line.
  `recent_files(root, limit)` reads `v:oldfiles` under
  `root` (readable files only, at most 20 checks); `branch(root)` reads
  `.git/HEAD` (or a worktree's `gitdir`) and never runs Git. The screen
  sets its buffer's `iara_context_root` to the working directory. A
  normal buffer shown in another window closes the screen's windows
  (never a tab page's last), so the screen never stays as a split.
  `buffer()` returns it while it exists.
- `iara.core.treesitter` (F6): `FILETYPES` (filetype -> language),
  `PARSERS`, `PARSER_RUNTIME` (development parser directory),
  `setup()` (puts `iara.core.parsers.runtime_dirs()` on 'runtimepath'
  and gates highlighting on FileType and `IaraEligibilityChanged`),
  `update(bufnr) -> active, reason?` (reasons "invalid", "ineligible",
  "unmanaged", "no_parser", "start_failed"), `is_active(bufnr)`.
  The pinned nvim-treesitter plugin owns `:TSInstall`, `:TSUpdate`,
  and `:TSUninstall`. It installs optional parsers and queries on
  request in `iara.core.parsers.extra_runtime()`, shared across
  releases under the current profile's data directory. Eligibility
  also gates highlighting for other parsers installed in this runtime.
- `iara.core.lsp` (F6): native LSP policy for language files.
  `setup()` (applies `diagnostic_options()`; semantic tokens, document
  colors, and inlay
  hints off, attach mappings, detach on ineligibility), `enable(name,
  overrides)` (lspconfig definition plus overrides, eligibility-gated
  `root_dir`), `gated_root_dir(base)`, `capabilities()` (cmp-nvim-lsp
  when installed), `report_unavailable(name, filetypes, err)` (one
  notice when such a buffer opens). Titled floats (V9): `hover()`
  (`vim.lsp.buf.hover` titled by `hover_title(bufnr)`, the LSP glyph
  and the sorted names of the buffer's clients that answer hover, nil
  when none), `signature_help()` (FU-V12-3: `iara.core.signature.
  open()`, required on the first call: asks the buffer's servers
  itself; titled "Signature", with several signatures "Signature i/n"
  and a centered `C-s next` footer, `<C-s>` in the float shows the
  next one, wrapping; `collect(results) -> signatures, active` and
  `frame(index, total) -> title, footer?` are its pure parts; "No
  signature help available" when none answers), both at most 80x20,
  and `float_title(text)` (the idle title
  of `iara.core.float.title`, `title_pos = "left"`). Attach mappings
  add `K` (hover) and Insert/Select `<C-s>` (signature help).
  Diagnostics (UX3, V8):
  `diagnostic_options()` returns the `vim.diagnostic.config` table:
  severity icons as signs on every line, `numhl` `DiagnosticError` for
  errors only, virtual text with the icon on the cursor's line only
  (`current_line`), and a straight-framed float titled "Diagnostics"
  (the idle `iara.core.float.title`, no header line,
  `float_prefix(diagnostic)` the icon in its `Diagnostic<Severity>`
  group, `float_suffix(diagnostic)` the
  code and, when the buffer has several sources, the source, in
  `IaraMuted`).
- `iara.languages.lua` (F6): `setup(settings)` with
  `config.languages.lua` enables lua_ls or reports why it cannot;
  `command(settings) -> argv|nil, err` (personal `cmd`, Mason artifact,
  then PATH; codes "invalid_cmd", "not_found"); `server_settings(settings)`.
  Also `SERVER`, `EXECUTABLE`, `FILETYPES`.

- `iara.theme` (U1, safe step): Iara-owned colors without plugins.
  `THEMES` (shipped names: catppuccin, chocolate, everforest,
  github_dark, github_light, gruvbox, gruvbox_light, kanagawa, nord,
  onedark, rosepine, tokyonight), `DEFAULT` ("chocolate"), `PREFIX`
  ("iara-"). `setup(config)` applies the startup theme and defines
  `:IaraTheme [name]` (completion; no argument opens the picker) and
  `:IaraToggleBackground`. Iara uses the terminal default background
  on the editor, start screen, tab line, split winbars, and panel
  surfaces. The terminal and agent panels, explorers, pickers, and
  other Iara floats follow the same mode.
  `ui.terminal_background = false` selects the palette background
  at startup. The command toggles the mode for the current session
  and reapplies the active Iara theme. Theme changes and previews
  use the session's mode.
  Startup precedence: `ui.theme` when `config.is_explicit("ui.theme")`,
  else the name stored in `stdpath("state")/iara/theme` by the last
  `:IaraTheme` or picker choice, else the default `ui.theme`. Startup
  calls `load` directly: no `:colorscheme` search, no ColorScheme event.
  `apply(name) -> applied` runs `:colorscheme iara-<name>`; an unknown
  name warns and applies chocolate. `set(name) -> ok` applies and stores
  (unknown names warn and change nothing). `load(name)` is the body of
  `colors/iara-<name>.lua` (`hi clear`, 'background' from the palette
  type, every group, `terminal_color_0..15` (`terminal_color_0` is
  the `mantle` role since V7), `g:colors_name`; the
  `hi clear` is skipped while no colorscheme is loaded).
  `current()` (nil under a foreign colorscheme), `palette(name)`,
  `is_theme(name)`, `choose(configured, explicit, persisted)`,
  `persisted()`, `persist(name) -> ok, err`, `state_path()`, `pick()`.
  `iara.theme.highlights`: `resolve(palette) -> groups, problems, roles` and
  `apply(palette, terminal_background?) -> problems`, over the slot-based table
  `iara.theme.groups`. `iara.theme.picker.open() -> picker?`: Snacks
  picker with live preview (cancel restores the previous colorscheme),
  else `vim.ui.select` without preview (returns nil). UX5: a compact
  straight frame (`layout.compact`, `WIDTH` 44) and the picker modes of
  9.9 (`Esc` to Normal mode, `j`/`k`, counts, `gg`/`G`, `Ctrl-d`/`u`,
  `Ctrl-f`/`b`, `H`/`M`/`L`; `Enter`/`o`/`l` apply; `q` or a second
  `Esc` cancel; `i`/`a`/`A`/`I`/`/` type), previewing the selection in
  both modes; it opens with the cursor on the active theme and applies
  no other theme until the cursor moves (FU-V12-6); split, preview,
  and quickfix keys are unbound. V10:
  `WIDTH` 50; rows are the name, the palette type (both in the item
  text, so `light` filters), `✓` on the stored (or active) theme, and
  swatches of `SWATCH_ROLES` (`base`, `mantle`, `accent`, `tide`,
  `error`, `warn`, `ok`, `info`) in `swatch_group(name, n)`
  (`IaraThemeSwatchGithubLight3`), defined by `define_swatches()` on
  open and again on every ColorScheme while the picker is open.
  Palettes
  (`iara.theme.palettes.*`) are `{ type, base_30, base_16, polish? }`
  ported from base46 (MIT), plus an optional `identity = { accent,
  tide }` (V1: slot names or "#rrggbb"; defaults `blue` and `teal`).
  Roles (V1, `iara.theme.roles`): `resolve(palette) -> table<role,
  "#rrggbb">` (cached per palette table), `names()`, `identity(palette)`,
  `ROLES`, `READABLE`, `STATES`, `MODES`, `GROUPS`, `FALLBACK_LINKS`.
  Role names: surfaces `base`, `mantle`, `crust`, `raised`, `overlay`,
  `cursorline`; text `fg`, `fg_strong` (7:1; `fg` also 4.5:1 on
  `overlay`, V12), `muted` (4.5:1),
  `subtle` (3:1; both also on `cursorline` and `overlay`), `faint`,
  `border` (decoration); identity `accent`
  (4.5:1), `accent_soft`, `accent_row` (V12: the accent moved until
  4.5:1 also on `cursorline` and `overlay`, for accent text on
  selected rows and cursor lines; equal to `accent` where it already
  is, so chocolate's `accent` stays copper `#d08b65`), `on_accent`
  (4.5:1 on `accent`),
  `border_focus` (3:1 on `mantle`), `tide` (4.5:1), `tide_soft`;
  states `error`, `warn`, `info`, `hint`, `ok` (4.5:1, also on their
  tint) and `<state>_soft`; `mode_<m>` and `on_mode_<m>` for normal,
  insert, visual, replace, command, select, terminal, confirm. Ratios
  hold on `base` and `mantle` unless stated. A group color may name a
  role as `"@<role>"`, alone or in a blend. Engine (V1):
  `highlights.luminance(hex)`, `contrast(a, b)`, and `readable(color,
  bg, ratio, target?)` (bg one color or a list; 5% steps toward
  `target`, else black or white). Groups live in
  `iara.theme.groups.{editor,syntax,floats,status,progress,search,start,
  panels,explorer,health,plugins,ai,markdown}`; `iara.theme.groups`
  merges them with
  the
  role groups `Iara{Accent,AccentSoft,OnAccent,Tide,TideSoft,Muted,
  Subtle,Faint,Border,BorderFocus,Mantle,Crust,Raised,Overlay}`.
  Iara-owned groups: `IaraBreadcrumb`, `IaraBreadcrumbSeparator` (for
  D4's breadcrumb), `IaraStatusWarn`, `IaraStatusConflict`,
  `IaraStatusRoot`, `IaraStatusSafe` (statusline parts),
  `IaraStatusTerminal`, `IaraStatusAgent`, `IaraStatusRunning`,
  `IaraStatusExited` (terminal status lines, UX2); UX3 adds
  `IaraStatusMode{Normal,Insert,Visual,Replace,Command,Select,Terminal,
  Confirm}`, `IaraStatusFile`, `IaraStatusModified`, `IaraStatusMuted`,
  `IaraStatusGit{Added,Changed,Removed}`,
  `IaraStatusDiag{Error,Warn,Info,Hint}`, `IaraStatusLsp`,
  `IaraStatusRootIcon`, `IaraStatusPositionIcon` (V4: no longer drawn),
  `IaraStatusPosition`, `IaraTab{Fill,Active,Inactive,Modified,
  ModifiedInactive,Number}`, and `IaraStart{Logo,Text,Icon,Action,Key,
  Footer}`; V6 adds `IaraStart{WaveTide,WaveMid,WaveAccent,Cursor,Bar,
  Section,Rule,FileIcon,File,Mark}`; V3 adds `IaraFloat{TitleFocus,
  TitleCap,TitleFocusCap,FooterKey}` (`groups/floats.lua`, fallback
  links in `iara.core.float`); V4 adds `IaraStatusMode<Mode>Cap`,
  `IaraStatusCap`, `IaraStatusMark`, `IaraTabActiveBar`, and
  `IaraWinbar{Bar,Icon,Path,Name,Modified,Inactive}`; V10 adds
  `IaraSearch{TitleCap,CrumbCap,CountBusy,Selection,SelectionBar,
  SelectionGap,GroupCount}`, `IaraTheme{Mark,Type}`,
  `IaraThemeSwatch<Theme><n>` (defined by the theme picker), and
  `IaraSelect{Key,Text,Detail}` (fallback links in their modules);
  V7 moves `IaraStatus{Terminal,Agent,Running,Exited}` onto roles
  (`mode_terminal`, `mode_visual`, `ok`, `error`) and adds `IaraPanel`
  (panel surface: `fg` on `mantle`) and
  `IaraPanel{Header,BarShell,BarAgent,BarFocus,Title,Cwd,Running,
  Stopping,Exited,Done,Key,Hint}` (all on `mantle`; fallback links in
  `iara.features.terminal.header`);
  V8 adds no group; it points `LineNr` to `muted` (line numbers
  are text, 4.5:1), `CursorLineNr` to `accent` bold, `Whitespace`
  (indent guides) to `faint`, `Diagnostic*` and
  `DiagnosticVirtualText*` (and `Ok`) to the state roles on their
  `*_soft` tints, and `GitSigns{Add,Change,Delete}[Nr]` to `ok`,
  `info`, `error`;
  `IaraSearchTitle` and `IaraSearchCrumb` are title text on the frame
  (V13: `accent` bold and `muted` on `mantle`; `IaraSearchBorderFocus`
  `border_focus` and `IaraSearchBorder` `border` color the frames), and
  `SnacksPickerListCursorLine` links to `IaraSearchSelection`
  (`overlay`).
  V9 (`groups/plugins.lua`, no new names): `CmpPmenu`,
  `CmpDoc` on `mantle`; `CmpBorder`, `CmpDocBorder`, and
  `WhichKeyBorder` link to `FloatBorder` (one straight frame per
  popup, the idle `border` since these never take the focus, no cmp
  scrollbar), `CmpSel` (`overlay`, bold, no fg),
  `CmpItemKind<Kind>` (the kind's syntax slot blended 70% over `fg`,
  >= 3:1 on `mantle` and `overlay`), `CmpItemKind` (kind names) and
  `CmpItemMenu` (`muted`), `CmpItemAbbrMatch` (`accent`),
  `WhichKey`/`WhichKeyGroup` (`accent`), `WhichKeySeparator` (`muted`),
  `LspSignatureActiveParameter` (`accent` bold underline, no bg). The
  cmp spec (`plugins/cmp.lua`) draws an accent `▎` (`IaraAccent`) over
  the left padding of the selected menu row and titles the
  documentation window "Kind · Source", following the `cmp_menu` and
  `cmp_docs` buffers through one decoration provider. The which-key
  spec (FU-V12-4) wraps which-key's prefix title in
  `iara.core.float.wrap_title` (one dash after the corner) and puts
  `Esc close · BS back` in the bottom border (`win.footer`, `show_help =
  false`).
  S11: which-key sets up a Snacks picker buffer (input, list, preview
  filetypes) 50 ms after it is first asked, not while the picker opens
  (about 1.5 ms of every Find files open); until then it answers nil,
  as for a buffer it skips.
  V12 follow-up (FU-V12-1/5/7, no new names): accent text on rows
  (`CmpItemAbbrMatch[Fuzzy]`, `PmenuMatchSel`, `IaraSearchMatch`,
  `SnacksPickerMatch`, `IaraSelectKey`, `NvimTreeOpenedHL`,
  `MatchParen`) uses `accent_row`; the status bar, progress, and
  terminal status parts sit on `mantle` (no longer `statusline_bg`;
  V13: every segment but the mode block is flat on `mantle`);
  `IaraStatusSafe` is `base` on `warn`;
  base46 slots below 4.5:1 move onto roles: `Search` `fg_strong` on
  `accent_soft`, `IncSearch`/`Substitute` `on_accent` on `accent`,
  `Folded` and `LspInlayHint` `muted` on `cursorline`, `WildMenu`
  `fg_strong` on `overlay`, `Diff{Add,Delete}` the state on its tint,
  `DiffChange` `info_soft`, `DiffText` `info` on `info_soft`,
  `VisualNOS` linked to `Visual`, `LspCodeLens`,
  `DiagnosticUnnecessary`, `GitSignsCurrentLineBlame`,
  `IaraBreadcrumb`, Mason's muted text, and ignored tree names
  `muted`, `IaraBreadcrumbSeparator` `subtle`, Lazy and Mason headers
  rectangular accent blocks and their other colors state roles,
  `SnacksPicker{Prompt,Selected}` `accent`.
  Under a foreign
  colorscheme every one gets a neutral default link (`FALLBACK_LINKS`;
  the V6 and V4 groups once `theme/init.lua` lists them, requested by
  both). A group color may be a blend
  `{ top_slot, bottom_slot, percent }` (`highlights.blend(top, bottom,
  percent)`). Mapping `<leader>th`
  ("Themes") is an `iara.core.keymaps` default.
- `iara.core.select` (V10, safe step): `setup()` sets `vim.ui.select`
  to `select(items, opts, on_choice)`: a centered float (V13:
  `float.border(ui.CHARS, true)`, the focus color while it holds the
  focus), the prompt without a trailing colon as the title (`title`),
  items as ` n  label` (`lines`, `format_item` honored), inside width
  even, `MIN_WIDTH` 48 to `MAX_WIDTH` 80, the `layout.BAR` selection
  bar, footer `⏎ choose · 1-9 pick · q cancel`). Keys: `j`/`k`, arrows,
  `Ctrl-n`/`Ctrl-p` (wrapping), `gg`/`G`, `Enter`/`o`/`l`, digits 1-9;
  `q`, `Esc`, `Ctrl-c`, or leaving the window cancel. `on_choice(item,
  index)` runs exactly once after the float closed, `(nil, nil)` on
  cancel and at once for an empty list. More than `FILTER_ABOVE` (12)
  items open Snacks' `select` with the compact frame and picker modes
  when Snacks loads, else the float. Returns the window, the picker,
  or nil.
- V11 groups: `IaraTreeBranch` (`groups/explorer.lua`), `IaraHealth{Ok,
  Warn,Error,Heading,Advice,Mark,Rule}` and `IaraContext{Chip,
  ChipWarn,Label,Value,Rule}` (`groups/health.lua`); their
  fallback links are set with `default = true` by the module that uses
  them (`iara.core.explorer`, `iara.core.health_look`,
  `iara.extras.agents.preview`) when it draws.
- `iara.core.explorer` (V11): `root_label(path)` (` ∿ name ` and the
  branch from `vim.g.gitsigns_head` when known), `branch()`,
  `mark_branch(bufnr)` (recolors the branch, `IaraTreeBranch`),
  `setup()` (subscribes to nvim-tree's `TreeRendered`; called from the
  plugin's `config`), `MARK`, `BRANCH_ICON`, `SEPARATOR`, `NAMESPACE`.
  The tree shows every Git state as one dot after the name, colored by
  state (`warn` modified, `ok` new/staged/renamed, `error`
  deleted/conflict, `subtle` ignored).
- `iara.core.health_look` (V11): `attach()` (a `FileType checkhealth`
  autocmd, registered by `iara.health.check`), `apply(bufnr)`,
  `decorations(lines) -> marks` (pure), `header_chunks(name, counts)`,
  `counts_text(counts)`, `STATES`, `WIDTH`, `MARK`, `FALLBACK_LINKS`.
  The buffer text is never changed: extmarks hide the `====` rules and
  the `ADVICE:` labels, draw each module header as `name ─── N ok · N
  warnings · N errors` (counted from its report lines; the mark `∿`
  before `iara`), and show report prefixes as `✓ ▲ ✗ ·`.
  `:checkhealth iara` sections: Mode, Releases, Plugins, Tree-sitter
  parsers, External tools.
- `iara.features.markdown` (MD1): Obsidian-like rendering of Markdown
  through render-markdown.nvim (spec `plugins/render_markdown.lua`,
  `ft = "markdown"`, `cmd` `COMMAND`, key `KEY` in Markdown buffers;
  Neovim's bundled markdown and markdown_inline parsers).
  `setup()` (from the spec's `config`) runs the plugin's setup with
  `options()`, defines `:IaraMarkdownToggle` (`COMMAND`), and follows
  `IaraEligibilityChanged`, `BufWinEnter`, and `BufWipeout`.
  `options()`: Normal, Command-line, and Terminal mode render
  (`RENDER_MODES`; Insert mode shows raw text), the cursor's line is
  raw (anti-conceal, 'concealcursor' ""), only
  buffers with 'buftype' "" attach, `max_file_size` is
  `eligibility.LIMITS.max_bytes`, no signs, inline heading icons on
  block bands, block code with a language label, straight padded
  tables, `TASK_STATES` (`[/]` progress, `[-]` cancelled, `[>]`
  forwarded, `[!]` important, `[?]` question; done and cancelled task
  text struck through), glyphs from `iara.core.icons.MARKDOWN`.
  `wanted(bufnr)` (the global switch is on and eligibility says
  eligible: conservative and unknown buffers show raw text),
  `apply(bufnr)` (switches an attached buffer to `wanted`),
  `attached(ctx)` (the plugin's `on.attach`), `toggle() -> enabled`
  (the global switch for every attached buffer, `KEY` `<leader>mr`
  "Markdown render toggle", which-key group `<leader>m` "Markdown"),
  `enabled()`, `rendering(bufnr) -> boolean|nil` (nil before attach).
  `drop_conceal_lines() -> changed` (MD2): disables the `conceal_lines`
  patterns of Neovim's markdown highlight query and clears its
  `has_conceal_line`, so Tree-sitter highlighters do not re-parse per
  row Neovim checks for hidden lines while scrolling with
  'conceallevel' 3 (render-markdown.nvim draws the code fence lines and
  disabled those patterns already); `attached` calls it and, when it
  changed the query, restarts the highlighters of file Markdown
  buffers, which read the flag when they start.
  Picker previews (S10, pooled 'buftype' "nofile" buffers with
  Tree-sitter only) are not rendered and never load the plugin. Groups
  (`iara.theme.groups.markdown`): `RenderMarkdownH<n>` (icon, the level
  color 75% over `fg_strong`), `RenderMarkdownH<n>Bg` (an 8% band),
  `@markup.heading.<n>.markdown` (text, 50%, bold) for levels `accent`,
  `tide`, `mode_visual`, `mode_terminal`, `mode_select`, `muted`
  (4.5:1 text on the band and the cursor line, 3:1 icons);
  `RenderMarkdownCode`, `CodeBorder`, `CodeInfo` on `mantle`,
  `IaraMarkdownCodeLanguage`; bullets, quote bar, rule, and table
  frame on `muted`/`subtle`; links `accent`; callouts on the state
  roles; `@markup.quote.markdown` without a surface;
  `IaraMarkdown{Struck,Progress,Cancelled,Forwarded,Important,
  Question}`.

## 14. Event index

| Pattern | Owner | Data |
| --- | --- | --- |
| `IaraRootChanged` | F3 | `bufnr?, cause, root?, previous?` |
| `IaraEligibilityChanged` | F5 | `bufnr, state, previous, reason?` |
| `IaraConflictDetected` | A3 | `bufnr, path, snapshot` |
| `IaraConflictResolved` | A3 | `bufnr, path, choice` |
| `IaraBufferReloaded` | A3 | `bufnr, path` |
| `IaraTerminalChanged` | T2 | `id, status, previous, generation` |
| `IaraProgressChanged` | V5 | none (read `iara.core.progress.state()`) |
