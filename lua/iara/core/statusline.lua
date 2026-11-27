--- Global statusline. File buffers (UX3, V4, V13) show, left to right:
--- the mode as a solid block in the mode's role, the file (icon, name,
--- modified dot), the Git branch and change counts (Gitsigns); in the
--- middle the LSP progress segment of `iara.core.progress` (V5, redrawn
--- on `IaraProgressChanged`); on the right the conservative-mode
--- reason, external change conflicts, diagnostic counts, the LSP
--- client, safe mode, the root (with the Iara mark for a trusted
--- project), and the cursor position. Segments are flat text on the
--- bar, set apart by spacing and color; only the mode is a filled
--- block, and nothing has caps or arrows (design 09, section 7). Narrow
--- screens drop the LSP name, then the Git counts, then the root
--- (`WIDTH_*`). Terminal windows show a clean name ("Terminal · zsh",
--- "Claude Code"), the job state, and the project instead of the
--- `term://` name (UX2); the tab line (`iara.core.tabline`) names
--- terminals the same way.
---
--- Drawing must stay cheap: it runs on every keystroke. Diagnostic
--- counts are cached per buffer and refreshed by DiagnosticChanged; the
--- file segment is cached per buffer until its name, flags, or icon source
--- change; the trusted-root mark is cached until the root changes; Git
--- data is read from Gitsigns' buffer variables; LSP names are read from
--- the attached clients (a short list; a forced stop detaches without a
--- reliable event to refresh a cache from). Each owner part comes from
--- its owner's `statusline()` function; a failing owner shows "?"
--- instead of raising, because an error in a statusline expression
--- repeats on every redraw. Each part has an `IaraStatus*` highlight
--- group defined by the theme.
local icons = require("iara.core.icons")

local M = {}

local EXPRESSION = "%!v:lua.require'iara.core.statusline'.render()"

-- Events after which the statusline text may differ.
local REDRAW_EVENTS = {
  "IaraRootChanged",
  "IaraEligibilityChanged",
  "IaraConflictDetected",
  "IaraConflictResolved",
  "IaraBufferReloaded",
  "IaraTerminalChanged",
  "IaraProgressChanged",
  "GitSignsUpdate",
}

-- Width tiers: below these widths the LSP name, the Git change counts,
-- and the root are left out, in that order.
M.WIDTH_LSP = 100
M.WIDTH_GIT_COUNTS = 80
M.WIDTH_ROOT = 70

-- The Iara mark (shared with the start screen), in a trusted project's
-- root segment.
M.MARK = icons.START.mark

---Mode label and highlight suffix by the first letter of the mode.
M.MODES = {
  n = { "NORMAL", "Normal" },
  i = { "INSERT", "Insert" },
  v = { "VISUAL", "Visual" },
  V = { "V-LINE", "Visual" },
  ["\22"] = { "V-BLOCK", "Visual" },
  s = { "SELECT", "Select" },
  S = { "S-LINE", "Select" },
  ["\19"] = { "S-BLOCK", "Select" },
  R = { "REPLACE", "Replace" },
  c = { "COMMAND", "Command" },
  r = { "CONFIRM", "Confirm" },
  ["!"] = { "SHELL", "Terminal" },
  t = { "TERMINAL", "Terminal" },
}

local SEVERITIES = {
  { "ERROR", "IaraStatusDiagError" },
  { "WARN", "IaraStatusDiagWarn" },
  { "INFO", "IaraStatusDiagInfo" },
  { "HINT", "IaraStatusDiagHint" },
}

local did_setup = false

---Cached text by buffer, refreshed by events.
---@type table<integer, string>
local diagnostics_cache = {}

---File segment by buffer, with the state it was drawn from.
---@type table<integer, { key: string, text: string }>
local file_cache = {}

---Whether the buffer's root is a trusted project, by buffer.
---@type table<integer, boolean>
local trusted_cache = {}

---Real paths of the personal `trusted_projects`, read once.
---@type table<string, true>|nil
local trusted_dirs = nil

---Escape text for literal display inside a statusline expression.
local function literal(text)
  return (text:gsub("%%", "%%%%"))
end

---Show `text` in highlight `group` (themed by iara.theme), then return
---to the StatusLine colors.
local function colored(group, text)
  return "%#" .. group .. "#" .. text .. "%*"
end

---Text of one owner's statusline part; "?" when the owner fails.
local function part(module, ...)
  local ok, text = pcall(function(...)
    return require(module).statusline(...)
  end, ...)
  if not ok or type(text) ~= "string" then
    return "?"
  end
  return text
