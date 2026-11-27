--- Directory tree of the eligible files (task S9): the model behind the
--- directory step of the search picker. Pure data; no UI.
---
--- The tree is derived from inventory paths (`Session:tree`), so it
--- lists only directories that hold eligible files under the current
--- hidden and ignored switches: `.git` and an excluded directory never
--- appear, and an empty directory does not either. Paths are
--- root-relative with `/` separators; the root itself is "".
---
--- Typed paths are resolved lexically against the current directory
--- (`..` and `.` segments, a leading `/` for an absolute path) and never
--- leave the root. A path that is not in the tree is refused, except
--- when the tree is incomplete (an inventory limit) and the directory
--- exists on disk: the search still applies eligibility in it.
local fuzzy = require("iara.features.search.fuzzy")

local M = {}

---Rows of a filtered listing; the rest is counted.
M.LIMIT = 200

---@class IaraSearchDir
---@field path string Root-relative; "" is the root.
---@field name string Last component; "" for the root.
---@field files integer Eligible files below it, at any depth.
---@field children string[] Paths of its subdirectories, in byte order.
---@field names string[] (S10) Names of its eligible files, byte order.

---@class IaraSearchDirTree
---@field dirs table<string, IaraSearchDir>
---@field list string[] Every directory but the root, in byte order.
---@field complete boolean The inventory listed every eligible file.

local function new_dir(path, name)
  return { path = path, name = name, files = 0, children = {}, names = {} }
end

