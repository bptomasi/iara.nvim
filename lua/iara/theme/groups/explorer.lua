--- nvim-tree groups (V11, design 09 section 3.11), on the `mantle`
--- surface with a `crust` gap instead of a separator line. Folders flow
--- in the tide color, opened files are the accent, and the Git dot after
--- a name is colored by its state.
return {
  NvimTreeNormal = { fg = "@fg", bg = "@mantle" },
  NvimTreeNormalNC = { fg = "@fg", bg = "@mantle" },
  NvimTreeEndOfBuffer = { fg = "@mantle", bg = "@mantle" },
  NvimTreeWinSeparator = { fg = "@crust", bg = "@crust" },
  -- The editor's cursor line surface: text roles stay readable on it.
  NvimTreeCursorLine = { bg = "@cursorline" },
  NvimTreeIndentMarker = { fg = "@faint" },
  NvimTreeRootFolder = { fg = "@fg_strong", bg = "@raised", bold = true },
  IaraTreeBranch = { fg = "@muted", bg = "@mantle" },
  NvimTreeFolderIcon = { fg = "@tide" },
  NvimTreeOpenedFolderIcon = { fg = "@tide" },
  NvimTreeClosedFolderIcon = { fg = "@tide" },
  NvimTreeFolderName = { fg = "@tide" },
  NvimTreeEmptyFolderName = { fg = "@tide" },
  NvimTreeSymlinkFolderName = { fg = "@tide" },
  NvimTreeOpenedFolderName = { fg = "@fg_strong", bold = true },
  NvimTreeFolderArrowOpen = { fg = "@subtle" },
  NvimTreeFolderArrowClosed = { fg = "@subtle" },
  -- Opened names also sit on the cursor line: the row-readable accent.
  NvimTreeOpenedHL = { fg = "@accent_row" },
  NvimTreeSpecialFile = { fg = "@fg_strong" },
  NvimTreeExecFile = { fg = "@ok" },
  NvimTreeSymlink = { fg = "@info" },
  NvimTreeHiddenDisplay = { fg = "@muted" },
  NvimTreeModifiedIcon = { fg = "@accent" },
  NvimTreeWindowPicker = { fg = "@on_accent", bg = "@accent", bold = true },
  NvimTreeLiveFilterPrefix = { fg = "@accent", bold = true },
  NvimTreeLiveFilterValue = { fg = "@fg_strong" },
  NvimTreeGitDirtyIcon = { fg = "@warn" },
  NvimTreeGitStagedIcon = { fg = "@ok" },
  NvimTreeGitNewIcon = { fg = "@ok" },
  NvimTreeGitRenamedIcon = { fg = "@ok" },
  NvimTreeGitDeletedIcon = { fg = "@error" },
  NvimTreeGitMergeIcon = { fg = "@error" },
  NvimTreeGitIgnoredIcon = { fg = "@subtle" },
  -- Ignored names are quiet but still text (4.5:1).
  NvimTreeGitFileIgnoredHL = { fg = "@muted" },
  NvimTreeGitFolderIgnoredHL = { fg = "@muted" },
}
