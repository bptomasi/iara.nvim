--- Search session: one query and one path glob drive up to two lanes.
---
--- The filename lane fuzzy-matches the query against the eligible
--- inventory; the content lane runs ripgrep over the same inventory, so a
--- path glob narrows both. Each lane has its own state, error, and quota
--- (200 file names, 1,000 occurrences); one lane never consumes the
--- other's capacity, and a full quota stops that lane's work visibly.
--- `mode` runs one lane only (UX1: "Find files" and "Find in files");
--- without it both lanes run. `within` narrows both lanes to a list of
--- paths taken from an earlier result (a chained filter step); it is
--- applied after eligibility and the glob, so it can only narrow them.
---
--- Every rerun increments the query generation, cancels fuzzy matching
--- and grep, and clears the records; callbacks of an older generation are
--- dropped. Filename matching starts at once and ranks eligible paths
--- while the inventory streams them: those records are provisional (the
--- lane stays loading) until the complete inventory is ranked. Content
--- search waits for the complete inventory and a 50 ms debounce. An
--- empty query never runs content search. It lists eligible files in
--- the "files" mode (UX1b: Find files lists every file as it opens) or
--- with a glob or `within` list: recently used buffers of the root
--- first, then shallower paths, then byte-wise path order. The 200-row
--- quota still applies; `total` counts every listed file.
---
--- Inventories are cached per identity (scope, visibility, glob) for the
--- life of the session: keystrokes reuse the current inventory and a
--- switch back reuses the previous one. Picker entry points may reuse
--- a complete root inventory after revalidating its disk dependencies.
--- A glob change reuses the complete
--- `E` of the same scope and switches and walks only `G`. At most two
--- inventories are kept.
---
--- Retained records are accounted in bytes: when content records would
--- take the session above 8 MiB of retained results, the content
--- lane stops as truncated with a "memory" error, like a full quota.
--- See contracts.md, section 9.5.
local open = require("iara.features.picker.open")
local fuzzy = require("iara.features.search.fuzzy")
local grep = require("iara.features.search.grep")
local inventory = require("iara.features.search.inventory")
local inventory_cache = require("iara.features.search.inventory_cache")
local recent = require("iara.features.search.recent")

local M = {}

local FILE_LIMIT = 200
---Path references retained separately from the ranked records.
local REFINEMENT_LIMIT = 8192
local OCCURRENCE_LIMIT = 1000
local MAX_QUERY_BYTES = 256
local DEBOUNCE_MS = 50
---Inventories kept per session; older identities are rebuilt on demand.
local MAX_INVENTORIES = 2
---Maximum retained bytes across both result lanes.
local RETAINED_BYTES = 8 * 1024 * 1024
---Accounted cost of one record table beyond its strings.
local RECORD_OVERHEAD = 200

local FIELD_TYPES = {
  query = "string",
  glob = "string",
  hidden = "boolean",
  ignored = "boolean",
  regex = "boolean",
  case = "string",
  scope = "table",
  focus = "string",
  mode = "string",
  within = "table",
}
local CASES = { smart = true, sensitive = true, insensitive = true }
local FOCUS = { files = true, content = true }
local MODES = { files = true, content = true }
---Values that clear an optional field in update(): `glob = ""` and
---`within = false`.
local CLEARS = { glob = "", within = false }
local SCOPE_KINDS = { root = true, directory = true, file = true }
---Fields whose change needs no rerun.
local PRESENTATION_FIELDS = { focus = true }

local GREP_STATES = {
  complete = "complete",
  no_match = "complete",
  error = "error",
  partial = "incomplete",
  cancelled = "cancelled",
}

-- Validation ------------------------------------------------------------

local function validate_scope(scope)
  if not SCOPE_KINDS[scope.kind] then
    error("search: scope.kind must be root, directory, or file", 4)
  end
  local path = scope.path
  local absolute = type(path) == "string" and path:sub(1, 1) == "/"
  if scope.kind ~= "root" and not absolute then
    error("search: scope.path must be an absolute path", 4)
  end
end

