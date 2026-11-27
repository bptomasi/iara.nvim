-- Tests for the search fixture corpus (task S1). Expectations in the
-- manifest are checked against the real ripgrep, which defines the
-- eligibility and match semantics that Iara relies on.
local helpers = require("helpers")

local expect = MiniTest.expect
local eq = expect.equality

local generator = helpers.iara_dir .. "/tests/fixtures/make_search_fixture.lua"
local fixture = dofile(generator)

-- Building the corpus takes a moment; share one build across read-only
-- tests.
local shared_manifest
local function manifest()
  shared_manifest = shared_manifest or fixture.build(helpers.temp_dir())
  return shared_manifest
end

local function filter(list, predicate)
  return vim.tbl_filter(predicate, list)
end

local function contains(list, value)
  return vim.list_contains(list, value)
end

---Run ripgrep in the corpus root with the manifest environment.
local function ripgrep(m, args)
  local argv = { "rg", "--no-config" }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { cwd = m.root, env = m.env }):wait(20000)
  return result.code, result.stdout, result.stderr
end

local function rg_files(m, flags)
  local args = { "--files", "-0" }
  vim.list_extend(args, flags)
  local code, stdout, stderr = ripgrep(m, args)
  eq({ code = code, stderr = stderr }, { code = 0, stderr = "" })
  return vim.split(stdout, "\0", { plain = true, trimempty = true })
end

---Eligible set computed as ARCH defines it: E from ripgrep with the
---switches, strict hidden rule, `.git` exclusion, then E∩G for a glob.
local function inventory(m, hidden, ignored, glob)
  local flags = {}
  if hidden then
    table.insert(flags, "--hidden")
  end
  if ignored then
    table.insert(flags, "--no-ignore")
  end
  local paths = filter(rg_files(m, flags), function(path)
    local visible = hidden or not fixture.is_hidden(path)
    return visible and not fixture.is_git_metadata(path)
  end)
  if glob then
    local globbed = rg_files(m, { "--hidden", "--no-ignore", "-g", glob })
    paths = filter(paths, function(path)
      return contains(globbed, path)
    end)
  end
  table.sort(paths)
  return paths
end

---Paths only in `actual` or only in `expected`, keyed for readable diffs.
local function difference(actual, expected)
  local result = {}
  for _, path in ipairs(actual) do
    if not contains(expected, path) then
      result[path] = "unexpected"
    end
  end
  for _, path in ipairs(expected) do
    if not contains(actual, path) then
      result[path] = "missing"
    end
  end
  return result
end

local function json_path(field)
  if field.text then
    return field.text
  end
  return vim.base64.decode(field.bytes)
end

local function record_match(found, data)
  local path = json_path(data.path):gsub("^%./", "")
  for _, submatch in ipairs(data.submatches) do
    table.insert(found, {
      path = path,
      line = data.line_number,
      byte_start = submatch.start,
      byte_end = submatch["end"],
    })
  end
end

---Occurrences per file from `rg --json`, applying the strict whole-file
---binary policy: a non-null binary_offset discards every occurrence.
local function parse_json_matches(stdout)
  local by_path, binary = {}, {}
  for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
    local message = vim.json.decode(line)
    local data = message.data
    if message.type == "match" then
      local path = json_path(data.path):gsub("^%./", "")
      by_path[path] = by_path[path] or {}
      record_match(by_path[path], data)
    elseif message.type == "end" and data.binary_offset ~= vim.NIL then
      local path = json_path(data.path):gsub("^%./", "")
      by_path[path] = nil
      table.insert(binary, path)
    end
  end
  local matches = {}
  for _, found in pairs(by_path) do
    vim.list_extend(matches, found)
  end
  return matches, binary
end

