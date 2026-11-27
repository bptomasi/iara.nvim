--- JSON target extraction from the current buffer text with Tree-sitter.
---
--- One asynchronous parse runs per buffer; it serves only the latest
--- cursor intent and the latest index intent, and older intents complete
--- as "stale" (targets) or "cancelled" (indexes). The parse callback is
--- the only completion path, and a 250 ms watchdog abandons publication
--- when it does not arrive and suspends the buffer: later requests are
--- refused with "watchdog" until an explicit `retry`. Results are
--- checked against the requesting changedtick before any extraction.
--- Traversals are iterative and capped (ARCH, Structured paths);
--- grammar acceptance is treated as recovery, so several top-level values
--- get recovery roots and ERROR subtrees make paths incomplete instead
--- of invented.
--- See contracts.md, section `iara.features.structured.json`.
local path = require("iara.features.structured.path")
local eligibility = require("iara.core.eligibility")

local M = {}

local api, uv = vim.api, vim.uv

local WATCHDOG_MS = 250
local MAX_SEGMENTS = 128
local MAX_SIBLING_VISITS = 2048
local MAX_PATH_BYTES = 16 * 1024
local MAX_RAW_KEY_BYTES = 4 * 1024
local MAX_ENTRIES = 10000
local MAX_PAYLOAD_BYTES = 8 * 1024 * 1024
local BATCH_NODES = 256
local BATCH_NS = 2 * 1000 * 1000
-- Rough accounting of retained index memory per target and per segment.
local ENTRY_OVERHEAD = 128
local SEGMENT_OVERHEAD = 32

local VALUE_TYPES = {
  object = true,
  array = true,
  string = true,
  number = true,
  ["true"] = true,
  ["false"] = true,
  null = true,
}
local CONTAINERS = { object = true, array = true }
local UNIQUE_RANK = { yes = 1, unverified = 2, no = 3 }

---@param code string
---@param message string
---@return IaraError
local function failure(code, message)
  return { code = code, message = message }
end

-- Requests -----------------------------------------------------------------

---@class IaraJsonRequest
---@field bufnr integer
---@field tick integer changedtick when the request was made.
---@field kind "target"|"index"
---@field done boolean The completion callback has been scheduled.
---@field complete fun(...) Caller's completion callback.
---@field fail fun(err: IaraError)
---@field supersede fun() A newer intent of the same kind replaces it.
---@field cancel fun()
---@field run fun(tree: TSTree, generation: integer)

---Schedule the completion callback, at most once per request.
local function deliver(request, ...)
  if request.done then
    return
  end
  request.done = true
  local args = vim.F.pack_len(...)
  vim.schedule(function()
    request.complete(vim.F.unpack_len(args))
  end)
end

-- Buffer parse state -------------------------------------------------------

---@class IaraJsonBufferState
---@field generation integer Parse generation, increasing per parse.
---@field parsing integer|nil Generation of the parse in flight.
---@field timer uv.uv_timer_t|nil Watchdog of the parse in flight.
---@field waiting table<string, IaraJsonRequest> Latest intent per kind.
---@field walk IaraJsonRequest|nil Index currently being enumerated.
---@field suspended string|nil Why automatic parses are suspended.

---@type table<integer, IaraJsonBufferState>
local buffers = {}
local group = nil

local function stop_watchdog(state)
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function fail_waiting(state, err)
  local waiting = state.waiting
  state.waiting = {}
  for _, request in pairs(waiting) do
    request.fail(err)
  end
end

---Drop every owned timer and request of a buffer, without waiting for a
---parse callback that may never arrive.
local function release(bufnr, reason)
  local state = buffers[bufnr]
  if not state then
    return
  end
  buffers[bufnr] = nil
  state.parsing = nil
  stop_watchdog(state)
  local err = failure("stale", reason)
  fail_waiting(state, err)
  if state.walk then
    state.walk.fail(err)
    state.walk = nil
  end
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  end
end

