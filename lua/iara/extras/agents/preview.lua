--- Window of the agent context preview (tasks V11, V13; design 09
--- sections 3.12 and 7): a straight-framed float titled "Agent context"
--- (the focus color while it has the focus), the payload size against
--- its cap as a chip on the right, key hints and the safety rule in the
--- footer, and a summary of the capture drawn as virtual lines above
--- the payload. The buffer holds exactly the payload, so what is shown
--- is what `y` copies.
local M = {}

local api = vim.api

M.NAMESPACE = api.nvim_create_namespace("iara.agents.preview")

M.TITLE = "Agent context"

---Footer hints `{ key, description }`, then the safety rule.
M.HINTS = { { "y", "copy" }, { "q", "close" } }
M.SAFETY = "(nothing is sent)"

---The size chip turns to the warning color above this share of the cap.
M.WARN_SHARE = 0.8

---Columns between the frame and the text (a blank sign column).
local PADDING = 2

local RULE = "\u{2500}"
local BULLET = "\u{25b8}"

local LINKS = {
  IaraContextChip = "IaraRaised",
  IaraContextChipWarn = "DiagnosticWarn",
  IaraContextLabel = "IaraAccent",
  IaraContextValue = "IaraMuted",
  IaraContextRule = "FloatBorder",
}

local function size_text(bytes)
  if bytes < 1024 then
    return ("%d B"):format(bytes)
  end
  return ("%.1f KiB"):format(bytes / 1024)
end

---Payload size against the cap: "3.1 KiB of 128 KiB".
---@param bytes integer
---@param limit integer
---@return string
function M.size_label(bytes, limit)
  return ("%s of %d KiB"):format(size_text(bytes), limit / 1024)
end

local function line_span(snapshot)
  local range = snapshot.range
  local first = range[1] + 1
  -- A linewise range ends at the start of the next line.
  local last = snapshot.mode == "linewise" and range[3] or range[3] + 1
  if last <= first then
    return (":%d"):format(first)
  end
  return (":%d-%d"):format(first, last)
end

---Summary rows `{ label, value }` of a snapshot.
---@param snapshot IaraContextSnapshot
---@return string[][]
function M.summary(snapshot)
  -- The label is project-relative; the payload names the full path.
  local name = snapshot.buffer_label
  local rows = {}
  if snapshot.mode == "reference" then
    rows[1] = { "Reference", name .. " (read from disk)" }
  else
    local value = ("%s%s  %s"):format(name, line_span(snapshot), snapshot.mode)
    if snapshot.unsaved then
      value = value .. ", unsaved"
    end
    rows[1] = { "Selection", value }
  end
  local diagnostics = snapshot.diagnostics
  if diagnostics then
    local count = #diagnostics == 0 and "none" or tostring(#diagnostics)
    table.insert(rows, { "Diagnostics", count .. " in the captured range" })
  end
  return rows
end

local function summary_lines(rows, width)
  local lines = {}
  for _, row in ipairs(rows) do
    table.insert(lines, {
      {
        BULLET .. " " .. row[1] .. (" "):rep(13 - #row[1]),
        "IaraContextLabel",
      },
      { row[2], "IaraContextValue" },
    })
  end
  table.insert(lines, { { RULE:rep(width), "IaraContextRule" } })
  return lines
end

---Title chunks spanning `width` columns: the title on the left, the
---size chip on the right when it fits, the border line between. Idle
---groups: the window's focused frame (`iara.core.float.focus`) remaps
---them while the preview has the focus.
---@param width integer Inner width of the window.
---@param bytes integer Payload size.
---@param limit integer Payload cap.
---@return table[]
function M.title(width, bytes, limit)
  local float = require("iara.core.float")
  local chunks = float.title(M.TITLE, false, width)
  local chip = " " .. M.size_label(bytes, limit) .. " "
  local chip_group = bytes > limit * M.WARN_SHARE and "IaraContextChipWarn"
    or "IaraContextChip"
  local fill = width - 1 - float.width(chunks) - api.nvim_strwidth(chip)
  if fill < 1 then
    return chunks
  end
  table.insert(chunks, float.rule(fill))
  table.insert(chunks, { chip, chip_group })
  table.insert(chunks, float.rule(1))
  return chunks
end

---Footer chunks: the float language's key hints (V3), then the safety
---rule in the hint color, after the hint separator.
---@return table[]
function M.footer()
  local float = require("iara.core.float")
  local chunks = float.footer(M.HINTS, math.huge)
  -- The footer ends in a padding space: the rule follows the separator.
  table.insert(chunks, { "· " .. M.SAFETY .. " ", float.FOOTER.text })
  return chunks
end

local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + api.nvim_strwidth(chunk[1])
  end
  return width
end

---Width of the window's text area: the widest payload or summary line,
---at least the footer, within the screen.
local function text_width(lines, rows)
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, api.nvim_strwidth(line))
  end
  for _, line in ipairs(summary_lines(rows, 0)) do
    width = math.max(width, chunks_width(line))
  end
  width = math.max(width, chunks_width(M.footer()))
  -- One blank column on the right too, so text never touches the frame.
  return math.min(width + PADDING + 1, math.max(20, vim.o.columns - 4))
end

local function window_config(lines, rows, bytes, limit)
  local width = text_width(lines, rows)
  local extra = #rows + 1
  local height = math.min(#lines + extra, math.max(3, vim.o.lines - 6))
  return require("iara.core.ui").float({
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    title = M.title(width, bytes, limit),
    title_pos = "left",
    footer = M.footer(),
    footer_pos = "center",
  })
end

local function define_fallbacks()
  for group, target in pairs(LINKS) do
    api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

---Open the preview window on a new scratch buffer holding `payload`.
---@param payload string
---@param snapshot IaraContextSnapshot
---@param limit integer Payload cap in bytes.
---@return integer buf
---@return integer win
function M.open(payload, snapshot, limit)
  define_fallbacks()
  local buf = api.nvim_create_buf(false, true)
  local lines = vim.split(payload, "\n", { plain = true })
  api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local rows = M.summary(snapshot)
  local config = window_config(lines, rows, #payload, limit)
  local win = api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].winhighlight = "SignColumn:NormalFloat"
  -- WinEnter came before the line above replaced 'winhighlight'.
  require("iara.core.float").focus(win)
  local virt = summary_lines(rows, config.width - PADDING - 1)
  api.nvim_buf_set_extmark(buf, M.NAMESPACE, 0, 0, {
    virt_lines = virt,
    virt_lines_above = true,
  })
  -- Virtual lines above the first line show only as filler at the top.
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, topfill = #virt })
  end)
  return buf, win
end

return M
