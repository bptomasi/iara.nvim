--- Structured path model: typed segments, canonical Iara paths, display
--- breadcrumbs, and strict JSON string decoding. Pure Lua; no buffer
--- access. Canonical paths are an Iara syntax, not JSONPath or jq.
local M = {}

-- ARCH, Structured paths: traversal caps that also bound copied paths.
local MAX_SEGMENTS = 128
local MAX_DECODED_PATH_BYTES = 16 * 1024
-- ARCH: 4 KiB raw key before extraction.
local DEFAULT_MAX_RAW_BYTES = 4 * 1024
local DEFAULT_MAX_CELLS = 160
local ELLIPSIS = "…"

local UNIQUE_STATES = { yes = true, no = true, unverified = true }

---@param code string
---@param message string
---@return nil, IaraError
local function fail(code, message)
  return nil, { code = code, message = message }
end

local function is_natural(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function is_ordinal(value)
  return value == nil or (is_natural(value) and value >= 1)
end

-- Validation ---------------------------------------------------------------

local function check_segment(segment, position)
  local ok = type(segment) == "table"
    and (
      (segment.kind == "key" and type(segment.value) == "string")
      or (segment.kind == "index" and is_natural(segment.value))
    )
  if not ok then
    error(("invalid path segment at position %d"):format(position), 3)
  end
end

local function check_certainty(certainty)
  local ok = type(certainty) == "table"
    and type(certainty.complete) == "boolean"
    and type(certainty.decoded) == "boolean"
    and UNIQUE_STATES[certainty.unique] ~= nil
  if not ok then
    error("invalid target certainty", 3)
  end
end

-- Raises at the public caller's level for malformed targets.
local function check_target(target)
  if type(target) ~= "table" or type(target.segments) ~= "table" then
    error("target must be a table with a segments list", 3)
  end
  if not is_ordinal(target.document) then
    error("target.document must be a positive integer or nil", 3)
  end
  if not is_ordinal(target.recovery_root) then
    error("target.recovery_root must be a positive integer or nil", 3)
  end
  check_certainty(target.certainty)
  for position, segment in ipairs(target.segments) do
    check_segment(segment, position)
  end
end

-- Rendering ----------------------------------------------------------------

-- Short escapes match JSON.stringify; other controls use lowercase \u00xx.
local JSON_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}
for byte = 0, 31 do
  local char = string.char(byte)
  JSON_ESCAPES[char] = JSON_ESCAPES[char] or ("\\u%04x"):format(byte)
end

local NEEDS_ESCAPE = '[%z\1-\31"\\]'

---@param key string
---@return string
local function quote_key(key)
  return '"' .. key:gsub(NEEDS_ESCAPE, JSON_ESCAPES) .. '"'
end

local function root_label(target)
  local label = ("doc[%d]"):format(target.document)
  if target.recovery_root then
    label = label .. ("/root[%d]"):format(target.recovery_root)
  end
  return label
end

local function canonical_segment(segment)
  if segment.kind == "index" then
    return ("[%d]"):format(segment.value)
  end
  return "[" .. quote_key(segment.value) .. "]"
end

local function decoded_path_bytes(segments)
  local total = 0
  for _, segment in ipairs(segments) do
    if segment.kind == "key" then
      total = total + #segment.value
    end
  end
  return total
end

-- Reasons a target has no canonical identity, in order of precedence.
local function refusal(target)
  local certainty = target.certainty
  if not target.document or not certainty.complete then
    return fail("incomplete", "Path is incomplete; use the source location")
  end
  if not certainty.decoded then
    return fail("source_only", "Key cannot be decoded; source location only")
  end
  if certainty.unique == "no" then
    return fail("ambiguous", "Duplicate keys make this path ambiguous")
  end
  local segments = target.segments
  if
    #segments > MAX_SEGMENTS
    or decoded_path_bytes(segments) > MAX_DECODED_PATH_BYTES
  then
    return fail("too_long", "Path exceeds the copy limit; not shortened")
  end
