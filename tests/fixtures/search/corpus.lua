-- Declarative description of the search fixture corpus (task S1).
--
-- make_search_fixture.lua writes these entries to disk and derives the
-- manifest from them. Every expectation here is checked against real
-- ripgrep by tests/test_search_fixture.lua; see README.md beside this file.
--
-- Paths are relative to the project root and use raw bytes: one name is
-- deliberately invalid UTF-8.

local corpus = {}

-- Ripgrep reads its first buffer (64 KiB) before it can see this NUL.
local NUL_OFFSET_TARGET = 128 * 1024
-- A JSON frame for a match on this line exceeds the 256 KiB frame cap.
local LONG_LINE_BYTES = 300 * 1024
local LONG_LINE_MARKER = "longlinemarker"
-- Enough files and occurrences to exceed the 200/1,000 result quotas.
local BULK_FILES = 240
local BULK_CONTENT = "bulkmark bulkmark\nbulkmark\nbulkmark bulkmark\n"
local BULK_OCCURRENCES_PER_FILE = 5

local BOM = "\239\187\191"
local SPECIAL_CONTENT = "special file name\n"

corpus.BULK_FILES = BULK_FILES

---Bytes of the long line, without its newline.
corpus.long_line_bytes = LONG_LINE_BYTES + #LONG_LINE_MARKER

---Ignore rules that live outside the project root.
corpus.global_ignore = "*.tmp\n"
corpus.parent_ignore = "parent-ignored.txt\n"

local GITIGNORE = table.concat({
  "*.log",
  "build/",
  ".env*",
  "!.env.example",
  "!.wl-git/",
  "ignored-content.txt",
  "tracked-ignored.txt",
  "",
}, "\n")

-- .ignore outranks .gitignore, so keep.log is searchable again.
local DOT_IGNORE = "!keep.log\n!.wl-ignore/\n"
local DOT_RGIGNORE = "rg-ignored.txt\n!.wl-rg/\n"

