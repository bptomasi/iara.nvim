--- Semantic color roles (task V1, design 09 section 2.2, "rio").
---
--- A palette fills about twenty named roles once per resolution; groups
--- name a role as a color ("@accent", "@muted") instead of a palette
--- slot, so one identity reads the same in every palette. Readable roles
--- are moved toward the palette's text color (`highlights.readable`)
--- until they meet their contrast on the editor (`base`) and chrome
--- (`mantle`) surfaces, so light palettes are fixed by rule, not by hand.
local M = {}

---@class IaraIdentity
---@field accent string|nil Slot (or "#rrggbb") of the signature accent:
---  focus, action, keys. Default `DEFAULT_IDENTITY.accent`.
---@field tide string|nil Slot of the "tide" color: flow, Insert mode,
---  running jobs, progress. Default `DEFAULT_IDENTITY.tide`.

---Identity of a palette that declares none.
M.DEFAULT_IDENTITY = { accent = "blue", tide = "teal" }

---Minimum contrasts (WCAG 2): text roles 4.5:1, meaningful glyphs 3:1,
---body text 7:1, on both `base` and `mantle` (`muted`, `subtle`, and
---`accent_row` also on `cursorline` and `overlay`; `fg` 4.5:1 on
---`overlay`). `border_focus` is checked on `mantle` only, `on_accent` on
---`accent`.
M.TEXT = 4.5
M.GLYPH = 3
M.BODY = 7

---Role names, in resolution order. `mode_<name>` and `on_mode_<name>`
---follow for every entry of `MODES`.
M.ROLES = {
  "base",
  "mantle",
  "crust",
  "raised",
  "overlay",
  "cursorline",
  "fg",
  "fg_strong",
  "muted",
  "subtle",
  "faint",
  "border",
  "accent",
  "accent_soft",
  "accent_row",
  "on_accent",
  "border_focus",
  "tide",
  "tide_soft",
  "error",
  "warn",
  "info",
  "hint",
  "ok",
  "error_soft",
  "warn_soft",
  "info_soft",
  "hint_soft",
  "ok_soft",
}

---Readable roles and their minimum contrast on `base` and `mantle`.
M.READABLE = {
  fg = M.BODY,
  fg_strong = M.BODY,
  muted = M.TEXT,
  subtle = M.GLYPH,
  accent = M.TEXT,
  tide = M.TEXT,
  error = M.TEXT,
  warn = M.TEXT,
  info = M.TEXT,
  hint = M.TEXT,
  ok = M.TEXT,
}

---State roles and their palette slots: they mean only their state.
M.STATES = {
  { "error", "red" },
  { "warn", "yellow" },
  { "info", "blue" },
  { "hint", "purple" },
  { "ok", "green" },
}

---Mode colors: the first role or slot not already taken by an earlier
---mode (same color) wins, so a mode that clashes with the accent or the
---tide takes its neighbor. Normal is the accent and Insert the tide
---everywhere. Neighbors taken in the shipped palettes: Confirm yields
---teal to the tide everywhere and shows cyan (nord: cyan is the accent,
---so nord_blue); Select shows nord_blue where blue is the accent
---(github_dark, github_light, kanagawa, onedark, tokyonight); Visual
---shows dark_purple in catppuccin and Terminal vibrant_green in
---everforest (accents purple and green). `test_theme_roles` checks
---that the eight colors differ in every palette.
M.MODES = {
  -- A role candidate stands alone: it is always taken.
  { "normal", { "@accent" } },
  { "insert", { "@tide" } },
  { "visual", { "purple", "dark_purple", "baby_pink" } },
  { "replace", { "red", "baby_pink", "pink" } },
  { "command", { "yellow", "sun", "orange" } },
  { "select", { "blue", "nord_blue", "cyan" } },
  { "terminal", { "green", "vibrant_green", "teal" } },
  { "confirm", { "teal", "cyan", "nord_blue" } },
}