end

---Canonical Iara path, for example `doc[2]::$["server.port"][0][""]`.
---Keys are JSON-escaped bracket strings; indexes are zero-based. A
---recovery root renders as `doc[1]/root[2]::$`. Uniqueness "unverified"
---still renders; callers must disclose it. Never shortened.
---Error codes: "incomplete" (also unknown document ordinal), "ambiguous",
---"too_long" (over 128 segments or 16 KiB of decoded keys),
---"source_only" (undecoded key).
---@param target IaraStructuredTarget
---@return string|nil path
---@return IaraError|nil err
function M.render(target)
  check_target(target)
  local _, err = refusal(target)
  if err then
    return nil, err
  end
  local parts = { root_label(target), "::$" }
  for _, segment in ipairs(target.segments) do
    parts[#parts + 1] = canonical_segment(segment)
  end
  return table.concat(parts)
end

-- Breadcrumb ---------------------------------------------------------------

-- Bare display keys hold only ASCII letters, digits, `_`, `-`, and
-- non-ASCII bytes, so they cannot be confused with separators, indexes,
-- or quoted keys.
local function is_bare_key(key)
  return key:find("^[%w_%-\128-\255]+$") ~= nil
end

local function display_segment(segment, first)
  if segment.kind == "index" then
    return ("[%d]"):format(segment.value)
  end
  local key = segment.value
  local text = is_bare_key(key) and key or quote_key(key)
  return first and text or "." .. text
end

local function display_prefix(target)
  if target.recovery_root then
    return root_label(target) .. ": "
  end
  if target.document == nil then
    return "doc[?]: "
  end
  if target.document > 1 then
    return root_label(target) .. ": "
  end
  return ""
end

local function display_status(certainty)
  if not certainty.complete then
    return " (incomplete)"
  end
  if not certainty.decoded then
    return " (source only)"
  end
  if certainty.unique == "no" then
    return " (ambiguous)"
  end
  return ""
end

-- Keeps the tail, where the current key is, and marks the clipped head.
local function clip_head(text, max_cells)
  if vim.fn.strdisplaywidth(text) <= max_cells then
    return text
  end
  local budget = max_cells - vim.fn.strdisplaywidth(ELLIPSIS)
  local start = #text + 1
  while start > 1 do
    local char_start = start - 1 + vim.str_utf_start(text, start - 1)
    local width = vim.fn.strdisplaywidth(text:sub(char_start, start - 1))
    if width > budget then
      break
    end
    budget = budget - width
    start = char_start
  end
  return ELLIPSIS .. text:sub(start)
end

---Compact display breadcrumb such as `server."a.b"[0].port`, with a
---document or recovery-root label when needed and a certainty suffix.
---Clipped at the head to `max_cells` display cells. Never use it to copy
---or locate a node.
---@param target IaraStructuredTarget
---@param max_cells integer? Default 160.
---@return string
function M.breadcrumb(target, max_cells)
  check_target(target)
  max_cells = max_cells or DEFAULT_MAX_CELLS
  if not is_natural(max_cells) or max_cells < 1 then
    error("max_cells must be a positive integer", 2)
  end
  local parts = { display_prefix(target) }
  for position, segment in ipairs(target.segments) do
    parts[#parts + 1] = display_segment(segment, position == 1)
  end
  if #target.segments == 0 then
    parts[#parts + 1] = "$"
  end
  parts[#parts + 1] = display_status(target.certainty)
  return clip_head(table.concat(parts), max_cells)
end

-- JSON string decoding -----------------------------------------------------

local SIMPLE_ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

---@param code_point integer
---@return string
local function utf8_encode(code_point)
  if code_point < 0x80 then
    return string.char(code_point)
  end
  if code_point < 0x800 then
    return string.char(
      0xC0 + math.floor(code_point / 0x40),
      0x80 + code_point % 0x40
    )
  end
  if code_point < 0x10000 then
    return string.char(
      0xE0 + math.floor(code_point / 0x1000),
      0x80 + math.floor(code_point / 0x40) % 0x40,
      0x80 + code_point % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(code_point / 0x40000),
    0x80 + math.floor(code_point / 0x1000) % 0x40,
    0x80 + math.floor(code_point / 0x40) % 0x40,
    0x80 + code_point % 0x40
  )
end

-- Reads `\uXXXX` at `pos` (the backslash). Returns the code unit or nil.
local function read_code_unit(body, pos)
  local hex = body:match("^\\u(%x%x%x%x)", pos)
  return hex and tonumber(hex, 16)
end

-- Decodes the `\u` escape at `pos`, pairing surrogates.
-- Returns decoded text and the next position, or nil and an error.
local function decode_unicode_escape(body, pos)
  local unit = read_code_unit(body, pos)
  if not unit then
    return fail("escape", "Invalid \\u escape in string")
  end
  if unit >= 0xDC00 and unit <= 0xDFFF then
    return fail("surrogate", "Unpaired low surrogate in string")
  end
  if unit < 0xD800 or unit > 0xDBFF then
    return utf8_encode(unit), pos + 6
  end
  local low = read_code_unit(body, pos + 6)
  if not low or low < 0xDC00 or low > 0xDFFF then
    return fail("surrogate", "Unpaired high surrogate in string")
  end
  local code_point = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
  return utf8_encode(code_point), pos + 12
end

-- Decodes the escape at `pos` (the backslash).
local function decode_escape(body, pos)
  local letter = body:sub(pos + 1, pos + 1)
  if letter == "u" then
    return decode_unicode_escape(body, pos)
  end
  local decoded = SIMPLE_ESCAPES[letter]
  if not decoded then
    return fail("escape", "Invalid escape sequence in string")
  end
  return decoded, pos + 2
end

-- Decodes the text between the quotes. Literal bytes at or above 0x20 are
-- kept unchanged: no Unicode normalization, case folding, or replacement.
local function decode_body(body)
  local parts = {}
  local pos = 1
  while true do
    local special = body:find('[%z\1-\31"\\]', pos)
    if not special then
      parts[#parts + 1] = body:sub(pos)
      return table.concat(parts)
    end
    parts[#parts + 1] = body:sub(pos, special - 1)
    local char = body:sub(special, special)
    if char == '"' then
      return fail("escape", "Unescaped quote inside string")
    end
    if char ~= "\\" then
      return fail("control", "Unescaped control character in string")
    end
    local decoded, next_pos_or_err = decode_escape(body, special)
    if not decoded then
      return nil, next_pos_or_err
    end
    parts[#parts + 1] = decoded
    pos = next_pos_or_err
  end
end

---Strict bounded decoding of a JSON string literal including quotes.
---The length check runs before any other work. Error codes: "escape"
---(invalid escape or malformed literal, such as a missing closing quote),
---"control" (raw byte below 0x20, including NUL), "surrogate" (lone or
---misordered surrogate), "too_long" (raw literal over `max_bytes`).
---@param raw string Source text of the literal, quotes included.
---@param max_bytes integer? Raw byte limit, default 4096.
---@return string|nil decoded
---@return IaraError|nil err
function M.decode_json_string(raw, max_bytes)
  if type(raw) ~= "string" then
    error("raw must be a string", 2)
  end
  max_bytes = max_bytes or DEFAULT_MAX_RAW_BYTES
  if not is_natural(max_bytes) then
    error("max_bytes must be a non-negative integer", 2)
  end
  if #raw > max_bytes then
    return fail("too_long", "String literal exceeds the decoding limit")
  end
  if #raw < 2 or raw:sub(1, 1) ~= '"' or raw:sub(-1) ~= '"' then
    return fail("escape", "String literal is not enclosed in quotes")
  end
  return decode_body(raw:sub(2, -2))
end

return M
