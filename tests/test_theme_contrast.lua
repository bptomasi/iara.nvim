-- Contrast audit of every theme group (V12 gate, FU-V12-1/5/7): text
-- 4.5:1 and meaningful glyphs 3:1 on the surface each group is drawn
-- on, in all 12 palettes, including text on highlighted rows (the
-- selected menu row, the cursor line). Syntax groups follow the
-- palette's code colors and are left out; decoration (frames, rules,
-- gaps, guides) has no contrast rule (design 09, section 2.2).
local eq = MiniTest.expect.equality

local theme = require("iara.theme")
local hl = require("iara.theme.highlights")
local roles = require("iara.theme.roles")

local T = MiniTest.new_set()

---Group modules checked, with the surface their groups are drawn on
---when the group has no background of its own.
local MODULES = {
  editor = "base",
  start = "base",
  health = "base",
  markdown = "base",
  status = "mantle",
  progress = "mantle",
  floats = "mantle",
  search = "mantle",
  panels = "mantle",
  explorer = "mantle",
  plugins = "mantle",
  ai = "mantle",
}

---Decoration: shapes and frames, no contrast rule.
local DECOR = {
  "Border",
  "Rule",
  "Faint",
  "Indent",
  "Whitespace",
  "NonText",
  "EndOfBuffer",
  "Cap$",
  "Swatch",
  "Gap$",
  "Crust",
  "WinSeparator",
  "VertSplit",
  "Fill$",
  "Thumb",
  "Soft$",
  "Conceal",
  "Dash$",
  "Quote$",
  "TableRow$",
  "TableHead$",
  "^SignColumn$",
  "^SpecialKey$",
  "^FoldColumn$",
  "^IaraOverlay$",
  "^IaraRaised$",
}

---Glyphs: meaningful shapes and numbers (3:1).
local GLYPH = {
  "Icon",
  "Bar$",
  "Sign",
  "Spinner",
  "Mark$",
  "Dot",
  "Wave",
  "Kind",
  "Bullet",
  "Arrow",
  "Location",
  "LineNr",
  "Separator",
  "^GitSigns",
  "Check",
  "Subtle",
  "Track",
  "Modified",
  "Cancelled$",
}

---Source labels of the popup menu are `subtle` by V3's decision
---(design 09, 3.8: quiet labels after the kind); held to 3:1.
local QUIET = { PmenuExtra = true, PmenuExtraSel = true }

local function matches(name, patterns)
  for _, pattern in ipairs(patterns) do
    if name:find(pattern) then
      return true
    end
  end
  return false
end

---The minimum ratio of a group, or nil for decoration.
local function rule(name)
  if matches(name, DECOR) then
    return nil
  end
  if QUIET[name] or matches(name, GLYPH) then
    return roles.GLYPH
  end
  return roles.TEXT
end

local function deref(groups, name)
  local spec = groups[name]
  for _ = 1, 10 do
    if not (spec and spec.link) then
      break
    end
    spec = groups[spec.link]
  end
  return spec
end

---"<palette> <group> <ratio>" for each group of `module` below its rule.
local function audit_module(name, groups, r, module, failures)
  for group in pairs(require("iara.theme.groups." .. module)) do
    local spec, ratio = deref(groups, group), rule(group)
    if spec and spec.fg and ratio then
      local surface = spec.bg or r[MODULES[module]]
      local value = hl.contrast(spec.fg, surface)
      if value < ratio then
        table.insert(failures, ("%s %s %.2f"):format(name, group, value))
      end
    end
  end
end

T["every theme group meets its contrast in every palette"] = function()
  local failures = {}
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, r = hl.resolve(palette), roles.resolve(palette)
    for module in pairs(MODULES) do
      audit_module(name, groups, r, module, failures)
    end
  end
  table.sort(failures)
  eq(failures, {})
end

---Text drawn on a highlighted row, by the row's surface role: the
---selected row of menus and lists (`overlay`) and the cursor line of
---the editor and the tree (`cursorline`). V12 measured the matches at
---3.55:1 and opened tree names at 4.12:1 there.
local ROW_TEXT = {
  overlay = {
    "CmpItemAbbr",
    "CmpItemAbbrMatch",
    "CmpItemAbbrMatchFuzzy",
    "PmenuMatchSel",
    "IaraSearchMatch",
    "IaraSearchFile",
    "IaraSearchDir",
    "SnacksPickerMatch",
    "IaraSelectKey",
    "IaraSelectText",
  },
  cursorline = {
    "NvimTreeNormal",
    "NvimTreeOpenedHL",
    "NvimTreeOpenedFolderName",
    "NvimTreeSpecialFile",
    "NvimTreeHiddenDisplay",
    "NvimTreeGitFileIgnoredHL",
    "MatchParen",
    "LineNr",
    "GitSignsCurrentLineBlame",
  },
}

T["text on selected rows and cursor lines is readable"] = function()
  local failures = {}
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, r = hl.resolve(palette), roles.resolve(palette)
    for row, names in pairs(ROW_TEXT) do
      for _, group in ipairs(names) do
        local value = hl.contrast(groups[group].fg, r[row])
        if value < roles.TEXT then
          local text = ("%s %s on %s %.2f"):format(name, group, row, value)
          table.insert(failures, text)
        end
      end
    end
  end
  eq(failures, {})
end

T["accent_row keeps the accent where it is already readable"] = function()
  -- Chocolate's copper is below 4.5:1 on its selected row: the row role
  -- moves, the accent itself stays exactly copper.
  local chocolate = roles.resolve(theme.palette("chocolate"))
  eq(chocolate.accent, "#d08b65")
  eq(chocolate.accent_row ~= chocolate.accent, true)
  for _, name in ipairs(theme.THEMES) do
    local r = roles.resolve(theme.palette(name))
    local rows = { r.base, r.mantle, r.cursorline, r.overlay }
    local readable = true
    for _, surface in ipairs(rows) do
      readable = readable and hl.contrast(r.accent, surface) >= roles.TEXT
    end
    if readable then
      eq({ name, r.accent_row }, { name, r.accent })
    end
  end
end

T["the status bar is the chrome surface with every part on it"] = function()
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, r = hl.resolve(palette), roles.resolve(palette)
    eq({ name, groups.StatusLine.bg }, { name, r.mantle })
    for _, group in ipairs({ "IaraStatusMuted", "IaraProgressClient" }) do
      eq({ name, group, groups[group].bg }, { name, group, r.mantle })
    end
    -- Safe mode is a warning chip, readable in light palettes too.
    local safe = groups.IaraStatusSafe
    eq({ name, safe.bg }, { name, r.warn })
    eq({ name, hl.contrast(safe.fg, safe.bg) >= roles.TEXT }, { name, true })
  end
end

return T