---Role groups for code that needs a group rather than a color.
M.GROUPS = {
  IaraAccent = { fg = "@accent" },
  IaraAccentSoft = { bg = "@accent_soft" },
  IaraOnAccent = { fg = "@on_accent", bg = "@accent", bold = true },
  IaraTide = { fg = "@tide" },
  IaraTideSoft = { bg = "@tide_soft" },
  IaraMuted = { fg = "@muted" },
  IaraSubtle = { fg = "@subtle" },
  IaraFaint = { fg = "@faint" },
  IaraBorder = { fg = "@border", bg = "@mantle" },
  IaraBorderFocus = { fg = "@border_focus", bg = "@mantle" },
  IaraMantle = { fg = "@fg", bg = "@mantle" },
  IaraCrust = { bg = "@crust" },
  IaraRaised = { fg = "@fg_strong", bg = "@raised" },
  IaraOverlay = { bg = "@overlay" },
}

---Neutral links of the role groups under a foreign colorscheme.
M.FALLBACK_LINKS = {
  IaraAccent = "Special",
  IaraAccentSoft = "Visual",
  IaraOnAccent = "TabLineSel",
  IaraTide = "String",
  IaraTideSoft = "Visual",
  IaraMuted = "Comment",
  IaraSubtle = "LineNr",
  IaraFaint = "NonText",
  IaraBorder = "FloatBorder",
  IaraBorderFocus = "Title",
  IaraMantle = "NormalFloat",
  IaraCrust = "TabLineFill",
  IaraRaised = "Pmenu",
  IaraOverlay = "PmenuSel",
}

local function blend(top, bottom, percent)
  return require("iara.theme.highlights").blend(top, bottom, percent)
end

local function readable(color, surfaces, ratio, target)
  local hl = require("iara.theme.highlights")
  return hl.readable(color, surfaces, ratio, target)
end

local function slot(palette, name)
  if name:sub(1, 1) == "#" then
    return name
  end
  return palette.base_30[name] or palette.base_16[name]
end

---The palette's identity with defaults for missing fields.
---@param palette IaraPalette
---@return { accent: string, tide: string }
function M.identity(palette)
  local identity = palette.identity or {}
  return {
    accent = identity.accent or M.DEFAULT_IDENTITY.accent,
    tide = identity.tide or M.DEFAULT_IDENTITY.tide,
  }
end

---Text for a block filled with `fill`: the palette's dark or light text
---slot, whichever stands out more, made readable on `fill`.
local function on(palette, fill)
  local hl = require("iara.theme.highlights")
  local dark = palette.base_30.black
  local light = palette.base_16.base07
  local text = light
  if hl.contrast(dark, fill) >= hl.contrast(light, fill) then
    text = dark
  end
  return readable(text, { fill }, M.TEXT)
end

local function surfaces(palette)
  local base = palette.base_16.base00
  local mantle = palette.base_30.darker_black
  -- Crust sits one step past the chrome, away from the editor surface.
  local hl = require("iara.theme.highlights")
  local away = "#ffffff"
  if hl.luminance(mantle) <= hl.luminance(base) then
    away = "#000000"
  end
  return {
    base = base,
    mantle = mantle,
    crust = blend(away, mantle, 6),
    raised = palette.base_30.one_bg,
    overlay = palette.base_30.one_bg2,
    cursorline = palette.base_30.black2,
  }
end

