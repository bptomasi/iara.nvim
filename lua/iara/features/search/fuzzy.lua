--- Fuzzy filename lane: bounded linear scoring and cancellable ranking.
---
--- Matching is a subsequence test. Smart case applies: a query without
--- ASCII uppercase letters matches case-insensitively; otherwise case
--- matters. Only ASCII letters fold; other bytes compare exactly.
---
--- Scoring locates one match window with linear passes over the path:
---
--- 1. Forward: greedily find where the query is first fully matched.
--- 2. Backward: from that end, walk back to the latest possible start,
---    which tightens the window (the fzf v1 approach).
--- 3. Score: walk the window forward again, rewarding each matched byte,
---    consecutive runs, and matches that start a word or path component,
---    and penalizing gaps.
---
--- The forward pass runs on the basename first and repeats on the whole
--- path only when the basename alone cannot match; basename windows earn
--- a bonus. Case folding searches both cases instead of lowercasing the
--- path, so rejecting a candidate allocates nothing. Each query byte is
--- found with plain `find` calls (one per case when folding), which
--- LuaJIT compiles; a character class pattern would abort the trace.
--- The result is not an optimal alignment, but it costs O(path length)
--- and stays predictable. An empty query matches every path with score 0.
---
--- Ranking an empty query lists files (UX1b): paths in `opts.recent`
--- (recently used buffers) come first, by their rank, then the others
--- with fewer path components first, ties by byte-wise path order.
---
--- Ranking keeps a bounded min-heap of the best `limit` candidates
--- (never sorting the whole catalog) and breaks score ties by byte-wise
--- path order. Work runs in batches of at most 128 candidates or 2 ms,
--- yielding to the event loop between batches. Only the latest call to
--- `match` runs: starting a new one cancels the previous one.
local M = {}

local MAX_PATH_BYTES = 4096
local DEFAULT_LIMIT = 200
local BATCH_SIZE = 128
local SLICE_NS = 2e6

local SCORE_MATCH = 16
local BONUS_COMPONENT = 10
local BONUS_WORD = 8
local BONUS_CAMEL = 7
local BONUS_CONSECUTIVE = 6
local BONUS_BASENAME = 20
local PENALTY_GAP_START = 3
local PENALTY_GAP_EXTEND = 1

local SLASH = 0x2F
---Listing score of the most recent path; any recent path beats the
---depth scores (zero or negative) of the others.
local RECENT_SCORE = 1e9
local WORD_SEPARATORS = {
  [0x20] = true, -- space
  [0x2D] = true, -- -
  [0x2E] = true, -- .
  [0x5F] = true, -- _
}

local byte, char, find = string.byte, string.char, string.find
local hrtime = vim.uv.hrtime

---@class IaraFuzzyMatch
---@field path string
---@field score number Higher is better.
---@field positions integer[] Zero-based byte offsets of matched bytes.

---@class IaraFuzzyQuery
---@field patterns string[] Each query byte (lowercased when folding).
---@field uppers (string|false)[] Its uppercase form when folding a letter.
---@field bytes integer[] Query bytes, lowercased when folding.
---@field fold boolean Case-insensitive (smart case found no uppercase).

---Fold an ASCII uppercase byte to lowercase.
local function fold_byte(value)
  if value >= 0x41 and value <= 0x5A then
    return value + 0x20
  end
  return value
end

---@param query string
---@return IaraFuzzyQuery
local function compile(query)
  local fold = not find(query, "%u")
  local patterns, uppers, bytes = {}, {}, {}
  for index = 1, #query do
    local value = byte(query, index)
    local letter = fold_byte(value)
    local folds = fold and letter >= 0x61 and letter <= 0x7A
    patterns[index] = char(folds and letter or value)
    uppers[index] = folds and char(letter - 0x20)
    bytes[index] = fold and letter or value
  end
  return { patterns = patterns, uppers = uppers, bytes = bytes, fold = fold }
end

