--- Ask AI popup groups (AI1). The popup is a float on `mantle`; its
--- border chips (location, state) sit on the frame's own background;
--- the title and footer hints come from `iara.core.float`.
return {
  -- Location chip in the top border and quiet notes in the conversation.
  IaraAskMeta = { fg = "@muted", bg = "@mantle" },
  -- A running request: the spinner chip is water in motion (tide).
  IaraAskSpinner = { fg = "@tide", bg = "@mantle", bold = true },
  IaraAskError = { fg = "@error", bg = "@mantle" },
  IaraAskQuestion = { fg = "@accent", bold = true },
  IaraAskPrompt = { fg = "@accent", bg = "@mantle", bold = true },
}
