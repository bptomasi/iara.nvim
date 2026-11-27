--- Editor groups: the text area, messages, diff and spelling,
--- diagnostics, LSP references, Gitsigns, and Iara's breadcrumb. Slot
--- choices follow base46's integrations (NvChad, MIT license); text
--- those slots left below 4.5:1 uses roles (V12).
return {
  Normal = { fg = "base05", bg = "base00" },
  Cursor = { fg = "base00", bg = "base05" },
  CursorLine = { bg = "black2" },
  CursorColumn = { bg = "base01" },
  ColorColumn = { bg = "black2" },
  -- Line numbers count as text (V8): the `muted` role, readable 4.5:1 on
  -- the editor and its cursor line; the cursor's number is the accent.
  CursorLineNr = { fg = "@accent", bold = true },
  LineNr = { fg = "@muted" },
  SignColumn = { fg = "base03" },
  FoldColumn = { fg = "base0F" },
  -- V12: base46's slots below 4.5:1 moved onto roles. Folds read as
  -- quiet text on the cursor line surface.
  Folded = { fg = "@muted", bg = "@cursorline" },
  Visual = { bg = "base02" },
  VisualNOS = { link = "Visual" },
  -- Matches are the accent's tint (as in the pickers); the current
  -- match and substitutions are an accent fill.
  Search = { fg = "@fg_strong", bg = "@accent_soft" },
  IncSearch = { fg = "@on_accent", bg = "@accent" },
  CurSearch = { link = "IncSearch" },
  Substitute = { fg = "@on_accent", bg = "@accent" },
  -- The pair may sit on the cursor line: the row-readable accent.
  MatchParen = { fg = "@accent_row", bold = true, underline = true },
  Title = { fg = "base0D", bold = true },
  Directory = { fg = "base0D" },
  NonText = { fg = "base03" },
  EndOfBuffer = { fg = "base00" },
  SpecialKey = { fg = "base03" },
  -- Indent guides are 'listchars' (`iara.core.guides`): decoration only.
  Whitespace = { fg = "@faint" },
  Conceal = { fg = "light_grey" },
  -- Messages are text in the command line: state roles keep them
  -- readable (4.5:1) in every palette (V12; yellow was 1.97:1 in
  -- gruvbox_light).
  ErrorMsg = { fg = "@error" },
  WarningMsg = { fg = "@warn" },
  ModeMsg = { fg = "@ok" },
  MoreMsg = { fg = "@ok" },
  Question = { fg = "base0D" },
  WildMenu = { fg = "@fg_strong", bg = "@overlay", bold = true },
  QuickFixLine = { bg = "base01" },
  NvimInternalError = { fg = "@error" },

  -- Diff and spelling
  Added = { fg = "@ok" },
  Changed = { fg = "@warn" },
  Removed = { fg = "@error" },
  -- Diff lines on their state's tint, readable by construction (V12);
  -- the changed text inside a changed line is bold `info` on it.
  DiffAdd = { fg = "@ok", bg = "@ok_soft" },
  DiffChange = { bg = "@info_soft" },
  DiffDelete = { fg = "@error", bg = "@error_soft" },
  DiffText = { fg = "@info", bg = "@info_soft", bold = true },
  SpellBad = { sp = "red", undercurl = true },
  SpellCap = { sp = "yellow", undercurl = true },
  SpellLocal = { sp = "teal", undercurl = true },
  SpellRare = { sp = "purple", undercurl = true },

  -- Diagnostics and LSP: the state roles, readable 4.5:1 on the editor
  -- and on their own tint. Info is blue, so it no longer reads as
  -- success next to Ok (design 09, decision 1).
  DiagnosticError = { fg = "@error" },
  DiagnosticWarn = { fg = "@warn" },
  DiagnosticInfo = { fg = "@info" },
  DiagnosticHint = { fg = "@hint" },
  DiagnosticOk = { fg = "@ok" },
  DiagnosticUnderlineError = { sp = "@error", undercurl = true },
  DiagnosticUnderlineWarn = { sp = "@warn", undercurl = true },
  DiagnosticUnderlineInfo = { sp = "@info", undercurl = true },
  DiagnosticUnderlineHint = { sp = "@hint", undercurl = true },
  DiagnosticUnderlineOk = { sp = "@ok", undercurl = true },
  -- Virtual text (current line only) sits on a faint tint of its color.
  DiagnosticVirtualTextError = { fg = "@error", bg = "@error_soft" },
  DiagnosticVirtualTextWarn = { fg = "@warn", bg = "@warn_soft" },
  DiagnosticVirtualTextInfo = { fg = "@info", bg = "@info_soft" },
  DiagnosticVirtualTextHint = { fg = "@hint", bg = "@hint_soft" },
  DiagnosticVirtualTextOk = { fg = "@ok", bg = "@ok_soft" },
  -- Unused code, hints, lenses, and blame are quiet but readable text.
  DiagnosticUnnecessary = { fg = "@muted" },
  DiagnosticDeprecated = { sp = "light_grey", strikethrough = true },
  LspReferenceText = { bg = "one_bg3" },
  LspReferenceRead = { bg = "one_bg3" },
  LspReferenceWrite = { bg = "one_bg3" },
  LspInlayHint = { fg = "@muted", bg = "@cursorline" },
  LspCodeLens = { fg = "@muted" },

  -- Gitsigns bars: added `ok`, changed `info` (blue: a change is not a
  -- warning), removed `error`.
  GitSignsAdd = { fg = "@ok" },
  GitSignsChange = { fg = "@info" },
  GitSignsDelete = { fg = "@error" },
  GitSignsAddNr = { fg = "@ok" },
  GitSignsChangeNr = { fg = "@info" },
  GitSignsDeleteNr = { fg = "@error" },
  GitSignsAddLn = { link = "DiffAdd" },
  GitSignsChangeLn = { link = "DiffChange" },
  GitSignsDeleteLn = { link = "DiffDelete" },
  GitSignsAddPreview = { link = "DiffAdd" },
  GitSignsDeletePreview = { link = "DiffDelete" },
  GitSignsCurrentLineBlame = { fg = "@muted" },

  -- The structured breadcrumb (D4): quiet like yaml-revealer's virtual
  -- text, but readable (its old link, Comment, was 2.3:1 in nord; V12).
  IaraBreadcrumb = { fg = "@muted" },
}