---First index at or after `init` of query byte `qi` in `path`, or nil.
---Plain finds, rather than lowercasing each path, allocate nothing.
local function find_byte(path, compiled, qi, init)
  local index = find(path, compiled.patterns[qi], init, true)
  local upper = compiled.uppers[qi]
  if not upper then
    return index
  end
  local other = find(path, upper, init, true)
  if other and (not index or other < index) then
    return other
  end
  return index
end

---One-based index of the first byte after the last slash.
local function basename_start(path)
  for index = #path, 1, -1 do
    if byte(path, index) == SLASH then
      return index + 1
    end
  end
  return 1
end

---Last index of the greedy forward match starting at `from`, or nil.
local function forward_end(path, compiled, from)
  local index = from - 1
  for qi = 1, #compiled.patterns do
    index = find_byte(path, compiled, qi, index + 1)
    if not index then
      return nil
    end
  end
  return index
end

---Latest start index from which the query still matches up to `last`.
local function backward_start(path, query, last)
  local bytes, fold = query.bytes, query.fold
  local qi = #bytes
  for index = last, 1, -1 do
    local value = byte(path, index)
    if (fold and fold_byte(value) or value) == bytes[qi] then
      if qi == 1 then
        return index
      end
      qi = qi - 1
    end
  end
  error("fuzzy: backward pass lost a forward match")
end

---True for an ASCII lowercase letter followed by an uppercase one.
local function is_camel_hump(previous, current)
  local lower_before = previous >= 0x61 and previous <= 0x7A
  return lower_before and current >= 0x41 and current <= 0x5A
end

---Bonus for a match at `index` that starts a component or a word.
local function boundary_bonus(path, index)
  if index == 1 then
    return BONUS_COMPONENT
  end
  local previous = byte(path, index - 1)
  if previous == SLASH then
    return BONUS_COMPONENT
  end
  if WORD_SEPARATORS[previous] then
    return BONUS_WORD
  end
  local current = byte(path, index)
  return is_camel_hump(previous, current) and BONUS_CAMEL or 0
end

---Score adjustment for the distance between two matched indexes.
local function gap_score(distance)
  if distance == 1 then
    return BONUS_CONSECUTIVE
  end
  return -(PENALTY_GAP_START + (distance - 2) * PENALTY_GAP_EXTEND)
end

---Score the greedy match from `first`; fill `positions` when given.
local function score_window(path, compiled, first, positions)
  local score, previous, index = 0, nil, first - 1
  for qi = 1, #compiled.patterns do
    index = find_byte(path, compiled, qi, index + 1)
    score = score + SCORE_MATCH + boundary_bonus(path, index)
    if previous then
      score = score + gap_score(index - previous)
    end
    if positions then
      positions[qi] = index - 1
    end
    previous = index
  end
  return score
end

---Score `path` against a compiled query.
---@param compiled IaraFuzzyQuery
---@param path string
---@param positions integer[]|nil Filled with zero-based offsets if given.
---@return number|nil
local function score_compiled(compiled, path, positions)
  if #path > MAX_PATH_BYTES then
    return nil
  end
  local patterns = compiled.patterns
  if #patterns == 0 then
    return 0
  end
  local bonus, last = BONUS_BASENAME, nil
  local base = basename_start(path)
  if #path - base + 1 >= #patterns then
    last = forward_end(path, compiled, base)
  end
  if not last then
    bonus, last = 0, forward_end(path, compiled, 1)
  end
  if not last then
    return nil
  end
  local first = backward_start(path, compiled, last)
  return bonus + score_window(path, compiled, first, positions)
end

---Pure, bounded linear score. Nil when `path` does not match or exceeds
---4 KiB. (S9) A `positions` table receives the zero-based offsets of the
---matched bytes.
---@param query string
---@param path string
---@param positions integer[]?
---@return number|nil
function M.score(query, path, positions)
  if type(query) ~= "string" or type(path) ~= "string" then
    error("fuzzy.score: query and path must be strings", 2)
  end
  return score_compiled(compile(query), path, positions)
