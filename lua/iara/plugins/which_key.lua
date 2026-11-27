-- Shortcut discovery with English group names. Groups are declared here
-- once; each feature describes its own mappings.
--
-- Look (design 09, 3.7, tasks V9, V13): the `classic` preset, a straight
-- frame
-- across the bottom of the screen with the pressed prefix as its title,
-- groups first with a `▸` and their names in the accent, keys bold in the
-- accent, no separator glyph (alignment carries the relation). FU-V12-4
-- and V13: the title is which-key's prefix trail as plain text one dash
-- after the corner, and the close and back hints sit centered in the
-- bottom border, as on every other float.

local float = require("iara.core.float")

---Key hints of the bottom border.
local HINTS = { { "Esc", "close" }, { "BS", "back" } }

---Sort key that puts groups before single mappings; which-key's own
---"group" field sorts them last.
---@param item { group: boolean|nil }
---@return integer
local function groups_first(item)
  return item.group and 0 or 1
end

---Buffers of a picker: Snacks creates new ones on every open.
local PICKER_FILETYPES = {
  snacks_picker_input = true,
  snacks_picker_list = true,
  snacks_picker_preview = true,
}

---Delay of which-key's set-up of a picker buffer (task S11).
local PICKER_DEFER_MS = 50

---which-key builds a buffer's key tree and triggers when the buffer is
---entered: about 1.5 ms per Find files open for the picker's new
---buffers, before its first rows (S11 profile). Do it for those
---buffers once the picker is drawn: the first request is deferred by
---PICKER_DEFER_MS and answered nil (which-key's answer for a buffer it
---skips); which-key asks again for the current buffer every 50 ms.
local function defer_picker_buffers()
  local ok, Buf = pcall(require, "which-key.buf")
  if not ok or type(Buf.get) ~= "function" then
    return -- Another which-key layout: leave it as it is.
  end
  local get, waiting = Buf.get, {}
  Buf.get = function(get_opts)
    local buf = get_opts and get_opts.buf or vim.api.nvim_get_current_buf()
    local valid = vim.api.nvim_buf_is_valid(buf)
    if not valid or Buf.bufs[buf] or not PICKER_FILETYPES[vim.bo[buf].ft] then
      return get(get_opts)
    end
    if not waiting[buf] then
      waiting[buf] = true
      vim.defer_fn(function()
        waiting[buf] = nil
        if vim.api.nvim_get_current_buf() == buf then
          get({ buf = buf })
        end
      end, PICKER_DEFER_MS)
    end
  end
end

---Set up which-key, then start its prefix title one dash after the
---corner: which-key builds the title from its trail on every key, so
---the trail is wrapped where the title asks for it (`{ title = true }`).
---@param opts table
local function config(_, opts)
  require("which-key").setup(opts)
  defer_picker_buffers()
  local view = require("which-key.view")
  local trail = view.trail
  view.trail = function(node, trail_opts)
    local chunks = trail(node, trail_opts)
    if trail_opts and trail_opts.title then
      return float.wrap_title(chunks)
    end
    return chunks
  end
end

return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  cmd = "WhichKey",
  keys = {
    { "<leader>wK", "<cmd>WhichKey<CR>", desc = "Show all mappings" },
  },
  config = config,
  opts = {
    preset = "classic",
    win = {
      border = require("iara.core.ui").BORDER,
      padding = { 1, 2 },
      title = true,
      title_pos = "left",
      footer = float.footer(HINTS, 40),
      footer_pos = "center",
    },
    -- The hints are in the footer instead of a help row inside.
    show_help = false,
    sort = { groups_first, "local", "order", "alphanum", "mod" },
    icons = {
      breadcrumb = "\u{bb}",
      separator = "",
      group = "\u{25b8} ",
    },
    spec = {
      { "<leader>a", group = "Agents" },
      { "<leader>f", group = "Find" },
      { "<leader>g", group = "Git" },
      { "<leader>m", group = "Markdown" },
      { "<leader>r", group = "Rename and numbers" },
      { "<leader>t", group = "Terminal and themes" },
      { "<leader>w", group = "Which-key" },
      { "<leader>y", group = "Structured data" },
    },
  },
}
