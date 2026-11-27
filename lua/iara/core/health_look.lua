--- Look of the `:checkhealth` buffer (task V11, design 09 section 3.12).
---
--- The buffer text stays exactly what Neovim wrote (tests and `y` read
--- it); extmarks only conceal and color it: each module header becomes
--- `name ──── 12 ok · 1 warning · 0 errors` (with the Iara mark for
--- `iara`), report prefixes become one colored glyph, section headings
--- are strong, and advice lines are muted with an arrow. Counts come
--- from the report lines of each module, so they match what was checked.
local M = {}

local api = vim.api

M.NAMESPACE = api.nvim_create_namespace("iara.health_look")

---The Iara mark, before the `iara` module header only.
M.MARK = "\u{223f}"

---Header width, as Neovim's own `====` rule.
M.WIDTH = 78

---Report prefixes written by `vim.health`, the glyph shown instead, its
---group, and the counter it adds to.
M.STATES = {
  {
    prefix = "- \u{2705} OK",
    glyph = "\u{2713}",
    group = "IaraHealthOk",
    key = "ok",
  },
  {
    prefix = "- \u{26a0}\u{fe0f} WARNING",
    glyph = "\u{25b2}",
    group = "IaraHealthWarn",
    key = "warn",
  },
  {
    prefix = "- \u{274c} ERROR",
    glyph = "\u{2717}",
    group = "IaraHealthError",
    key = "error",
  },
}

---Links used when the groups are not defined (a foreign colorscheme).
M.FALLBACK_LINKS = {
  IaraHealthOk = "DiagnosticOk",
  IaraHealthWarn = "DiagnosticWarn",
  IaraHealthError = "DiagnosticError",
  IaraHealthHeading = "Title",
  IaraHealthAdvice = "Comment",
  IaraHealthMark = "Special",
  IaraHealthRule = "FloatBorder",
}

---@class IaraHealthCounts
---@field ok integer
---@field warn integer
---@field error integer

local function plural(count, word)
  return ("%d %s%s"):format(count, word, count == 1 and "" or "s")
end

---Summary text of a module: "12 ok · 1 warning · 0 errors".
---@param counts IaraHealthCounts
---@return string
function M.counts_text(counts)
  return ("%d ok \u{b7} %s \u{b7} %s"):format(
    counts.ok,
    plural(counts.warn, "warning"),
    plural(counts.error, "error")
  )
end

local function state_of(line)
  for _, state in ipairs(M.STATES) do
    if vim.startswith(line, state.prefix .. " ") then
      return state
    end
  end
  return nil
end

local function is_rule(line)
  return #line >= 10 and line:match("^=+$") ~= nil
end

---Report counts of the lines `first..last` (1-based, inclusive).
local function count_section(lines, first, last)
  local counts = { ok = 0, warn = 0, error = 0 }
  for index = first, last do
    local state = state_of(lines[index])
    if state then
      counts[state.key] = counts[state.key] + 1
    end
  end
  return counts
end

local function count_chunk(count, text, group)
  return { text, count > 0 and group or "IaraHealthAdvice" }
end

---Virtual text of a module header.
---@param name string Module name ("iara", "vim.lsp").
---@param counts IaraHealthCounts
---@return table[] chunks `{ text, group }`
function M.header_chunks(name, counts)
  local chunks = {}
  if name == "iara" then
    table.insert(chunks, { M.MARK .. " ", "IaraHealthMark" })
  end
  table.insert(chunks, { name, "IaraHealthHeading" })
  local summary = M.counts_text(counts)
  local used = api.nvim_strwidth(name) + api.nvim_strwidth(summary) + 2
  used = used + (name == "iara" and 2 or 0)
  local rule = ("\u{2500}"):rep(math.max(3, M.WIDTH - used))
  table.insert(chunks, { " " .. rule .. " ", "IaraHealthRule" })
  local sep = { " \u{b7} ", "IaraHealthAdvice" }
  local ok = counts.ok .. " ok"
  table.insert(chunks, count_chunk(counts.ok, ok, "IaraHealthOk"))
  table.insert(chunks, sep)
  local warn = plural(counts.warn, "warning")
  table.insert(chunks, count_chunk(counts.warn, warn, "IaraHealthWarn"))
  table.insert(chunks, sep)
  local error = plural(counts.error, "error")
  table.insert(chunks, count_chunk(counts.error, error, "IaraHealthError"))
  return chunks
