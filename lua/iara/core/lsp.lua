--- Native LSP policy shared by language files.
---
--- Servers use nvim-lspconfig definitions through `vim.lsp.config` and
--- `vim.lsp.enable`; Iara adds no FileType start of its own. Eligibility
--- enters the native activation path through `root_dir(bufnr, on_dir)`,
--- which delegates to the definition's own root rules. A buffer that
--- leaves the eligible state is detached from Iara's servers; one that
--- becomes eligible goes through native activation again. Semantic tokens,
--- document colors, and inlay hints start off. See ARCH, "Language tools
--- and safe activation".
local M = {}

local eligibility = require("iara.core.eligibility")

---Servers enabled through M.enable(), by name.
---@type table<string, boolean>
local owned = {}

---Buffer mappings set on attach, removed when the last server detaches:
---`{ lhs, rhs, desc, modes? }` (Normal mode unless `modes` is given).
local ATTACH_KEYMAPS = {
  { "gd", vim.lsp.buf.definition, "Go to definition" },
  { "gD", vim.lsp.buf.declaration, "Go to declaration" },
  { "<leader>D", vim.lsp.buf.type_definition, "Go to type definition" },
  { "<leader>ra", vim.lsp.buf.rename, "Rename symbol" },
  {
    "K",
    function()
      M.hover()
    end,
    "Hover documentation",
  },
  {
    "<C-s>",
    function()
      M.signature_help()
    end,
    "Signature help",
    { "i", "s" },
  },
}

---Size limits of the hover and signature floats, as for completion docs.
local FLOAT_MAX = { width = 80, height = 20 }

local did_setup = false

---Completion capabilities of cmp-nvim-lsp when it is installed.
---@return table
function M.capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
  if ok then
    capabilities =
      vim.tbl_deep_extend("force", capabilities, cmp_lsp.default_capabilities())
  end
  return capabilities
end

---`root_dir` that admits only eligible buffers and otherwise keeps the
---server definition's own root rules.
---@param base vim.lsp.Config Resolved definition before Iara's changes.
---@return fun(bufnr: integer, on_dir: fun(root: string?))
function M.gated_root_dir(base)
  local original, markers = base.root_dir, base.root_markers
  return function(bufnr, on_dir)
    if not eligibility.is_eligible(bufnr) then
      return
    end
    if type(original) == "function" then
      return original(bufnr, on_dir)
    end
    if type(original) == "string" then
      return on_dir(original)
    end
    on_dir(markers and vim.fs.root(bufnr, markers) or nil)
  end
end

---Configure and enable a server for eligible buffers.
---@param name string Server name, for example "lua_ls".
---@param overrides vim.lsp.Config Merged over the definition (`cmd`, ...).
function M.enable(name, overrides)
  M.setup()
  local base = vim.lsp.config[name] or {}
  local config = vim.tbl_extend("force", overrides, {
    capabilities = M.capabilities(),
    root_dir = M.gated_root_dir(base),
  })
  vim.lsp.config(name, config)
  owned[name] = true
  vim.lsp.enable(name)
end

---Tell the user once, when a buffer of `filetypes` opens, that a server
---is unavailable.
---@param name string
---@param filetypes string[]
---@param err IaraError
function M.report_unavailable(name, filetypes, err)
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("IaraLspMissing_" .. name, {}),
    pattern = filetypes,
    once = true,
    callback = function()
      local text = "Iara: %s disabled: %s"
      vim.notify(text:format(name, err.message), vim.log.levels.WARN)
    end,
  })
end

---Owned clients attached to `bufnr`.
local function owned_clients(bufnr)
  return vim.tbl_filter(function(client)
    return owned[client.name] == true
  end, vim.lsp.get_clients({ bufnr = bufnr }))
end

local function on_attach(args)
  local client = vim.lsp.get_client_by_id(args.data.client_id)
  if not client or not owned[client.name] then
    return
  end
  for _, map in ipairs(ATTACH_KEYMAPS) do
    local opts = { buffer = args.buf, desc = map[3] }
    vim.keymap.set(map[4] or "n", map[1], map[2], opts)
  end
end

local function on_detach(args)
  local client = vim.lsp.get_client_by_id(args.data.client_id)
  if not client or not owned[client.name] then
    return
  end
  local others = vim.tbl_filter(function(other)
    return other.id ~= client.id
  end, owned_clients(args.buf))
  if #others > 0 then
    return
  end
  for _, map in ipairs(ATTACH_KEYMAPS) do
    pcall(vim.keymap.del, map[4] or "n", map[1], { buffer = args.buf })
  end
end

---Float title chunks (design 09, 3.8): `text` as the idle title of the
---float language (`iara.core.float.title`), one dash after the corner.
---@param text string
---@return table[] chunks For `title` with `title_pos = "left"`.
function M.float_title(text)
  return require("iara.core.float").title(text)
end

