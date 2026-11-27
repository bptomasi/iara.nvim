--- Theme picker. With snacks.nvim (Iara's picker presentation) moving
--- the cursor previews each theme live; confirming stores the choice and
--- cancelling restores the colorscheme active when the picker opened.
--- It has the Vim-style modes of the search pickers (UX5, through
--- `iara.features.picker.modal`): `Esc` leaves the prompt for Normal
--- mode, where `j`/`k` and the other list keys move (and preview),
--- `Enter`/`o`/`l` apply, and `q` or a second `Esc` cancel. Its frame is
--- the straight results frame of `iara.features.picker.layout`.
---
--- Each row (V10, design 09 section 3.5) shows the theme's name, its
--- type (`dark`/`light`, part of the filtered text), `✓` on the stored
--- choice, and swatches of eight roles of that palette, drawn with
--- groups `IaraThemeSwatch<Theme><n>` computed from the palettes without
--- applying them. A live preview runs `:hi clear`, so the swatches are
--- defined again on every ColorScheme event while the picker is open.
---
--- Without Snacks (safe mode) it falls back to `vim.ui.select`, which
--- offers no preview: a choice applies on confirm.
local M = {}

---Inside width of the picker frame, in columns.
M.WIDTH = 50

---Roles shown as swatches, in order.
M.SWATCH_ROLES =
  { "base", "mantle", "accent", "tide", "error", "warn", "ok", "info" }

local SWATCH = "██ "
local NAME_WIDTH = 15
local TYPE_WIDTH = 6

---Keys of the search pickers that mean nothing for a list of themes:
---splits, the preview window, the quickfix list, and Snacks' toggles.
local UNUSED_KEYS = {
  "v",
  "s",
  "p",
  "<c-v>",
  "<c-s>",
  "<c-q>",
  "<c-t>",
  "<S-CR>",
  "<a-h>",
  "<a-i>",
  "<a-f>",
  "<a-p>",
  "<c-g>",
}

---Fallback links of the row groups under a foreign colorscheme.
local HIGHLIGHTS = {
  IaraThemeMark = "Special",
  IaraThemeType = "Comment",
}

local function theme()
  return require("iara.theme")
end

---Colorscheme to restore on cancel: the active one, or the default.
local function active_colorscheme()
  return vim.g.colors_name or "default"
end

local function restore(colorscheme)
  if vim.g.colors_name ~= colorscheme then
    vim.cmd.colorscheme(colorscheme)
  end
end

local function preview(name)
  if vim.g.colors_name ~= theme().PREFIX .. name then
    theme().apply(name)
  end
end

---Group of the `index`th swatch of theme `name`
---(`IaraThemeSwatchGithubLight3`).
---@param name string
---@param index integer
---@return string
function M.swatch_group(name, index)
  local camel = name:gsub("^%l", string.upper):gsub("_(%l)", string.upper)
  return ("IaraThemeSwatch%s%d"):format(camel, index)
end

---Define the swatch groups of every theme from its palette's roles.
function M.define_swatches()
  local roles = require("iara.theme.roles")
  for _, name in ipairs(theme().THEMES) do
    local resolved = roles.resolve(theme().palette(name))
    for index, role in ipairs(M.SWATCH_ROLES) do
      local group = M.swatch_group(name, index)
      vim.api.nvim_set_hl(0, group, { fg = resolved[role] })
    end
  end
  for group, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---Picker items. The text is the name and type padded as the row shows
---them, so Snacks' match marks land on the typed characters.
local function items()
  local list = {}
  for _, name in ipairs(theme().THEMES) do
    local kind = theme().palette(name).type
    local text = ("%-" .. NAME_WIDTH .. "s%-" .. TYPE_WIDTH .. "s"):format(
      name,
      kind
    )
    table.insert(list, { text = text, name = name })
  end
  return list
end

---Row chunks: name, type, the stored choice's mark, swatches.
---@param item table
---@param stored string|nil Name of the stored choice.
---@return table[] chunks
local function format_row(item, stored)
  local chunks = {
    { item.text:sub(1, NAME_WIDTH), "IaraSearchFile" },
    { item.text:sub(NAME_WIDTH + 1), "IaraThemeType" },
    { item.name == stored and "✓ " or "  ", "IaraThemeMark" },
  }
  for index in ipairs(M.SWATCH_ROLES) do
    table.insert(chunks, { SWATCH, M.swatch_group(item.name, index) })
  end
  return chunks
end

---Footer hints of each mode, most useful first.
local HINTS = {
  insert = {
    { "⏎", "apply" },
    { "Esc", "normal" },
    { "C-n/C-p", "move" },
  },
  normal = {
    { "j/k", "move" },
    { "⏎", "apply" },
    { "i", "insert" },
    { "q", "cancel" },
  },
}

---Keys of the input or list window: the modal keys without UNUSED_KEYS.
---@param modal table `iara.features.picker.modal`.
---@param window "input"|"list"
local function keys(modal, window)
  local result = modal.keys(window)
  for _, lhs in ipairs(UNUSED_KEYS) do
    result[lhs] = false
  end
  return result
end

---Keep the swatches defined while the picker is open.
local function follow_colorschemes(state)
  state.autocmd = vim.api.nvim_create_autocmd("ColorScheme", {
    callback = M.define_swatches,
  })
end

local function close(state)
  pcall(vim.api.nvim_del_autocmd, state.autocmd)
  -- Closing windows first keeps the redraw of the final theme clean.
  vim.schedule(function()
    if state.chosen then
      theme().set(state.chosen)
    else
      restore(state.previous)
    end
  end)
end

---Put the cursor on the active theme when the picker shows (design
---3.5). Under a foreign colorscheme the list starts at the top.
local function start_on_current(picker)
  local current = theme().current()
  local index = current and vim.fn.index(theme().THEMES, current)
  if index and index >= 0 then
    picker.list:view(index + 1)
  end
end

---Snacks options of the picker; `state.chosen` receives the choice.
local function options(state)
  local modal = require("iara.features.picker.modal")
  local layout = require("iara.features.picker.layout")
  local themes = items()
  return {
    title = "Themes",
    items = themes,
    format = function(item)
      return format_row(item, state.stored)
    end,
    preview = "none",
    prompt = " ❯ ",
    layout = { layout = layout.compact(#themes, M.WIDTH) },
    actions = state.modal:actions(),
    win = {
      input = { keys = keys(modal, "input") },
      list = { keys = keys(modal, "list"), wo = layout.list_wo() },
    },
    on_show = function(picker)
      start_on_current(picker)
      state.shown = true
    end,
    -- Snacks reports its first row before `on_show` moves the cursor:
    -- previewing it would flash another theme (FU-V12-6).
    on_change = function(_, item)
      if item and state.shown then
        preview(item.name)
      end
    end,
    confirm = function(instance, item)
      state.chosen = item and item.name
      instance:close()
    end,
    on_close = function()
      close(state)
    end,
  }
end

local function open_snacks(snacks_picker)
  local modal = require("iara.features.picker.modal")
  modal.define_highlights()
  require("iara.features.picker.layout").define_highlights()
  M.define_swatches()
  local state = {
    previous = active_colorscheme(),
    stored = theme().persisted() or theme().current(),
    modal = modal.new(),
  }
  follow_colorschemes(state)
  local picker = snacks_picker.pick(options(state))
  state.modal:decorate(picker, HINTS)
  state.modal:attach(picker)
  return picker
end

local function open_select()
  vim.ui.select(theme().THEMES, { prompt = "Theme" }, function(choice)
    if choice then
      theme().set(choice)
    end
  end)
end

---Open the picker; Snacks when it can be loaded, else vim.ui.select.
---@return table|nil picker The Snacks picker, nil for `vim.ui.select`.
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if ok and type(snacks) == "table" and snacks.picker then
    return open_snacks(snacks.picker)
  end
  open_select()
end

return M
