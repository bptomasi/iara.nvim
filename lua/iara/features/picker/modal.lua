--- Vim-style modes for Iara's Snacks pickers (task UX4).
---
--- A picker opens in Insert mode in its prompt. `Esc` leaves Insert mode
--- and the prompt's Normal mode drives the list: `j`/`k` (with counts),
--- `gg`/`G`, `Ctrl-d`/`Ctrl-u`, `Ctrl-f`/`Ctrl-b`, `H`/`M`/`L`, `o`/`l`
--- open, `v`/`s` split, `p` preview, `q` or a second `Esc` close, and
--- `i`, `a`, `A`, `I`, `/` return to Insert mode with the query kept.
--- Movement skips rows the picker says are not selectable (group
--- headers, notices). The prompt glyph turns from `❯` into `❮` and a
--- `NORMAL` chip shows in Normal mode; the owner redraws them, and its
--- footer hints, when told the mode changed, or lets `Modal:decorate`
--- keep them drawn (UX5: the structured key search, the theme picker).
local picker_layout = require("iara.features.picker.layout")

local M = {}

local chip_ns = vim.api.nvim_create_namespace("iara.picker.mode")

M.CHIP = " NORMAL "

---Window in which a reopened picker takes back Insert mode (ms).
M.REOPEN_MS = 200

---Fallback links of the groups this module draws with.
M.HIGHLIGHTS = {
  IaraSearchPrompt = "Special",
  IaraSearchPromptNormal = "Comment",
  IaraSearchFooter = "Comment",
  IaraSearchFooterKey = "Special",
  IaraSearchModeChip = "PmenuSel",
}

---Keys of the prompt's Normal mode, also bound in the list window.
local NORMAL_KEYS = {
  j = "list_down",
  k = "list_up",
  gg = "list_top",
  G = "list_bottom",
  H = "iara_screen_top",
  M = "iara_screen_middle",
  L = "iara_screen_bottom",
  o = "confirm",
  l = "confirm",
  v = "edit_vsplit",
  s = "edit_split",
  p = "toggle_preview",
  q = "cancel",
  i = "iara_insert",
  a = "iara_append",
  A = "iara_append",
  I = "iara_insert_start",
  ["/"] = "iara_append",
}

---@class IaraPickerModal
---@field normal boolean The prompt is in Normal mode.
---@field insert_col integer? Byte column Insert mode was left at.
---@field selectable fun(item: table?): boolean
---@field on_mode fun(normal: boolean)?
local Modal = {}
Modal.__index = Modal

---@param opts { selectable: (fun(item: table?): boolean)?,
---  on_mode: fun(normal: boolean)? }?
---@return IaraPickerModal
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    normal = false,
    selectable = opts.selectable or function(item)
      return item ~= nil
    end,
    on_mode = opts.on_mode,
  }, Modal)
end