local function validate_within(within)
  for index, path in ipairs(within) do
    if type(path) ~= "string" then
      error(("search: request.within[%d] must be a string"):format(index), 4)
    end
  end
end

local function validate_fields(request)
  if type(request) ~= "table" then
    error("search: request must be a table", 4)
  end
  for key, value in pairs(request) do
    local expected = FIELD_TYPES[key]
    if not expected then
      error(("search: unknown request field %q"):format(tostring(key)), 4)
    end
    if type(value) ~= expected and value ~= CLEARS[key] then
      error(("search: request.%s must be a %s"):format(key, expected), 4)
    end
  end
end

local function validate_request(request)
  validate_fields(request)
  if request.case ~= nil and not CASES[request.case] then
    error("search: request.case must be smart, sensitive, or insensitive", 3)
  end
  if request.focus ~= nil and not FOCUS[request.focus] then
    error("search: request.focus must be files or content", 3)
  end
  if request.mode ~= nil and not MODES[request.mode] then
    error("search: request.mode must be files or content", 3)
  end
  if type(request.within) == "table" then
    validate_within(request.within)
  end
  if request.scope then
    validate_scope(request.scope)
  end
end

---Runtime input error for a query that cannot reach a matcher, or nil.
local function query_error(query)
  if #query > MAX_QUERY_BYTES then
    local message = ("query exceeds %d bytes"):format(MAX_QUERY_BYTES)
    return { code = "query", message = message }
  end
  if query:find("\0", 1, true) then
    return { code = "query", message = "query contains a NUL byte" }
  end
end

-- Lanes and notification ------------------------------------------------

local function new_lane(active, limit)
  local state = active and "loading" or "idle"
  return { state = state, count = 0, total = 0, limit = limit }
end

local function is_loading(holder)
  return holder.lane.state == "loading"
end

local function end_lane(holder, state, err)
  holder.lane.state = state
  holder.lane.error = err
end

---Coalesce changes into one scheduled call of the subscriber.
local function changed(session)
  if session.notify_pending then
    return
  end
  session.notify_pending = true
  vim.schedule(function()
    session.notify_pending = false
    if not session.closed and session.subscriber then
      session.subscriber(session:snapshot())
    end
  end)
end

local function is_current(session, generation)
  return not session.closed and session.generation == generation
end

-- Filename lane ---------------------------------------------------------

local function file_record(session, match)
  return {
    id = "file:" .. match.path,
    generation = session.generation,
    root = session.root.path,
    kind = "file",
    path = match.path,
    score = match.score,
    positions = match.positions,
  }
end

---Final filename lane state once every eligible path is ranked.
local function files_state(truncated, result)
  if result.state == "incomplete" then
    local message = ("file inventory incomplete (%s)"):format(
      result.reason or "limit"
    )
    return "incomplete", { code = "inventory", message = message }
  end
  return truncated and "truncated" or "complete"
end

---True when match `a` ranks before `b`: the order of fuzzy.match.
local function ranks_before(a, b)
  if a.score ~= b.score then
    return a.score > b.score
  end
  return a.path < b.path
end

---Best `limit` of two ranked match lists. Ranking the catalog in slices
---and merging gives the same result as ranking it at once.
local function merge_matches(top, matches, limit)
  local merged = vim.list_extend(vim.list_slice(top), matches)
  table.sort(merged, ranks_before)
  for index = #merged, limit + 1, -1 do
    merged[index] = nil
  end
  return merged
end

---Accounted bytes of one retained record.
local function record_bytes(record)
  local positions = record.positions and #record.positions * 8 or 0
  return #record.id
    + #record.path
    + #(record.text or "")
    + positions
    + RECORD_OVERHEAD
end

