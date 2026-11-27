--- Glyphs shared by the status line, tab line, start screen, diagnostics,
--- Gitsigns, completion, and the file tree (UX3). They need a Nerd Font,
--- as nvim-web-devicons does. Code points are written as escapes so the
--- source stays readable without the font.
---
--- File icons come from nvim-web-devicons only when it is already loaded:
--- drawing a status line or tab line never loads a plugin.
local M = {}

M.FILE = "\u{f021a}" -- document
M.MODIFIED = "\u{25cf}" -- dot
M.READONLY = "\u{f033e}" -- lock
M.FOLDER = "\u{f024b}"
M.FOLDER_OPEN = "\u{f0770}"
M.GIT_BRANCH = "\u{e725}"
M.LSP = "\u{f085}" -- gears
M.TERMINAL = "\u{f489}"
M.AGENT = "\u{f06a9}" -- robot
M.WARNING = "\u{f071}"
M.CONFLICT = "\u{f0026}" -- alert

---Diagnostic glyphs by severity name, as `vim.diagnostic.severity` keys.
M.DIAGNOSTICS = {
  ERROR = "\u{f057}",
  WARN = "\u{f071}",
  INFO = "\u{f02fc}",
  HINT = "\u{f06e9}",
}

---Git change counts (status line).
M.GIT = { added = "\u{f457}", changed = "\u{f459}", removed = "\u{f458}" }

---Gitsigns sign column glyphs: thin bars for changes, a triangle where
---lines were removed.
M.GIT_SIGNS = {
  add = "\u{258e}",
  change = "\u{258e}",
  delete = "\u{f0d7}",
  topdelete = "\u{f0d8}",
  changedelete = "\u{258e}",
  untracked = "\u{2506}",
}

---Completion item kinds (LSP CompletionItemKind names).
M.KINDS = {
  Text = "\u{f027f}",
  Method = "\u{f01a7}",
  Function = "\u{f0295}",
  Constructor = "\u{f0ad}",
  Field = "\u{f0722}",
  Variable = "\u{f002b}",
  Class = "\u{f0831}",
  Interface = "\u{f0e8}",
  Module = "\u{f487}",
  Property = "\u{f0722}",
  Unit = "\u{f046d}",
  Value = "\u{f03a0}",
  Enum = "\u{f15d}",
  Keyword = "\u{f030b}",
  Snippet = "\u{f0c4}",
  Color = "\u{f03d8}",
  File = "\u{f0219}",
  Reference = "\u{f0207}",
  Folder = "\u{f024b}",
  EnumMember = "\u{f15d}",
  Constant = "\u{f03ff}",
  Struct = "\u{f0645}",
  Event = "\u{f0e7}",
  Operator = "\u{f0195}",
  TypeParameter = "\u{ea92}",
}

---Start screen actions.
M.ACTIONS = {
  files = "\u{f021e}",
  grep = "\u{f002}",
  recent = "\u{f02da}",
  new = "\u{f0224}",
  terminal = "\u{f489}",
  themes = "\u{f03d8}",
  quit = "\u{f0206}",
}

---Start screen shapes (Unicode, not Nerd Font): the Iara mark (a sine
---wave, design 09 section 2.3), the selection bar, and the section rule.
M.START = { mark = "\u{223f}", bar = "\u{258e}", rule = "\u{2500}" }

---Markdown rendering (MD1, V13): heading numbers in circle outlines,
---list bullets, box-outline checkboxes (Obsidian's custom states
---included), the quote bar (the selection bar's shape), a straight
---table frame (design 09, section 7), and the link icon.
M.MARKDOWN = {
  headings = {
    "\u{f0ca1} ", -- numeric_1_circle_outline
    "\u{f0ca3} ",
    "\u{f0ca5} ",
    "\u{f0ca7} ",
    "\u{f0ca9} ",
    "\u{f0cab} ",
  },
  bullets = { "\u{25cf}", "\u{25cb}", "\u{25c6}", "\u{25c7}" },
  unchecked = "\u{f0131} ", -- checkbox_blank_outline
  checked = "\u{f0c52} ", -- checkbox_outline
  progress = "\u{f0856} ", -- checkbox_intermediate, "[/]"
  cancelled = "\u{f0158} ", -- close_box_outline, "[-]"
  forwarded = "\u{f0736} ", -- arrow_right_bold_box_outline, "[>]"
  important = "\u{f0ce4} ", -- alert_box_outline, "[!]"
  question = "\u{f078b} ", -- help_box, "[?]"
  quote = "\u{258e}",
  -- Corners, joints, and lines: top, delimiter row, bottom, then the
  -- vertical and horizontal lines (render-markdown.nvim's order).
  table = {
    "\u{250c}",
    "\u{252c}",
    "\u{2510}",
    "\u{251c}",
    "\u{253c}",
    "\u{2524}",
    "\u{2514}",
    "\u{2534}",
    "\u{2518}",
    "\u{2502}",
    "\u{2500}",
  },
  alignment = "\u{2501}",
  rule = "\u{2500}",
  link = "\u{f0339} ", -- link_variant
}

---Icon of a file name: nvim-web-devicons' glyph when that plugin is
---loaded, else the generic file glyph.
---@param name string File name or path.
---@return string
function M.file(name)
  local devicons = package.loaded["nvim-web-devicons"]
  if type(devicons) ~= "table" or name == "" then
    return M.FILE
  end
  local tail = vim.fn.fnamemodify(name, ":t")
  local ok, icon = pcall(devicons.get_icon, tail, nil, { default = true })
  return ok and icon or M.FILE
end

return M