end

---Buffer shown in the window whose statusline is being drawn.
local function drawn_window()
  local window = vim.g.statusline_winid
  if window and vim.api.nvim_win_is_valid(window) then
    return window
  end
  return vim.api.nvim_get_current_win()
end

local function drawn_buffer()
  return vim.api.nvim_win_get_buf(drawn_window())
end

---Root part, only for buffers that name a file or carry an owner's
---context root: resolving a fresh unnamed buffer would cache its root
---before an owner (terminal, picker) sets `iara_context_root`.
local function root_part(bufnr)
  local named = vim.api.nvim_buf_get_name(bufnr) ~= ""
  if not named and vim.b[bufnr].iara_context_root == nil then
    return ""
  end
  return part("iara.core.root")
end

---Clean description of a terminal buffer, nil for other buffers or when
---the terminal feature is not loaded or fails.
---@return IaraTerminalDescription|nil
function M.terminal_of(bufnr)
  if vim.bo[bufnr].buftype ~= "terminal" then
    return nil
  end
  local ok, description = pcall(function()
    return require("iara.features.terminal.title").describe(bufnr)
  end)
  return ok and description or nil
end

---Highlighted items, skipping empty texts, separated by two spaces.
local function join(entries)
  local items = {}
  for _, entry in ipairs(entries) do
    if entry[2] ~= "" then
      table.insert(items, colored(entry[1], literal(entry[2])))
    end
  end
  return table.concat(items, "  ")
end

local function safe_text()
  return vim.g.iara_mode == "safe" and "[safe]" or ""
end

local function read_trusted_dirs()
  local dirs = {}
  local ok, list = pcall(function()
    return require("iara.config").get("trusted_projects")
  end)
  for _, dir in ipairs(ok and type(list) == "table" and list or {}) do
    local real = type(dir) == "string" and vim.uv.fs_realpath(dir)
    if real then
      dirs[vim.fs.normalize(real)] = true
    end
  end
  return dirs
end

---Whether the root of `bufnr` is listed in the personal
---`trusted_projects`. Cached until the root changes.
---@param bufnr integer
---@return boolean
function M.trusted(bufnr)
  if trusted_cache[bufnr] == nil then
    trusted_dirs = trusted_dirs or read_trusted_dirs()
    local ok, root = pcall(require("iara.core.root").resolve, bufnr)
    local path = ok and vim.uv.fs_realpath(root.path)
    trusted_cache[bufnr] = path and trusted_dirs[vim.fs.normalize(path)]
      or false
  end
  return trusted_cache[bufnr]
end

---Root segment: the Iara mark for a trusted project, else a folder
---icon, and the root label; empty without a root or below `WIDTH_ROOT`.
local function root_segment(bufnr)
  if vim.o.columns < M.WIDTH_ROOT then
    return ""
  end
  local label = root_part(bufnr)
  if label == "" then
    return ""
  end
  local mark = colored("IaraStatusRootIcon", " " .. icons.FOLDER)
  if M.trusted(bufnr) then
    mark = colored("IaraStatusMark", " " .. M.MARK)
  end
  local text = mark .. "%#IaraStatusRoot# " .. literal(label) .. " "
  return colored("IaraStatusRoot", text)
end

---Terminal windows: name, job state, project, and safe mode.
---@param description IaraTerminalDescription
local function render_terminal(bufnr, description)
  local agent = description.kind == "agent"
  local name = agent and "IaraStatusAgent" or "IaraStatusTerminal"
  local exited = description.state ~= "running"
  local state = exited and "IaraStatusExited" or "IaraStatusRunning"
  local left = colored(name, literal(" " .. description.title .. " "))
    .. " "
    .. colored(state, literal(description.state))
  local right = join({ { "IaraStatusSafe", safe_text() } })
  local root = root_segment(bufnr)
  return " " .. left .. "%=" .. right .. (right ~= "" and " " or "") .. root
end

---Mode block of the current mode: its label with one space of padding
---on the mode's fill, flush with the left edge.
local function mode_block()
  local mode = vim.api.nvim_get_mode().mode
  local entry = M.MODES[mode:sub(1, 1)] or M.MODES.n
  return colored("IaraStatusMode" .. entry[2], " " .. entry[1] .. " ")
end

---Filetypes of the Snacks picker windows that take focus.
local PICKER_FILETYPES = {
  snacks_picker_input = true,
  snacks_picker_list = true,
}

