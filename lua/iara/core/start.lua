--- Start screen (UX3, V6): a Braille wave, a tagline, the actions,
--- the project's recent files, and a footer with the
--- project, branch, Neovim version, and startup time. Shown when Iara
--- starts without file arguments on an empty buffer with a UI attached.
---
--- `nvim file` pays only the argument check. The screen is a scratch
--- buffer wiped as soon as another buffer replaces it in its window, so
--- opening a file (from a picker, the tree, or `:edit`) closes it; `i`
--- starts editing a new empty buffer. Window options it changes are local
--- to the screen, so the next buffer in that window gets the usual ones.
--- Actions whose command is not defined (a disabled feature) are hidden.
---
--- Costs, paid once when the screen opens: recent files come from
--- `v:oldfiles` (in memory after ShaDa) with one `filereadable()` per
--- candidate under the project root; the branch is read from the root's
--- `.git/HEAD` (Git never runs). Moving the cursor only moves one extmark.
local icons = require("iara.core.icons")

local M = {}

M.FILETYPE = "iara-start"

M.TAGLINE = "Edit, search, and run in one place"

---@class IaraStartAction
---@field key string Key that runs the action on the screen.
---@field icon string
---@field label string
---@field command string Ex command; the action shows when it exists.

---@type IaraStartAction[]
M.ACTIONS = {
  {
    key = "f",
    icon = icons.ACTIONS.files,
    label = "Find files",
    command = "IaraFiles",
  },
  {
    key = "w",
    icon = icons.ACTIONS.grep,
    label = "Find in files",
    command = "IaraGrep",
  },
  {
    key = "r",
    icon = icons.ACTIONS.recent,
    label = "Recent files",
    command = "IaraRecent",
  },
  { key = "e", icon = icons.ACTIONS.new, label = "New file", command = "enew" },
  {
    key = "t",
    icon = icons.ACTIONS.terminal,
    label = "Terminal",
    command = "IaraTermToggle",
  },
  {
    key = "h",
    icon = icons.ACTIONS.themes,
    label = "Themes",
    command = "IaraTheme",
  },
  { key = "q", icon = icons.ACTIONS.quit, label = "Quit", command = "qall" },
}

---Most recent files shown; digits `1`..`RECENT_LIMIT` open them.
M.RECENT_LIMIT = 5

-- Bounds the `filereadable()` calls when old files under the root are
-- gone (deleted branches, moved trees).
local CHECK_LIMIT = 20
local MENU_WIDTH = 50
local SEPARATOR = "  ·  "

local did_setup = false
local stdin = false
local wave_animation = true
local focused = true
local motion

---@type number|nil Milliseconds from `init.lua` entry to VimEnter.
local startup_ms = nil

-- The screen on display: its buffer, what it shows, per row the action
-- or file that Enter runs there, the selectable rows in order, the
-- column of the selection bar, and the selected item.
local state = { buf = nil, info = nil, items = {}, rows = {}, bar_col = 0 }

local namespace = vim.api.nvim_create_namespace("iara.start")
local cursor_namespace = vim.api.nvim_create_namespace("iara.start.cursor")

---Whether the startup state calls for the screen: no file arguments, no
---standard input, an empty unnamed buffer, and an attached UI.
---@return boolean
function M.wanted()
  if vim.fn.argc() > 0 or stdin or #vim.api.nvim_list_uis() == 0 then
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_name(bufnr) == ""
    and vim.bo[bufnr].buftype == ""
    and not vim.bo[bufnr].modified
    and vim.api.nvim_buf_line_count(bufnr) == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] == ""
end

---Actions whose command exists now.
---@return IaraStartAction[]
function M.available()
  return vim.tbl_filter(function(action)
    return vim.fn.exists(":" .. action.command) == 2
  end, M.ACTIONS)
end

---@return integer|nil bufnr The start screen buffer while it exists.
function M.buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  return nil
end

---@class IaraStartFile
---@field path string Absolute path, as in `v:oldfiles`.
---@field name string Path relative to the project root.
---@field key string Digit that opens it.

