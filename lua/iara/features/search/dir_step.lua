--- Directory step of the search picker (task S9): `Alt-d` in Find files
--- or Find in files lists the project's directories in the same frame,
--- so the search can be scoped to one of them.
---
--- The step starts in the current scope's directory and lists it as a
--- tree (task S10): subdirectories, then the eligible files. `Enter`
--- expands or collapses the directory under the cursor in place (and
--- opens a file), `l` goes into it, `..` (or `h`, `-`, `Backspace` on
--- an empty prompt) goes up, never above the root. `E` opens Oil.
--- Typing filters every directory below fuzzily; a typed relative path
--- (`lua/iara/core`, `../tests`) jumps there on `Enter`, `Tab` completes
--- its last segment. `Enter` on the `.` row or `Alt-d` searches here:
--- the step hands the directory back as the request's scope.
---
--- Directories come from `Session:tree`, the eligible inventory of the
--- root, so the hidden and ignored switches hold and `.git` never shows;
--- the tree is indexed once per switch combination, and keystrokes only
--- filter it. The step is a state object driven by the search UI
--- (`iara.features.search.ui`), which owns the picker; `host` draws.
local icons = require("iara.core.icons")
local dirs = require("iara.features.search.dirs")
local layout = require("iara.features.picker.layout")
local modal = require("iara.features.picker.modal")

local M = {}

