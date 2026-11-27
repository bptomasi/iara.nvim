--- The `vim.ui.select` presenter (task V10, design 09 section 3.12).
---
--- A small centered float in Iara's shape: a straight frame in the
--- focus color (it holds the focus while open), the prompt as the title
--- on its top border, items are numbered, the row under the cursor has
--- the `▎` bar, and the footer lists the keys. `j`/`k` (and arrows,
--- `Ctrl-n`/`p`, `gg`/`G`) move, `Enter`/`o`/`l` or a digit `1`-`9`
--- choose, `q`, `Esc`, or `Ctrl-c` cancel, and leaving the window
--- cancels too. A cancel calls `on_choice(nil, nil)`; the callback runs
--- once, after the float closed. It needs no plugin, so it works in
--- safe mode; only lists above `FILTER_ABOVE` items open a Snacks
--- picker with fuzzy filtering (loaded then, never at startup), with
--- the picker modes of `iara.features.picker.modal`.
local M = {}

---Lists longer than this get a filtering picker when Snacks loads.
M.FILTER_ABOVE = 12
---Inside width bounds of the float, in columns.
M.MIN_WIDTH = 48
M.MAX_WIDTH = 80

---Fallback links of the groups drawn here.
M.HIGHLIGHTS = {
  IaraSelectKey = "Special",
  IaraSelectText = "NormalFloat",
  IaraSelectDetail = "Comment",
}

local FOOTER = { { "⏎", "choose" }, { "1-9", "pick" }, { "q", "cancel" } }
local MOVES = {
  j = 1,
  k = -1,
  ["<Down>"] = 1,
  ["<Up>"] = -1,
  ["<C-n>"] = 1,
  ["<C-p>"] = -1,
}

---Title text of a prompt: trimmed, without a trailing colon.
---@param prompt string|nil
---@return string
function M.title(prompt)
  local text = vim.trim(prompt or "Select"):gsub("%s*:$", "")
  return text ~= "" and text or "Select"
end

---Display lines of `items`: ` 1  label`, numbers right-aligned.
---@param items any[]
---@param format_item fun(item: any): string
---@return string[] lines
function M.lines(items, format_item)
  local digits = #tostring(#items)
  local lines = {}
  for index, item in ipairs(items) do
    local label = tostring(format_item(item)):gsub("\n", " ")
    local number = ("%" .. digits .. "d"):format(index)
    lines[index] = (" %s  %s"):format(number, label)
  end
  return lines
end

---Float size for `lines` and a title: even inside width (UX4 rule)
---between MIN_WIDTH and MAX_WIDTH, height capped by the editor.
local function size(lines, title)
  local width = vim.api.nvim_strwidth(title) + 8
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line) + 3)
  end
  width = math.min(math.max(width, M.MIN_WIDTH), M.MAX_WIDTH)
  width = math.min(width - width % 2, vim.o.columns - 4)
  return width, math.max(math.min(#lines, vim.o.lines - 6), 1)
end

---Highlight the numbers of `lines` as keys and the labels as text.
local function decorate(buf, lines)
  local ns = vim.api.nvim_create_namespace("iara.select")
  for row, line in ipairs(lines) do
    local stop = line:find("%d ") or 1
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
      end_col = stop,
      hl_group = "IaraSelectKey",
    })
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, stop, {
      end_col = #line,
      hl_group = "IaraSelectText",
    })
  end
end

local function open_window(buf, lines, title)
  local float = require("iara.core.float")
  local layout = require("iara.features.picker.layout")
  local modal = require("iara.features.picker.modal")
  local width, height = size(lines, title)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = float.border(require("iara.core.ui").CHARS, true),
    title = float.title(title, true),
    title_pos = "left",
    footer = modal.footer(FOOTER, width),
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].statuscolumn = layout.BAR
  vim.wo[win].winhighlight = "Normal:NormalFloat,CursorLine:"
    .. "IaraSearchSelection"
  return win
end

---@class IaraSelectState
---@field items any[]
---@field on_choice fun(item: any, index: integer|nil)
---@field win integer
---@field buf integer
---@field done boolean

