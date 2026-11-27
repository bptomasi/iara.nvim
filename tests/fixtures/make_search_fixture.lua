-- Search fixture corpus generator (task S1).
--
-- Usage: nvim -l tests/fixtures/make_search_fixture.lua DIR
--   Builds the corpus in DIR (absent or empty) and writes DIR/manifest.json.
--
-- From Lua:
--   local fixture = dofile(".../make_search_fixture.lua")
--   local manifest = fixture.build(dir)
--
-- The corpus is declared in search/corpus.lua; search/README.md documents
-- the layout and the manifest format.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = vim.fn.fnamemodify(source, ":p:h")
local corpus = dofile(script_dir .. "/search/corpus.lua")

local fixture = {}

---Version of the manifest format.
fixture.FORMAT = 1

---Glob kind for "no path glob".
fixture.NO_GLOB = "none"

local function is_dot_component(component)
  return component:sub(1, 1) == "."
end

local function is_git_component(component)
  return component == ".git"
end

local function has_component(path, predicate)
  for component in path:gmatch("[^/]+") do
    if predicate(component) then
      return true
    end
  end
  return false
end

---Whether `path`, relative to the root, has a dot-prefixed component.
---@param path string
---@return boolean
function fixture.is_hidden(path)
  return has_component(path, is_dot_component)
end

---Whether `path`, relative to the root, has a `.git` component.
---@param path string
---@return boolean
function fixture.is_git_metadata(path)
  return has_component(path, is_git_component)
end

local function parent_of(path)
  return path:match("^(.*)/[^/]*$")
end

local function write_file(path, content)
  local parent = parent_of(path)
  if parent then
    vim.fn.mkdir(parent, "p")
  end
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

---Paths and environment of a corpus built in `dir`.
---@param dir string Absolute build directory.
---@return table layout { root, home, outside, global_ignore, parent_ignore }
local function layout_of(dir)
  local home = dir .. "/home"
  return {
    root = dir .. "/project",
    home = home,
    outside = dir .. "/outside",
    gitconfig = home .. "/.gitconfig",
    global_ignore = home .. "/global-ignore",
    parent_ignore = dir .. "/.ignore",
  }
end

---Environment for Git and ripgrep that hides the user's configuration:
---ripgrep reads the global ignore through $HOME/.gitconfig, Git through
---GIT_CONFIG_GLOBAL; system configuration is disabled.
---@param layout table
---@return table<string, string>
local function environment_of(layout)
  return {
    HOME = layout.home,
    XDG_CONFIG_HOME = layout.home .. "/.config",
    GIT_CONFIG_GLOBAL = layout.gitconfig,
    GIT_CONFIG_NOSYSTEM = "1",
  }
end

local function run_git(layout, args)
  local env = environment_of(layout)
  env.PATH = vim.env.PATH
  env.LC_ALL = "C"
  local argv = { "git", "-C", layout.root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { env = env, clear_env = true }):wait()
  if result.code ~= 0 then
    error(("git %s failed: %s"):format(args[1], result.stderr), 0)
  end
end

local function write_outside_files(layout)
  write_file(
    layout.gitconfig,
    ("[core]\n\texcludesFile = %s\n"):format(layout.global_ignore)
  )
  write_file(layout.global_ignore, corpus.global_ignore)
  write_file(layout.parent_ignore, corpus.parent_ignore)
  write_file(layout.outside .. "/target.txt", "outside the root\n")
end

local function write_project_files(root)
  for _, entry in ipairs(corpus.files()) do
    write_file(root .. "/" .. entry.path, entry.content)
  end
  for _, link in ipairs(corpus.symlinks) do
    assert(vim.uv.fs_symlink(link.target, root .. "/" .. link.path))
  end
end

local function init_repository(layout)
  run_git(layout, { "-c", "init.defaultBranch=main", "init", "-q" })
  for _, entry in ipairs(corpus.files()) do
    if entry.git_add then
      run_git(layout, { "add", "--force", "--", entry.path })
    end
  end
end

local function assert_empty_directory(dir)
  local stat = vim.uv.fs_stat(dir)
  if not stat then
    vim.fn.mkdir(dir, "p")
    return
  end
  if stat.type ~= "directory" or next(vim.fn.readdir(dir)) ~= nil then
    error(("fixture directory must be absent or empty: %s"):format(dir), 0)
  end
end

local function eligible_paths(hidden, ignored, glob)
  local paths = {}
  for _, entry in ipairs(corpus.files()) do
    local path = entry.path
    local visible = hidden or not fixture.is_hidden(path)
    local allowed = ignored or not entry.ignored
    if visible and allowed and not fixture.is_git_metadata(path) then
      if glob.matches(path) then
        table.insert(paths, path)
      end
    end
  end
  table.sort(paths)
  return paths
end

local function glob_cases()
  local cases = {
    {
      kind = fixture.NO_GLOB,
      matches = function()
        return true
      end,
    },
  }
  vim.list_extend(cases, corpus.globs)
  return cases
end