end

local function mark(marks, row, col, opts)
  table.insert(marks, { row = row, col = col, opts = opts })
end

---Decorations of one module header: the `====` rule line is hidden and
---the title line is replaced by the header chunks.
local function header_marks(marks, lines, rule_index)
  local title_index = rule_index + 1
  local title = lines[title_index] or ""
  local name = title:match("^([^%s:]+):")
  if not name then
    return
  end
  local last = title_index + 1
  while lines[last] and not is_rule(lines[last]) do
    last = last + 1
  end
  local counts = count_section(lines, title_index + 1, last - 1)
  mark(marks, rule_index - 1, 0, { conceal_lines = "" })
  -- Overlay, not conceal plus inline text: concealed text still counts
  -- for wrapping, which would add an empty screen row. Spaces cover a
  -- title wider than the header.
  local chunks = M.header_chunks(name, counts)
  local extra = api.nvim_strwidth(title) - M.WIDTH
  if extra > 0 then
    table.insert(chunks, { (" "):rep(extra), "IaraHealthAdvice" })
  end
  mark(marks, title_index - 1, 0, {
    virt_text = chunks,
    virt_text_pos = "overlay",
  })
end

---Decorations of a report, heading, or advice line.
local function line_marks(marks, line, row)
  local state = state_of(line)
  if state then
    local opts = { end_col = #state.prefix, conceal = state.glyph }
    opts.hl_group = state.group
    mark(marks, row, 0, opts)
  elseif line == "  - ADVICE:" then
    mark(marks, row, 0, { conceal_lines = "" })
  elseif vim.startswith(line, "    - ") then
    local opts =
      { end_col = 5, conceal = "\u{2192}", hl_group = "IaraHealthAdvice" }
    mark(marks, row, 4, opts)
    mark(marks, row, 6, { end_col = #line, hl_group = "IaraHealthAdvice" })
  elseif line:match("^.+ ~$") then
    local text = #line - 2
    mark(marks, row, 0, { end_col = text, hl_group = "IaraHealthHeading" })
    mark(marks, row, text, { end_col = #line, conceal = "" })
  elseif vim.startswith(line, "- ") then
    local opts = { end_col = 1, conceal = "\u{b7}" }
    opts.hl_group = "IaraHealthAdvice"
    mark(marks, row, 0, opts)
  end
end

---@class IaraHealthMark
---@field row integer 0-based.
---@field col integer 0-based byte column.
---@field opts table `nvim_buf_set_extmark` options.

---Extmarks that give a health buffer's lines the Iara look. Pure.
---@param lines string[]
---@return IaraHealthMark[]
function M.decorations(lines)
  local marks = {}
  local index = 1
  while index <= #lines do
    local line = lines[index]
    if is_rule(line) then
      header_marks(marks, lines, index)
      index = index + 2
    else
      line_marks(marks, line, index - 1)
      index = index + 1
    end
  end
  return marks
end

local function define_fallbacks()
  for group, target in pairs(M.FALLBACK_LINKS) do
    api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

---Decorate a health buffer and the windows that show it.
---@param bufnr integer
function M.apply(bufnr)
  define_fallbacks()
  api.nvim_buf_clear_namespace(bufnr, M.NAMESPACE, 0, -1)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, item in ipairs(M.decorations(lines)) do
    api.nvim_buf_set_extmark(bufnr, M.NAMESPACE, item.row, item.col, item.opts)
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local wo = vim.wo[win][0]
    wo.conceallevel = 2
    wo.concealcursor = "nc"
    wo.number = false
    wo.relativenumber = false
    wo.fillchars = "eob: "
  end
end

---Decorate every health buffer from now on. `:checkhealth` sets the
---filetype after the checks ran, so calling this from a check is early
---enough; nothing runs at startup.
function M.attach()
  local group = api.nvim_create_augroup("IaraHealthLook", { clear = true })
  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "checkhealth",
    callback = function(args)
      M.apply(args.buf)
    end,
  })
end

return M