---A buffer that leaves the "eligible" state drops its parse and index
---at once instead of waiting for a callback.
local function on_eligibility(args)
  local data = args.data or {}
  if buffers[data.bufnr] and data.state ~= "eligible" then
    release(data.bufnr, "buffer is no longer eligible")
  end
end

local function ensure_group()
  if group then
    return group
  end
  group = api.nvim_create_augroup("IaraStructuredJson", { clear = true })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for bufnr in pairs(buffers) do
        release(bufnr, "Neovim is exiting")
      end
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = on_eligibility,
  })
  return group
end

local function ensure_state(bufnr)
  local state = buffers[bufnr]
  if state then
    return state
  end
  state = { generation = 0, waiting = {} }
  buffers[bufnr] = state
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout", "FileType" }, {
    group = ensure_group(),
    buffer = bufnr,
    callback = function()
      release(bufnr, "buffer unloaded or filetype changed")
    end,
  })
  return state
end

-- Parsing ------------------------------------------------------------------

local function acquire_parser(bufnr)
  local ok, parser =
    pcall(vim.treesitter.get_parser, bufnr, "json", { error = false })
  if ok and parser then
    return parser
  end
  return nil, failure("no_parser", "JSON Tree-sitter parser is unavailable")
end

-- The JSON grammar's root is `document`, or ERROR when recovery fails.
local function is_json_tree(tree)
  local kind = tree and tree:root():type()
  return kind == "document" or kind == "ERROR"
end

local start_parse

local RETRY_HINT = "; run :IaraStructuredRetry to try again"

---Abandon the parse in flight and refuse later requests until `retry`.
---The parser itself is not interrupted; its late callback is ignored.
local function suspend(state, message)
  state.parsing = nil
  stop_watchdog(state)
  state.suspended = message .. RETRY_HINT
  fail_waiting(state, failure("watchdog", state.suspended))
end

---@class IaraJsonParsed
---@field err string|nil Parse error ("TIMEOUT" from Tree-sitter).
---@field tree TSTree|nil
---@field tick integer changedtick when the parse completed.

---Serve one request from a finished parse, or re-queue it when the tree
---was produced for older text. The changedtick recorded at completion
---decides, not `LanguageTree:is_valid()`: after a paste it stayed false
---while every parse completed at once, which re-queued forever and kept
---re-arming the watchdog (M2-D growing-buffer measurement).
---@param parsed IaraJsonParsed
local function serve(bufnr, state, request, parsed)
  if request.done then
    return
  end
  if api.nvim_buf_get_changedtick(bufnr) ~= request.tick then
    return request.fail(failure("stale", "Buffer changed during the parse"))
  end
  if not is_json_tree(parsed.tree) then
    return request.fail(failure("no_parser", "Unexpected JSON grammar"))
  end
  if parsed.tick ~= request.tick then
    state.waiting[request.kind] = request
    return
  end
  request.run(parsed.tree, state.generation)
end

---@param parsed IaraJsonParsed
local function on_parsed(bufnr, state, generation, parsed)
  if buffers[bufnr] ~= state or state.parsing ~= generation then
    return
  end
  state.parsing = nil
  stop_watchdog(state)
  if parsed.err == "TIMEOUT" then
    return suspend(state, "JSON parse exceeded 'redrawtime'")
  end
  if parsed.err then
    return fail_waiting(state, failure("no_parser", "JSON parse failed"))
  end
  local waiting = state.waiting
  state.waiting = {}
  for _, kind in ipairs({ "target", "index" }) do
    if waiting[kind] then
      serve(bufnr, state, waiting[kind], parsed)
    end
  end
  if next(state.waiting) then
    start_parse(bufnr, state)
  end
end

local function arm_watchdog(bufnr, state, generation)
  local timer = assert(uv.new_timer())
  state.timer = timer
  timer:start(
    WATCHDOG_MS,
    0,
    vim.schedule_wrap(function()
      if buffers[bufnr] ~= state or state.parsing ~= generation then
        return
      end
      suspend(state, "JSON parse exceeded 250 ms; result abandoned")
    end)
  )