local function eligible_cases()
  local cases = {}
  for _, hidden in ipairs({ false, true }) do
    for _, ignored in ipairs({ false, true }) do
      for _, glob in ipairs(glob_cases()) do
        table.insert(cases, {
          hidden = hidden,
          ignored = ignored,
          glob = glob.kind,
          paths = eligible_paths(hidden, ignored, glob),
        })
      end
    end
  end
  return cases
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

local function documented_queries()
  local queries = corpus.queries()
  for _, query in ipairs(queries) do
    if query.matches then
      table.sort(query.matches, occurrence_less)
    end
  end
  return queries
end

local function glob_table()
  local globs = {}
  for _, glob in ipairs(corpus.globs) do
    globs[glob.kind] = glob.glob
  end
  return globs
end

local function special_paths()
  return {
    names = corpus.special_names,
    name_only = "needle-name-only.txt",
    content_only = "content-only.txt",
    name_and_content = "needle-both.txt",
    repeated_same_line = "repeated.txt",
    nested_dotfolder = "src/.cache/deep/.hidden/hidden-needle.txt",
    whitelisted_hidden = corpus.whitelisted_hidden,
    ignored_hidden = ".env",
    tracked_ignored = "tracked-ignored.txt",
    git_metadata = { ".git/HEAD", "vendor/lib/.git" },
    not_git_metadata = "my.git/readme.txt",
    symlinks = corpus.symlinks,
    crlf = "crlf.txt",
    bom = "bom.txt",
    unicode_content = "unicode.txt",
    binary = {
      path = "binary-late-nul.dat",
      nul_offset = corpus.binary_nul_offset,
    },
    long_line = {
      path = "long-line.txt",
      line_bytes = corpus.long_line_bytes,
    },
    bulk = {
      directory = "bulk",
      name_query = "bulk",
      file_count = corpus.BULK_FILES,
    },
  }
end

local function describe(layout)
  return {
    format = fixture.FORMAT,
    root = layout.root,
    env = environment_of(layout),
    ignore_files = {
      global = layout.global_ignore,
      parent = layout.parent_ignore,
    },
    globs = glob_table(),
    eligible = eligible_cases(),
    queries = documented_queries(),
    special = special_paths(),
  }
end

---Build the corpus in `dir` and return its manifest.
---@param dir string Directory that is absent or empty.
---@return table manifest See tests/fixtures/search/README.md.
function fixture.build(dir)
  dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  assert_empty_directory(dir)
  local layout = layout_of(dir)
  write_outside_files(layout)
  write_project_files(layout.root)
  init_repository(layout)
  return describe(layout)
end

---Expected eligible paths for one combination.
---@param manifest table
---@param hidden boolean
---@param ignored boolean
---@param glob_kind string|nil "none" (default), "broad", ...
---@return string[] paths Sorted, relative to the root.
function fixture.eligible(manifest, hidden, ignored, glob_kind)
  glob_kind = glob_kind or fixture.NO_GLOB
  for _, case in ipairs(manifest.eligible) do
    local same_switches = case.hidden == hidden and case.ignored == ignored
    if same_switches and case.glob == glob_kind then
      return case.paths
    end
  end
  error(("unknown glob kind: %s"):format(glob_kind), 2)
end

---Documented query by id.
---@param manifest table
---@param id string
---@return table query
function fixture.query(manifest, id)
  for _, query in ipairs(manifest.queries) do
    if query.id == id then
      return query
    end
  end
  error(("unknown query id: %s"):format(id), 2)
end

---Occurrences of query `id` restricted to the `eligible` paths.
---@param manifest table
---@param id string
---@param eligible string[]
---@return table[] occurrences { path, line, byte_start, byte_end }
function fixture.expected_matches(manifest, id, eligible)
  local allowed = {}
  for _, path in ipairs(eligible) do
    allowed[path] = true
  end
  return vim.tbl_filter(function(occurrence)
    return allowed[occurrence.path] == true
  end, fixture.query(manifest, id).matches or {})
end

---Write `manifest` as JSON. Path bytes are kept raw, including the one
---invalid UTF-8 name, so read it back with vim.json.decode.
---@param manifest table
---@param path string
function fixture.write_manifest(manifest, path)
  write_file(path, vim.json.encode(manifest) .. "\n")
end

local function main(args)
  if #args ~= 1 then
    io.stderr:write("usage: nvim -l make_search_fixture.lua DIR\n")
    return 2
  end
  local ok, result = pcall(fixture.build, args[1])
  if not ok then
    io.stderr:write(("make_search_fixture: %s\n"):format(result))
    return 1
  end
  local manifest_path = vim.fs.dirname(result.root) .. "/manifest.json"
  fixture.write_manifest(result, manifest_path)
  io.stdout:write(manifest_path .. "\n")
  return 0
end

local invoked_as_script = _G.arg ~= nil
  and _G.arg[0] ~= nil
  and vim.fn.fnamemodify(_G.arg[0], ":p") == vim.fn.fnamemodify(source, ":p")
if invoked_as_script then
  os.exit(main(_G.arg))
end

return fixture