---Paths of `paths` that the request's `within` list keeps, in order.
local function narrow(session, paths)
  local keep = session.within_set
  if not keep then
    return paths
  end
  local kept = {}
  for _, path in ipairs(paths) do
    if keep[path] then
      kept[#kept + 1] = path
    end
  end
  return kept
end

---Replace the file records with the current ranking.
local function set_file_records(session)
  local files = session.files
  files.records, files.bytes = {}, 0
  for index = 1, math.min(#files.top, FILE_LIMIT) do
    local record = file_record(session, files.top[index])
    files.records[index] = record
    files.bytes = files.bytes + record_bytes(record)
  end
  files.lane.count = #files.records
end

local pump_files

local function on_slice_ranked(session, last, ranked)
  local files, matches = session.files, ranked.matches
  session.jobs.fuzzy = nil
  if not ranked.complete then
    return end_lane(files, "cancelled")
  end
  files.matched = last
  files.lane.total = files.lane.total + ranked.total
  if files.paths then
    files.paths = ranked.paths and vim.list_extend(files.paths, ranked.paths)
  end
  if #matches > 0 then
    files.top = merge_matches(files.top, matches, FILE_LIMIT + 1)
    set_file_records(session)
    changed(session)
  end
  pump_files(session)
end

---Rank the catalog paths admitted since the last slice. Records shown
---before the inventory completes are provisional: every one is eligible,
---but better matches may still arrive, so the lane stays loading.
local function rank_slice(session, catalog, stable)
  local files = session.files
  local generation = session.generation
  local first, last = files.matched + 1, #catalog
  local slice = stable and first == 1 and catalog
    or vim.list_slice(catalog, first, last)
  if not files.rank_paths then
    slice = narrow(session, slice)
  end
  -- One extra match reveals whether the quota hid further names.
  session.jobs.fuzzy = fuzzy.match(session.request.query, slice, {
    limit = FILE_LIMIT + 1,
    recent = session.recent,
    path_cap = files.paths and REFINEMENT_LIMIT - #files.paths,
    on_done = function(matches, complete, total, paths)
      if is_current(session, generation) and is_loading(session.files) then
        on_slice_ranked(session, last, {
          matches = matches,
          complete = complete,
          total = total,
          paths = paths,
        })
      end
    end,
  })
end

---Retain the whole match set only for a settled, complete inventory.
local function finish_files(session, result)
  local files = session.files
  session.refinement = nil
  if result.state == "complete" and files.paths then
    session.refinement = {
      paths = files.paths,
      generation = result.generation,
      query = session.request.query,
      within = session.request.within,
    }
  end
  files.paths, files.rank_paths = nil, nil
  local truncated = #files.top > FILE_LIMIT
  end_lane(files, files_state(truncated, result))
  changed(session)
end

---Advance the filename lane: rank newly admitted paths, or settle the
---lane once the inventory is complete and every path is ranked.
function pump_files(session)
  local files = session.files
  local entry = session.inventories[session.inventory_key]
  if not is_loading(files) or session.jobs.fuzzy or not entry then
    return
  end
  local catalog = files.rank_paths or entry.catalog
  if files.matched < #catalog then
    return rank_slice(session, catalog, entry.result ~= nil)
  end
  if entry.result then
    finish_files(session, entry.result)
  end
end

-- Content lane ----------------------------------------------------------

local function occurrence_record(session, path, item)
  return {
    id = ("occurrence:%d:%d:%d:%s"):format(
      item.row,
      item.byte_start,
      item.byte_end,
      path
    ),
    generation = session.generation,
    root = session.root.path,
    kind = "occurrence",
    path = path,
    row = item.row,
    byte_start = item.byte_start,
    byte_end = item.byte_end,
    text = item.text,
  }
end

local function location_less(a, b)
  if a.row ~= b.row then
    return a.row < b.row
  end
  if a.byte_start ~= b.byte_start then
    return a.byte_start < b.byte_start
  end
  return a.byte_end < b.byte_end
end

local function cancel_job(session, name)
  local job = session.jobs[name]
  session.jobs[name] = nil
  if job then
    job:cancel()
  end
end

---Stop content search at its quota; later occurrences stay uncollected.
local function truncate_content(session)
  end_lane(session.content, "truncated")
  cancel_job(session, "grep")
end

local function group_for(content, path)
  local group = content.by_path[path]
  if not group then
    group = { path = path, records = {} }
    content.by_path[path] = group
    table.insert(content.groups, group)
  end
  return group
end

---Whether retaining `record` keeps the session within its byte limit.
local function fits(session, record)
  local used = session.files.bytes + session.content.bytes
  return used + record_bytes(record) <= RETAINED_BYTES
end

local function refuse_content(session)
  truncate_content(session)
  session.content.lane.error = {
    code = "memory",
    message = ("retained results reached %d MiB"):format(
      RETAINED_BYTES / 1048576
    ),
  }
end

local function add_occurrences(session, path, items)
  local content = session.content
  table.sort(items, location_less)
  for _, item in ipairs(items) do
    local record = occurrence_record(session, path, item)
    if not content.seen[record.id] then
      if content.lane.count == OCCURRENCE_LIMIT then
        return truncate_content(session)
      end
      if not fits(session, record) then
        return refuse_content(session)
      end
      content.seen[record.id] = true
      table.insert(group_for(content, path).records, record)
      content.lane.count = content.lane.count + 1
      content.bytes = content.bytes + record_bytes(record)
    end
  end
end

local function grep_error(result)
  local err = result.error
  if result.state ~= "partial" or not err then
    return err
  end
  -- A deadline arrives as code "rg"; either way the results are a prefix.
  local message = "content search stopped early: " .. err.message
  return { code = err.code, message = message, uv_error = err.uv_error }
end

local function start_content(session, paths)
  local generation, request = session.generation, session.request
  local function accepts()
    return is_current(session, generation) and is_loading(session.content)
  end
  session.jobs.grep = grep.run({
    root = session.root.path,
    files = paths,
    query = request.query,
    regex = request.regex,
    case = request.case,
    generation = generation,
  }, {
    on_file = function(path, items)
      if accepts() then
        add_occurrences(session, path, items)
        changed(session)
      end
    end,
    on_done = function(result)
      if accepts() then
        session.jobs.grep = nil
        end_lane(session.content, GREP_STATES[result.state], grep_error(result))
        changed(session)
      end
    end,
  })
end

local function current_inventory(session)
  local entry = session.inventories[session.inventory_key]
  return entry and entry.result
end

---Start content search once the debounce elapsed and eligibility is known.
local function try_content(session)
  local content = session.content
  if not session.debounced or content.started or not is_loading(content) then
    return
  end
  local result = current_inventory(session)
  if result then
    content.started = true
    start_content(session, narrow(session, result.paths))
  end
end

local function start_debounce(session)
  local generation = session.generation
  session.timer:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      if is_current(session, generation) then
        session.debounced = true
        try_content(session)
      end
    end)
  end)
