local path = require("iara.features.structured.path")

local expect = MiniTest.expect
local eq = expect.equality

local function raises(fn, ...)
  local args = { n = select("#", ...), ... }
  expect.error(function()
    fn(unpack(args, 1, args.n))
  end)
end

local function key(value)
  return { kind = "key", value = value }
end

local function index(value)
  return { kind = "index", value = value }
end

---Target with complete, decoded, unique certainty unless overridden.
local function target(segments, overrides)
  local result = {
    bufnr = 1,
    changedtick = 1,
    parser_generation = 1,
    document = 1,
    segments = segments,
    certainty = { complete = true, decoded = true, unique = "yes" },
  }
  for field, value in pairs(overrides or {}) do
    result[field] = value
  end
  return result
end

local function certainty(complete, decoded, unique)
  return { complete = complete, decoded = decoded, unique = unique }
end

local function render_error_code(t)
  local rendered, err = path.render(t)
  eq(rendered, nil)
  return err.code
end

local function decode_error_code(raw, max_bytes)
  local decoded, err = path.decode_json_string(raw, max_bytes)
  eq(decoded, nil)
  eq(type(err.message), "string")
  return err.code
end

local T = MiniTest.new_set()

-- render ---------------------------------------------------------------------

local render = MiniTest.new_set()
T["render"] = render

render["renders the architecture example exactly"] = function()
  local t = target({ key("server.port"), index(0), key("") }, {
    document = 2,
  })
  eq(path.render(t), 'doc[2]::$["server.port"][0][""]')
end

render["renders the root of a document as doc[1]::$"] = function()
  eq(path.render(target({})), "doc[1]::$")
end

render["starts root array paths with an index"] = function()
  eq(path.render(target({ index(0), key("id") })), 'doc[1]::$[0]["id"]')
end

render["keeps key '0' distinct from index 0"] = function()
  local as_key = path.render(target({ key("0") }))
  local as_index = path.render(target({ index(0) }))
  eq(as_key, 'doc[1]::$["0"]')
  eq(as_index, "doc[1]::$[0]")
end

render["keeps literal dots and brackets inside one key"] = function()
  local literal = path.render(target({ key("a.b"), key("[0]") }))
  local nested = path.render(target({ key("a"), key("b"), index(0) }))
  eq(literal, 'doc[1]::$["a.b"]["[0]"]')
  eq(nested, 'doc[1]::$["a"]["b"][0]')
end

render["renders multi-digit indexes"] = function()
  eq(path.render(target({ index(9), index(10) })), "doc[1]::$[9][10]")
end

render["JSON-escapes quotes, backslashes, and controls"] = function()
  local t = target({ key('say "hi"\\now'), key("\b\f\n\r\t\0\31") })
  local expected = 'doc[1]::$["say \\"hi\\"\\\\now"]'
    .. '["\\b\\f\\n\\r\\t\\u0000\\u001f"]'
  eq(path.render(t), expected)
end

render["keeps multibyte keys as raw UTF-8 without escaping"] = function()
  eq(path.render(target({ key("café😀") })), 'doc[1]::$["café😀"]')
end

render["renders round-trippable keys"] = function()
  local original = 'tab\there "q" \\ \1 é'
  local rendered = path.render(target({ key(original) }))
  local literal = rendered:match("^doc%[1%]::%$%[(.*)%]$")
  eq(path.decode_json_string(literal), original)
  eq(vim.json.decode(literal), original)
end

render["gives recovery roots an explicit identity"] = function()
  local first = path.render(target({ key("a") }, { recovery_root = 1 }))
  local second = path.render(target({ key("a") }, { recovery_root = 2 }))
  eq(first, 'doc[1]/root[1]::$["a"]')
  eq(second, 'doc[1]/root[2]::$["a"]')
end

render["refuses incomplete paths"] = function()
  local t = target({ key("a") }, { certainty = certainty(false, true, "yes") })
  eq(render_error_code(t), "incomplete")
end

render["refuses an unknown document ordinal"] = function()
  local t = target({ key("a") })
  t.document = nil
  eq(render_error_code(t), "incomplete")
end

render["refuses undecoded keys as source only"] = function()
  local t = target({ key("a") }, { certainty = certainty(true, false, "yes") })
  eq(render_error_code(t), "source_only")
end

render["refuses ambiguous paths"] = function()
  local t = target({ key("a") }, { certainty = certainty(true, true, "no") })
  eq(render_error_code(t), "ambiguous")
end

render["still renders when uniqueness is unverified"] = function()
  local t = target({ key("a") }, {
    certainty = certainty(true, true, "unverified"),
  })
  eq(path.render(t), 'doc[1]::$["a"]')