---Define the fallback links without replacing a theme's groups.
function M.define_highlights()
  for name, link in pairs(M.HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

-- Movement ----------------------------------------------------------------

---A count typed in Normal mode; Insert mode cannot type one.
local function count1()
  return vim.fn.mode():sub(1, 1) == "i" and 1 or vim.v.count1
end

---Nearest selectable index from `index` towards `step`, then backwards.
local function nearest(list, index, step, selectable)
  local count = list:count()
  if count == 0 then
    return nil
  end
  index = math.min(math.max(index, 1), count)
  for _, direction in ipairs({ step, -step }) do
    for candidate = index, direction > 0 and count or 1, direction do
      if selectable(list:get(candidate)) then
        return candidate
      end
    end
  end
end

---Next selectable index after `index`, wrapping around the list.
local function wrapped(list, index, delta, selectable)
  local count = list:count()
  for _ = 1, count do
    index = (index - 1 + delta) % count + 1
    if selectable(list:get(index)) then
      return index
    end
  end
end

---Move to the selectable row nearest to `index`, looking towards `step`
---(1 down, -1 up) first.
---@param picker table Snacks picker.
---@param index integer
---@param step integer
function Modal:go(picker, index, step)
  local target = nearest(picker.list, index, step, self.selectable)
  if target then
    picker.list:move(target, true)
  end
end

---Move `delta` selectable rows (times a typed count), wrapping around.
---@param picker table Snacks picker.
---@param delta integer 1 or -1.
function Modal:step(picker, delta)
  local list = picker.list
  local index = list.cursor
  for _ = 1, count1() do
    index = wrapped(list, index, delta, self.selectable) or index
  end
  if index ~= list.cursor then
    list:move(index, true)
  end
end

---Move by `pages` list heights (0.5 is half a page; negative is up).
---@param picker table Snacks picker.
---@param pages number
function Modal:page(picker, pages)
  local list = picker.list
  local rows = math.floor(math.max(list:height(), 1) * math.abs(pages))
  rows = math.max(rows, 1) * (pages < 0 and -1 or 1)
  self:go(picker, list.cursor + rows, rows < 0 and -1 or 1)
end

---Move within the visible rows: `fraction` 0 top, 0.5 middle, 1 bottom.
---@param picker table Snacks picker.
---@param fraction number
function Modal:screen(picker, fraction)
  local list = picker.list
  local last = math.min(list.top + list:height() - 1, list:count())
  local index = list.top + math.floor((last - list.top) * fraction)
  self:go(picker, index, fraction < 1 and 1 or -1)
end

-- Insert mode -------------------------------------------------------------

---Start Insert mode in the prompt at byte `col`; nil appends.
local function insert_at(picker, col)
  local win = picker.input.win
  if not win:valid() then
    return
  end
  vim.api.nvim_set_current_win(win.win)
  if not col or col >= #picker.input:get() then
    return vim.cmd.startinsert({ bang = true })
  end
  vim.api.nvim_win_set_cursor(win.win, { 1, col })
  vim.cmd.startinsert()
end

-- Actions and keys --------------------------------------------------------

---Actions by name, as functions of the modal state and the picker.
local ACTIONS = {
  list_down = function(m, p)
    m:step(p, 1)
  end,
  list_up = function(m, p)
    m:step(p, -1)
  end,
  list_top = function(m, p)
    m:go(p, 1, 1)
  end,
  list_bottom = function(m, p)
    m:go(p, p.list:count(), -1)
  end,
  list_scroll_down = function(m, p)
    m:page(p, 0.5)
  end,
  list_scroll_up = function(m, p)
    m:page(p, -0.5)
  end,
  iara_page_down = function(m, p)
    m:page(p, 1)
  end,
  iara_page_up = function(m, p)
    m:page(p, -1)
  end,
  iara_screen_top = function(m, p)
    m:screen(p, 0)
  end,
  iara_screen_middle = function(m, p)
    m:screen(p, 0.5)
  end,
  iara_screen_bottom = function(m, p)
    m:screen(p, 1)
  end,
  iara_insert = function(m, p)
    insert_at(p, m.insert_col)
  end,
  iara_insert_start = function(_, p)
    insert_at(p, 0)
  end,
  iara_append = function(_, p)
    insert_at(p)
  end,
}

---Snacks actions of the modes. Movement actions replace Snacks' own of
---the same names so every key that moves skips unselectable rows.
---@return table<string, fun(picker: table)>
function Modal:actions()
  local result = {}
  for name, action in pairs(ACTIONS) do
    result[name] = function(picker)
      action(self, picker)
    end
  end
  return result
end

---Keys of the prompt (`input`) or the list window. In the prompt,
---`Ctrl-f`/`Ctrl-b` keep scrolling the preview in Insert mode and page
---the list in Normal mode.
---@param window "input"|"list"
---@return table<string, table|string>
function M.keys(window)
  local keys = vim.deepcopy(NORMAL_KEYS)
  keys.iara_page_down = { "<c-f>", "iara_page_down", mode = "n" }
  keys.iara_page_up = { "<c-b>", "iara_page_up", mode = "n" }
  if window == "input" then
    keys["<c-f>"] = { "preview_scroll_down", mode = "i" }
    keys["<c-b>"] = { "preview_scroll_up", mode = "i" }
  else
    keys["<c-f>"] = false
    keys["<c-b>"] = false
  end
  return keys
end

-- Mode tracking -----------------------------------------------------------

function Modal:set_normal(normal)
  if self.normal == normal then
    return
  end
  self.normal = normal
  if self.on_mode then
    self.on_mode(normal)
  end
end

---Enter Insert mode in the prompt again when the Insert mode left
---behind by a picker closed in this tick (a reopened search) ends: Snacks
---stops it on close, and the stop lands after this picker started its
---own. Only a stop within `REOPEN_MS` counts, never a later `Esc`.
local function keep_insert(picker)
  local since = vim.uv.now()
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = picker.input.win.buf,
    once = true,
    callback = function()
      if vim.uv.now() - since > M.REOPEN_MS then
        return
      end
      vim.schedule(function()
        local win = picker.input.win
        if win:valid() and vim.api.nvim_get_current_win() == win.win then
          vim.cmd.startinsert({ bang = true })
        end
      end)
    end,
  })