end

-- Inventory -------------------------------------------------------------

---Provisional file names cannot stand when the inventory failed.
local function fail_lanes(session, result)
  cancel_job(session, "fuzzy")
  local files, content = session.files, session.content
  if is_loading(files) then
    files.records, files.top, files.lane.count = {}, {}, 0
  end
  for _, holder in ipairs({ files, content }) do
    if is_loading(holder) then
      end_lane(holder, result.state, result.error)
    end
  end
  changed(session)
end

local function on_inventory_ready(session, result)
  local content = session.content
  if result.state == "error" or result.state == "cancelled" then
    return fail_lanes(session, result)
  end
  if result.state == "incomplete" and is_loading(content) then
    end_lane(content, "incomplete", {
      code = "inventory",
      message = "file inventory incomplete; content search withheld",
    })
  end
  pump_files(session)
  try_content(session)
  changed(session)
end

---Identity of `E`: what an inventory depends on besides the glob.
local function base_key(request)
  local scope = request.scope
  return table.concat({
    scope.kind,
    scope.path or "",
    tostring(request.hidden),
    tostring(request.ignored),
  }, "\0")
end

local function inventory_key(request)
  return base_key(request) .. "\0" .. (request.glob or "")
end

---The complete `E` of a cached inventory with the same scope and
---switches, so a glob change walks only `G`.
local function reusable_base(session, wanted)
  for _, entry in pairs(session.inventories) do
    local result = entry.result
    if entry.base_key == wanted and result and result.base then
      return result.base
    end
  end
end

