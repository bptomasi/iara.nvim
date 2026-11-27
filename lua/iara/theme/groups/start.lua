--- Start screen groups (UX3, V6; design 09 section 3.1). The foam
--- uses strong text, the wave shades into tide, and keys are chips
--- on the accent tint, and an accent bar leads the `overlay` cursor row.
--- Labels and key letters use
--- `fg_strong`: `fg` and `accent` fall below 4.5:1 on `overlay` or on
--- the accent tint in some palettes (V6 evidence). Text is not italic:
--- many terminal fonts render italics poorly.
return {
  IaraStartWaveFoam = { fg = "@fg_strong" },
  IaraStartWaveMid = { fg = { "@fg_strong", "@tide", 50 } },
  IaraStartWaveTide = { fg = "@tide" },
  IaraStartText = { fg = "@muted" },
  IaraStartIcon = { fg = "@accent" },
  IaraStartAction = { fg = "@fg_strong" },
  IaraStartKey = { fg = "@fg_strong", bg = "@accent_soft", bold = true },
  IaraStartCursor = { bg = "@overlay" },
  IaraStartBar = { fg = "@accent", bg = "@overlay" },
  IaraStartSection = { fg = "@muted" },
  IaraStartRule = { fg = "@border" },
  IaraStartFileIcon = { fg = "@muted" },
  IaraStartFile = { fg = "@fg_strong" },
  IaraStartMark = { fg = "@accent" },
  IaraStartFooter = { fg = "@muted" },
}