---Title of the Snacks picker whose prompt or list is `bufnr` ("Themes",
---"Search"); nil for other buffers. Snacks is only read when loaded.
---@param bufnr integer
---@return string|nil
function M.picker_title(bufnr)
  local snacks = package.loaded.snacks
  if not snacks or not PICKER_FILETYPES[vim.bo[bufnr].filetype] then
    return nil
  end
  local ok, pickers = pcall(snacks.picker.get, { tab = false })
  for _, picker in ipairs(ok and pickers or {}) do
    local input, list = picker.input, picker.list
    local owns = (input and input.win.buf == bufnr)
      or (list and list.win.buf == bufnr)
    if owns and type(picker.title) == "string" then
      return picker.title
    end
  end
  return nil
end

---Title shown instead of the file name: an owner's (the start screen's
---"Iara") or, with `true`, a focused picker's (FU-V12-8: the prompt
---buffer read `[No Name]`). Cheap: a buffer variable and a filetype.
local function shown_title(bufnr)
  local title = vim.b[bufnr].iara_status_title
  if title then
    return title, false
  end
  local picker = M.picker_title(bufnr)
  return picker, picker ~= nil
end

---Everything the file segment is drawn from, as one comparable string.
local function file_key(bufnr, path, title)
  local options = vim.bo[bufnr]
  return table.concat({
    path,
    tostring(title),
    tostring(options.modified),
    tostring(options.readonly),
    tostring(options.modifiable),
    options.buftype,
    tostring(package.loaded["nvim-web-devicons"] ~= nil),
  }, "\0")
end

---Icon, name, and markers of the file; a picker's title leads with the
---search glyph.
local function draw_file(bufnr, path)
  local title, picker = shown_title(bufnr)
  local name = title
    or (path == "" and "[No Name]" or vim.fn.fnamemodify(path, ":t"))
  local icon = picker and icons.ACTIONS.grep or icons.file(path)
  local text = " " .. icon .. " " .. literal(name) .. " "
  if vim.bo[bufnr].modified then
    text = text
      .. "%#IaraStatusModified#"
      .. icons.MODIFIED
      .. " %#IaraStatusFile#"
  end
  local file = vim.bo[bufnr].buftype == ""
  if file and (vim.bo[bufnr].readonly or not vim.bo[bufnr].modifiable) then
    text = text .. icons.READONLY .. " "
  end
  return colored("IaraStatusFile", text)
end

