-- Completion with nvim-cmp and LuaSnip, loaded on the first insertion.
-- Completion is off in buffers that are not eligible, and the buffer
-- source reads only eligible visible buffers.

local function eligible(bufnr)
  return require("iara.core.eligibility").is_eligible(bufnr)
end

---Visible file buffers whose words the buffer source may index. Terminal
---and other special buffers are skipped: indexing a streaming terminal
---made typing stall (M2-T measured p95 26-40 ms against 3 ms).
local function eligible_visible_buffers()
  local buffers = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(window)
    if vim.bo[bufnr].buftype == "" and eligible(bufnr) then
      buffers[bufnr] = true
    end
  end
  return vim.tbl_keys(buffers)
end

local function tab_mapping(cmp, direction)
  local luasnip = require("luasnip")
  return cmp.mapping(function(fallback)
    if cmp.visible() then
      if direction > 0 then
        cmp.select_next_item()
      else
        cmp.select_prev_item()
      end
    elseif direction > 0 and luasnip.expand_or_jumpable() then
      luasnip.expand_or_jump()
    elseif direction < 0 and luasnip.jumpable(-1) then
      luasnip.jump(-1)
    else
      fallback()
    end
  end, { "i", "s" })
end

local function mappings(cmp)
  return {
    ["<C-p>"] = cmp.mapping.select_prev_item(),
    ["<C-n>"] = cmp.mapping.select_next_item(),
    ["<C-d>"] = cmp.mapping.scroll_docs(-4),
    ["<C-f>"] = cmp.mapping.scroll_docs(4),
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<C-e>"] = cmp.mapping.close(),
    ["<CR>"] = cmp.mapping.confirm({
      behavior = cmp.ConfirmBehavior.Insert,
      select = true,
    }),
    ["<Tab>"] = tab_mapping(cmp, 1),
    ["<S-Tab>"] = tab_mapping(cmp, -1),
  }
end

-- Source labels shown in the menu column.
local SOURCE_LABELS = {
  nvim_lsp = "LSP",
  luasnip = "LuaSnip",
  buffer = "Buffer",
  path = "Path",
}

---Menu row (design 09, 3.8): the kind icon in its kind color
---(`CmpItemKind<Kind>`), the label, then the kind name and the source
---label as quiet text. The label width is bounded so columns stay
---aligned.
local function format(entry, item)
  local icons = require("iara.core.icons").KINDS
  local kind = item.kind or "Text"
  item.icon = icons[kind] or icons.Text
  item.icon_hl_group = "CmpItemKind" .. kind
  item.kind = kind
  item.kind_hl_group = "CmpItemKind"
  item.menu = SOURCE_LABELS[entry.source.name] or entry.source.name
  if vim.api.nvim_strwidth(item.abbr) > 40 then
    item.abbr = vim.fn.strcharpart(item.abbr, 0, 39) .. "\u{2026}"
  end
  return item
end

---Bordered menu and documentation windows in the theme's Cmp* groups.
---The menu keeps one column of padding on each side; the left one holds
---the selection bar.
local function windows(cmp)
  return {
    completion = cmp.config.window.bordered({
      border = require("iara.core.ui").BORDER,
      winhighlight = "Normal:CmpPmenu,FloatBorder:CmpBorder,"
        .. "CursorLine:CmpSel,Search:None",
      scrollbar = false,
      -- Border, padding, and icon: the label starts under the typed word.
      col_offset = -4,
      side_padding = 1,
    }),
    documentation = cmp.config.window.bordered({
      border = require("iara.core.ui").BORDER,
      winhighlight = "Normal:CmpDoc,FloatBorder:CmpDocBorder",
      max_width = 80,
      max_height = 20,
    }),
  }
end

-- The menu's look beyond cmp's options (design 09, 3.8): an accent bar on
-- the selected row and a title on the documentation window naming the
-- kind and source. Both are drawn when Neovim redraws those windows,
-- which cmp marks with its documented filetypes `cmp_menu` and
-- `cmp_docs`; nothing runs for other windows but one table lookup.

---Glyph of the selection bar.
local SELECTION_BAR = "\u{258e}"

local LOOK_FILETYPES = { cmp_menu = "menu", cmp_docs = "docs" }

