--- Locate keys by their YAML structure while preserving the path prompt.
local path = require("iara.features.structured.path")

local M = {}
local api = vim.api
local hrtime = vim.uv.hrtime
local KEY_LIMIT = 16384
local DEPTH_LIMIT = 128
local SEQUENCE_STEP_LIMIT = 512
local SLICE_NS = 2e6
local PAIRS = { block_mapping_pair = true, flow_pair = true }
local SEQUENCES = { block_sequence = true, flow_sequence = true }
local CERTAINTY = { complete = true, decoded = true, unique = "yes" }
local SCALARS = {
  plain_scalar = true,
  single_quote_scalar = true,
  double_quote_scalar = true,
}

local key_query, active

local function key_text(bufnr, key)
  local count = key:named_child_count()
  local scalar = count > 0 and key:named_child(count - 1) or key
  local kind = scalar:type()
  local _, _, first, _, _, last = scalar:range(true)
  if not SCALARS[kind] or last - first > 4096 then
    return nil
  end
  local text = vim.treesitter.get_node_text(scalar, bufnr)
  if kind == "plain_scalar" then
    return text
  end
  if kind == "single_quote_scalar" then
    return (text:sub(2, -2):gsub("''", "'"))
  end
  if kind == "double_quote_scalar" then
    return path.decode_json_string(text)
  end
end

---Advance each sequence once as keys inside later entries are visited.
local function sequence_index(run, sequence, item)
  local id = item:id()
  if run.indices[id] ~= nil then
    return run.indices[id]
  end
  local sequence_id = sequence:id()
  local scan = run.sequences[sequence_id]
  if not scan then
    scan = { next = sequence:named_child(0), index = 0 }
    run.sequences[sequence_id] = scan
  end
  for _ = 1, SEQUENCE_STEP_LIMIT do
    local child = scan.next
    if not child then
      return nil
    end
    scan.next = child:next_named_sibling()
    if child:type() ~= "comment" then
      local index = scan.index
      scan.index = scan.index + 1
      if child == item then
        run.indices[id] = index
        return index
      end
    end
  end
  run.limited = true
end

local function append_segments(run, segments, node, parent)
  if PAIRS[node:type()] then
    local key = node:field("key")[1]
    local value = key and key_text(run.bufnr, key)
    if not value then
      return false
    end
    segments[#segments + 1] = { kind = "key", value = value }
  end
  -- A flow pair can itself be an entry of a flow sequence.
  if parent and SEQUENCES[parent:type()] then
    local value = sequence_index(run, parent, node)
    if value == nil then
      return false
    end
    segments[#segments + 1] = { kind = "index", value = value }
  end
  return true
end

local function key_path(run, key)
  local segments = {}
  local node = key:parent()
  for _ = 1, DEPTH_LIMIT do
    if not node then
      return path.breadcrumb({
        document = 1,
        segments = vim.fn.reverse(segments),
        certainty = CERTAINTY,
      }, 65536)
    end
    local parent = node:parent()
    if not append_segments(run, segments, node, parent) then
      return nil
    end
    node = parent
  end
  run.limited = true
end

local function current(run)
  if active ~= run then
    return false
  end
  if
    api.nvim_get_current_win() == run.win
    and api.nvim_win_get_buf(run.win) == run.bufnr
    and api.nvim_buf_get_changedtick(run.bufnr) == run.tick
  then
    return true
  end
  active = nil
  return false
end

local function finish(run, key)
  active = nil
  if key then
    local row, col = key:start()
    api.nvim_win_set_cursor(0, { row + 1, col })
  elseif run.limited then
    run.fail("YAML search reached its scan limit")
  else
    run.fail(("YAML key not found: %s"):format(run.query))
  end
end

local function match_key(run, key)
  if run.bare and key_text(run.bufnr, key) ~= run.query then
    return false
  end
  if key_path(run, key) == run.query then
    return true
  end
  if run.bare then
    run.fallback = run.fallback or key
  end
  return false
end

local function scan_keys(run)
  if not current(run) then
    return
  end
  local deadline = hrtime() + SLICE_NS
  for _ = 1, 128 do
    local _, key = run.keys()
    if not key then
      return finish(run, run.fallback)
    end
    run.count = run.count + 1
    if run.count > KEY_LIMIT then
      run.limited = true
      return finish(run, run.fallback)
    end
    if match_key(run, key) then
      return finish(run, key)
    end
    if hrtime() >= deadline then
      break
    end
  end
  vim.schedule(function()
    scan_keys(run)
  end)
end

local function parsed(run, err, trees)
  if not current(run) then
    return
  end
  if err or not trees or not trees[1] then
    active = nil
    return run.fail("could not parse YAML: " .. tostring(err or "no tree"))
  end
  run.keys = key_query:iter_captures(trees[1]:root(), run.bufnr)
  scan_keys(run)
end

---Jump to a key name or a dotted path, with zero-based sequence indexes.
---@param bufnr integer
---@param query string
---@param on_error fun(message: string)
function M.jump(bufnr, query, on_error)
  active = nil
  local parser = vim.treesitter.get_parser(bufnr, "yaml", { error = false })
  if not parser then
    return on_error("YAML parser is unavailable")
  end
  key_query = key_query
    or vim.treesitter.query.parse(
      "yaml",
      [[
    (block_mapping_pair key: (_) @key)
    (flow_pair key: (_) @key)
  ]]
    )
  local run = {
    bufnr = bufnr,
    win = api.nvim_get_current_win(),
    tick = api.nvim_buf_get_changedtick(bufnr),
    query = query,
    bare = not query:find('[.%[%]"%z]'),
    fail = on_error,
    count = 0,
    sequences = {},
    indices = {},
  }
  active = run
  parser:parse(
    nil,
    vim.schedule_wrap(function(err, trees)
      parsed(run, err, trees)
    end)
  )
end

return M
