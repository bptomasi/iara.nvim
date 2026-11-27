--- Snacks picker and Iara search groups (UX1, UX4, UX5, V10).
--- Directories, counts, placeholders, and footer text use the `muted`
--- role and locations the `subtle` role, so they stay readable in every
--- palette. V10 and V13 (design 09 sections 3.3-3.5, 3.12, and 7):
--- plain titles, focus shown by the frame's color, the selection bar on
--- the `overlay` row, the streaming count in the `tide`, tinted
--- notices, theme swatches, and the select presenter.
return {
  SnacksPicker = { link = "NormalFloat" },
  SnacksPickerBorder = { link = "FloatBorder" },
  SnacksPickerTitle = { link = "FloatTitle" },
  -- The prompt draws the top of the results frame and its separator.
  SnacksPickerInputBorder = { link = "FloatBorder" },
  SnacksPickerPrompt = { fg = "@accent" },
  SnacksPickerMatch = { fg = "@accent_row", bold = true },
  SnacksPickerDir = { fg = "@muted" },
  SnacksPickerFile = { fg = "@fg_strong" },
  SnacksPickerSelected = { fg = "@accent" },
  SnacksPickerTotals = { fg = "@muted" },
  -- The selected row: the `overlay` surface plus a bar (IaraSearch-
  -- SelectionBar) in the list's status column.
  SnacksPickerListCursorLine = { link = "IaraSearchSelection" },
  SnacksPickerPreviewCursorLine = { link = "CursorLine" },

  -- Titles are plain text on the frame's top edge: the focused pane's
  -- in the accent, the other pane's and earlier chain steps' muted. The
  -- focused pane's frame is `border_focus`, the other's `border`.
  IaraSearchTitle = { fg = "@accent", bg = "@mantle", bold = true },
  IaraSearchCrumb = { fg = "@muted", bg = "@mantle" },
  IaraSearchBorder = { fg = "@border", bg = "@mantle" },
  IaraSearchBorderFocus = { fg = "@border_focus", bg = "@mantle" },
  IaraSearchCrumbSeparator = { fg = "@subtle", bg = "@mantle" },
  -- Switches read as modifiers of the title, not as titles.
  IaraSearchChip = { fg = "@warn", bg = "@mantle" },
  IaraSearchPrompt = { fg = "@accent", bold = true },
  -- Picker Normal mode (UX4): a muted prompt glyph and a mode chip like
  -- the status line's Normal mode block.
  IaraSearchPromptNormal = { fg = "@muted", bold = true },
  IaraSearchModeChip = {
    fg = "@on_mode_normal",
    bg = "@mode_normal",
    bold = true,
  },
  IaraSearchCount = { fg = "@muted" },
  -- Flow: the count and spinner while results stream in.
  IaraSearchCountBusy = { fg = "@tide" },
  IaraSearchSpinner = { fg = "@tide" },
  IaraSearchSelection = { bg = "@overlay" },
  IaraSearchSelectionBar = { fg = "@accent", bg = "@overlay" },
  IaraSearchSelectionGap = { bg = "@mantle" },
  IaraSearchDir = { fg = "@muted" },
  IaraSearchFile = { fg = "@fg_strong" },
  IaraSearchMatch = { fg = "@accent_row", bold = true },
  IaraSearchLocation = { fg = "@subtle" },
  IaraSearchText = { link = "NormalFloat" },
  -- The accent tint marks the match; the text stays strong, since the
  -- accent on its own tint is below 4.5:1 in six palettes.
  IaraSearchTextMatch = {
    fg = "@fg_strong",
    bg = "@accent_soft",
    bold = true,
  },
  IaraSearchGroupFile = { fg = "@fg_strong", bold = true },
  IaraSearchGroupCount = { fg = "@fg", bg = "@raised" },
  -- One-line notices on their state's tint, the full row wide.
  IaraSearchNotice = { fg = "@warn", bg = "@warn_soft" },
  IaraSearchError = { fg = "@error", bg = "@error_soft" },
  IaraSearchPlaceholder = { fg = "@muted" },
  IaraSearchFooter = { fg = "@muted", bg = "@mantle" },
  IaraSearchFooterKey = { fg = "@accent", bg = "@mantle", bold = true },
  IaraSearchPreviewLine = { bg = "@accent_soft" },
  -- The marked line's background wins over the match's, so the match is
  -- strong text with an accent underline (`Search`, a fg and bg pair,
  -- lost its bg there and read 1.0:1 before V10).
  IaraSearchPreviewMatch = {
    fg = "@fg_strong",
    sp = "@accent",
    bold = true,
    underline = true,
  },

  -- Theme picker rows: the stored choice's mark and the theme type.
  IaraThemeMark = { fg = "@accent", bold = true },
  IaraThemeType = { fg = "@muted" },

  -- The vim.ui.select presenter (iara.core.select).
  IaraSelectKey = { fg = "@accent_row", bold = true },
  IaraSelectText = { fg = "@fg" },
  IaraSelectDetail = { fg = "@muted" },
}