local function binary_content()
  local head = "needle before nul\n"
  local filler = ("filler "):rep(9) .. "\n"
  local count = math.floor((NUL_OFFSET_TARGET - #head) / #filler)
  local before = head .. filler:rep(count)
  return before .. "\0" .. "needle after nul\n", #before
end

local BINARY_CONTENT, BINARY_NUL_OFFSET = binary_content()
corpus.binary_nul_offset = BINARY_NUL_OFFSET

---Files whose content or name matters to a documented expectation.
---@return table[] entries { path, content, ignored?, git_add? }
local function core_files()
  return {
    { path = ".gitignore", content = GITIGNORE },
    { path = ".ignore", content = DOT_IGNORE },
    { path = ".rgignore", content = DOT_RGIGNORE },
    { path = "needle-name-only.txt", content = "matches by name only\n" },
    { path = "content-only.txt", content = "a line with needle inside\n" },
    { path = "needle-both.txt", content = "needle in name and here\n" },
    {
      path = "repeated.txt",
      content = "needle needle needle\nno match here\nneedle at start\n",
    },
    { path = "unicode.txt", content = "ação needle\n" },
    { path = "crlf.txt", content = "first line\r\nsecond needle\r\n" },
    { path = "bom.txt", content = BOM .. "needle after bom\n" },
    { path = "binary-late-nul.dat", content = BINARY_CONTENT },
    {
      path = "long-line.txt",
      content = ("x"):rep(LONG_LINE_BYTES) .. LONG_LINE_MARKER .. "\n",
    },
    { path = "dashes.txt", content = "alpha -- beta\nalpha beta\n-\n" },
    {
      path = "regex.txt",
      content = "color\ncolour\nliteral colou?r\nopen (unclosed paren\n",
    },
    { path = "src/main.lua", content = "local needle = 1\n" },
    { path = "my.git/readme.txt", content = "not git metadata\n" },
    { path = "vendor/lib/lib.txt", content = "vendored\n" },
  }
end

---Hidden, ignored, and Git metadata entries.
---@return table[]
local function visibility_files()
  return {
    { path = "src/.gitignore", content = "generated/\n" },
    { path = ".env", content = "TOKEN=needle\n", ignored = true },
    { path = ".env.example", content = "TOKEN=\n" },
    { path = ".wl-git/kept.txt", content = "whitelisted\n" },
    { path = ".wl-ignore/kept.txt", content = "whitelisted\n" },
    { path = ".wl-rg/kept.txt", content = "whitelisted\n" },
    { path = ".config/app/settings.json", content = "{}\n" },
    {
      path = "src/.cache/deep/.hidden/hidden-needle.txt",
      content = "hidden needle\n",
    },
    { path = ".hidden-ignored.log", content = "both\n", ignored = true },
    { path = "keep.log", content = "kept by .ignore\n" },
    { path = "debug.log", content = "ignored log\n", ignored = true },
    { path = "build/output.txt", content = "built\n", ignored = true },
    { path = "src/generated/out.txt", content = "gen\n", ignored = true },
    { path = "notes.tmp", content = "global\n", ignored = true },
    { path = "parent-ignored.txt", content = "parent\n", ignored = true },
    { path = "rg-ignored.txt", content = "rg\n", ignored = true },
    {
      path = "ignored-content.txt",
      content = "ignored needle\n",
      ignored = true,
    },
    {
      path = "tracked-ignored.txt",
      content = "tracked\n",
      ignored = true,
      git_add = true,
    },
    -- A gitfile as found in linked worktrees and submodules.
    {
      path = "vendor/lib/.git",
      content = "gitdir: ../../.git/worktrees/lib\n",
      git_metadata = true,
    },
  }
end

---Names that break naive argv, line, or UTF-8 handling.
corpus.special_names = {
  spaces = "dir with spaces/file name with spaces.txt",
  unicode = "unicodé/naïve-ação.txt",
  leading_dash = "-leading-dash.txt",
  double_dash = "--looks-like-flag.txt",
  colon = "colon:name.txt",
  tab = "tab\tname.txt",
  newline = "newline\nname.txt",
  invalid_utf8 = "invalid-\255-utf8.txt",
}

local function special_files()
  local keys = vim.tbl_keys(corpus.special_names)
  table.sort(keys)
  local entries = {}
  for _, key in ipairs(keys) do
    local path = corpus.special_names[key]
    table.insert(entries, { path = path, content = SPECIAL_CONTENT })
  end
  return entries
end

local function bulk_files()
  local entries = {}
  for index = 1, BULK_FILES do
    local path = ("bulk/bulk-%03d.txt"):format(index)
    table.insert(entries, { path = path, content = BULK_CONTENT })
  end
  return entries
end

---Every regular file of the corpus, in a fixed order.
---@return table[] entries
function corpus.files()
  local entries = {}
  vim.list_extend(entries, core_files())
  vim.list_extend(entries, visibility_files())
  vim.list_extend(entries, special_files())
  vim.list_extend(entries, bulk_files())
  return entries
end

---Symbolic links. Following is off in the MVP, so ripgrep lists none of
---them in any combination. `external` points outside the project root.
corpus.symlinks = {
  { path = "link-to-content.txt", target = "content-only.txt", kind = "file" },
  { path = "link-to-src", target = "src", kind = "directory" },
  { path = "broken-link", target = "does-not-exist.txt", kind = "broken" },
  { path = "loop-link", target = "loop-link", kind = "loop" },
  {
    path = "external-link",
    target = "../outside/target.txt",
    kind = "external",
  },
  { path = "link-to-git", target = ".git", kind = "git_metadata" },
}

---Hidden paths that ripgrep lists without --hidden because an ignore file
---whitelists them; only the strict dot-component rule removes them.
corpus.whitelisted_hidden = {
  ".env.example",
  ".wl-git/kept.txt",
  ".wl-ignore/kept.txt",
  ".wl-rg/kept.txt",
}

---Path globs for the glob cases. `matches` states, by construction of the
---corpus, which project paths the glob alone selects.
corpus.globs = {
  {
    kind = "broad",
    glob = "*",
    matches = function()
      return true
    end,
  },
  {
    kind = "ignored_name",
    glob = ".env",
    matches = function(path)
      return path == ".env"
    end,
  },
  {
    kind = "exclusion",
    glob = "!*.txt",
    matches = function(path)
      return not vim.endswith(path, ".txt")
    end,
  },
}

local function occurrence(path, line, byte_start, byte_end)
  return {
    path = path,
    line = line,
    byte_start = byte_start,
    byte_end = byte_end,
  }
end

local NEEDLE_MATCHES = {
  occurrence("bom.txt", 1, 3, 9),
  occurrence("content-only.txt", 1, 12, 18),
  occurrence("crlf.txt", 2, 7, 13),
  occurrence(".env", 1, 6, 12),
  occurrence("ignored-content.txt", 1, 8, 14),
  occurrence("needle-both.txt", 1, 0, 6),
  occurrence("repeated.txt", 1, 0, 6),
  occurrence("repeated.txt", 1, 7, 13),
  occurrence("repeated.txt", 1, 14, 20),
  occurrence("repeated.txt", 3, 0, 6),
  occurrence("src/.cache/deep/.hidden/hidden-needle.txt", 1, 7, 13),
  occurrence("src/main.lua", 1, 6, 12),
  occurrence("unicode.txt", 1, 7, 13),
}

local QUERIES = {
  {
    id = "needle",
    query = "needle",
    regex = false,
    matches = NEEDLE_MATCHES,
    binary_paths = { "binary-late-nul.dat" },
  },
  {
    id = "alpha_dashes",
    query = "alpha -- beta",
    regex = false,
    matches = { occurrence("dashes.txt", 1, 0, 13) },
  },
  {
    id = "regex_optional",
    query = "colou?r",
    regex = true,
    matches = {
      occurrence("regex.txt", 1, 0, 5),
      occurrence("regex.txt", 2, 0, 6),
    },
  },
  {
    id = "literal_optional",
    query = "colou?r",
    regex = false,
    matches = { occurrence("regex.txt", 3, 8, 15) },
  },
  {
    id = "literal_paren",
    query = "(unclosed",
    regex = false,
    matches = { occurrence("regex.txt", 4, 5, 14) },
  },
  { id = "invalid_regex", query = "(unclosed", regex = true, error = true },
  {
    id = "long_line",
    query = LONG_LINE_MARKER,
    regex = false,
    matches = {
      occurrence("long-line.txt", 1, LONG_LINE_BYTES, corpus.long_line_bytes),
    },
  },
  {
    id = "bulk",
    query = "bulkmark",
    regex = false,
    file_count = BULK_FILES,
    occurrence_count = BULK_FILES * BULK_OCCURRENCES_PER_FILE,
  },
}

---Documented content queries. Case-sensitive. `matches` covers every
---non-binary candidate file regardless of visibility; filter it by an
---eligible set to get the expectation for one combination.
---@return table[] queries A fresh copy.
function corpus.queries()
  return vim.deepcopy(QUERIES)
end

return corpus