end

---In-flight state exists before the protected parse call, whose callback
---may run synchronously; the callback is the only completion path.
start_parse = function(bufnr, state)
  local parser, err = acquire_parser(bufnr)
  if not parser then
    return fail_waiting(state, err)
  end
  state.generation = state.generation + 1
  local generation = state.generation
  state.parsing = generation
  arm_watchdog(bufnr, state, generation)
  local ok = pcall(parser.parse, parser, nil, function(parse_err, trees)
    local parsed = {
      err = parse_err,
      tree = trees and trees[1],
      tick = api.nvim_buf_is_valid(bufnr)
        and api.nvim_buf_get_changedtick(bufnr),
    }
    vim.schedule(function()
      on_parsed(bufnr, state, generation, parsed)
    end)
  end)
  if not ok then
    local parsed = { err = "parse raised an error", tick = -1 }
    vim.schedule(function()
      on_parsed(bufnr, state, generation, parsed)
    end)
  end
end

---Admit a request: cheap eligibility check before parser acquisition,
---then keep it as the latest intent of its kind.
local function submit(request)
  local bufnr = request.bufnr
  local verdict = eligibility.check(bufnr)
  if verdict.state ~= "eligible" then
    local message = verdict.message or "buffer is not eligible"
    return request.fail(failure("ineligible", message))
  end
  local state = ensure_state(bufnr)
  if state.suspended then
    return request.fail(failure("watchdog", state.suspended))
  end
  local previous = state.waiting[request.kind]
  if previous then
    previous.supersede()
  end
  if request.kind == "index" and state.walk then
    state.walk.supersede()
    state.walk = nil
  end
  state.waiting[request.kind] = request
  if not state.parsing then
    start_parse(bufnr, state)
  end
end

local function new_request(bufnr, kind, complete)
  return {
    bufnr = bufnr,
    tick = api.nvim_buf_get_changedtick(bufnr),
    kind = kind,
    done = false,
    complete = complete,
  }
end

---Forget a cancelled request. A parse that no request waits for any
---more is abandoned with its watchdog, without suspending the buffer.
local function withdraw(request)
  local state = buffers[request.bufnr]
  if not state then
    return
  end
  if state.waiting[request.kind] == request then
    state.waiting[request.kind] = nil
  end
  if state.walk == request then
    state.walk = nil
  end
  if state.parsing and next(state.waiting) == nil then
    state.parsing = nil
    stop_watchdog(state)
  end
end

local function handle_for(request)
  return {
    cancel = function(_)
      if not request.done then
        withdraw(request)
        request.cancel()
      end
    end,
  }
end

---Lift a watchdog suspension so that the next request makes one more
---parse attempt, itself bounded by the 250 ms watchdog.
---@param bufnr integer 0 for the current buffer.
---@return boolean lifted False when the buffer was not suspended.
function M.retry(bufnr)
  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  local state = buffers[bufnr]
  if not state or not state.suspended then
    return false
  end
  state.suspended = nil
  return true
end

---Owned state of a buffer, nil when nothing is held (for health checks
---and tests).
---@param bufnr integer 0 for the current buffer.
---@return { parsing: boolean, watchdog: boolean, suspended: string|nil,
---  waiting: string[], indexing: boolean }|nil
function M.status(bufnr)
  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  local state = buffers[bufnr]
  if not state then
    return nil
  end
  local waiting = vim.tbl_keys(state.waiting)
  table.sort(waiting)
  return {
    parsing = state.parsing ~= nil,
    watchdog = state.timer ~= nil,
    suspended = state.suspended,
    waiting = waiting,
    indexing = state.walk ~= nil,
  }
end

-- Shared node helpers ------------------------------------------------------