end

---Follow the prompt's mode. Leaving the prompt in Insert mode (to the
---list window) also counts as Normal mode.
---@param picker table Snacks picker.
---@param reopened boolean? Another picker was closed just before.
function Modal:attach(picker, reopened)
  local buf = picker.input.win.buf
  local function on(event, callback)
    vim.api.nvim_create_autocmd(event, { buffer = buf, callback = callback })
  end
  if reopened and vim.fn.mode():sub(1, 1) == "i" then
    keep_insert(picker)
  end
  on("InsertLeavePre", function()
    self.insert_col = vim.api.nvim_win_get_cursor(0)[2]
  end)
  on("InsertLeave", function()
    self:set_normal(true)
  end)
  on("InsertEnter", function()
    self:set_normal(false)
  end)
end

-- Presentation ------------------------------------------------------------

---Status column of the prompt: `❯` in Insert mode, `❮` in Normal mode.
---@param normal boolean
---@return string
function M.prompt_column(normal)
  if normal then
    return "%#IaraSearchPromptNormal# ❮ %*"
  end
  return "%#IaraSearchPrompt# ❯ %*"
end

---Set the prompt glyph of `input` (a Snacks picker input).
---@param input table
---@param normal boolean
function M.draw_prompt(input, normal)
  local column = M.prompt_column(normal)
  if input.win.opts.wo.statuscolumn ~= column then
    input.win.opts.wo.statuscolumn = column
    vim.wo[input.win.win].statuscolumn = column
  end
end

---Footer chunks: `hints` (`{ key, description }`, most useful first)
---that fit in a box `width` columns wide, as the float language's
---footer (` key desc · key desc `) in the picker's footer groups. The
---corners and a dash at each end stay free.
---@param hints string[][]
---@param width integer
---@return table[] chunks
function M.footer(hints, width)
  return require("iara.core.float").footer(hints, width - 2, {
    key = "IaraSearchFooterKey",
    text = "IaraSearchFooter",
    max = math.huge,
  })
end

---Draw the decorations of a mode: the footer `hints` of the mode
---(`{ insert = ..., normal = ... }`), the prompt glyph, and the
---`NORMAL` chip on the prompt line.
---@param picker table Snacks picker in an `iara.features.picker.layout`.
---@param normal boolean
---@param hints { insert: string[][], normal: string[][] }
function M.draw_mode(picker, normal, hints)
  local width = picker_layout.results_width(picker)
  if not width or not picker.input.win:valid() then
    return
  end
  local mode_hints = normal and hints.normal or hints.insert
  picker_layout.set_footer(picker, M.footer(mode_hints, width))
  M.draw_prompt(picker.input, normal)
  local chip = normal and { { M.CHIP, "IaraSearchModeChip" } }
  vim.api.nvim_buf_set_extmark(picker.input.win.buf, chip_ns, 0, 0, {
    id = 1,
    virt_text = chip or { { "" } },
    virt_text_pos = "right_align",
  })
end

---Keep the mode decorations of `picker` drawn (see `M.draw_mode`): when
---the mode changes and after Snacks redraws its titles or prompt status.
---The picker's title stays inline on the frame's top edge. Replaces the
---modal's `on_mode`.
---@param picker table Snacks picker.
---@param hints { insert: string[][], normal: string[][] }
function Modal:decorate(picker, hints)
  local function draw()
    M.draw_mode(picker, self.normal, hints)
  end
  local update_titles, update_input = picker.update_titles, picker.input.update
  picker.update_titles = function(instance)
    update_titles(instance)
    picker_layout.set_title(instance, instance.title or "")
    draw()
  end
  picker.input.update = function(input)
    update_input(input)
    draw()
  end
  self.on_mode = draw
  picker_layout.set_title(picker, picker.title or "")
  draw()
end

---Hints of Normal mode, followed by `extra` (most useful first).
---@param extra string[][]?
---@return string[][]
function M.normal_hints(extra)
  local hints = {
    { "j/k", "move" },
    { "i", "insert" },
    { "⏎", "open" },
    { "q", "close" },
  }
  return vim.list_extend(hints, extra or {})
end

return M
