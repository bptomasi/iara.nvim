--- Status line, tab line, and winbar groups (UX3, V4, V13: design 09
--- sections 3.2 and 7). The bar is the chrome surface `mantle` (design
--- 2.1) with flat segments on it: only the mode is a solid block; the
--- tab fill is `crust`; every color is a role.

-- The bar left the palette's `statusline_bg` in V12 (V4's request):
-- `mantle` holds every role's contrast by construction.
local BAR = "@mantle"
local WARN = "@warn"

---Mode block: the mode's text color on its fill.
local function mode(name)
  return {
    fg = "@on_mode_" .. name,
    bg = "@mode_" .. name,
    bold = true,
  }
end

local groups = {
  StatusLine = { fg = "@fg", bg = BAR },
  StatusLineNC = { fg = "@muted", bg = BAR },
  TabLine = { fg = "@muted", bg = "@crust" },
  TabLineSel = { fg = "@fg_strong", bg = "@base", bold = true },
  TabLineFill = { bg = "@crust" },
  WinBar = { fg = "@fg", bg = "@base" },
  WinBarNC = { fg = "@muted", bg = "@base" },

  -- Status line parts on the bar.
  IaraStatusWarn = { fg = WARN, bg = BAR },
  IaraStatusConflict = { fg = "@error", bg = BAR, bold = true },
  -- Safe mode is a warning chip: `base` text on the warning color, 4.5:1
  -- by construction (`warn` is readable on `base`); U1's black on orange
  -- was 3.0:1 in light palettes.
  IaraStatusSafe = { fg = "@base", bg = "@warn", bold = true },
  IaraStatusMuted = { fg = "@muted", bg = BAR },
  IaraStatusGitAdded = { fg = "@ok", bg = BAR },
  IaraStatusGitChanged = { fg = "@info", bg = BAR },
  IaraStatusGitRemoved = { fg = "@error", bg = BAR },
  IaraStatusDiagError = { fg = "@error", bg = BAR },
  IaraStatusDiagWarn = { fg = WARN, bg = BAR },
  IaraStatusDiagInfo = { fg = "@info", bg = BAR },
  IaraStatusDiagHint = { fg = "@hint", bg = BAR },
  IaraStatusLsp = { fg = "@muted", bg = BAR },
  -- Flat segments (file, root, position) on the bar, set apart by
  -- spacing and color. The root leads with the Iara mark in the tide
  -- for a trusted project, else a folder icon.
  IaraStatusFile = { fg = "@fg_strong", bg = BAR, bold = true },
  IaraStatusModified = { fg = "@accent", bg = BAR },
  IaraStatusRootIcon = { fg = "@muted", bg = BAR },
  IaraStatusMark = { fg = "@tide", bg = BAR, bold = true },
  IaraStatusRoot = { fg = "@fg", bg = BAR },
  IaraStatusPosition = { fg = "@fg_strong", bg = BAR },
  -- No longer drawn (V4 dropped the position glyph); kept while
  -- `iara.theme` links it under foreign colorschemes.
  IaraStatusPositionIcon = { fg = "@fg_strong", bg = BAR },

  -- Tab line: the current label joins the editor surface behind an
  -- accent bar; the others sit on the crust fill. The current tab
  -- number is an accent chip.
  IaraTabFill = { bg = "@crust" },
  IaraTabActive = { fg = "@fg_strong", bg = "@base", bold = true },
  IaraTabActiveBar = { fg = "@accent", bg = "@base" },
  IaraTabInactive = { fg = "@muted", bg = "@crust" },
  IaraTabModified = { fg = "@accent", bg = "@base" },
  IaraTabModifiedInactive = { fg = "@warn", bg = "@crust" },
  IaraTabNumber = { fg = "@on_accent", bg = "@accent", bold = true },

  -- Split winbars: the current window leads with an accent bar and
  -- names its file in the accent; other windows are muted.
  IaraWinbarBar = { fg = "@accent", bg = "@base" },
  IaraWinbarIcon = { fg = "@fg", bg = "@base" },
  IaraWinbarPath = { fg = "@muted", bg = "@base" },
  IaraWinbarName = { fg = "@accent", bg = "@base", bold = true },
  IaraWinbarModified = { fg = "@accent", bg = "@base" },
  IaraWinbarInactive = { fg = "@muted", bg = "@base" },
}

for _, name in ipairs({
  "Normal",
  "Insert",
  "Visual",
  "Replace",
  "Command",
  "Select",
  "Terminal",
  "Confirm",
}) do
  groups["IaraStatusMode" .. name] = mode(name:lower())
end

return groups