end

-- Ranking -------------------------------------------------------------

---Listing score of `path` for an empty query: recent paths by rank,
---then fewer slashes (shallower paths) first.
---@param recent table<string, integer>
---@param path string
---@return number|nil
local function listing_score(recent, path)
  if #path > MAX_PATH_BYTES then
    return nil
  end
  local rank = recent[path]
  if rank then
    return RECENT_SCORE - rank
  end
  local depth, index = 0, find(path, "/", 1, true)
  while index do
    depth = depth + 1
    index = find(path, "/", index + 1, true)
  end
  return -depth
end

---True when entry `a` ranks before entry `b`.
local function ranks_before(a, b)
  if a.score ~= b.score then
    return a.score > b.score
  end
  return a.path < b.path -- LuaJIT compares strings byte-wise
end

---Restore the heap property upward from `index`; the root is the worst.
local function sift_up(heap, index)
  while index > 1 do
    local parent = math.floor(index / 2)
    if not ranks_before(heap[parent], heap[index]) then
      return
    end
    heap[parent], heap[index] = heap[index], heap[parent]
    index = parent
  end
end

---Restore the heap property downward from the root.
local function sift_down(heap)
  local index, size = 1, #heap
  while true do
    local worst = index
    for child = 2 * index, math.min(2 * index + 1, size) do
      if ranks_before(heap[worst], heap[child]) then
        worst = child
      end
    end
    if worst == index then
      return
    end
    heap[worst], heap[index] = heap[index], heap[worst]
    index = worst
  end
end

-- Reused for comparisons so rejected candidates allocate nothing.
local probe = { path = "", score = 0 }