end

render["reports incompleteness before other refusals"] = function()
  local t = target({ key("a") }, { certainty = certainty(false, false, "no") })
  eq(render_error_code(t), "incomplete")
end

render["refuses more than 128 segments instead of shortening"] = function()
  local segments = {}
  for i = 1, 128 do
    segments[i] = index(0)
  end
  eq(type(path.render(target(segments))), "string")
  segments[129] = index(0)
  eq(render_error_code(target(segments)), "too_long")
end

render["refuses more than 16 KiB of decoded keys"] = function()
  local half = string.rep("k", 8 * 1024)
  eq(type(path.render(target({ key(half), key(half) }))), "string")
  eq(render_error_code(target({ key(half), key(half .. "k") })), "too_long")
end

render["raises on malformed targets"] = function()
  local bad_targets = {
    target({ { kind = "key", value = 1 } }),
    target({ { kind = "index", value = -1 } }),
    target({ { kind = "index", value = 1.5 } }),
    target({ { kind = "field", value = "a" } }),
    target({}, { document = 0 }),
    target({}, { recovery_root = 0 }),
    target({}, { certainty = { complete = true, decoded = true } }),
  }
  for _, bad in ipairs(bad_targets) do
    raises(path.render, bad)
  end
  raises(path.render, nil)
end

-- breadcrumb -----------------------------------------------------------------

local breadcrumb = MiniTest.new_set()
T["breadcrumb"] = breadcrumb

breadcrumb["joins simple keys with dots and indexes with brackets"] = function()
  local t = target({ key("servers"), index(0), key("port") })
  eq(path.breadcrumb(t), "servers[0].port")
end

breadcrumb["quotes keys that contain separators or are empty"] = function()
  local t = target({ key("a.b"), key("[0]"), key(""), key('q"') })
  eq(path.breadcrumb(t), '"a.b"."[0]"."".' .. '"q\\""')
end

breadcrumb["keeps key '0' visually distinct from index 0"] = function()
  eq(path.breadcrumb(target({ key("a"), key("0") })), "a.0")
  eq(path.breadcrumb(target({ key("a"), index(0) })), "a[0]")
end

breadcrumb["escapes control characters instead of printing them"] = function()
  eq(path.breadcrumb(target({ key("a\nb") })), '"a\\nb"')
end

breadcrumb["shows multibyte keys bare"] = function()
  eq(path.breadcrumb(target({ key("configuração") })), "configuração")
end

breadcrumb["shows a root array path"] = function()
  eq(path.breadcrumb(target({ index(3), key("id") })), "[3].id")
end

breadcrumb["shows the document root as $"] = function()
  eq(path.breadcrumb(target({})), "$")
end

breadcrumb["labels documents after the first"] = function()
  eq(path.breadcrumb(target({ key("a") }, { document = 2 })), "doc[2]: a")
end

breadcrumb["labels recovery roots and unknown documents"] = function()
  local recovered = target({ key("a") }, { recovery_root = 2 })
  local unknown = target({ key("a") })
  unknown.document = nil
  eq(path.breadcrumb(recovered), "doc[1]/root[2]: a")
  eq(path.breadcrumb(unknown), "doc[?]: a")
end

breadcrumb["marks incomplete, source-only, and ambiguous paths"] = function()
  local function with(c)
    return path.breadcrumb(target({ key("a") }, { certainty = c }))
  end
  eq(with(certainty(false, true, "yes")), "a (incomplete)")
  eq(with(certainty(true, false, "yes")), "a (source only)")
  eq(with(certainty(true, true, "no")), "a (ambiguous)")
  eq(with(certainty(true, true, "unverified")), "a")
end

breadcrumb["clips the head to 160 cells by default"] = function()
  local t = target({ key(string.rep("a", 200)), key("port") })
  local shown = path.breadcrumb(t)
  eq(vim.fn.strdisplaywidth(shown), 160)
  eq(vim.startswith(shown, "…"), true)
  eq(vim.endswith(shown, ".port"), true)
end

breadcrumb["leaves text that fits unchanged"] = function()
  local t = target({ key(string.rep("a", 10)) })
  eq(path.breadcrumb(t, 10), string.rep("a", 10))
end

breadcrumb["never splits multibyte or wide characters"] = function()
  local t = target({ key(string.rep("界", 10)) })
  local shown = path.breadcrumb(t, 6)
  eq(shown, "…界界")
  eq(vim.fn.strdisplaywidth(shown) <= 6, true)
  eq(vim.str_utf_pos(shown), { 1, 4, 7 })
