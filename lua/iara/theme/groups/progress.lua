--- LSP progress segment of the status line (V5, design 09 section
--- 3.10): the spinner and bar in the tide (things in motion), the bar's
--- remaining cells `subtle` (a faint track vanishes on light palettes),
--- title and percent muted, "ready" in the ok state. Same background as
--- the other status line parts.
return {
  IaraProgressSpinner = { fg = "@tide", bg = "@mantle" },
  IaraProgressClient = { fg = "@fg", bg = "@mantle" },
  IaraProgressTitle = { fg = "@muted", bg = "@mantle" },
  IaraProgressBar = { fg = "@tide", bg = "@mantle" },
  IaraProgressBarTrack = { fg = "@subtle", bg = "@mantle" },
  IaraProgressDone = { fg = "@ok", bg = "@mantle" },
}
