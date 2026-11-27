--- Markdown rendering groups (task MD1): render-markdown.nvim's groups,
--- Iara's custom task states, and the Markdown heading captures.
---
--- Heading levels take the accent, the tide, then the Visual, Terminal,
--- and Select mode colors (already distinct from the accent and tide in
--- every palette, `iara.theme.roles`), and muted text for level 6. The
--- heading text is that color blended half toward `fg_strong`, the icon
--- three quarters, on an 8% tint of it: readable on the tint and on the
--- cursor line (4.5:1 text, 3:1 icons) in all 12 palettes, light ones
--- included (`tests/test_markdown.lua`). Code sits on the chrome surface,
--- borders and bullets are quiet, and callouts use the state colors.

---Color of each heading level.
local LEVELS = {
  "@accent",
  "@tide",
  "@mode_visual",
  "@mode_terminal",
  "@mode_select",
  "@muted",
}

-- Share of the level color in the text, the icon, and the band.
local TEXT, ICON, TINT = 50, 75, 8

local groups = {
  -- Code blocks and inline code.
  RenderMarkdownCode = { bg = "@mantle" },
  RenderMarkdownCodeBorder = { bg = "@mantle" },
  RenderMarkdownCodeInfo = { fg = "@muted", bg = "@mantle" },
  RenderMarkdownCodeFallback = { fg = "@muted", bg = "@mantle" },
  IaraMarkdownCodeLanguage = { fg = "@muted", bg = "@mantle", bold = true },
  RenderMarkdownCodeInline = { bg = "@raised" },
  RenderMarkdownInlineHighlight = { bg = "@accent_soft" },

  -- Lists, quotes, rules, tables: quiet glyphs, readable text.
  RenderMarkdownBullet = { fg = "@muted" },
  RenderMarkdownQuote = { fg = "@subtle" },
  -- Quotes and callouts are a bar and plain text (Obsidian), not the
  -- generic quote surface, so callout titles keep 4.5:1 on light themes.
  ["@markup.quote.markdown"] = { fg = "@fg" },
  RenderMarkdownDash = { fg = "@subtle" },
  RenderMarkdownTableHead = { fg = "@muted" },
  RenderMarkdownTableRow = { fg = "@subtle" },
  ["@markup.heading.markdown"] = { fg = "@fg_strong", bold = true },

  -- Links: the accent marks what can be followed. Labels are not
  -- underlined: custom task markers ("[/]") are shortcut links too.
  RenderMarkdownLink = { fg = "@accent" },
  RenderMarkdownLinkTitle = { fg = "@accent" },
  ["@markup.link.label.markdown_inline"] = { fg = "@accent" },
  ["@markup.link.url.markdown_inline"] = { fg = "@muted", underline = true },

  -- Tasks: open is quiet, done is ok and its text struck through and
  -- faded (Obsidian), in progress flows (tide).
  RenderMarkdownUnchecked = { fg = "@muted" },
  RenderMarkdownChecked = { fg = "@ok" },
  RenderMarkdownTodo = { fg = "@tide" },
  IaraMarkdownStruck = { fg = "@muted", strikethrough = true },
  IaraMarkdownProgress = { fg = "@tide" },
  IaraMarkdownCancelled = { fg = "@subtle" },
  IaraMarkdownForwarded = { fg = "@muted" },
  IaraMarkdownImportant = { fg = "@warn" },
  IaraMarkdownQuestion = { fg = "@info" },

  -- Callouts (> [!NOTE] ...) keep their state meaning.
  RenderMarkdownSuccess = { fg = "@ok" },
  RenderMarkdownInfo = { fg = "@info" },
  RenderMarkdownHint = { fg = "@hint" },
  RenderMarkdownWarn = { fg = "@warn" },
  RenderMarkdownError = { fg = "@error" },
}

for level, color in ipairs(LEVELS) do
  groups["RenderMarkdownH" .. level] = { fg = { color, "@fg_strong", ICON } }
  groups["RenderMarkdownH" .. level .. "Bg"] = { bg = { color, "@base", TINT } }
  groups[("@markup.heading.%d.markdown"):format(level)] =
    { fg = { color, "@fg_strong", TEXT }, bold = true }
end

return groups