local function text_roles(palette, roles)
  local on_both = { roles.base, roles.mantle }
  local fg = readable(palette.base_16.base05, on_both, M.BODY)
  -- Body text also sits on the selected row of menus and lists (V12:
  -- tokyonight's was 4.23:1 there).
  fg = readable(fg, { roles.overlay }, M.TEXT)
  roles.fg = fg
  roles.fg_strong = readable(palette.base_16.base07, on_both, M.BODY, fg)
  -- Muted text and line numbers also sit on highlighted rows: the
  -- cursor line and the selected row of lists.
  local on_rows = { roles.base, roles.mantle, roles.cursorline }
  table.insert(on_rows, roles.overlay)
  roles.muted = readable(blend(fg, roles.base, 62), on_rows, M.TEXT, fg)
  roles.subtle = readable(blend(fg, roles.base, 42), on_rows, M.GLYPH, fg)
  roles.faint = blend(fg, roles.base, 16)
  roles.border = blend(fg, roles.mantle, 22)
end

local function identity_roles(palette, roles)
  local on_both = { roles.base, roles.mantle }
  local identity = M.identity(palette)
  local accent = slot(palette, identity.accent)
  roles.accent = readable(accent, on_both, M.TEXT, roles.fg)
  roles.accent_soft = blend(roles.accent, roles.base, 18)
  -- Accent text on highlighted rows (matches on a selected menu row,
  -- the opened file on the tree's cursor line). It is its own role so
  -- `accent` keeps the palette's exact color (chocolate's copper).
  local rows = { roles.base, roles.mantle, roles.cursorline, roles.overlay }
  roles.accent_row = readable(roles.accent, rows, M.TEXT, roles.fg)
  roles.on_accent = on(palette, roles.accent)
  roles.border_focus =
    readable(roles.accent, { roles.mantle }, M.GLYPH, roles.fg)
  local tide = slot(palette, identity.tide)
  roles.tide = readable(tide, on_both, M.TEXT, roles.fg)
  roles.tide_soft = blend(roles.tide, roles.base, 15)
  for _, state in ipairs(M.STATES) do
    -- The tint comes from the palette color, and the state stays
    -- readable on it too: virtual text and notices sit on their tint.
    local name, color = state[1], palette.base_30[state[2]]
    local soft = blend(color, roles.base, 12)
    local surfaces = { roles.base, roles.mantle, soft }
    roles[name] = readable(color, surfaces, M.TEXT, roles.fg)
    roles[name .. "_soft"] = soft
  end
end

---A role candidate, or the first slot candidate whose color no earlier
---mode took (the first one when all are taken).
local function pick_mode(palette, roles, candidates, taken)
  if candidates[1]:sub(1, 1) == "@" then
    return roles[candidates[1]:sub(2)]
  end
  local first = slot(palette, candidates[1])
  for _, name in ipairs(candidates) do
    local color = slot(palette, name)
    if color and not taken[color] then
      return color
    end
  end
  return first
end

local function mode_roles(palette, roles)
  -- Raw identity colors count as taken, so a mode that shares the
  -- accent's or tide's slot yields even after `readable` moved them.
  local identity = M.identity(palette)
  local taken = {
    [slot(palette, identity.accent) or ""] = true,
    [slot(palette, identity.tide) or ""] = true,
  }
  for _, mode in ipairs(M.MODES) do
    local name, candidates = mode[1], mode[2]
    local color = pick_mode(palette, roles, candidates, taken)
    taken[color] = true
    roles["mode_" .. name] = color
    roles["on_mode_" .. name] = on(palette, color)
  end
end

local cache = setmetatable({}, { __mode = "k" })

---Every role of `palette` as "#rrggbb", computed once per palette table
---(palettes are modules, so a theme pays this on its first use only).
---@param palette IaraPalette
---@return table<string, string>
function M.resolve(palette)
  if cache[palette] then
    return cache[palette]
  end
  local roles = surfaces(palette)
  text_roles(palette, roles)
  identity_roles(palette, roles)
  mode_roles(palette, roles)
  cache[palette] = roles
  return roles
end

---Every role name, `ROLES` then the mode roles.
---@return string[]
function M.names()
  local names = vim.list_extend({}, M.ROLES)
  for _, mode in ipairs(M.MODES) do
    table.insert(names, "mode_" .. mode[1])
    table.insert(names, "on_mode_" .. mode[1])
  end
  return names
end

return M