---cmp's menu and documentation buffers: buffer number -> "menu"|"docs".
---@type table<integer, string>
local look_buffers = {}

---Documentation title last set per window.
---@type table<integer, string>
local titled = {}

local look_ns = vim.api.nvim_create_namespace("iara.cmp.look")

---The accent bar over the left padding of the selected row; cmp shows
---'cursorline' only while an entry is selected.
local function draw_selection_bar(win, buf)
  if not vim.wo[win].cursorline then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  vim.api.nvim_buf_set_extmark(buf, look_ns, row, 0, {
    virt_text = { { SELECTION_BAR, "IaraAccent" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
    ephemeral = true,
  })
end

---"Kind · Source" of the selected entry, or nil.
local function docs_title_text()
  local cmp = package.loaded.cmp
  local entry = cmp and cmp.get_selected_entry()
  if not entry then
    return nil
  end
  local kinds = require("cmp.types").lsp.CompletionItemKind
  local source = entry.source.name
  local kind = kinds[entry:get_kind()] or "Text"
  return kind .. " \u{b7} " .. (SOURCE_LABELS[source] or source)
end

---Put the selected entry's title on the documentation window. A window
---cannot be reconfigured while it is drawn, so the change is scheduled.
local function title_docs(win)
  local text = docs_title_text()
  local current = vim.api.nvim_win_get_config(win).title
  if not text or (titled[win] == text and current) then
    return
  end
  titled[win] = text
  -- The idle title of the float language, cut to the window's width.
  local width = vim.api.nvim_win_get_width(win)
  local title = require("iara.core.float").title(text, false, width)
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, { title = title, title_pos = "left" })
    end
  end)
end

local function on_win(_, win, buf)
  local role = look_buffers[buf]
  if role == "menu" then
    draw_selection_bar(win, buf)
  elseif role == "docs" then
    title_docs(win)
  end
  return false
end

local function track(bufnr)
  look_buffers[bufnr] = LOOK_FILETYPES[vim.bo[bufnr].filetype]
end

---Follow cmp's menu and documentation buffers and draw their look.
local function setup_look()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("IaraCmpLook", { clear = true }),
    pattern = vim.tbl_keys(LOOK_FILETYPES),
    callback = function(args)
      track(args.buf)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    track(bufnr)
  end
  vim.api.nvim_set_decoration_provider(look_ns, { on_win = on_win })
end

local function options()
  local cmp = require("cmp")
  return {
    enabled = function()
      return vim.bo.buftype ~= "prompt" and eligible(0)
    end,
    completion = { completeopt = "menu,menuone" },
    snippet = {
      expand = function(args)
        require("luasnip").lsp_expand(args.body)
      end,
    },
    mapping = mappings(cmp),
    window = windows(cmp),
    formatting = {
      fields = { "icon", "abbr", "kind", "menu" },
      format = format,
    },
    sources = {
      { name = "nvim_lsp" },
      { name = "luasnip" },
      {
        name = "buffer",
        option = { get_bufnrs = eligible_visible_buffers },
      },
      { name = "path" },
    },
  }
end

return {
  "hrsh7th/nvim-cmp",
  event = "InsertEnter",
  dependencies = {
    {
      "L3MON4D3/LuaSnip",
      dependencies = { "rafamadriz/friendly-snippets" },
      opts = { history = true, updateevents = "TextChanged,TextChangedI" },
      config = function(_, opts)
        require("luasnip").config.set_config(opts)
        require("luasnip.loaders.from_vscode").lazy_load()
      end,
    },
    "saadparwaiz1/cmp_luasnip",
    {
      "hrsh7th/cmp-nvim-lsp",
      -- Its plugin file requires cmp on InsertEnter, and nvim-lspconfig
      -- loads it before cmp: it may only load when cmp can (task X3).
      cond = function(plugin)
        local lazy = require("iara.core.lazy")
        return lazy.available(plugin) and lazy.available({ name = "nvim-cmp" })
      end,
    },
    "hrsh7th/cmp-buffer",
    "hrsh7th/cmp-path",
  },
  opts = options,
  config = function(_, opts)
    require("cmp").setup(opts)
    setup_look()
  end,
}