---Close the float and report `index` (nil cancels). Runs once.
---@param state IaraSelectState
---@param index integer|nil
local function finish(state, index)
  if state.done then
    return
  end
  state.done = true
  pcall(vim.api.nvim_win_close, state.win, true)
  pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  local item = index and state.items[index]
  state.on_choice(item, item ~= nil and index or nil)
end

local function move(state, delta)
  local count = #state.items
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  local steps = delta * vim.v.count1
  row = (row - 1 + steps) % count + 1
  vim.api.nvim_win_set_cursor(state.win, { row, 0 })
end

---Buffer-local keys of the float.
local function map_keys(state)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true })
  end
  local function choose_cursor()
    finish(state, vim.api.nvim_win_get_cursor(state.win)[1])
  end
  for _, lhs in ipairs({ "<CR>", "o", "l" }) do
    map(lhs, choose_cursor)
  end
  for _, lhs in ipairs({ "q", "<Esc>", "<C-c>" }) do
    map(lhs, function()
      finish(state, nil)
    end)
  end
  for lhs, delta in pairs(MOVES) do
    map(lhs, function()
      move(state, delta)
    end)
  end
  for digit = 1, math.min(#state.items, 9) do
    map(tostring(digit), function()
      finish(state, digit)
    end)
  end
end

---Show `items` in the Iara float.
local function open_float(items, opts, on_choice)
  local lines = M.lines(items, opts.format_item or tostring)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  decorate(buf, lines)
  local state = { items = items, on_choice = on_choice, buf = buf }
  state.win = open_window(buf, lines, M.title(opts.prompt))
  map_keys(state)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      finish(state, nil)
    end,
  })
  return state.win
end

---Snacks picker options for long lists: Iara's compact frame, the
---picker modes, and the selection bar.
local function snacks_options(count, title)
  local layout = require("iara.features.picker.layout")
  local modal = require("iara.features.picker.modal").new()
  local keys = require("iara.features.picker.modal").keys
  return {
    title = title,
    prompt = " ❯ ",
    layout = { layout = layout.compact(count, M.MIN_WIDTH) },
    actions = modal:actions(),
    win = {
      input = { keys = keys("input") },
      list = { keys = keys("list"), wo = layout.list_wo() },
    },
  },
    modal
end

---Long lists: Snacks' select with Iara's frame and modes, or nil when
---Snacks cannot be loaded.
local function open_snacks(items, opts, on_choice)
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" or not snacks.picker then
    return nil
  end
  local title = M.title(opts.prompt)
  local picker_opts, modal = snacks_options(#items, title)
  local select_opts = vim.tbl_extend("force", opts, { snacks = picker_opts })
  local picker = snacks.picker.select(items, select_opts, on_choice)
  modal:decorate(picker, {
    insert = { { "⏎", "choose" }, { "Esc", "normal" } },
    normal = require("iara.features.picker.modal").normal_hints(),
  })
  modal:attach(picker)
  return picker
end

---Define the fallback links without replacing a theme's groups.
function M.define_highlights()
  for name, link in pairs(M.HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  require("iara.features.picker.layout").define_highlights()
  require("iara.features.picker.modal").define_highlights()
end

---`vim.ui.select` replacement (same arguments). Returns the float's
---window, the Snacks picker for long lists, or nil for an empty list
---(which is cancelled at once).
---@param items any[]
---@param opts table|nil `prompt`, `format_item`, `kind`.
---@param on_choice fun(item: any, index: integer|nil)
---@return integer|table|nil
function M.select(items, opts, on_choice)
  vim.validate("on_choice", on_choice, "function")
  opts = opts or {}
  if #items == 0 then
    on_choice(nil, nil)
    return nil
  end
  M.define_highlights()
  if #items > M.FILTER_ABOVE then
    local picker = open_snacks(items, opts, on_choice)
    if picker then
      return picker
    end
  end
  return open_float(items, opts, on_choice)
end

---Install the presenter as `vim.ui.select`. The module stays small at
---startup: the float and Snacks load on the first call.
function M.setup()
  vim.ui.select = M.select
end

return M