local function forget_inventory(session, key)
  local entry = session.inventories[key]
  session.inventories[key] = nil
  for index, cached in ipairs(session.inventory_order) do
    if cached == key then
      table.remove(session.inventory_order, index)
      break
    end
  end
  if entry and entry.handle then
    entry.handle:cancel()
  end
end

local function oldest_unkept(session, keep)
  for _, key in ipairs(session.inventory_order) do
    if not keep[key] then
      return key
    end
  end
end

---Drop unfinished walks of identities not in `keep` and the oldest
---finished ones beyond the cache size, so typing never starves
---enumeration while a switch is not left running in the background.
---@param keep table<string, true> Inventory keys to keep.
local function prune_inventories(session, keep)
  for _, key in ipairs(vim.list_slice(session.inventory_order)) do
    local entry = session.inventories[key]
    if not keep[key] and not entry.result then
      forget_inventory(session, key)
    end
  end
  while #session.inventory_order > MAX_INVENTORIES do
    local oldest = oldest_unkept(session, keep)
    if not oldest then
      return
    end
    forget_inventory(session, oldest)
  end
end

---Deliver a finished inventory to the callers of `Session:tree` that
---waited for it.
local function release_waiters(entry)
  local waiters = entry.waiters
  entry.waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter(entry.result)
  end
end

local function on_entry_done(session, entry, result)
  if session.closed or session.inventories[entry.key] ~= entry then
    return
  end
  entry.handle, entry.result = nil, result
  -- The final paths keep admission order, so ranking resumes where the
  -- progress reports left off.
  entry.catalog = result.paths
  if entry.key == session.inventory_key then
    on_inventory_ready(session, result)
  end
  release_waiters(entry)
end

---Start the inventory of `request` under `key`.
local function build_inventory(session, key, request)
  local entry =
    { key = key, base_key = base_key(request), catalog = {}, waiters = {} }
  local base = reusable_base(session, entry.base_key)
  session.inventories[key] = entry
  table.insert(session.inventory_order, key)
  session.inventory_generation = session.inventory_generation + 1
  local provider = session.shared_inventory and inventory_cache or inventory
  entry.handle = provider.build({
    root = session.root.path,
    scope = request.scope,
    hidden = request.hidden,
    ignored = request.ignored,
    glob = request.glob,
    base = base,
    generation = session.inventory_generation,
  }, function(result)
    on_entry_done(session, entry, result)
  end, function(paths)
    if session.closed or session.inventories[key] ~= entry then
      return
    end
    vim.list_extend(entry.catalog, paths)
    if key == session.inventory_key then
      pump_files(session)
    end
  end)
  return entry
end

local function ensure_inventory(session)
  local key = inventory_key(session.request)
  session.inventory_key = key
  if not session.inventories[key] then
    build_inventory(session, key, session.request)
  end
  prune_inventories(session, { [key] = true })
  return session.inventories[key].result
end

-- Generations -----------------------------------------------------------

local function stop_work(session)
  session.timer:stop()
  cancel_job(session, "fuzzy")
  cancel_job(session, "grep")
end

---Lookup set of `within`, or nil when the request does not narrow.
local function within_set(within)
  if not within then
    return nil
  end
  local set = {}
  for _, path in ipairs(within) do
    set[path] = true
  end
  return set
end

---Which lanes a request runs. With an empty query, file names list the
---eligible files in the "files" mode or when a glob or `within` narrows
---them; content never runs for an empty query.
local function wanted_lanes(request)
  local query, mode = request.query, request.mode
  local lists = mode == "files" or request.glob ~= nil or request.within ~= nil
  local files = mode ~= "content" and (query ~= "" or lists)
  return files, mode ~= "files" and query ~= ""
end

---An appended subsequence can only narrow an unchanged inventory and
---path restriction. ASCII smart case can only become more restrictive.
local function refined_paths(session, result)
  local prior, request = session.refinement, session.request
  if
    prior
    and result
    and result.generation == prior.generation
    and request.within == prior.within
    and #request.query > #prior.query
    and vim.startswith(request.query, prior.query)
  then
    return prior.paths
  end
end

