--- Terminal and agent panel groups.
---
--- UX2: the name as a colored label in the status line, then the job
--- state. V7 (design 09 section 3.6): panels on the `mantle` surface and
--- their headers (`iara.features.terminal.header`): a bar in `tide` for
--- shells, `hint` for agents, `accent` when focused; the label in
--- `fg_strong`; directory and hint texts `muted`; keys `accent`; the
--- state `tide` while running and `error` after a failure. Every part
--- carries the surface, so it reads the same in the winbar and on a
--- float's border.
local function on_panel(fg, extra)
  local spec = { fg = fg, bg = "@mantle" }
  for key, value in pairs(extra or {}) do
    spec[key] = value
  end
  return spec
end

return {
  -- Status line labels (V7 on V4's request): mode-block roles, whose text
  -- is readable on the fill; the state in the `ok` and `error` roles.
  IaraStatusTerminal = {
    fg = "@on_mode_terminal",
    bg = "@mode_terminal",
    bold = true,
  },
  IaraStatusAgent = {
    fg = "@on_mode_visual",
    bg = "@mode_visual",
    bold = true,
  },
  IaraStatusRunning = { fg = "@ok", bg = "@mantle" },
  IaraStatusExited = { fg = "@error", bg = "@mantle", bold = true },
  IaraPanel = on_panel("@fg"),
  IaraPanelHeader = on_panel("@muted"),
  IaraPanelBarShell = on_panel("@tide"),
  IaraPanelBarAgent = on_panel("@hint"),
  IaraPanelBarFocus = on_panel("@accent"),
  IaraPanelTitle = on_panel("@fg_strong", { bold = true }),
  IaraPanelCwd = on_panel("@muted"),
  IaraPanelRunning = on_panel("@tide"),
  IaraPanelStopping = on_panel("@warn"),
  IaraPanelExited = on_panel("@error", { bold = true }),
  IaraPanelDone = on_panel("@muted"),
  IaraPanelKey = on_panel("@accent", { bold = true }),
  IaraPanelHint = on_panel("@muted"),
}