---The most recent readable files under `root`, from `v:oldfiles`.
---@param root string Absolute project directory.
---@param limit integer
---@return IaraStartFile[]
function M.recent_files(root, limit)
  local prefix = root:gsub("/+$", "") .. "/"
  local files, checked = {}, 0
  for _, entry in ipairs(vim.v.oldfiles or {}) do
    if #files >= limit or checked >= CHECK_LIMIT then
      break
    end
    local path = vim.fs.normalize(entry)
    if vim.startswith(path, prefix) then
      checked = checked + 1
      if vim.fn.filereadable(path) == 1 then
        local key = tostring(#files + 1)
        local name = path:sub(#prefix + 1)
        table.insert(files, { path = path, name = name, key = key })
      end
    end
  end
  return files
end

local function first_line(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local line = file:read("*l")
  file:close()
  return line
end

---Branch checked out at `root`, read from its HEAD without running Git;
---nil without a repository or with a detached HEAD.
---@param root string Absolute project directory.
---@return string|nil
function M.branch(root)
  local head = first_line(root .. "/.git/HEAD")
  if not head then
    -- A linked worktree: `.git` is a file naming the real directory.
    local link = first_line(root .. "/.git")
    local dir = link and link:match("^gitdir:%s*(.-)%s*$")
    if dir and dir ~= "" then
      if dir:sub(1, 1) ~= "/" then
        dir = root .. "/" .. dir
      end
      head = first_line(dir .. "/HEAD")
    end
  end
  return head and head:match("^ref:%s*refs/heads/(.-)%s*$")
end

---The project of the screen: the root of the startup directory, which
---the screen also records as its buffer's context root.
local function project_root(bufnr)
  local cwd = vim.fn.getcwd()
  vim.b[bufnr].iara_context_root = cwd
  local ok, root = pcall(function()
    return require("iara.core.root").resolve(bufnr).path
  end)
  return ok and root or cwd
end

---@class IaraStartInfo
---@field actions IaraStartAction[]
---@field project string|nil Project name.
---@field branch string|nil
---@field files IaraStartFile[]
---@field startup_ms number|nil

---What the screen shows for buffer `bufnr`, gathered once.
---@return IaraStartInfo
local function collect(bufnr)
  local root = project_root(bufnr)
  local name = vim.fs.basename(root)
  return {
    actions = M.available(),
    project = name ~= "" and name or root,
    branch = M.branch(root),
    files = M.recent_files(root, M.RECENT_LIMIT),
    startup_ms = startup_ms,
  }
end

---@class IaraStartRow
---@field text string Content without the centering margin.
---@field marks {[1]: integer, [2]: integer, [3]: string}[] Byte ranges
---  of `text` and their groups.
---@field wave table|nil Artwork and width on its first row.
---@field menu boolean|nil In the left-aligned menu block.
---@field item table|nil Action or file that Enter runs on this row.

local function row(text, group)
  return { text = text, marks = group and { { 0, #text, group } } or {} }
end

---`text` cut at the left with an ellipsis to fit `room` cells.
local function fit(text, room)
  if vim.api.nvim_strwidth(text) <= room then
    return text
  end
  local chars = vim.fn.strchars(text)
  return "…" .. vim.fn.strcharpart(text, chars - math.max(room - 1, 0))
end

local function wave_for(width, height)
  for _, wave in ipairs(require("iara.core.start_wave")) do
    if wave.min_width <= width and #wave.still <= height then
      return wave
    end
  end
end

local function wave_line(line, canvas, width)
  if width >= canvas then
    return line .. (" "):rep(width - vim.api.nvim_strwidth(line))
  end
  -- Sample both ends of the canvas to keep its edges at the menu edges.
  local chars = vim.fn.split(line, "\\zs")
  local sample = {}
  for col = 1, width do
    local source = (col - 1) * (canvas - 1) / (width - 1)
    sample[col] = chars[math.floor(source + 0.5) + 1] or " "
  end
  return table.concat(sample)
end

local WAVE_TONES = {
  "IaraStartWaveTide",
  "IaraStartWaveMid",
  "IaraStartWaveFoam",
}

-- Number of cells before a tone boundary after nearest-neighbor sampling.
local function fitted_boundary(source, canvas, width)
  if width >= canvas then
    return source
  end
  return math.ceil((source - 0.5) * (width - 1) / (canvas - 1))
end

local function tinted_wave_line(encoded, canvas, width)
  local spans, groups = {}, {}
  for tone, span in encoded:gmatch("([123])([^123]+)") do
    table.insert(spans, span)
    table.insert(groups, WAVE_TONES[tonumber(tone)])
  end
  local line = wave_line(table.concat(spans), canvas, width)
  local chunks, source, left = {}, 0, 0
  for index, span in ipairs(spans) do
    source = source + vim.api.nvim_strwidth(span)
    local right = fitted_boundary(source, canvas, width)
    if right > left then
      local text = vim.fn.strcharpart(line, left, right - left)
      table.insert(chunks, { text, groups[index] })
      left = right
    end
  end
  if left < width then
    table.insert(chunks, { vim.fn.strcharpart(line, left), WAVE_TONES[1] })
  end
  return chunks
end

local function wave_row(line, canvas, width)
  local entry = row("")
  for _, chunk in ipairs(tinted_wave_line(line, canvas, width)) do
    local col = #entry.text
    entry.text = entry.text .. chunk[1]
    table.insert(entry.marks, { col, #entry.text, chunk[2] })
  end
  return entry
end

local function header(wave, width)
  if not wave then
    return {}
  end
  local rows = {}
  for _, line in ipairs(wave.still) do
    table.insert(rows, wave_row(line, wave.width, width))
  end
  rows[1].wave = { variant = wave, width = width }
  return rows
end

---A menu row: the bar slot, icon, label, and the key chip at the right.
---@param entry { icon: string, icon_group: string, label: string,
---  label_group: string, key: string, item: table }
local function menu_row(entry, width)
  local lead = "  " .. entry.icon .. "  "
  local chip = " " .. entry.key .. " "
  local room = width - vim.api.nvim_strwidth(lead) - #chip - 1
  local label = fit(entry.label, room)
  local gap = (" "):rep(room - vim.api.nvim_strwidth(label) + 1)
  local text = lead .. label .. gap .. chip
  return {
    text = text,
    menu = true,
    item = entry.item,
    marks = {
      { 2, 2 + #entry.icon, entry.icon_group },
      { #lead, #lead + #label, entry.label_group },
      { #text - #chip, #text, "IaraStartKey" },
    },
  }
end

local function action_rows(actions, width)
  local rows = {}
  for _, action in ipairs(actions) do
    table.insert(
      rows,
      menu_row({
        icon = action.icon,
        icon_group = "IaraStartIcon",
        label = action.label,
        label_group = "IaraStartAction",
        key = action.key,
        item = action,
      }, width)
    )
  end
  return rows
end

local function file_rows(info, width)
  if #info.files == 0 then
    return {}
  end
  local title = "  Recent in " .. fit(info.project, width - 16)
  local room = width - vim.api.nvim_strwidth(title) - 1
  local glyph = icons.START.rule
  local cells = vim.api.nvim_strwidth(glyph)
  local rule = glyph:rep(math.floor(room / cells)) .. (" "):rep(room % cells)
  local heading = { text = title .. " " .. rule, menu = true }
  heading.marks = {
    { 2, #title, "IaraStartSection" },
    { #title + 1, #heading.text, "IaraStartRule" },
  }
  local rows = { heading }
  for _, file in ipairs(info.files) do
    local entry = {
      icon = icons.file(file.name),
      icon_group = "IaraStartFileIcon",
      label = file.name,
      label_group = "IaraStartFile",
      key = file.key,
      item = file,
    }
    table.insert(rows, menu_row(entry, width))
  end
  return rows
end

local function footer_row(info)
  local parts = { fit(info.project, 24) }
  if info.branch then
    table.insert(parts, fit(info.branch, 24))
  end
  local version = vim.version()
  table.insert(
    parts,
    ("nvim %d.%d.%d"):format(version.major, version.minor, version.patch)
  )
  if info.startup_ms then
    table.insert(parts, ("%d ms"):format(math.floor(info.startup_ms + 0.5)))
  end
  local mark = icons.START.mark .. "  "
  local text = mark .. table.concat(parts, SEPARATOR)
  return {
    text = text,
    marks = {
      { 0, #icons.START.mark, "IaraStartMark" },
      { #mark, #text, "IaraStartFooter" },
    },
  }
end

-- The wave and the menu share the same width for aligned edges.
local function blocks(info, width, wave)
  local tagline = {}
  if vim.api.nvim_strwidth(M.TAGLINE) <= width then
    tagline = { row(M.TAGLINE, "IaraStartText") }
  end
  return {
    head = header(wave, width),
    tagline = tagline,
    actions = action_rows(info.actions, width),
    files = file_rows(info, width),
    footer = { footer_row(info) },
  }
end

-- Layouts from the richest down, using the compact wave first.
-- Blank rows shrink, then the recent files go, then the tagline.
local LAYOUTS = {
  { gap = 2, blocks = { "head", "tagline", "actions", "files", "footer" } },
  { gap = 1, blocks = { "head", "tagline", "actions", "files", "footer" } },
  { gap = 2, blocks = { "head", "tagline", "actions", "footer" } },
  { gap = 1, blocks = { "head", "tagline", "actions", "footer" } },
  { gap = 1, blocks = { "head", "actions", "footer" } },
}

local function stack(parts, layout)
  local rows = {}
  for _, name in ipairs(layout.blocks) do
    if #parts[name] > 0 then
      for _ = 1, #rows > 0 and layout.gap or 0 do
        table.insert(rows, row(""))
      end
      vim.list_extend(rows, parts[name])
    end
  end
  return rows
end

---Rows of the screen for a window of `width` x `height` cells: the
---richest layout that fits (the last one when none does).
---@param info IaraStartInfo
---@param width integer
---@param height integer
---@return IaraStartRow[]
function M.layout(info, width, height)
  local block_width = math.min(MENU_WIDTH, width - 2)
  local compact = wave_for(block_width, 3)
  local parts = blocks(info, block_width, compact)
  for _, layout in ipairs(LAYOUTS) do
    local rows = stack(parts, layout)
    if #rows <= height then
      -- Use only spare rows for larger art; keep the chosen menu layout.
      local wave = wave_for(block_width, #parts.head + height - #rows)
      if wave == compact then
        return rows
      end
      parts.head = header(wave, block_width)
      return stack(parts, layout)
    end
  end
  parts.head = {}
  return stack(parts, LAYOUTS[#LAYOUTS])
end

local function center_col(width, text)
  return math.max(math.floor((width - vim.api.nvim_strwidth(text)) / 2), 0)
end

---Left column of the menu block: centered on its widest row.
local function menu_col(rows, width)
  local widest = 0
  for _, entry in ipairs(rows) do
    if entry.menu then
      widest = math.max(widest, vim.api.nvim_strwidth(entry.text))
    end
  end
  return math.max(math.floor((width - widest) / 2), 0)
end

local function place(bufnr, rows, width, top)
  local menu = menu_col(rows, width)
  local lines = {}
  for _ = 1, top do
    table.insert(lines, "")
  end
  for _, entry in ipairs(rows) do
    local col = entry.menu and menu or center_col(width, entry.text)
    entry.col = col
    table.insert(lines, (" "):rep(col) .. entry.text)
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  return menu
end

local function highlight(bufnr, rows, top)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for index, entry in ipairs(rows) do
    for _, mark in ipairs(entry.marks) do
      vim.api.nvim_buf_set_extmark(
        bufnr,
        namespace,
        top + index - 1,
        entry.col + mark[1],
        {
          end_col = entry.col + mark[2],
          hl_group = mark[3],
        }
      )
    end
  end
end

local function stop_motion()
  if motion then
    motion.stop()
  end
end

local function wave_frame(art, frame)
  local chunks = {}
  local wave = art.variant
  for index, line in ipairs(wave.frames[frame]) do
    chunks[index] = tinted_wave_line(line, wave.width, art.width)
  end
  return chunks
end

local function sync_motion()
  local art = state.art
  if
    not wave_animation
    or not focused
    or not art
    or vim.fn.bufwinid(state.buf) == -1
    or #vim.api.nvim_list_uis() == 0
  then
    stop_motion()
    return
  end
  motion = motion or require("iara.core.start_motion")
  motion.play(state.buf, art.top, art.col, #art.variant.frames, function(frame)
    return wave_frame(art, frame)
  end)
end

local function toggle_motion()
  wave_animation = not wave_animation
  sync_motion()
  local status = wave_animation and "enabled" or "disabled"
  vim.notify("Iara: wave animation " .. status, vim.log.levels.INFO)
end

---Draw the screen at the window's current dimensions.
local function draw(bufnr, width, height)
  stop_motion()
  state.width, state.height = width, height
  local rows = M.layout(state.info, width, height)
  local top = math.max(math.floor((height - #rows) / 2), 0)
  state.bar_col = place(bufnr, rows, width, top)
  highlight(bufnr, rows, top)
  local first = rows[1]
  state.art = first and first.wave
  if state.art then
    state.art.top = top
    state.art.col = first.col
  end
  sync_motion()
  state.items, state.rows = {}, {}
  for index, entry in ipairs(rows) do
    if entry.item then
      state.items[top + index] = entry.item
      table.insert(state.rows, top + index)
    end
  end
end

---Row of `item` on the screen, else the first selectable row.
local function row_of(item)
  for _, line in ipairs(state.rows) do
    if state.items[line] == item then
      return line
    end
  end
  return state.rows[1]
end

local function nearest(line)
  local best = state.rows[1]
  for _, candidate in ipairs(state.rows) do
    if math.abs(candidate - line) < math.abs(best - line) then
      best = candidate
    end
  end
  return best
end

---Keep the cursor on a selectable row, on its icon, and mark that row
---with the selection background and the accent bar.
local function show_cursor()
  local bufnr = M.buffer()
  if not bufnr or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, cursor_namespace, 0, -1)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = nearest(cursor[1])
  if not line then
    return
  end
  local col = state.bar_col + 2
  if cursor[1] ~= line or cursor[2] ~= col then
    vim.api.nvim_win_set_cursor(0, { line, col })
  end
  state.selected = state.items[line]
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, true)[1]
  local mark = {
    end_col = #text,
    hl_group = "IaraStartCursor",
    priority = 100,
    virt_text = { { icons.START.bar, "IaraStartBar" } },
    virt_text_pos = "overlay",
  }
  vim.api.nvim_buf_set_extmark(
    bufnr,
    cursor_namespace,
    line - 1,
    state.bar_col,
    mark
  )
end

---Put the cursor on `line` and mark it.
local function select_row(line)
  if line then
    vim.api.nvim_win_set_cursor(0, { line, state.bar_col + 2 })
  end
  show_cursor()
end

---Move to the next (`step` 1) or previous (-1) selectable row.
local function move(step)
  local current = vim.api.nvim_win_get_cursor(0)[1]
  local target = current
  local first, last = 1, #state.rows
  if step < 0 then
    first, last = last, first
  end
  for index = first, last, step do
    if (state.rows[index] - current) * step > 0 then
      target = state.rows[index]
      break
    end
  end
  select_row(target)
end

local function run(item)
  if item.command then
    vim.cmd(item.command)
  else
    vim.cmd.edit(vim.fn.fnameescape(item.path))
  end
end

local function run_at_cursor()
  local item = state.items[vim.api.nvim_win_get_cursor(0)[1]]
  if item then
    run(item)
  end
end

local function start_editing()
  vim.cmd.enew()
  vim.cmd.startinsert()
end

local function map_keys(bufnr)
  local function map(lhs, rhs, desc)
    local opts = { buffer = bufnr, desc = desc, nowait = true }
    vim.keymap.set("n", lhs, rhs, opts)
  end
  for _, item in
    ipairs(
      vim.list_extend(vim.list_slice(state.info.actions), state.info.files)
    )
  do
    map(item.key, function()
      run(item)
    end, item.label or item.name)
  end
  for lhs, step in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
    map(lhs, function()
      move(step)
    end, step > 0 and "Next item" or "Previous item")
  end
  map("<CR>", run_at_cursor, "Run the item")
  map("i", start_editing, "Edit a new file")
  map("a", start_editing, "Edit a new file")
end

local function set_window_options(win)
  local options = {
    number = false,
    relativenumber = false,
    cursorline = false,
    signcolumn = "no",
    foldcolumn = "0",
    list = false,
    colorcolumn = "",
    statuscolumn = "",
    spell = false,
  }
  for name, value in pairs(options) do
    -- Local to this buffer in the window (`:setlocal`): the next buffer
    -- shown there gets the window's usual values.
    vim.wo[win][0][name] = value
  end
end

local function create_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].iara_status_title = "Iara"
  return bufnr
end

local function redraw(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return
  end
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  -- One resize can emit both VimResized and WinResized.
  if width == state.width and height == state.height then
    return
  end
  -- The remembered item, not the cursor row: shrinking the window can
  -- move the cursor before VimResized runs.
  local selected = state.selected
  draw(bufnr, width, height)
  vim.api.nvim_win_call(win, function()
    select_row(row_of(selected))
  end)
end

---Close the screen's windows once a file shows in another window: a
---picker, the tree, or `:cfirst` may not reuse a `nofile` window and
---split a new one, and the start screen must never stay as a split.
---@param bufnr integer The start screen.
---@param file_buf integer Buffer that entered the current window.
local function close_beside(bufnr, file_buf)
  local win = vim.api.nvim_get_current_win()
  local floating = vim.api.nvim_win_get_config(win).relative ~= ""
  if vim.bo[file_buf].buftype ~= "" or floating then
    return
  end
  -- Scheduled: closing windows inside BufWinEnter can disturb the
  -- command that is opening the file.
  vim.schedule(function()
    for _, screen_win in ipairs(vim.fn.win_findbuf(bufnr)) do
      local tab = vim.api.nvim_win_get_tabpage(screen_win)
      local alone = #vim.api.nvim_tabpage_list_wins(tab) == 1
      if screen_win ~= win and not alone then
        pcall(vim.api.nvim_win_close, screen_win, false)
      end
    end
  end)
end

local function watch_motion(group)
  vim.api.nvim_create_autocmd(
    { "BufEnter", "WinEnter", "TabEnter", "UIEnter", "UILeave" },
    { group = group, callback = sync_motion }
  )
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = stop_motion,
  })
  -- A panel can leave a different window focused when the dashboard closes.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = vim.schedule_wrap(sync_motion),
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
    group = group,
    callback = function(args)
      focused = args.event == "FocusGained"
      sync_motion()
    end,
  })
end

local function watch(bufnr)
  local group = vim.api.nvim_create_augroup("IaraStart", { clear = true })
  watch_motion(group)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      close_beside(bufnr, args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      redraw(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = show_cursor,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      if state.buf == bufnr then
        stop_motion()
        state.buf = nil
        state.art = nil
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

---Show the start screen in the current window, replacing the empty
---startup buffer (or a start screen already there).
function M.open()
  local initial = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local bufnr = create_buffer()
  -- Set after the switch: a start screen shown before is wiped by it.
  vim.api.nvim_win_set_buf(win, bufnr)
  state.buf = bufnr
  set_window_options(win)
  vim.bo[bufnr].filetype = M.FILETYPE
  state.info = collect(bufnr)
  draw(bufnr, vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win))
  map_keys(bufnr)
  watch(bufnr)
  select_row(state.rows[1])
  if initial ~= bufnr and vim.api.nvim_buf_is_valid(initial) then
    pcall(vim.api.nvim_buf_delete, initial, {})
  end
end

---Recent files: the Snacks picker when snacks.nvim is installed, else
---the native `:browse oldfiles` list.
function M.recent()
  local ok, snacks = pcall(require, "snacks")
  if ok and type(snacks) == "table" and snacks.picker then
    snacks.picker.recent()
    return
  end
  vim.cmd("browse oldfiles")
end

---Milliseconds since `init.lua` recorded `vim.g.iara_startup_hrtime`.
---@return number|nil
local function elapsed_ms()
  local started = vim.g.iara_startup_hrtime
  if type(started) ~= "number" then
    return nil
  end
  return (vim.uv.hrtime() - started) / 1e6
end

---Register commands and show the start screen at VimEnter when wanted.
---@param config table Composed start screen configuration.
function M.setup(config)
  if did_setup then
    return
  end
  did_setup = true
  vim.api.nvim_create_user_command("IaraRecent", M.recent, {
    desc = "Recent files",
  })
  vim.api.nvim_create_user_command("IaraToggleWaveAnimation", toggle_motion, {
    desc = "Toggle the start screen wave animation",
  })
  local ui = type(config) == "table" and config.ui or {}
  wave_animation = type(ui) ~= "table" or ui.wave_animation ~= false
  if type(ui) == "table" and ui.start_screen == false then
    return
  end
  if vim.fn.argc() > 0 then
    return
  end
  local group = vim.api.nvim_create_augroup("IaraStartup", { clear = true })
  vim.api.nvim_create_autocmd("StdinReadPre", {
    group = group,
    callback = function()
      stdin = true
    end,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      startup_ms = elapsed_ms()
      if M.wanted() then
        M.open()
      end
    end,
  })
end

return M