local function occurrence_less(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  if a.line ~= b.line then
    return a.line < b.line
  end
  return a.byte_start < b.byte_start
end

---Search every candidate file the way the content runner does.
local function search(m, query)
  local args = { "--json", "--encoding", "none", "-e", query.query, "--" }
  if not query.regex then
    table.insert(args, 1, "--fixed-strings")
  end
  for _, path in ipairs(fixture.eligible(m, true, true)) do
    table.insert(args, "./" .. path)
  end
  local code, stdout = ripgrep(m, args)
  local matches, binary = parse_json_matches(stdout)
  table.sort(matches, occurrence_less)
  table.sort(binary)
  return code, matches, binary
end

local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Snapshot of the project tree outside `.git`: type and bytes per path.
local function snapshot(root)
  local entries = {}
  local function skip_git(name)
    return name ~= ".git"
  end
  local walk = vim.fs.dir(root, { depth = math.huge, skip = skip_git })
  for name, kind in walk do
    local path = root .. "/" .. name
    if kind == "link" then
      entries[name] = "link:" .. assert(vim.uv.fs_readlink(path))
    elseif kind == "file" then
      entries[name] = "file:" .. vim.fn.sha256(read_bytes(path))
    else
      entries[name] = kind
    end
  end
  return entries
end

---Manifest with the build directory replaced, for comparing two builds.
local function normalized(m)
  local dir = vim.pesc(vim.fs.dirname(m.root))
  local text = vim.json.encode(m):gsub(dir, "<dir>")
  return vim.json.decode(text)
end

local T = MiniTest.new_set()

local eligibility = MiniTest.new_set()
T["eligibility"] = eligibility

eligibility["matches ripgrep for every switch and glob case"] = function()
  local m = manifest()
  eq(#m.eligible, 16)
  eq(#fixture.eligible(m, false, false) > 0, true)
  for _, case in ipairs(m.eligible) do
    local glob = m.globs[case.glob]
    local actual = inventory(m, case.hidden, case.ignored, glob)
    local label = ("hidden=%s ignored=%s glob=%s"):format(
      case.hidden,
      case.ignored,
      case.glob
    )
    eq({ label, difference(actual, case.paths) }, { label, {} })
  end
end

eligibility["requires both switches for an ignored .env"] = function()
  local m = manifest()
  local function has_env(hidden, ignored, glob_kind)
    return contains(fixture.eligible(m, hidden, ignored, glob_kind), ".env")
  end
  for _, glob_kind in ipairs({ "none", "broad", "ignored_name" }) do
    eq(has_env(false, false, glob_kind), false)
    eq(has_env(true, false, glob_kind), false)
    eq(has_env(false, true, glob_kind), false)
    eq(has_env(true, true, glob_kind), true)
  end
  eq(fixture.eligible(m, false, false, "ignored_name"), {})
end

eligibility["a broad glob never widens the eligible set"] = function()
  local m = manifest()
  for _, hidden in ipairs({ false, true }) do
    for _, ignored in ipairs({ false, true }) do
      eq(
        fixture.eligible(m, hidden, ignored, "broad"),
        fixture.eligible(m, hidden, ignored)
      )
    end
  end
end

eligibility["a positive glob alone would leak an ignored file"] = function()
  local m = manifest()
  local ignored_name = m.globs.ignored_name
  eq(rg_files(m, { "--hidden", "-g", ignored_name }), { ignored_name })
end

eligibility["whitelists expose hidden paths without --hidden"] = function()
  local m = manifest()
  local raw = rg_files(m, {})
  for _, path in ipairs(m.special.whitelisted_hidden) do
    eq({ path, contains(raw, path) }, { path, true })
    eq(contains(fixture.eligible(m, false, false), path), false)
    eq(contains(fixture.eligible(m, true, false), path), true)
  end
end

eligibility["unrestricted walks list .git metadata"] = function()
  local m = manifest()
  local raw = rg_files(m, { "--hidden", "--no-ignore" })
  for _, path in ipairs(m.special.git_metadata) do
    eq({ path, contains(raw, path) }, { path, true })
    eq(contains(fixture.eligible(m, true, true), path), false)
  end
  eq(contains(fixture.eligible(m, false, false), "my.git/readme.txt"), true)
end

eligibility["ripgrep lists no symlink without following"] = function()
  local m = manifest()
  local raw = rg_files(m, { "--hidden", "--no-ignore" })
  for _, link in ipairs(m.special.symlinks) do
    local stat = assert(vim.uv.fs_lstat(m.root .. "/" .. link.path))
    eq({ link.path, stat.type }, { link.path, "link" })
    local listed = filter(raw, function(path)
      return path == link.path or vim.startswith(path, link.path .. "/")
    end)
    eq(listed, {})
  end
end

eligibility["special names are eligible by default"] = function()
  local m = manifest()
  local default = fixture.eligible(m, false, false)
  for key, path in pairs(m.special.names) do
    eq({ key, contains(default, path) }, { key, true })
  end
end

local content = MiniTest.new_set()
T["content"] = content

content["documented occurrences match ripgrep JSON"] = function()
  local m = manifest()
  for _, query in ipairs(m.queries) do
    if query.matches then
      local code, matches, binary = search(m, query)
      eq({ query.id, code }, { query.id, 0 })
      eq({ query.id, matches }, { query.id, query.matches })
      eq({ query.id, binary }, { query.id, query.binary_paths or {} })
    end
  end
end

content["the invalid regex is an error, not an empty result"] = function()
  local m = manifest()
  local query = fixture.query(m, "invalid_regex")
  eq(query.error, true)
  local code = ripgrep(m, { "--json", "-e", query.query, "--", "regex.txt" })
  eq(code, 2)
  eq(fixture.query(m, "literal_paren").query, query.query)
end

content["the bulk query exceeds both result quotas"] = function()
  local m = manifest()
  local query = fixture.query(m, "bulk")
  local _, matches = search(m, query)
  local files = {}
  for _, occurrence in ipairs(matches) do
    files[occurrence.path] = true
  end
  eq(#matches, query.occurrence_count)
  eq(vim.tbl_count(files), query.file_count)
  eq(query.occurrence_count > 1000, true)
  local named = filter(fixture.eligible(m, false, false), function(path)
    return path:find(m.special.bulk.name_query, 1, true) ~= nil
  end)
  eq(#named > 200, true)
end

content["expected matches follow the eligible set"] = function()
  local m = manifest()
  local default = fixture.eligible(m, false, false)
  local paths = vim.tbl_map(function(occurrence)
    return occurrence.path
  end, fixture.expected_matches(m, "needle", default))
  eq(contains(paths, ".env"), false)
  eq(contains(paths, "ignored-content.txt"), false)
  eq(contains(paths, m.special.nested_dotfolder), false)
  eq(contains(paths, "content-only.txt"), true)
end

content["special files carry their byte properties"] = function()
  local m = manifest()
  local function bytes(path)
    return read_bytes(m.root .. "/" .. path)
  end
  local binary = bytes(m.special.binary.path)
  eq(binary:find("\0", 1, true), m.special.binary.nul_offset + 1)
  eq(m.special.binary.nul_offset > 64 * 1024, true)
  eq(bytes(m.special.bom):sub(1, 3), "\239\187\191")
  eq(bytes(m.special.crlf):find("\r\n", 1, true) ~= nil, true)
  local long = bytes(m.special.long_line.path)
  eq(#long, m.special.long_line.line_bytes + 1)
  eq(m.special.long_line.line_bytes > 256 * 1024, true)
end

local generation = MiniTest.new_set()
T["generation"] = generation

generation["is deterministic across builds"] = function()
  local first = fixture.build(helpers.temp_dir())
  local second = fixture.build(helpers.temp_dir())
  eq(normalized(first), normalized(second))
  eq(snapshot(first.root), snapshot(second.root))
end

generation["keeps the user's Git configuration out"] = function()
  local m = manifest()
  local dir = vim.fs.dirname(m.root)
  eq(m.env.GIT_CONFIG_NOSYSTEM, "1")
  for _, name in ipairs({ "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL" }) do
    eq({ name, vim.startswith(m.env[name], dir .. "/") }, { name, true })
  end
  eq(contains(fixture.eligible(m, false, false), "notes.tmp"), false)
end

generation["the command line writes a manifest.json"] = function()
  local dir = helpers.temp_dir() .. "/corpus"
  local argv = { vim.v.progpath, "--clean", "-l", generator, dir }
  local result = helpers.run(argv)
  eq(result.code, 0)
  eq(vim.trim(result.stdout), dir .. "/manifest.json")
  local written = vim.json.decode(read_bytes(dir .. "/manifest.json"))
  eq(normalized(written), normalized(manifest()))
end

generation["refuses a directory that is not empty"] = function()
  local dir = helpers.temp_dir()
  helpers.write_file(dir .. "/existing.txt", "keep\n")
  local argv = { vim.v.progpath, "--clean", "-l", generator, dir }
  local result = helpers.run(argv)
  eq(result.code, 1)
  helpers.expect_match(result.stderr, "must be absent or empty")
  eq(vim.fn.readdir(dir), { "existing.txt" })
end

return T
