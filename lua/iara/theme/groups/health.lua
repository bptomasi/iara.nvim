--- Health, and the agent context preview (V11, design 09 section 3.12).
return {
  -- Neovim's own report groups: state colors, no filled blocks.
  healthSuccess = { fg = "@ok", bold = true },
  healthWarning = { fg = "@warn", bold = true },
  healthError = { fg = "@error", bold = true },
  healthSectionDelim = { fg = "@fg_strong", bold = true },
  -- `iara.core.health_look`.
  IaraHealthOk = { fg = "@ok" },
  IaraHealthWarn = { fg = "@warn" },
  IaraHealthError = { fg = "@error" },
  IaraHealthHeading = { fg = "@fg_strong", bold = true },
  IaraHealthAdvice = { fg = "@muted" },
  IaraHealthMark = { fg = "@accent", bold = true },
  IaraHealthRule = { fg = "@border" },
  -- Agent context preview (`iara.extras.agents.preview`): a float on
  -- `mantle`.
  IaraContextChip = { fg = "@fg_strong", bg = "@raised" },
  -- States are readable on their own tint (V1).
  IaraContextChipWarn = { fg = "@warn", bg = "@warn_soft", bold = true },
  IaraContextLabel = { fg = "@accent", bg = "@mantle", bold = true },
  IaraContextValue = { fg = "@muted", bg = "@mantle" },
  -- The rule under the summary is a quiet line in the idle frame's
  -- color (V13: the frame itself lights up only with the focus).
  IaraContextRule = { fg = "@border", bg = "@mantle" },
}