---Count `path` in every directory above it, creating them on the way.
local function add_path(dirs, list, path)
  local parent, start = dirs[""], 1
  parent.files = parent.files + 1
  local slash = path:find("/", start, true)
  while slash do
    local rel = path:sub(1, slash - 1)
    local dir = dirs[rel]
    if not dir then
      dir = new_dir(rel, path:sub(start, slash - 1))
      dirs[rel] = dir
      list[#list + 1] = rel
      parent.children[#parent.children + 1] = rel
    end
    dir.files = dir.files + 1
    parent, start = dir, slash + 1
    slash = path:find("/", start, true)
  end
  parent.names[#parent.names + 1] = path:sub(start)
end

---Index the directories of eligible `paths`.
---@param paths string[] Root-relative eligible file paths.
---@param complete boolean? The paths are the complete inventory.
---@return IaraSearchDirTree
function M.index(paths, complete)
  local dirs, list = { [""] = new_dir("", "") }, {}
  for _, path in ipairs(paths) do
    add_path(dirs, list, path)
  end
  table.sort(list)
  for _, dir in pairs(dirs) do
    table.sort(dir.children)
    table.sort(dir.names)
  end
  return { dirs = dirs, list = list, complete = complete ~= false }
end

---(S10) Add directory `path` and its missing parents to `tree` with no
---files: a directory created in the step lists before it holds an
---eligible file.
---@param tree IaraSearchDirTree
---@param path string Root-relative, not "".
function M.add_dir(tree, path)
  local parent = M.parent(path)
  if path == "" or tree.dirs[path] or not parent then
    return
  end
  M.add_dir(tree, parent)
  tree.dirs[path] = new_dir(path, path:match("([^/]*)$"))
  local siblings = tree.dirs[parent].children
  siblings[#siblings + 1] = path
  table.sort(siblings)
  tree.list[#tree.list + 1] = path
  table.sort(tree.list)
end

-- Paths -----------------------------------------------------------------

---Parent of a root-relative directory; nil for the root.
---@param path string
---@return string|nil
function M.parent(path)
  if path == "" then
    return nil
  end
  return path:match("^(.*)/[^/]*$") or ""
end

---Segments of `path` after `start` (a segment list), with `.` dropped
---and `..` going up; nil when `..` goes above the start's base.
local function walk(start, path)
  local parts = vim.list_slice(start)
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if #parts == 0 then
        return nil
      end
      parts[#parts] = nil
    elseif segment ~= "." then
      parts[#parts + 1] = segment
    end
  end
  return parts
end

local function segments(path)
  return path == "" and {} or vim.split(path, "/", { plain = true })
end

---An absolute path made root-relative, lexically; nil outside the root.
local function from_absolute(root, path)
  local parts = walk({}, path)
  if not parts then
    return nil
  end
  local trimmed = root:gsub("^/", ""):gsub("/$", "")
  local base = segments(trimmed)
  for index, segment in ipairs(base) do
    if parts[index] ~= segment then
      return nil
    end
  end
  return table.concat(vim.list_slice(parts, #base + 1), "/")
end

---Root-relative directory named by `text`, typed relative to `from` or
---absolute; nil when it leaves the root. Lexical: nothing is read.
---@param root string Absolute root.
---@param from string Root-relative directory.
---@param text string
---@return string|nil path
function M.normalize(root, from, text)
  if text:sub(1, 1) == "/" then
    return from_absolute(root, text)
  end
  local parts = walk(segments(from), text)
  return parts and table.concat(parts, "/") or nil
end

local function shown(path)
  return vim.fn.strtrans((path:gsub("\n", "\\n")))
end

local function is_directory(root, path)
  local absolute = path == "" and root or (root:gsub("/$", "") .. "/" .. path)
  local stat = vim.uv.fs_stat(absolute)
  return stat ~= nil and stat.type == "directory"
end

---The directory to go to for typed `text`, or a message saying why not.
---Reads the disk only for a path the tree does not list.
---@param tree IaraSearchDirTree
---@param root string
---@param from string
---@param text string
---@return string|nil path
---@return string|nil message
function M.resolve(tree, root, from, text)
  local path = M.normalize(root, from, text)
  if not path then
    return nil, "Outside the project root: " .. shown(text)
  end
  if tree.dirs[path] then
    return path
  end
  if not is_directory(root, path) then
    return nil, "No such directory: " .. shown(text)
  end
  if not tree.complete then
    return path
  end
  return nil, "No searchable files in " .. shown(text)
end

-- Listing and filtering -------------------------------------------------

---@class IaraSearchDirEntry
---@field path string Root-relative directory.
---@field label string Path shown, relative to the listed base.
---@field files integer
---@field positions integer[]? Matched bytes of `label`.

---@class IaraSearchDirListing
---@field base string Directory listed or searched.
---@field entries IaraSearchDirEntry[]
---@field filtered boolean The entries match a typed name.
---@field total integer Matching directories, also beyond the limit.

local function entry(tree, path, label, positions)
  local files = tree.dirs[path].files
  return { path = path, label = label, files = files, positions = positions }
end

local function children(tree, base, head)
  local entries = {}
  for index, path in ipairs(tree.dirs[base].children) do
    entries[index] = entry(tree, path, head .. tree.dirs[path].name)
  end
  return { base = base, entries = entries, filtered = false, total = #entries }
end

local function by_score(a, b)
  if a.score ~= b.score then
    return a.score > b.score
  end
  return a.path < b.path
end

---Directories below `base` whose path from `base` matches `needle`.
local function matches(tree, base, needle, head)
  local prefix = base == "" and "" or base .. "/"
  local found = {}
  for _, path in ipairs(tree.list) do
    if vim.startswith(path, prefix) then
      local label, positions = path:sub(#prefix + 1), {}
      local score = fuzzy.score(needle, label, positions)
      if score then
        local item = entry(tree, path, label, positions)
        item.score = score
        found[#found + 1] = item
      end
    end
  end
  table.sort(found, by_score)
  local entries = vim.list_slice(found, 1, M.LIMIT)
  for _, item in ipairs(entries) do
    item.label = head .. item.label
    for index, position in ipairs(item.positions) do
      item.positions[index] = position + #head
    end
  end
  return { base = base, entries = entries, filtered = true, total = #found }
end

---What the directory step lists for the typed `query` in `from`: the
---text up to the last `/` names a directory to list (relative to
---`from`); the rest filters every directory below it fuzzily. Without
---a filter, the subdirectories are listed.
---@param tree IaraSearchDirTree
---@param root string
---@param from string
---@param query string
---@return IaraSearchDirListing|nil listing
---@return string|nil message Why the typed directory cannot be listed.
function M.list(tree, root, from, query)
  local head, needle = query:match("^(.*/)([^/]*)$")
  local base = from
  if head then
    local path = M.normalize(root, from, head)
    if not path then
      return nil, "Outside the project root: " .. shown(head)
    end
    if not tree.dirs[path] then
      return nil, "No directory " .. shown(head)
    end
    base = path
  end
  needle = needle or query
  if needle == "" then
    return children(tree, base, head or "")
  end
  return matches(tree, base, needle, head or "")
end

---Longest common prefix of `names`.
local function common_prefix(names)
  local prefix = names[1]
  for index = 2, #names do
    local name = names[index]
    local length = 0
    while
      length < #prefix and prefix:byte(length + 1) == name:byte(length + 1)
    do
      length = length + 1
    end
    prefix = prefix:sub(1, length)
  end
  return prefix
end

---Complete the last segment of `query` like a shell: the one
---subdirectory it starts, with a trailing `/`, or the longest prefix
---several share. Nil when nothing extends it.
---@param tree IaraSearchDirTree
---@param root string
---@param from string
---@param query string
---@return string|nil completed
function M.complete(tree, root, from, query)
  local head, needle = query:match("^(.*/)([^/]*)$")
  head, needle = head or "", needle or query
  local base = head == "" and from or M.normalize(root, from, head)
  local dir = base and tree.dirs[base]
  if not dir then
    return nil
  end
  local names = {}
  for _, path in ipairs(dir.children) do
    local name = tree.dirs[path].name
    if vim.startswith(name, needle) then
      names[#names + 1] = name
    end
  end
  if #names == 0 then
    return nil
  end
  local completed = #names == 1 and names[1] .. "/" or common_prefix(names)
  if completed == needle then
    return nil
  end
  return head .. completed
end

---Label of `path` as a breadcrumb: the root's name, then the path.
---@param root string
---@param path string
---@return string
function M.crumb(root, path)
  local name = vim.fs.basename(root)
  if name == "" then
    return "/" .. shown(path)
  end
  return path == "" and name or name .. "/" .. shown(path)
end

M.shown = shown

return M