---Hover title text: the LSP glyph and the names of the buffer's clients
---that answer hover, or nil when none does.
---@param bufnr integer
---@return string|nil
function M.hover_title(bufnr)
  local clients = vim.lsp.get_clients({
    bufnr = bufnr,
    method = "textDocument/hover",
  })
  local names = vim.tbl_map(function(client)
    return client.name
  end, clients)
  if #names == 0 then
    return nil
  end
  table.sort(names)
  local glyph = require("iara.core.icons").LSP
  return glyph .. " " .. table.concat(names, " \u{b7} ")
end

---`vim.lsp.buf.hover` in a titled float (`K` on attach).
function M.hover()
  local text = M.hover_title(vim.api.nvim_get_current_buf())
  vim.lsp.buf.hover({
    title = text and M.float_title(text),
    title_pos = text and "left" or nil,
    max_width = FLOAT_MAX.width,
    max_height = FLOAT_MAX.height,
  })
end

---Signature help in a float titled "Signature" (`<C-s>` in Insert and
---Select modes on attach), through `iara.core.signature`: with several
---signatures the title shows the active one's index ("Signature 1/2")
---and the bottom border the `C-s next` hint. The active parameter is
---`LspSignatureActiveParameter`.
function M.signature_help()
  require("iara.core.signature").open()
end

---Detach from buffers that left the eligible state; re-run native
---activation for buffers that entered it.
local function on_eligibility(args)
  local bufnr = args.data.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Events arrive after later changes; act on the current state.
  if not eligibility.is_eligible(bufnr) then
    for _, client in ipairs(owned_clients(bufnr)) do
      vim.lsp.buf_detach_client(bufnr, client.id)
    end
    return
  end
  if #owned_clients(bufnr) == 0 and next(owned) then
    -- Neovim's own activation group: keeps server root rules and avoids a
    -- second, competing start path.
    pcall(vim.api.nvim_exec_autocmds, "FileType", {
      group = "nvim.lsp.enable",
      buffer = bufnr,
      modeline = false,
    })
  end
end

---Severity icons of `iara.core.icons`, keyed by severity number.
local function sign_text()
  local icons = require("iara.core.icons").DIAGNOSTICS
  local text = {}
  for name, glyph in pairs(icons) do
    text[vim.diagnostic.severity[name]] = glyph
  end
  return text
end

---Severity groups of the float and the virtual text, by severity number.
local SEVERITY_GROUPS = {
  "DiagnosticError",
  "DiagnosticWarn",
  "DiagnosticInfo",
  "DiagnosticHint",
}

---Float prefix: the severity glyph in its color.
---@param diagnostic vim.Diagnostic
---@return string text, string group
function M.float_prefix(diagnostic)
  local glyph = sign_text()[diagnostic.severity] or ""
  return glyph .. " ", SEVERITY_GROUPS[diagnostic.severity] or "NormalFloat"
end

---Distinct sources of the diagnostics of `bufnr`, counted up to two.
local function several_sources(bufnr)
  local first
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    local source = diagnostic.source
    if source and first and source ~= first then
      return true
    end
    first = first or source
  end
  return false
end

---Float suffix: the code, and the source when the buffer has several,
---in the muted role after the message (a float line takes one
---highlight per part, so they cannot have a line of their own).
---@param diagnostic vim.Diagnostic
---@return string text, string group
function M.float_suffix(diagnostic)
  local parts = {}
  if diagnostic.code then
    table.insert(parts, tostring(diagnostic.code))
  end
  local bufnr = diagnostic.bufnr
  if diagnostic.source and bufnr and several_sources(bufnr) then
    table.insert(parts, diagnostic.source)
  end
  if #parts == 0 then
    return "", "NormalFloat"
  end
  return "  " .. table.concat(parts, " · "), "IaraMuted"
end

---Options of `vim.diagnostic.config` (design 09, sections 3.2 and 3.8):
---signs and error line numbers on every line, virtual text on the
---cursor's line only, and a titled float with glyphs and details.
---@return vim.diagnostic.Opts
function M.diagnostic_options()
  local ui = require("iara.core.ui")
  local text = sign_text()
  return {
    underline = true,
    signs = {
      text = text,
      numhl = { [vim.diagnostic.severity.ERROR] = "DiagnosticError" },
    },
    virtual_text = {
      current_line = true,
      spacing = 2,
      prefix = function(diagnostic)
        return text[diagnostic.severity] .. " "
      end,
    },
    float = {
      border = ui.BORDER,
      -- The same idle title as the hover and signature floats (V9).
      title = M.float_title("Diagnostics"),
      title_pos = "left",
      header = "",
      source = false,
      prefix = M.float_prefix,
      suffix = M.float_suffix,
    },
    virtual_lines = false,
    update_in_insert = false,
    severity_sort = true,
  }
end

---Diagnostics presentation, native defaults, and attach handlers, once.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  vim.diagnostic.config(M.diagnostic_options())
  vim.lsp.semantic_tokens.enable(false)
  vim.lsp.document_color.enable(false)
  vim.lsp.inlay_hint.enable(false)
  local group = vim.api.nvim_create_augroup("IaraLsp", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = on_attach,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = on_detach,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = on_eligibility,
  })
end

return M