---Start a new generation: drop all records, then run the wanted lanes.
local function rerun(session)
  stop_work(session)
  session.generation = session.generation + 1
  session.debounced = false
  local request = session.request
  local query = request.query
  local wants_files, wants_content = wanted_lanes(request)
  session.within_set = within_set(request.within)
  session.files = {
    lane = new_lane(wants_files, FILE_LIMIT),
    records = {},
    top = {},
    matched = 0,
    bytes = 0,
    paths = wants_files and query ~= "" and {} or nil,
  }
  session.content = {
    lane = new_lane(wants_content, OCCURRENCE_LIMIT),
    groups = {},
    by_path = {},
    seen = {},
    bytes = 0,
  }
  local result = ensure_inventory(session)
  local input_error = query_error(query)
  if input_error then
    end_lane(session.files, "error", input_error)
    end_lane(session.content, "error", input_error)
  elseif result then
    session.files.rank_paths = refined_paths(session, result)
    on_inventory_ready(session, result)
  else
    pump_files(session)
  end
  if wants_content then
    start_debounce(session)
  end
  changed(session)
end

-- Session ---------------------------------------------------------------

local Session = {}
Session.__index = Session

local function copy_lane(lane)
  return {
    state = lane.state,
    error = lane.error,
    count = lane.count,
    total = math.max(lane.total, lane.count),
    limit = lane.limit,
  }
end

---Current request, lane states, and records of the current generation.
---Records are shared and must not be modified.
---@return IaraSearchSnapshot
function Session:snapshot()
  local groups = {}
  for index, group in ipairs(self.content.groups) do
    groups[index] =
      { path = group.path, records = vim.list_slice(group.records) }
  end
  return {
    request = vim.deepcopy(self.request),
    root = self.root,
    generation = self.generation,
    files = {
      lane = copy_lane(self.files.lane),
      records = vim.list_slice(self.files.records),
    },
    content = { lane = copy_lane(self.content.lane), groups = groups },
  }
end

---Apply request changes. Unchanged values do nothing; `focus` alone does
---not rerun; anything else starts a new generation. `glob = ""` clears
---the glob and `within = false` the path list. Does nothing after
---close().
---@param changes IaraSearchRequest
function Session:update(changes)
  validate_request(changes)
  if self.closed then
    return
  end
  local needs_rerun, differs = false, false
  for key, value in pairs(changes) do
    if value == CLEARS[key] then
      value = nil
    end
    if not vim.deep_equal(self.request[key], value) then
      differs = true
      needs_rerun = needs_rerun or not PRESENTATION_FIELDS[key]
      self.request[key] = vim.deepcopy(value)
    end
  end
  if needs_rerun then
    rerun(self)
  elseif differs then
    changed(self)
  end
end