---Offer a scored path to a heap that keeps the best `limit` entries.
local function heap_offer(heap, limit, path, score)
  if #heap < limit then
    heap[#heap + 1] = { path = path, score = score }
    sift_up(heap, #heap)
    return
  end
  probe.path, probe.score = path, score
  if ranks_before(probe, heap[1]) then
    heap[1].path, heap[1].score = path, score
    sift_down(heap)
  end
end

-- Runs ----------------------------------------------------------------

---@class IaraFuzzyRun
---@field generation integer
---@field query IaraFuzzyQuery
---@field candidates string[]
---@field count integer Candidate count snapshotted at start.
---@field next integer Next candidate index.
---@field limit integer
---@field heap { path: string, score: number }[]
---@field total integer Candidates matched so far, retained or not.
---@field recent table<string, integer>|nil Empty query: listing order.
---@field paths string[]? Every match, until the optional path cap is hit.
---@field path_cap integer? Maximum number of paths to return.
---@field on_done fun(matches: IaraFuzzyMatch[], complete: boolean,
---  total: integer, paths: string[]?)
---@field done boolean

local generation = 0
---@type IaraFuzzyRun|nil
local active = nil
---@type uv.uv_timer_t|nil
local timer = nil

local function is_current(run)
  return not run.done and run.generation == generation
end

---Sorted matches with positions, recomputed only for the retained few.
local function collect(run)
  local entries = run.heap
  table.sort(entries, ranks_before)
  local matches = {}
  for index, entry in ipairs(entries) do
    local positions = {}
    score_compiled(run.query, entry.path, positions)
    matches[index] =
      { path = entry.path, score = entry.score, positions = positions }
  end
  return matches
end

---Mark `run` finished and report it. Runs at most once per run.
local function finish(run, complete)
  if run.done then
    return
  end
  run.done = true
  if active == run then
    active = nil
  end
  run.on_done(collect(run), complete, run.total, complete and run.paths or nil)
end

---Cancel `run`, reporting asynchronously with `complete = false`.
local function cancel(run)
  if not is_current(run) then
    return
  end
  run.generation = -1 -- stale from now on
  if active == run then
    active = nil
  end
  vim.schedule(function()
    finish(run, false)
  end)
end

local step

---Run the next batch after the event loop had a chance to poll input.
local function yield(run)
  timer = timer or assert(vim.uv.new_timer())
  timer:start(0, 0, function()
    vim.schedule(function()
      step(run)
    end)
  end)
end

---Keep path membership independently of the ranked heap.
local function offer(run, path, score)
  run.total = run.total + 1
  if run.paths then
    if run.total > run.path_cap then
      run.paths = nil
    else
      run.paths[run.total] = path
    end
  end
  heap_offer(run.heap, run.limit, path, score)
end

---Score one batch of at most BATCH_SIZE candidates or SLICE_NS.
---@param run IaraFuzzyRun
function step(run)
  local deadline = hrtime() + SLICE_NS
  local stop = math.min(run.next + BATCH_SIZE - 1, run.count)
  for index = run.next, stop do
    if not is_current(run) then
      return
    end
    local path = run.candidates[index]
    local score = run.recent and listing_score(run.recent, path)
      or score_compiled(run.query, path)
    if score then
      offer(run, path, score)
    end
    run.next = index + 1
    if hrtime() >= deadline then
      break
    end
  end
  if not is_current(run) then
    return
  end
  if run.next > run.count then
    return finish(run, true)
  end
  yield(run)
end

---@param query any
---@param candidates any
---@param opts any
local function validate(query, candidates, opts)
  if type(query) ~= "string" then
    error("fuzzy.match: query must be a string", 3)
  end
  if type(candidates) ~= "table" then
    error("fuzzy.match: candidates must be a list of paths", 3)
  end
  if type(opts) ~= "table" or type(opts.on_done) ~= "function" then
    error("fuzzy.match: opts.on_done must be a function", 3)
  end
  if opts.recent ~= nil and type(opts.recent) ~= "table" then
    error("fuzzy.match: opts.recent must be a table of path ranks", 3)
  end
  local limit = opts.limit
  local valid = type(limit) == "number" and limit >= 1 and limit % 1 == 0
  if limit ~= nil and not valid then
    error("fuzzy.match: opts.limit must be a positive integer", 3)
  end
  local cap = opts.path_cap
  if cap ~= nil and (type(cap) ~= "number" or cap < 0 or cap % 1 ~= 0) then
    error("fuzzy.match: opts.path_cap must be a nonnegative integer", 3)
  end
end

---Rank candidates in cancellable batches (<= 128 candidates or 2 ms).
---`on_done` receives at most `limit` (default 200) matches sorted by
---score, ties by byte-wise path order; `complete` is false if cancelled;
---`total` counts every matching candidate scanned, including those the
---limit left out. An empty query ranks a listing: `recent` paths first
---by rank, then fewer path components, then byte-wise order. Starting
---a new match cancels the previous pending one, whose `on_done` then
---receives its provisional matches with `complete = false`. The caller
---must not modify `candidates` until `on_done` runs.
---With `path_cap`, a complete run also returns every matched path in
---input order if the number of matches fits the cap (nil otherwise).
---@param query string
---@param candidates string[] Root-relative paths.
---@param opts { limit: integer?, recent: table<string, integer>?,
---  path_cap: integer?,
---  on_done: fun(matches: IaraFuzzyMatch[], complete: boolean,
---  total: integer, paths: string[]?) }
---@return { cancel: fun(self) } handle
function M.match(query, candidates, opts)
  validate(query, candidates, opts)
  if active then
    cancel(active)
  end
  generation = generation + 1
  local run = {
    generation = generation,
    query = compile(query),
    candidates = candidates,
    count = #candidates,
    next = 1,
    limit = opts.limit or DEFAULT_LIMIT,
    heap = {},
    total = 0,
    path_cap = opts.path_cap,
    paths = opts.path_cap ~= nil and {} or nil,
    recent = query == "" and (opts.recent or {}) or nil,
    on_done = opts.on_done,
    done = false,
  }
  active = run
  yield(run)
  return {
    cancel = function()
      cancel(run)
    end,
  }
end

return M