---File segment of `bufnr`, drawn again only when its state changed.
local function file_segment(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local key = file_key(bufnr, path, shown_title(bufnr))
  local cached = file_cache[bufnr]
  if not cached or cached.key ~= key then
    cached = { key = key, text = draw_file(bufnr, path) }
    file_cache[bufnr] = cached
  end
  return cached.text
end

---Branch and change counts that Gitsigns keeps in buffer variables;
---the counts only from `WIDTH_GIT_COUNTS` columns.
---@param bufnr integer
---@return string
function M.git_text(bufnr)
  local status = vim.b[bufnr].gitsigns_status_dict
  if type(status) ~= "table" or not status.head or status.head == "" then
    return ""
  end
  local text = colored("IaraStatusMuted", icons.GIT_BRANCH .. " ")
    .. colored("IaraStatusMuted", literal(status.head))
  if vim.o.columns < M.WIDTH_GIT_COUNTS then
    return text
  end
  local counts = {
    { "added", "IaraStatusGitAdded" },
    { "changed", "IaraStatusGitChanged" },
    { "removed", "IaraStatusGitRemoved" },
  }
  for _, count in ipairs(counts) do
    local value = status[count[1]]
    if type(value) == "number" and value > 0 then
      local glyph = icons.GIT[count[1]]
      text = text .. colored(count[2], " " .. glyph .. " " .. value)
    end
  end
  return text
end

---Diagnostic counts of `bufnr` with severity icons ("" without any).
---@param bufnr integer
---@return string
function M.diagnostics_text(bufnr)
  local counts = vim.diagnostic.count(bufnr)
  local items = {}
  for _, entry in ipairs(SEVERITIES) do
    local count = counts[vim.diagnostic.severity[entry[1]]]
    if count and count > 0 then
      local text = icons.DIAGNOSTICS[entry[1]] .. " " .. count
      table.insert(items, colored(entry[2], text))
    end
  end
  return table.concat(items, " ")
end

---Names of the LSP clients attached to `bufnr` ("" without any).
---@param bufnr integer
---@return string
function M.lsp_text(bufnr)
  local names = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    table.insert(names, client.name)
  end
  if #names == 0 then
    return ""
  end
  table.sort(names)
  local text = icons.LSP .. " " .. table.concat(names, ", ")
  return colored("IaraStatusLsp", literal(text))
end

---Owner notices: conservative-mode reason and disk conflict.
local function notices(bufnr)
  local warn = part("iara.core.eligibility", bufnr)
  local conflict = part("iara.core.reconcile", bufnr)
  local items = {}
  if warn ~= "" then
    local text = literal(icons.WARNING .. " " .. warn)
    table.insert(items, colored("IaraStatusWarn", text))
  end
  if conflict ~= "" then
    local text = literal(icons.CONFLICT .. " " .. conflict)
    table.insert(items, colored("IaraStatusConflict", text))
  end
  return items
end

---Cursor position at the right edge; scratch screens (start screen,
---tool windows) have none.
local function position_segment(bufnr)
  if vim.bo[bufnr].filetype == "iara-pdf" then
    local page = vim.w[drawn_window()].iara_pdf_page
    return page and colored("IaraStatusPosition", page) or ""
  end
  if vim.bo[bufnr].buftype ~= "" then
    return ""
  end
  return colored("IaraStatusPosition", " %l:%c ")
end

---Right side of a file buffer's statusline.
local function right_side(bufnr)
  local items = notices(bufnr)
  table.insert(items, diagnostics_cache[bufnr] or "")
  if vim.o.columns >= M.WIDTH_LSP then
    table.insert(items, M.lsp_text(bufnr))
  end
  local safe = safe_text()
  if safe ~= "" then
    table.insert(items, colored("IaraStatusSafe", safe))
  end
  local shown = vim.tbl_filter(function(item)
    return item ~= ""
  end, items)
  local text = table.concat(shown, "  ")
  local tail = root_segment(bufnr) .. position_segment(bufnr)
  return text .. (text ~= "" and tail ~= "" and " " or "") .. tail
end

---Statusline text for the window being drawn.
---@return string
function M.render()
  local bufnr = drawn_buffer()
  local description = M.terminal_of(bufnr)
  if description then
    return render_terminal(bufnr, description)
  end
  local git = M.git_text(bufnr)
  local left = mode_block() .. " " .. file_segment(bufnr)
  if git ~= "" then
    left = left .. "  " .. git
  end
  -- The progress segment is already escaped and highlighted.
  local progress = part("iara.core.progress")
  return left .. "%<%=" .. progress .. "%=" .. right_side(bufnr)
end

---Tab line text (see `iara.core.tabline`).
---@return string
function M.tabline()
  return require("iara.core.tabline").render()
end

local function redraw()
  -- Without a UI nothing is drawn; rendering anyway would resolve and
  -- cache roots of buffers whose owners are still setting them up.
  if #vim.api.nvim_list_uis() > 0 then
    vim.cmd.redrawstatus({ bang = true })
  end
end

---Refresh the cached parts of `bufnr` and redraw.
local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  diagnostics_cache[bufnr] = M.diagnostics_text(bufnr)
  redraw()
end

local function forget(bufnr)
  diagnostics_cache[bufnr] = nil
  file_cache[bufnr] = nil
  trusted_cache[bufnr] = nil
end

local function create_autocmds(group)
  local autocmd = vim.api.nvim_create_autocmd
  autocmd("User", { group = group, pattern = REDRAW_EVENTS, callback = redraw })
  autocmd("User", {
    group = group,
    pattern = "IaraRootChanged",
    callback = function()
      trusted_cache = {}
    end,
  })
  autocmd("ModeChanged", { group = group, callback = redraw })
  autocmd({ "DiagnosticChanged", "LspAttach", "LspDetach" }, {
    group = group,
    callback = function(args)
      vim.schedule(function()
        refresh(args.buf)
      end)
    end,
  })
  autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      forget(args.buf)
    end,
  })
  -- File icons come from nvim-web-devicons once it is loaded; load it
  -- when the editor is first idle, never on the startup path.
  autocmd("CursorHold", {
    group = group,
    once = true,
    callback = function()
      if pcall(require, "nvim-web-devicons") then
        vim.cmd.redrawtabline()
        redraw()
      end
    end,
  })
end

---Install the statusline, the split winbar (`iara.core.winbar`), and
---redraws when an owner's state changes.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  vim.o.statusline = EXPRESSION
  create_autocmds(
    vim.api.nvim_create_augroup("IaraStatusline", { clear = true })
  )
  require("iara.core.winbar").setup()
end

return M