end

breadcrumb["raises on an invalid cell limit"] = function()
  raises(path.breadcrumb, target({}), 0)
  raises(path.breadcrumb, target({}), 2.5)
end

-- decode_json_string ---------------------------------------------------------

local decode = MiniTest.new_set()
T["decode_json_string"] = decode

decode["decodes plain and empty strings"] = function()
  eq(path.decode_json_string('"server.port"'), "server.port")
  eq(path.decode_json_string('""'), "")
end

decode["decodes every simple escape"] = function()
  local decoded = path.decode_json_string([["\"\\\/\b\f\n\r\t"]])
  eq(decoded, '"\\/\b\f\n\r\t')
end

decode["decodes \\u escapes in either hex case"] = function()
  eq(path.decode_json_string([["ééA"]]), "ééA")
  eq(path.decode_json_string([["€߿"]]), "€\223\191")
end

decode["decodes an escaped NUL to a NUL byte"] = function()
  eq(path.decode_json_string([["a\u0000b"]]), "a\0b")
end

decode["combines surrogate pairs into one code point"] = function()
  eq(path.decode_json_string([["😀"]]), "😀")
  eq(path.decode_json_string([["􏿿"]]), "\244\143\191\191")
end

decode["makes escaped and literal spellings compare equal"] = function()
  local escaped = path.decode_json_string([["café 😀"]])
  local literal = path.decode_json_string('"café 😀"')
  eq(escaped, literal)
end

decode["does not normalize Unicode or case"] = function()
  local composed = path.decode_json_string('"\195\169"')
  local decomposed = path.decode_json_string('"e\204\129"')
  eq(composed == decomposed, false)
  eq(decomposed, "e\204\129")
  eq(
    path.decode_json_string('"Key"') == path.decode_json_string('"key"'),
    false
  )
end

decode["agrees with vim.json.decode on valid literals"] = function()
  local literals = {
    [["a\"b\\c\/d"]],
    [["\u0001\u001f\u007f"]],
    [["𝄞 and 世"]],
    '"[0].a b"',
  }
  for _, literal in ipairs(literals) do
    eq(path.decode_json_string(literal), vim.json.decode(literal))
  end
end

decode["rejects invalid escapes"] = function()
  eq(decode_error_code([["\x41"]]), "escape")
  eq(decode_error_code([["\u12"]]), "escape")
  eq(decode_error_code([["\u12G4"]]), "escape")
  eq(decode_error_code([["\U0041"]]), "escape")
  eq(decode_error_code([["\'"]]), "escape")
end

decode["rejects malformed literals"] = function()
  eq(decode_error_code("abc"), "escape")
  eq(decode_error_code('"'), "escape")
  eq(decode_error_code('"unterminated'), "escape")
  eq(decode_error_code('"ends in escaped quote\\"'), "escape")
  eq(decode_error_code('"a"b"'), "escape")
  eq(decode_error_code("'single'"), "escape")
end

decode["rejects raw control characters including NUL"] = function()
  eq(decode_error_code('"tab\there"'), "control")
  eq(decode_error_code('"line\nbreak"'), "control")
  eq(decode_error_code('"nul\0byte"'), "control")
  eq(decode_error_code('"unit\31sep"'), "control")
end

decode["accepts a raw DEL byte as JSON allows"] = function()
  eq(path.decode_json_string('"a\127b"'), "a\127b")
end

decode["rejects lone and misordered surrogates"] = function()
  eq(decode_error_code([["\ud83d"]]), "surrogate")
  eq(decode_error_code([["\ud83d tail"]]), "surrogate")
  eq(decode_error_code([["\ude00"]]), "surrogate")
  eq(decode_error_code([["\ude00\ud83d"]]), "surrogate")
  eq(decode_error_code([["\ud83d\ud83d"]]), "surrogate")
  eq(decode_error_code([["\ud83dA"]]), "surrogate")
end

decode["enforces the raw byte limit before decoding"] = function()
  local raw = '"' .. string.rep("a", 4094) .. '"'
  eq(#path.decode_json_string(raw), 4094)
  eq(decode_error_code('"' .. string.rep("a", 4095) .. '"'), "too_long")
  -- The limit applies even to text that would fail to decode.
  eq(decode_error_code('"\\x"', 3), "too_long")
  eq(path.decode_json_string('"ab"', 4), "ab")
end

decode["raises on non-string input or invalid limits"] = function()
  raises(path.decode_json_string, nil)
  raises(path.decode_json_string, 42)
  raises(path.decode_json_string, '""', -1)
end

return T
