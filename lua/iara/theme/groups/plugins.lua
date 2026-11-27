--- Plugin UI groups: completion (nvim-cmp), signature help, which-key,
--- lazy.nvim, and Mason. Completion and which-key follow design 09
--- (sections 3.7 and 3.8, task V9); lazy.nvim and Mason keep base46's
--- integration slots (NvChad, MIT license).

---Kind color: the kind's syntax slot, softened 30% toward the text
---color. Kinds read like the code they complete, and the softening keeps
---every kind at 3:1 or more on the menu (`mantle`) and its selected row
---(`overlay`) in all shipped palettes, light ones included.
---@param slot string base_16 syntax slot
---@return table spec Group spec whose fg blends `slot` over `@fg`.
local function kind(slot)
  return { fg = { slot, "@fg", 70 } }
end

local groups = {
  -- The active parameter is marked by the accent, not by a filled block.
  LspSignatureActiveParameter = {
    fg = "@accent",
    sp = "@accent",
    bold = true,
    underline = true,
  },

  -- nvim-cmp: menu and documentation on the chrome surface inside the
  -- one straight frame every popup shares (V13: the subtle `border`,
  -- since the menu never takes the focus); the selected row is the
  -- overlay surface, bold, led by an accent bar drawn by
  -- `iara.plugins.cmp`.
  CmpPmenu = { fg = "@fg", bg = "@mantle" },
  CmpSel = { bg = "@overlay", bold = true },
  CmpBorder = { link = "FloatBorder" },
  CmpDoc = { fg = "@fg", bg = "@mantle" },
  CmpDocBorder = { link = "FloatBorder" },
  CmpItemAbbr = { fg = "@fg" },
  -- Matches sit on the menu and on its selected row: the accent made
  -- readable on `overlay` too (`accent_row`; V12 measured 3.55:1).
  CmpItemAbbrMatch = { fg = "@accent_row", bold = true },
  CmpItemAbbrMatchFuzzy = { fg = "@accent_row" },
  CmpItemAbbrDeprecated = { fg = "@muted", strikethrough = true },
  -- Kind names and source labels are quiet text.
  CmpItemKind = { fg = "@muted" },
  CmpItemMenu = { fg = "@muted", italic = true },
  CmpItemKindText = { fg = "@muted" },
  CmpItemKindFile = { fg = "@muted" },
  CmpItemKindFolder = { fg = "@muted" },
  CmpItemKindReference = { fg = "@muted" },
  CmpItemKindFunction = kind("base0D"),
  CmpItemKindMethod = kind("base0D"),
  CmpItemKindConstructor = kind("base0D"),
  CmpItemKindVariable = kind("base08"),
  CmpItemKindField = kind("base08"),
  CmpItemKindProperty = kind("base08"),
  CmpItemKindIdentifier = kind("base08"),
  CmpItemKindKeyword = kind("base0E"),
  CmpItemKindOperator = kind("base0E"),
  CmpItemKindConstant = kind("base09"),
  CmpItemKindEnumMember = kind("base09"),
  CmpItemKindValue = kind("base09"),
  CmpItemKindUnit = kind("base09"),
  CmpItemKindColor = kind("base09"),
  CmpItemKindClass = kind("base0A"),
  CmpItemKindInterface = kind("base0A"),
  CmpItemKindStruct = kind("base0A"),
  CmpItemKindEnum = kind("base0A"),
  CmpItemKindType = kind("base0A"),
  CmpItemKindTypeParameter = kind("base0A"),
  CmpItemKindModule = kind("base0A"),
  CmpItemKindSnippet = kind("base0C"),
  CmpItemKindEvent = kind("base0C"),

  -- which-key (classic preset): keys and groups in the accent, plain
  -- descriptions, quiet help text, on the float surface and frame.
  WhichKey = { fg = "@accent", bold = true },
  WhichKeyGroup = { fg = "@accent" },
  WhichKeyDesc = { fg = "@fg" },
  WhichKeySeparator = { fg = "@muted" },
  WhichKeyValue = { fg = "@muted" },
  WhichKeyNormal = { link = "NormalFloat" },
  WhichKeyBorder = { link = "FloatBorder" },
  WhichKeyTitle = { link = "FloatTitle" },
  WhichKeyIcon = { fg = "@muted" },

  -- lazy.nvim and Mason (V12): base46's slots moved onto roles so their
  -- text is readable in every palette. Headers and active buttons are
  -- rectangular accent blocks; `base` text on a state fill is readable
  -- because the state role is readable on `base`.
  LazyH1 = { fg = "@on_accent", bg = "@accent", bold = true },
  LazyH2 = { fg = "@accent", bold = true, underline = true },
  LazyButton = { fg = "@fg_strong", bg = "@overlay" },
  LazyButtonActive = { fg = "@on_accent", bg = "@accent", bold = true },
  LazySpecial = { fg = "@info" },
  LazyCommit = { fg = "@ok" },
  LazyProgressDone = { fg = "@ok" },
  LazyReasonPlugin = { fg = "@error" },
  LazyReasonEvent = { fg = "@warn" },
  LazyReasonKeys = { fg = "@tide" },
  LazyReasonCmd = { fg = "@accent" },
  LazyReasonFt = { fg = "@hint" },

  MasonHeader = { fg = "@on_accent", bg = "@accent", bold = true },
  MasonHighlight = { fg = "@info" },
  MasonHighlightBlock = { fg = "@base", bg = "@ok" },
  MasonHighlightBlockBold = { fg = "@base", bg = "@ok", bold = true },
  MasonMuted = { fg = "@muted" },
  MasonMutedBlock = { fg = "@muted", bg = "@overlay" },
}

return groups