local ICON = icons.FOLDER .. " "
local OPEN_ICON = icons.FOLDER_OPEN .. " "
local SPINNER =
  { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 80
local KINDS = { dir = true, dir_here = true, dir_up = true, entry = true }
-- Path lists are immutable. Drop their indexes when their owners release them.
local indexes = setmetatable({}, { __mode = "k" })

local function index(result)
  local paths = result.paths
  local complete = result.state == "complete"
  local tree = indexes[paths]
  if not tree or tree.complete ~= complete then
    tree = dirs.index(paths, complete)
    indexes[paths] = tree
  end
  return tree
end

---@class IaraSearchDirHost
---@field render fun(rows: table[], cursor_id: string?) Show the rows.
---@field set_prompt fun(text: string) Show `text` in the prompt.
---@field redraw fun() Redraw the title, footer, and status.
---@field leave fun(path: string|false|nil) End the step; a path ("" is
---  the root) scopes the search, false clears the scope, nil cancels.
---@field open fun(path: string) (S10) Close the picker, edit the file.

---@class IaraSearchDirStep
---@field root string Absolute root.
---@field from string Root-relative directory shown.
---@field query string Typed text.
---@field tree IaraSearchDirTree|nil Nil while it loads.
---@field message string|nil Inline notice: an error of the last action.
---@field message_level string|nil "error" (default) or "notice".
---@field focus string|nil Row id to put the cursor on.
---@field expanded table<string, true> (S10) Directories shown open.
---@field waiting function[] (V12) Keys that arrived while the tree was
---  listed, run in order once it is.
local Step = {}
Step.__index = Step

---@param row table|nil
---@return boolean
function M.is_selectable(row)
  return row ~= nil and row.iara ~= nil and KINDS[row.iara.kind] == true
end

---Root-relative directory of the scope `request.scope` names.
local function scope_dir(root, scope)
  if scope.kind == "root" or not scope.path then
    return ""
  end
  local path = scope.kind == "file" and vim.fs.dirname(scope.path) or scope.path
  return vim.fs.relpath(root, path) or ""
end

---Open the step for `session` in the directory of its current scope.
---@param session table Search session (`Session:tree`, `snapshot`).
---@param host IaraSearchDirHost
---@return IaraSearchDirStep
function M.new(session, host)
  local snapshot = session:snapshot()
  local root = snapshot.root.path
  local from = scope_dir(root, snapshot.request.scope)
  local step = setmetatable({
    session = session,
    host = host,
    root = root,
    from = from == "." and "" or from,
    query = "",
    expanded = {},
    waiting = {},
  }, Step)
  step:load()
  return step
end

---(Re)load the tree under the session's current switches.
function Step:load()
  if self.handle then
    self.handle:cancel()
  end
  self.tree, self.failure = nil, nil
  self.handle = self.session:tree(function(result)
    self.handle = nil
    if result.state == "error" then
      self.failure = result.error and result.error.message or "error"
      self.tree = dirs.index({}, true)
    else
      self.tree = index(result)
    end
    if not self.tree.dirs[self.from] then
      self.from = ""
    end
    self:show()
    self:run_waiting()
  end)
  self:show()
end

---(V12) Keys typed ahead of the listing (a fast `<A-d>src<CR>`) reach
---the step before its tree: each waits, with the text typed by then,
---and runs once the tree is there, so none of them is lost.
---@param action fun() Runs with the step listed and its query restored.
function Step:when_listed(action)
  if self.tree then
    return action()
  end
  local query = self.query
  table.insert(self.waiting, function()
    self.query = query
    action()
  end)
end

---The row the cursor starts on: the first directory listed.
---@return table|nil
function Step:first_dir()
  for _, candidate in ipairs(self:rows()) do
    if candidate.iara.kind == "dir" then
      return candidate
    end
  end
end

function Step:run_waiting()
  local waiting = self.waiting
  self.waiting = {}
  for _, action in ipairs(waiting) do
    if self.closed then
      return
    end
    action()
  end
end

function Step:close()
  if self.handle then
    self.handle:cancel()
    self.handle = nil
  end
  self.waiting = {}
  self.closed = true
end

---@return boolean
function Step:busy()
  return self.tree == nil and not self.closed
end

-- Rows ------------------------------------------------------------------

local function row(id, data)
  return { text = id, positions = {}, iara = data }
end

local function notice_row(text, level)
  return row("notice", {
    kind = "notice",
    notice = { text = text, level = level or "error" },
  })
end

local function placeholder_row(text)
  return row("placeholder", {
    kind = "placeholder",
    text = text,
    centered = true,
  })
end

---The `.` and `..` rows of an unfiltered listing of `from`.
local function anchor_rows(self)
  local here = self.tree.dirs[self.from]
  local rows = {
    row("dir_here", {
      kind = "dir_here",
      path = self.from,
      label = ".",
      files = here.files,
      hint = "search here",
    }),
  }
  local parent = dirs.parent(self.from)
  if parent then
    table.insert(
      rows,
      row("dir_up", {
        kind = "dir_up",
        path = parent,
        label = "..",
        hint = "up to " .. dirs.crumb(self.root, parent),
      })
    )
  end
  return rows
end

local function entry_rows(listing, rows)
  local entries = listing.entries
  for index, item in ipairs(entries) do
    table.insert(
      rows,
      row("dir:" .. item.path, {
        kind = "dir",
        path = item.path,
        label = item.label,
        files = item.files,
        positions = item.positions,
        branch = not listing.filtered
          and (index == #entries and "└ " or "├ "),
      })
    )
  end
  local more = listing.total - #entries
  if more > 0 then
    local text = ("%d more; type to narrow"):format(more)
    table.insert(rows, row("more", { kind = "placeholder", text = text }))
  end
end

---Subdirectories, then files, of directory `path`.
local function tree_items(dir)
  local items = {}
  for _, child in ipairs(dir.children) do
    items[#items + 1] = { dir = child }
  end
  for _, name in ipairs(dir.names) do
    items[#items + 1] = { name = name }
  end
  return items
end

local function item_row(self, path, item, branch)
  if item.dir then
    local dir = self.tree.dirs[item.dir]
    return row("dir:" .. item.dir, {
      kind = "dir",
      path = item.dir,
      label = dir.name,
      files = dir.files,
      branch = branch,
      open = self.expanded[item.dir] == true,
    })
  end
  local rel = path == "" and item.name or path .. "/" .. item.name
  return row("entry:" .. rel, {
    kind = "entry",
    path = rel,
    label = item.name,
    branch = branch,
  })
end

---(S10) Rows of directory `path` as a tree: its subdirectories (the
---expanded ones followed by their own rows, indented), then its files.
local function tree_rows(self, path, prefix, rows)
  local items = tree_items(self.tree.dirs[path])
  local count = math.min(#items, dirs.LIMIT)
  for index = 1, count do
    local last = index == #items
    local branch = prefix .. (last and "└ " or "├ ")
    local item = items[index]
    rows[#rows + 1] = item_row(self, path, item, branch)
    if item.dir and self.expanded[item.dir] then
      tree_rows(self, item.dir, prefix .. (last and "  " or "│ "), rows)
    end
  end
  if #items > count then
    local text = ("%s%d more"):format(prefix, #items - count)
    rows[#rows + 1] =
      row("more:" .. path, { kind = "placeholder", text = text })
  end
end

---Rows of the current state: a notice, then `.` and `..` when nothing
---is typed, then the tree of `from`, or the directories listed or
---matched for the typed text.
---@return table[] rows
function Step:rows()
  if not self.tree then
    return { placeholder_row("Listing directories…") }
  end
  local rows = {}
  local message = self.message or self.failure
  local listing, invalid =
    dirs.list(self.tree, self.root, self.from, self.query)
  message = message or invalid
  if message then
    local level = self.message and self.message_level or "error"
    table.insert(rows, notice_row(message, level))
  end
  if self.query == "" then
    vim.list_extend(rows, anchor_rows(self))
    tree_rows(self, self.from, "", rows)
  elseif listing then
    entry_rows(listing, rows)
  end
  if #rows == 0 or (listing and listing.filtered and listing.total == 0) then
    table.insert(rows, placeholder_row("No directories match"))
  end
  return rows
end

---Rows to the host, the cursor on `focus` or the first directory.
function Step:show()
  if self.closed then
    return
  end
  local rows = self:rows()
  local cursor = nil
  for _, candidate in ipairs(rows) do
    if candidate.text == self.focus then
      cursor = candidate.text
      break
    end
    local kind = candidate.iara.kind
    cursor = cursor or (kind == "dir" and candidate.text or nil)
  end
  self.host.render(rows, cursor or "dir_here")
  self.host.redraw()
end

---(S10) Show `message` as the notice row ("error" or "notice").
---@param message string
---@param level string|nil
function Step:notify(message, level)
  self.message, self.message_level = message, level
  self:show()
end

-- Navigation ------------------------------------------------------------

---Show directory `path` with an empty prompt; the cursor goes to
---`focus` (the directory left when going up).
function Step:go(path, focus)
  self.from, self.query, self.message = path, "", nil
  self.focus = focus
  self.host.set_prompt("")
  self:show()
end

---Go to the parent directory; false at the root.
---@return boolean
function Step:up()
  local parent = dirs.parent(self.from)
  if not parent or not self.tree then
    return false
  end
  self:go(parent, "dir:" .. self.from)
  return true
end

---The prompt changed.
---@param text string
function Step:on_query(text)
  if text == self.query then
    return
  end
  self.query, self.message, self.focus = text, nil, nil
  self:show()
end

---A typed plain name (no path syntax) may stand for the row under the
---cursor; anything with `/` or dots must resolve on its own.
local function is_path_syntax(query)
  return query:find("/", 1, true) ~= nil or query:match("^%.%.?$") ~= nil
end

local function fail(self, message)
  self:notify(message)
end

---Act on a row: `.` searches here, `..` goes up, a file opens; a
---directory goes through `on_dir`.
local function act(self, data, on_dir)
  if data.kind == "dir_here" then
    return self.host.leave(self.from)
  end
  if data.kind == "dir_up" then
    return self:up()
  end
  if data.kind == "entry" then
    return self.host.open(vim.fs.joinpath(self.root, data.path))
  end
  on_dir(data.path)
end

---(S10) Expand or collapse directory `path` in place.
---@param path string
function Step:toggle(path)
  self.expanded[path] = not self.expanded[path] or nil
  self.focus = "dir:" .. path
  self:show()
end

---`Enter`: jump to the typed path, or act on the row under the cursor:
---a directory expands or collapses (with typed text, it is gone into).
---@param current table|nil Row under the cursor.
function Step:confirm(current)
  if not self.tree then
    return self:when_listed(function()
      self:confirm(self:first_dir())
    end)
  end
  local typed = self.query ~= ""
  if typed then
    local path, message =
      dirs.resolve(self.tree, self.root, self.from, self.query)
    if path then
      return self:go(path)
    end
    if is_path_syntax(self.query) or not M.is_selectable(current) then
      return fail(self, message)
    end
  end
  if M.is_selectable(current) then
    act(self, current.iara, function(path)
      return typed and self:go(path) or self:toggle(path)
    end)
  end
end

---(S10) `l`: go into the directory under the cursor (or act on `.`,
---`..`, or a file like `Enter`).
---@param current table|nil
function Step:enter(current)
  if self.tree and M.is_selectable(current) then
    act(self, current.iara, function(path)
      self:go(path)
    end)
  end
end

---Directory to open in Oil for the current row.
---@param current table|nil
---@return string
function Step:oil_directory(current)
  local data = current and current.iara
  local path = self.from
  if data and (data.kind == "dir" or data.kind == "dir_up") then
    path = data.path
  elseif data and data.kind == "entry" then
    path = dirs.parent(data.path) or ""
  end
  return vim.fs.joinpath(self.root, path)
end

---`Alt-d`: search the typed directory, or the one shown.
function Step:search_here()
  if not self.tree then
    return self:when_listed(function()
      self:search_here()
    end)
  end
  if self.query == "" then
    return self.host.leave(self.from)
  end
  local path, message =
    dirs.resolve(self.tree, self.root, self.from, self.query)
  if not path then
    return fail(self, message)
  end
  self.host.leave(path)
end

---`Tab`: complete the typed path, else take the row under the cursor.
---@param current table|nil
function Step:complete(current)
  if not self.tree then
    return self:when_listed(function()
      self:complete(self:first_dir())
    end)
  end
  local completed = dirs.complete(self.tree, self.root, self.from, self.query)
  local data = M.is_selectable(current) and current.iara or {}
  if not completed and data.kind == "dir_up" then
    completed = "../"
  elseif not completed and data.kind == "dir" then
    local prefix = self.from == "" and 0 or #self.from + 1
    completed = data.path:sub(prefix + 1) .. "/"
  end
  if completed then
    self.host.set_prompt(completed)
    self:on_query(completed)
  end
end

-- Presentation ----------------------------------------------------------

---Path chunks: dimmed parent, bright last component, matched bytes.
local function label_chunks(data, offset)
  local label = dirs.shown(data.label)
  local parent, name = label:match("^(.*/)([^/]*)$")
  parent, name = parent or "", name or label
  local chunks = {
    { parent, "IaraSearchDir" },
    { name .. (data.kind == "dir" and "/" or ""), "IaraSearchGroupFile" },
  }
  if label == data.label then
    for _, position in ipairs(data.positions or {}) do
      table.insert(chunks, {
        col = offset + position,
        end_col = offset + position + 1,
        hl_group = "IaraSearchMatch",
      })
    end
  end
  return chunks
end

---Highlighted text of a file row (S10): branch, file icon, name.
local function entry_chunks(data)
  return {
    { data.branch or "", "IaraSearchCrumbSeparator" },
    { icons.file(data.label) .. " ", "IaraSearchDir" },
    { dirs.shown(data.label), "IaraSearchFile" },
  }
end

---Highlighted text of a directory row: tree branch, icon (open when
---expanded), path, a dim hint, and the count of searchable files as a
---chip at the right; a file row in the tree has its icon and name.
---@param data table `row.iara` of a directory or file row.
---@return table[] chunks
function M.format(data)
  if data.kind == "entry" then
    return entry_chunks(data)
  end
  local branch = data.branch or ""
  local icon = data.open and OPEN_ICON or ICON
  local chunks = {
    { branch, "IaraSearchCrumbSeparator" },
    { icon, "IaraSearchGroupFile" },
  }
  vim.list_extend(chunks, label_chunks(data, #branch + #icon))
  if data.hint then
    table.insert(chunks, { "  " .. data.hint, "IaraSearchPlaceholder" })
  end
  if data.files then
    table.insert(chunks, {
      col = 0,
      virt_text = { { " " .. data.files .. " ", "IaraSearchGroupCount" } },
      virt_text_pos = "right_align",
    })
  end
  return chunks
end

---Title chunks: the search's title (idle), then the directory shown as
---the focused breadcrumb step (`Find files › 󰉋 src`).
---@param search_title string
---@param focused boolean?
---@return table[] chunks
function Step:title(search_title, focused)
  local crumb = ICON .. dirs.crumb(self.root, self.from)
  return {
    { " " .. search_title, layout.title_group(false) },
    { " › ", "IaraSearchCrumbSeparator" },
    { crumb .. " ", layout.title_group(focused ~= false) },
  }
end

local INSERT_HINTS = {
  { "⏎", "expand" },
  { "A-d", "search here" },
  { "BS", "up" },
  { "Tab", "complete" },
  { "A-x", "whole root" },
  { "C-o", "cancel" },
}

local NORMAL_HINTS = {
  { "⏎", "expand" },
  { "l", "open" },
  { "h", "up" },
  { "E", "Oil" },
  { "A-d", "search here" },
  { "q", "close" },
}

---Footer chunks of the step's keys that fit in `width`.
---@param normal boolean
---@param width integer
---@return table[] chunks
function M.footer(normal, width)
  return modal.footer(normal and NORMAL_HINTS or INSERT_HINTS, width)
end

---Prompt status: a spinner while the tree loads, then the count.
---@param now integer Milliseconds.
---@return table[] chunks
function Step:status(now)
  if not self.tree then
    local frame = math.floor(now / SPINNER_MS) % #SPINNER + 1
    return { { SPINNER[frame] .. " ", "IaraSearchSpinner" } }
  end
  local listing = dirs.list(self.tree, self.root, self.from, self.query)
  if not listing then
    return {}
  end
  local count = listing.total
  local noun = count == 1 and "directory" or "directories"
  return { { ("%d %s "):format(count, noun), "IaraSearchCount" } }
end

---Preview lines of a directory row: its path, file count,
---subdirectories, and (S10) its files.
---@param data table `row.iara`.
---@return string[]|nil lines
function Step:preview(data)
  local dir = self.tree and self.tree.dirs[data.path]
  if not dir then
    return nil
  end
  local lines = {
    dirs.crumb(self.root, dir.path) .. "/",
    ("%d searchable files"):format(dir.files),
    "",
  }
  for _, path in ipairs(dir.children) do
    local child = self.tree.dirs[path]
    table.insert(
      lines,
      ("  %s/  %d"):format(dirs.shown(child.name), child.files)
    )
  end
  for _, name in ipairs(dir.names) do
    table.insert(lines, "  " .. dirs.shown(name))
  end
  return lines
end

return M
