--- Float, popup menu, and window separator groups (tasks V3, V13;
--- design 09 sections 2.4 and 7). Floats and the popup menu sit on the
--- `mantle` surface. Frames are thin straight lines: the subtle
--- `border` role at rest, `border_focus` on the focused float, whose
--- title is the `accent` (idle titles are `muted`). Border and title
--- cells share the float's background, so no cell shows two colors.
--- Key hints in footers are accent keys on muted text.
return {
  NormalFloat = { fg = "@fg", bg = "@mantle" },
  FloatBorder = { fg = "@border", bg = "@mantle" },
  FloatTitle = { fg = "@muted", bg = "@mantle", bold = true },
  FloatFooter = { fg = "@muted", bg = "@mantle" },
  IaraFloatBorderFocus = { fg = "@border_focus", bg = "@mantle" },
  IaraFloatTitleFocus = { fg = "@accent", bg = "@mantle", bold = true },
  IaraFloatFooterKey = { fg = "@accent", bg = "@mantle", bold = true },
  -- Native popup menu ('pumborder'): the selected row is the `overlay`
  -- surface with a bold label, never a filled accent block.
  Pmenu = { fg = "@fg", bg = "@mantle" },
  PmenuSel = { fg = "@fg_strong", bg = "@overlay", bold = true },
  PmenuKind = { fg = "@muted", bg = "@mantle" },
  PmenuKindSel = { fg = "@muted", bg = "@overlay" },
  PmenuExtra = { fg = "@subtle", bg = "@mantle" },
  PmenuExtraSel = { fg = "@subtle", bg = "@overlay" },
  PmenuSbar = { bg = "@mantle" },
  PmenuThumb = { bg = "@border" },
  PmenuBorder = { link = "FloatBorder" },
  PmenuMatch = { fg = "@accent", bg = "@mantle", bold = true },
  -- Matched characters on the selected row: the accent made readable on
  -- `overlay` too (`accent_row`; V12 measured the accent at 3.55:1).
  PmenuMatchSel = { fg = "@accent_row", bg = "@overlay", bold = true },
  -- Splits read as a gap of chrome, not a line (design 2.4).
  WinSeparator = { fg = "@crust", bg = "@mantle" },
  VertSplit = { link = "WinSeparator" },
}