---Set the single subscriber; changes are coalesced into one scheduled
---call with a fresh snapshot. Nil unsubscribes.
---@param fn fun(snapshot: IaraSearchSnapshot)|nil
function Session:on_change(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("search: on_change expects a function", 2)
  end
  self.subscriber = fn
end

---Request of the directory tree: the root scope under the current
---switches, without a glob.
local function tree_request(request)
  return {
    scope = { kind = "root" },
    hidden = request.hidden,
    ignored = request.ignored,
  }
end

---A finished tree, or the inventory entry still listing it. A complete
---`E` of the root scope serves it at once; otherwise the root walk
---joins the inventory cache (the current inventory is that walk at the
---root scope without a glob).
---@return IaraInventory|nil result
---@return table|nil entry
local function find_tree(session)
  local request = tree_request(session.request)
  local base = reusable_base(session, base_key(request))
  if base then
    return { generation = 0, state = "complete", paths = base.paths }
  end
  local key = inventory_key(request)
  local entry = session.inventories[key]
  if not entry then
    entry = build_inventory(session, key, request)
    local keep = { [key] = true, [session.inventory_key] = true }
    prune_inventories(session, keep)
  end
  return entry.result, entry
end

---(S9) Eligible paths of the whole root under the current hidden and
---ignored switches, without scope, glob, or `within`: the source of the
---directory step. `on_done` runs once, never synchronously, and not
---after close() or cancel().
---@param on_done fun(result: IaraInventory)
---@return { cancel: fun(self) } handle
function Session:tree(on_done)
  if type(on_done) ~= "function" then
    error("search: tree expects a function", 2)
  end
  local handle = { live = true }
  function handle.cancel()
    handle.live = false
  end
  local function deliver(result)
    if handle.live and not self.closed then
      handle.live = false
      on_done(result)
    end
  end
  local result, entry = find_tree(self)
  if result then
    vim.schedule(function()
      deliver(result)
    end)
  else
    table.insert(entry.waiters, deliver)
  end
  return handle
end

---(S10) Files changed on disk (the directory step created, renamed, or
---deleted one): forget every inventory and run the request again, so
---names and content match the disk. Does nothing after close().
function Session:refresh()
  if self.closed then
    return
  end
  if self.shared_inventory then
    inventory_cache.invalidate()
  end
  for _, key in ipairs(vim.list_slice(self.inventory_order)) do
    forget_inventory(self, key)
  end
  rerun(self)
end

local function quickfix_item(record)
  local root = record.root == "/" and "" or record.root
  local item = { filename = root .. "/" .. record.path, text = "" }
  if record.kind == "occurrence" then
    -- Quickfix lines and byte columns are one-based; end_col exclusive.
    -- Columns count buffer bytes, as the picker jump does.
    local location =
      { path = item.filename, row = record.row, disk_bytes = true }
    local start = open.buffer_column(location, record.byte_start)
    local stop = open.buffer_column(location, record.byte_end)
    item.lnum, item.end_lnum = record.row + 1, record.row + 1
    item.col, item.end_col = start + 1, stop + 1
    item.vcol, item.text = 0, record.text or ""
  end
  return item
end

---Export records to a new quickfix list. File records carry no position;
---occurrences open at their line and byte column.
---@param records IaraSearchRecord[]
---@param title string
---@return integer id Quickfix list id.
function Session.to_quickfix(_, records, title)
  if type(records) ~= "table" or type(title) ~= "string" then
    error("search: to_quickfix expects records and a title", 2)
  end
  local items = {}
  for index, record in ipairs(records) do
    items[index] = quickfix_item(record)
  end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  return vim.fn.getqflist({ nr = "$", id = 0 }).id
end

---Cancel all work and stop notifying. Loading lanes become "cancelled";
---snapshot() keeps working for resume. Idempotent.
function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  self.subscriber = nil
  self.refinement = nil
  stop_work(self)
  self.timer:close()
  for _, key in ipairs(vim.list_slice(self.inventory_order)) do
    forget_inventory(self, key)
  end
  for _, holder in ipairs({ self.files, self.content }) do
    if is_loading(holder) then
      end_lane(holder, "cancelled")
    end
  end
end

local function default_request(request)
  local defaults = {
    query = "",
    hidden = false,
    ignored = false,
    regex = false,
    case = "smart",
    scope = { kind = "root" },
  }
  local merged = vim.tbl_extend("force", defaults, vim.deepcopy(request))
  for key, cleared in pairs(CLEARS) do
    if merged[key] == cleared then
      merged[key] = nil
    end
  end
  return merged
end

---Start a search session for `root` and run `request` at once.
---@param request IaraSearchRequest?
---@param root IaraRoot Snapshotted root; never re-resolved.
---@param shared_inventory? boolean Reuse a validated root inventory.
---@return table session Methods: update, snapshot, on_change,
---  to_quickfix, close.
function M.new(request, root, shared_inventory)
  request = request or {}
  validate_request(request)
  if type(root) ~= "table" or type(root.path) ~= "string" then
    error("search: root must be an IaraRoot", 2)
  end
  local session = setmetatable({
    request = default_request(request),
    root = root,
    shared_inventory = shared_inventory,
    generation = 0,
    inventory_generation = 0,
    inventories = {},
    inventory_order = {},
    jobs = {},
    timer = assert(vim.uv.new_timer()),
    -- Snapshotted with the root: the buffers in use when it opened.
    recent = recent.ranks(root.path),
  }, Session)
  rerun(session)
  return session
end

return M
