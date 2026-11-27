--- Tree-sitter highlighting gated by buffer eligibility.
---
--- Parsers come from two pinned sources, never from a startup install:
--- Neovim bundles lua, vim, query, markdown, and markdown_inline (pinned by
--- the Neovim build); the others (json, yaml) are built at the commits of
--- `parsers-lock.txt`, by the bootstrap into stdpath("data")/treesitter
--- for an installation and by `scripts/parsers.sh` into
--- `iara/.tools/treesitter` for development. Additional parsers are
--- installed explicitly through nvim-treesitter. A missing parser or
--- query keeps regex syntax.
---
--- Neovim's own lua, markdown, query, and help ftplugins start
--- highlighting unconditionally; the FileType handler here runs after them
--- and stops it again for any buffer that is not eligible (conservative or
--- still unknown), before the first redraw parses anything.
local M = {}

---Languages Iara highlights with Tree-sitter, by filetype.
M.FILETYPES = {
  bash = "bash",
  c = "c",
  cpp = "cpp",
  go = "go",
  hcl = "hcl",
  java = "java",
  javascript = "javascript",
  javascriptreact = "javascript",
  lua = "lua",
  json = "json",
  yaml = "yaml",
  vim = "vim",
  query = "query",
  markdown = "markdown",
  rust = "rust",
  sh = "bash",
  terraform = "terraform",
  typescript = "typescript",
  typescriptreact = "tsx",
}

local did_setup = false

---Keep the pinned parser directories on 'runtimepath'. lazy.nvim resets
---'runtimepath' after this module's setup, so this runs again on use.
local function ensure_runtime()
  local present = {}
  for _, entry in ipairs(vim.opt.runtimepath:get()) do
    present[entry] = true
  end
  local dirs = require("iara.core.parsers").runtime_dirs()
  for index = #dirs, 1, -1 do
    local dir = dirs[index]
    if not present[dir] and vim.fn.isdirectory(dir) == 1 then
      vim.opt.runtimepath:prepend(dir)
    end
  end
end

local function language(filetype)
  local known = M.FILETYPES[filetype]
  if known then
    return known
  end
  local lang = vim.treesitter.language.get_lang(filetype)
  if lang and lang:match("^[%w_]+$") then
    local parsers = require("iara.core.parsers")
    local path = parsers.parser_path(parsers.extra_runtime(), lang)
    return vim.uv.fs_stat(path) and lang or nil
  end
end

local function eligible(bufnr)
  local ok, eligibility = pcall(require, "iara.core.eligibility")
  return ok and eligibility.is_eligible(bufnr)
end

---@param bufnr integer
---@return boolean
function M.is_active(bufnr)
  return vim.treesitter.highlighter.active[bufnr] ~= nil
end

---Start or stop highlighting for `bufnr` according to its eligibility.
---Reasons: "ineligible", "unmanaged" (filetype not in FILETYPES),
---"no_parser", "start_failed" (for example a missing query).
---@param bufnr integer
---@return boolean active
---@return string|nil reason Why highlighting is off.
function M.update(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid"
  end
  if not eligible(bufnr) then
    vim.treesitter.stop(bufnr)
    return false, "ineligible"
  end
  local lang = language(vim.bo[bufnr].filetype)
  if not lang then
    return M.is_active(bufnr), "unmanaged"
  end
  if M.is_active(bufnr) then
    return true
  end
  ensure_runtime()
  if not vim.treesitter.language.add(lang) then
    return false, "no_parser"
  end
  if not pcall(vim.treesitter.start, bufnr, lang) then
    return false, "start_failed"
  end
  return true
end

---Put the pinned parser directories on 'runtimepath' and gate
---highlighting.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  ensure_runtime()
  for filetype, lang in pairs(M.FILETYPES) do
    if lang ~= filetype then
      vim.treesitter.language.register(lang, filetype)
    end
  end
  local group = vim.api.nvim_create_augroup("IaraTreesitter", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      M.update(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = function(args)
      M.update(args.data.bufnr)
    end,
  })
end

return M