local function node_range(node)
  if not node then
    return nil
  end
  local start_row, start_col, end_row, end_col = node:range()
  return { start_row, start_col, end_row, end_col }
end

local function field(node, name)
  return node:field(name)[1]
end

-- Raw key text that decodes to itself: no escape, no control character.
local PLAIN_KEY = '^"[^%z\1-\31\\"]*"$'

---Decoded key, or the raw text between quotes when decoding fails. The
---raw length is checked before any text is read; plain keys skip the
---decoder.
---@return string key, boolean decoded
local function read_key(bufnr, key_node)
  if not key_node or key_node:missing() then
    return "", false
  end
  if key_node:byte_length() > MAX_RAW_KEY_BYTES then
    return "", false
  end
  local raw = vim.treesitter.get_node_text(key_node, bufnr)
  if raw:find(PLAIN_KEY) then
    return raw:sub(2, -2), true
  end
  local decoded = path.decode_json_string(raw, MAX_RAW_KEY_BYTES)
  if decoded then
    return decoded, true
  end
  return raw:sub(2, -2), false
end

---A pair whose key, separator, or value had to be recovered.
local function is_broken_pair(pair)
  for child in pair:iter_children() do
    if child:type() == "ERROR" or child:missing() then
      return true
    end
  end
  return false
end

local function copy_certainty(certainty)
  return {
    complete = certainty.complete,
    decoded = certainty.decoded,
    unique = certainty.unique,
  }
end

---Next named child from a child iterator; punctuation is skipped
---without counting toward an index batch.
local function next_named(iter)
  local child = iter()
  while child and not child:named() do
    child = iter()
  end
  return child
end

local function weaken(certainty, unique)
  if UNIQUE_RANK[unique] > UNIQUE_RANK[certainty.unique] then
    certainty.unique = unique
  end
end

-- Cursor extraction --------------------------------------------------------

---@class IaraJsonWalk
---@field bufnr integer
---@field budget integer Remaining sibling visits.
---@field segments IaraPathSegment[] Collected from the leaf upward.
---@field path_bytes integer Decoded key bytes in `segments`.
---@field certainty table
---@field document integer|nil
---@field recovery_root integer|nil
---@field unchecked { pair: TSNode, key: string }[] Pairs whose
---  uniqueness is checked after the structural climb.

---Spend one sibling visit; false once the budget is exhausted.
---Punctuation tokens are not siblings and cost nothing.
local function spend(walk, sibling)
  if not sibling:named() then
    return true
  end
  if walk.budget <= 0 then
    return false
  end
  walk.budget = walk.budget - 1
  return true
end

---Key node of a pair; the first named child unless recovery moved it.
local function pair_key(pair)
  local first = pair:named_child(0)
  if first and first:type() == "string" then
    return first
  end
  return field(pair, "key")
end

---Whether a key node decodes to `key`. Decoded keys are never longer
---than their raw text, so shorter raw keys are rejected unread, and plain
---raw keys (the common case) are compared without decoding.
local function decodes_to(bufnr, node, key)
  local length = node:byte_length() - 2
  if length < #key or length + 2 > MAX_RAW_KEY_BYTES then
    return false
  end
  local raw = vim.treesitter.get_node_text(node, bufnr)
  if length == #key and raw:find(PLAIN_KEY) then
    return raw:sub(2, -2) == key
  end
  local text, decoded = read_key(bufnr, node)
  return decoded and text == key
end

---Whether another pair of `pair`'s object decodes to the same key.
local function sibling_uniqueness(walk, pair, key)
  for sibling in pair:parent():iter_children() do
    if not spend(walk, sibling) then
      return "unverified"
    end
    local other = sibling:type() == "pair" and pair_key(sibling)
    if other and not sibling:equal(pair) then
      if decodes_to(walk.bufnr, other, key) then
        return "no"
      end
    end
  end
  return "yes"
end

