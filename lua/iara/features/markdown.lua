--- Markdown rendering (task MD1): an Obsidian-like live preview through
--- render-markdown.nvim, loaded only for Markdown buffers.
---
--- Normal, Command-line, and Terminal mode render, and the cursor's line
--- shows its raw text (anti-conceal), like Obsidian's live preview.
--- Insert mode shows the raw note (Obsidian's source mode): rendering
--- while typing raised measured p95 input latency from 5 to 17-20 ms.
--- Only file
--- buffers ('buftype' "") attach: picker previews, hover floats, and
--- other scratch buffers stay as Tree-sitter highlights them.
---
--- A buffer renders while the global switch is on (`toggle`) and
--- `iara.core.eligibility` finds it eligible: conservative or still
--- unknown buffers show raw text, and follow `IaraEligibilityChanged`.
--- See contracts.md, section 13.
local M = {}

M.COMMAND = "IaraMarkdownToggle"
M.DESC = "Markdown render toggle"

---Modes that render; Insert mode shows raw text (see above).
M.RENDER_MODES = { "n", "c", "t" }

local MIB = 1048576

---Global switch (`toggle`) and the state last applied per buffer.
local state = { enabled = true, applied = {} }

local api = vim.api

---Obsidian's custom task states, drawn as checkboxes: raw marker, glyph
---name in `iara.core.icons.MARKDOWN`, group, and text group. Keys are
---render-markdown.nvim's; its own `todo` entry ("[-]") is replaced by
---Obsidian's meaning of that marker, cancelled.
M.TASK_STATES = {
  progress = { "[/]", "progress", "IaraMarkdownProgress" },
  todo = { "[-]", "cancelled", "IaraMarkdownCancelled", "IaraMarkdownStruck" },
  forwarded = { "[>]", "forwarded", "IaraMarkdownForwarded" },
  important = { "[!]", "important", "IaraMarkdownImportant" },
  question = { "[?]", "question", "IaraMarkdownQuestion" },
}

local function custom_checkboxes(glyphs)
  local custom = {}
  for key, entry in pairs(M.TASK_STATES) do
    custom[key] = {
      raw = entry[1],
      rendered = glyphs[entry[2]],
      highlight = entry[3],
      scope_highlight = entry[4],
    }
  end
  return custom
end

local function checkbox(glyphs)
  return {
    -- The glyphs carry their own trailing space.
    right_pad = 0,
    unchecked = { icon = glyphs.unchecked },
    checked = {
      icon = glyphs.checked,
      -- Obsidian strikes done tasks through and fades them.
      scope_highlight = "IaraMarkdownStruck",
    },
    custom = custom_checkboxes(glyphs),
  }
end

local function heading(glyphs)
  return {
    sign = false,
    icons = glyphs.headings,
    position = "inline",
    width = "block",
    right_pad = 1,
  }
end

local function code()
  return {
    sign = false,
    width = "block",
    min_width = 48,
    left_pad = 1,
    right_pad = 1,
    border = "thin",
    language_pad = 1,
    highlight_language = "IaraMarkdownCodeLanguage",
  }
end

local function pipe_table(glyphs)
  return {
    border = glyphs.table,
    alignment_indicator = glyphs.alignment,
    cell = "padded",
  }
end

---Options for render-markdown.nvim's setup().
---@return table
function M.options()
  local glyphs = require("iara.core.icons").MARKDOWN
  local limit = require("iara.core.eligibility").LIMITS.max_bytes
  return {
    file_types = { "markdown" },
    render_modes = M.RENDER_MODES,
    max_file_size = limit / MIB,
    ignore = function(bufnr)
      return vim.bo[bufnr].buftype ~= ""
    end,
    anti_conceal = { enabled = true, above = 0, below = 0 },
    sign = { enabled = false },
    heading = heading(glyphs),
    code = code(),
    bullet = { icons = glyphs.bullets },
    checkbox = checkbox(glyphs),
    quote = { icon = glyphs.quote },
    pipe_table = pipe_table(glyphs),
    dash = { icon = glyphs.rule },
    link = { hyperlink = glyphs.link },
    on = { attach = M.attached },
  }
end

---True when `bufnr` should render now.
---@param bufnr integer
---@return boolean
function M.wanted(bufnr)
  return state.enabled
    and api.nvim_buf_is_valid(bufnr)
    and require("iara.core.eligibility").is_eligible(bufnr)
end

---Global switch.
---@return boolean
function M.enabled()
  return state.enabled
end

---Rendering state applied to `bufnr`: nil while the plugin has not
---attached to it.
---@param bufnr integer
---@return boolean|nil
function M.rendering(bufnr)
  return state.applied[bufnr]
end

---Switch rendering of `bufnr`. The plugin's public buffer switches act
---on the current buffer, hence `nvim_buf_call`.
local function switch(bufnr, enable)
  local render_markdown = require("render-markdown")
  api.nvim_buf_call(bufnr, function()
    if enable then
      render_markdown.buf_enable()
    else
      render_markdown.buf_disable()
    end
  end)
end

---Bring an attached buffer to its wanted state.
---@param bufnr integer
function M.apply(bufnr)
  local applied = state.applied[bufnr]
  if applied == nil or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local wanted = M.wanted(bufnr)
  if wanted ~= applied then
    state.applied[bufnr] = wanted
    switch(bufnr, wanted)
  end
end

---A buffer switched off while hidden keeps its marks (the plugin only
---clears a buffer shown in a window): clear them when it is shown.
local function shown(bufnr)
  M.apply(bufnr)
  if state.applied[bufnr] == false then
    switch(bufnr, false)
  end
end

local function sets_conceal_lines(directives)
  for _, directive in ipairs(directives or {}) do
    if directive[1] == "set!" and directive[2] == "conceal_lines" then
      return true
    end
  end
  return false
end

---Neovim's markdown highlight query hides code fence lines
---(`conceal_lines`). render-markdown.nvim draws those lines and disables
---the patterns, but the query still reports `has_conceal_line`, so with
---'conceallevel' 3 the Tree-sitter highlighter re-parses the tree for
---every row Neovim checks while scrolling: jumps through a 531 KiB note
---took 76 ms at p95 (MD2 evidence). Disable the patterns here and clear
---the flag. Idempotent.
---@return boolean changed The flag was set and is now cleared.
function M.drop_conceal_lines()
  local ok, query = pcall(vim.treesitter.query.get, "markdown", "highlights")
  if not ok or not query or not query.has_conceal_line then
    return false
  end
  for id, directives in pairs(query.info.patterns) do
    if sets_conceal_lines(directives) then
      query.query:disable_pattern(id)
    end
  end
  query.has_conceal_line = false
  return true
end

---A highlighter reads `has_conceal_line` when it starts: restart the
---ones of rendered (file) Markdown buffers started before the change.
local function restart_highlighters()
  local active = vim.tbl_keys(vim.treesitter.highlighter.active)
  for _, bufnr in ipairs(active) do
    local bo = vim.bo[bufnr]
    if bo.filetype == "markdown" and bo.buftype == "" then
      vim.treesitter.stop(bufnr)
      vim.treesitter.start(bufnr, "markdown")
    end
  end
end

---render-markdown.nvim attached `ctx.buf`, enabled: apply Iara's state
---before its first render.
---@param ctx { buf: integer }
function M.attached(ctx)
  if M.drop_conceal_lines() then
    restart_highlighters()
  end
  state.applied[ctx.buf] = true
  M.apply(ctx.buf)
end

---Flip the global switch and apply it to every attached buffer.
---@return boolean enabled
function M.toggle()
  state.enabled = not state.enabled
  for bufnr in pairs(state.applied) do
    M.apply(bufnr)
  end
  local word = state.enabled and "on" or "off"
  vim.notify("Markdown rendering " .. word, vim.log.levels.INFO)
  return state.enabled
end

local function create_autocmds()
  local group = api.nvim_create_augroup("IaraMarkdown", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = function(args)
      M.apply(args.data.bufnr)
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      shown(args.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      state.applied[args.buf] = nil
    end,
  })
end

---Set up render-markdown.nvim with `options()`, the eligibility
---handlers, and `:IaraMarkdownToggle`. Called by the plugin spec.
function M.setup()
  create_autocmds()
  api.nvim_create_user_command(M.COMMAND, function()
    M.toggle()
  end, { desc = M.DESC })
  require("render-markdown").setup(M.options())
end

return M