local function push_segment(walk, segment)
  local bytes = segment.kind == "key" and #segment.value or 0
  if
    #walk.segments >= MAX_SEGMENTS
    or walk.path_bytes + bytes > MAX_PATH_BYTES
  then
    walk.certainty.complete = false
    return false
  end
  walk.segments[#walk.segments + 1] = segment
  walk.path_bytes = walk.path_bytes + bytes
  return true
end

local function climb_pair(walk, pair)
  local key, decoded = read_key(walk.bufnr, field(pair, "key"))
  if is_broken_pair(pair) then
    walk.certainty.complete = false
  end
  if not push_segment(walk, { kind = "key", value = key }) then
    return nil
  end
  local parent = pair:parent()
  if not decoded then
    walk.certainty.decoded = false
    weaken(walk.certainty, "unverified")
  elseif parent:type() == "object" then
    walk.unchecked[#walk.unchecked + 1] = { pair = pair, key = key }
  end
  return parent
end

---Zero-based element index, skipping comments; nil over the budget.
local function element_index(walk, node)
  local index = 0
  for sibling in node:parent():iter_children() do
    if sibling:equal(node) then
      return index
    end
    if not spend(walk, sibling) then
      return nil
    end
    local kind = sibling:type()
    if kind == "ERROR" then
      walk.certainty.complete = false
    elseif VALUE_TYPES[kind] then
      index = index + 1
    end
  end
end

---Document 1, plus a recovery-root ordinal when the grammar recovered
---several top-level values.
local function root_identity(walk, node)
  local ordinal, total = nil, 0
  for sibling in node:parent():iter_children() do
    if not spend(walk, sibling) then
      walk.certainty.complete = false
      return
    end
    local kind = sibling:type()
    if kind == "ERROR" then
      walk.certainty.complete = false
    elseif VALUE_TYPES[kind] then
      total = total + 1
      ordinal = sibling:equal(node) and total or ordinal
    end
  end
  walk.document = 1
  walk.recovery_root = total > 1 and ordinal or nil
end

---Index of an array element. An unknown exact index is never guessed:
---the deeper segments are dropped and the path ends at the array.
local function climb_element(walk, node)
  local index = element_index(walk, node)
  if index == nil then
    walk.certainty.complete = false
    walk.segments, walk.path_bytes, walk.unchecked = {}, 0, {}
    return node:parent()
  end
  if not push_segment(walk, { kind = "index", value = index }) then
    return nil
  end
  return node:parent()
end

local function climb_value(walk, node)
  local parent = node:parent()
  local kind = parent and parent:type()
  if kind == "pair" then
    return parent
  end
  if kind == "array" then
    return climb_element(walk, node)
  end
  if kind == "document" then
    root_identity(walk, node)
    return nil
  end
  walk.certainty.complete = false
  return parent
end

---One step toward the root; nil when the walk is finished.
local function climb(walk, node)
  local kind = node:type()
  if kind == "pair" then
    return climb_pair(walk, node)
  end
  if VALUE_TYPES[kind] then
    return climb_value(walk, node)
  end
  -- ERROR or another recovery wrapper: its position is not structural.
  walk.certainty.complete = false
  local parent = node:parent()
  if parent and parent:type() == "document" then
    return nil
  end
  return parent
end

---Innermost pair, or value outside a pair, enclosing the position.
local function find_anchor(root, row, col)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node do
    local kind = node:type()
    if kind == "pair" then
      return node
    end
    local parent = node:parent()
    if VALUE_TYPES[kind] and parent and parent:type() ~= "pair" then
      return node
    end
    node = parent
  end
end

---Uniqueness gets the sibling visits left after the climb, so a wide
---object leaves it "unverified" without making indexes or the document
---identity unknown.
local function check_uniqueness(walk)
  for _, entry in ipairs(walk.unchecked) do
    local unique = sibling_uniqueness(walk, entry.pair, entry.key)
    weaken(walk.certainty, unique)
    if unique == "no" then
      return
    end
  end
end

local function reversed(list)
  local result = {}
  for i = #list, 1, -1 do
    result[#result + 1] = list[i]
  end
  return result
end

local function extract(request, tree, generation, row, col)
  local anchor = find_anchor(tree:root(), row, col)
  if not anchor then
    return nil, failure("no_target", "No JSON value at this position")
  end
  local walk = {
    bufnr = request.bufnr,
    budget = MAX_SIBLING_VISITS,
    segments = {},
    path_bytes = 0,
    certainty = { complete = true, decoded = true, unique = "yes" },
    unchecked = {},
  }
  local node = anchor
  while node do
    node = climb(walk, node)
  end
  check_uniqueness(walk)
  local is_pair = anchor:type() == "pair"
  return {
    bufnr = request.bufnr,
    changedtick = request.tick,
    parser_generation = generation,
    document = walk.document,
    recovery_root = walk.recovery_root,
    segments = reversed(walk.segments),
    key_range = is_pair and node_range(field(anchor, "key")) or nil,
    value_range = node_range(is_pair and field(anchor, "value") or anchor),
    certainty = walk.certainty,
  }
end

local function check_buffer(bufnr)
  if type(bufnr) ~= "number" then
    error("bufnr must be an integer", 3)
  end
  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if not api.nvim_buf_is_valid(bufnr) then
    error("invalid buffer handle", 3)
  end
  return bufnr
end

local function check_position(row, col)
  for _, value in ipairs({ row, col }) do
    if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
      error("row and col must be non-negative integers", 3)
    end
  end
end

---Target under a zero-based row and byte column, from a parse of the
---current (possibly unsaved) buffer text. Completes once, never
---synchronously. A newer request for the same buffer, a cancel, or an
---edit before publication complete this one with "stale".
---Error codes: "ineligible", "stale", "watchdog", "no_parser",
---"no_target".
---@param bufnr integer 0 for the current buffer.
---@param row integer Zero-based row.
---@param col integer Zero-based byte column.
---@param on_done fun(target: IaraStructuredTarget|nil, err: IaraError|nil)
---@return { cancel: fun(self) } handle
function M.target_at(bufnr, row, col, on_done)
  bufnr = check_buffer(bufnr)
  check_position(row, col)
  if type(on_done) ~= "function" then
    error("on_done must be a function", 2)
  end
  local request = new_request(bufnr, "target", on_done)
  function request.fail(err)
    deliver(request, nil, err)
  end
  function request.supersede()
    request.fail(failure("stale", "Superseded by a newer request"))
  end
  function request.cancel()
    request.fail(failure("stale", "Request cancelled"))
  end
  function request.run(tree, generation)
    deliver(request, extract(request, tree, generation, row, col))
  end
  submit(request)
  return handle_for(request)
end

-- Explicit index -----------------------------------------------------------

---@class IaraJsonFrame A container whose children are being enumerated.
---@field node TSNode
---@field kind "document"|"array"|"object"
---@field iter function|nil Child iterator; nil once keys are read.
---@field base table Identity shared by the container's children.
---@field next_index integer Next element ordinal (arrays, document).
---@field uncertain boolean A recovered sibling made later indexes unsure.
---@field multiple boolean|nil Document holds several top-level values.
---@field entries table[] Pairs read so far (objects).
---@field seen table<string, IaraStructuredTarget> Decoded keys (objects).
---@field position integer Next pair to descend into (objects).

---@class IaraJsonIndexJob
---@field request IaraJsonRequest
---@field state IaraJsonBufferState
---@field generation integer
---@field stack IaraJsonFrame[]
---@field targets IaraStructuredTarget[]
---@field payload integer Accounted bytes.
---@field partial boolean A cap left part of the buffer unindexed.

local function push_frame(job, node, base)
  job.stack[#job.stack + 1] = {
    node = node,
    kind = node:type(),
    iter = node:iter_children(),
    base = base,
    next_index = 0,
    uncertain = false,
    entries = {},
    seen = {},
    position = 0,
  }
end

---Whether the document holds more than one top-level value.
local function has_several_roots(document)
  local total = 0
  for child in document:iter_children() do
    if VALUE_TYPES[child:type()] then
      total = total + 1
      if total > 1 then
        return true
      end
    end
  end
  return false
end

local function child_base(frame, ordinal)
  local base = frame.base
  local certainty = copy_certainty(base.certainty)
  certainty.complete = certainty.complete and not frame.uncertain
  local child = {
    document = base.document,
    recovery_root = base.recovery_root,
    segments = base.segments,
    path_bytes = base.path_bytes,
    cost = base.cost,
    certainty = certainty,
  }
  if frame.kind == "document" then
    child.recovery_root = frame.multiple and ordinal + 1 or nil
  else
    child.segments = vim.list_extend({}, base.segments)
    child.segments[#child.segments + 1] = { kind = "index", value = ordinal }
    child.cost = base.cost + SEGMENT_OVERHEAD
  end
  return child
end

local function step_sequence(job, frame)
  local child = next_named(frame.iter)
  if not child then
    table.remove(job.stack)
    return
  end
  local kind = child:type()
  if kind == "ERROR" then
    frame.uncertain = true
    return
  end
  if not VALUE_TYPES[kind] then
    return
  end
  local ordinal = frame.next_index
  frame.next_index = ordinal + 1
  if not CONTAINERS[kind] then
    return
  end
  local base = child_base(frame, ordinal)
  if #base.segments >= MAX_SEGMENTS then
    job.partial = true
    return
  end
  push_frame(job, child, base)
end

---Retain a target unless a cap is reached; caps end the enumeration.
local function retain(job, target, cost)
  if #job.targets >= MAX_ENTRIES or job.payload + cost > MAX_PAYLOAD_BYTES then
    job.partial, job.stack = true, {}
    return false
  end
  job.payload = job.payload + cost
  job.targets[#job.targets + 1] = target
  return true
end

---@param nodes { key: TSNode|nil, value: TSNode|nil }
local function pair_target(job, frame, pair, nodes, key, decoded)
  local base = frame.base
  local certainty = copy_certainty(base.certainty)
  certainty.complete = certainty.complete and not is_broken_pair(pair)
  certainty.decoded = certainty.decoded and decoded
  if not decoded then
    weaken(certainty, "unverified")
  end
  local segments = vim.list_extend({}, base.segments)
  segments[#segments + 1] = { kind = "key", value = key }
  return {
    bufnr = job.request.bufnr,
    changedtick = job.request.tick,
    parser_generation = job.generation,
    document = base.document,
    recovery_root = base.recovery_root,
    segments = segments,
    key_range = node_range(nodes.key),
    value_range = node_range(nodes.value),
    certainty = certainty,
  }
end

---Duplicates at this object are found before any child is entered, so
---descendants inherit the ambiguity of every duplicated ancestor.
local function mark_duplicate(frame, target, key)
  local first = frame.seen[key]
  if not first then
    frame.seen[key] = target
    return
  end
  first.certainty.unique = "no"
  target.certainty.unique = "no"
end

local function read_pair(job, frame, pair)
  local nodes = { key = pair_key(pair), value = field(pair, "value") }
  local key, decoded = read_key(job.request.bufnr, nodes.key)
  local base = frame.base
  local path_bytes = base.path_bytes + #key
  if #base.segments >= MAX_SEGMENTS or path_bytes > MAX_PATH_BYTES then
    job.partial = true
    return
  end
  local target = pair_target(job, frame, pair, nodes, key, decoded)
  local cost = base.cost + SEGMENT_OVERHEAD + #key
  if not retain(job, target, ENTRY_OVERHEAD + cost) then
    return
  end
  if decoded then
    mark_duplicate(frame, target, key)
  end
  frame.entries[#frame.entries + 1] = {
    value = nodes.value,
    base = {
      document = target.document,
      recovery_root = target.recovery_root,
      segments = target.segments,
      path_bytes = path_bytes,
      cost = cost,
      certainty = target.certainty,
    },
  }
end

local function step_object(job, frame)
  if frame.iter then
    local child = next_named(frame.iter)
    if not child then
      frame.iter = nil
    elseif child:type() == "pair" then
      read_pair(job, frame, child)
    end
    return
  end
  frame.position = frame.position + 1
  local entry = frame.entries[frame.position]
  if not entry then
    table.remove(job.stack)
    return
  end
  if entry.value and CONTAINERS[entry.value:type()] then
    push_frame(job, entry.value, entry.base)
  end
end

local function by_position(a, b)
  local x, y = a.key_range, b.key_range
  if x[1] ~= y[1] then
    return x[1] < y[1]
  end
  return x[2] < y[2]
end

local function finish_index(job)
  local state = job.state
  if state.walk == job.request then
    state.walk = nil
  end
  table.sort(job.targets, by_position)
  if job.partial then
    for _, target in ipairs(job.targets) do
      weaken(target.certainty, "unverified")
    end
  end
  deliver(job.request, {
    state = job.partial and "partial" or "complete",
    targets = job.targets,
  })
end

local function is_current(job)
  local request = job.request
  return not request.done
    and buffers[request.bufnr] == job.state
    and api.nvim_buf_get_changedtick(request.bufnr) == request.tick
end

---Enumerate at most 256 nodes or about 2 ms, then yield to the loop.
local function run_batch(job)
  if job.request.done then
    return
  end
  if not is_current(job) then
    return job.request.fail(failure("stale", "Buffer changed"))
  end
  local started = uv.hrtime()
  for _ = 1, BATCH_NODES do
    local frame = job.stack[#job.stack]
    if not frame then
      return finish_index(job)
    end
    if frame.kind == "object" then
      step_object(job, frame)
    else
      step_sequence(job, frame)
    end
    if uv.hrtime() - started > BATCH_NS then
      break
    end
  end
  vim.schedule(function()
    run_batch(job)
  end)
end

local function start_index(request, tree, generation)
  local state = buffers[request.bufnr]
  state.walk = request
  local job = {
    request = request,
    state = state,
    generation = generation,
    stack = {},
    targets = {},
    payload = 0,
    partial = false,
  }
  local root = tree:root()
  if root:type() == "document" then
    push_frame(job, root, {
      document = 1,
      segments = {},
      path_bytes = 0,
      cost = 0,
      certainty = { complete = true, decoded = true, unique = "yes" },
    })
    job.stack[1].multiple = has_several_roots(root)
  end
  vim.schedule(function()
    run_batch(job)
  end)
end

---Explicit bounded index of every key target of the current (possibly
---unsaved) buffer text, in source order. Work yields every 256 nodes or
---about 2 ms. At most 10,000 targets and 8 MiB of accounted payload are
---retained; reaching a cap gives state "partial", where uniqueness is
---"unverified". An edit gives state "error" with code "stale"; a newer
---index request or `cancel` gives "cancelled". Other error codes:
---"ineligible", "watchdog", "no_parser".
---@param bufnr integer 0 for the current buffer.
---@param on_done fun(result: { state: "complete"|"partial"|"error"|
---  "cancelled", targets: IaraStructuredTarget[], error: IaraError? })
---@return { cancel: fun(self) } handle
function M.index(bufnr, on_done)
  bufnr = check_buffer(bufnr)
  if type(on_done) ~= "function" then
    error("on_done must be a function", 2)
  end
  local request = new_request(bufnr, "index", on_done)
  function request.fail(err)
    deliver(request, { state = "error", targets = {}, error = err })
  end
  function request.cancel()
    deliver(request, { state = "cancelled", targets = {} })
  end
  request.supersede = request.cancel
  function request.run(tree, generation)
    start_index(request, tree, generation)
  end
  submit(request)
  return handle_for(request)
end

return M
