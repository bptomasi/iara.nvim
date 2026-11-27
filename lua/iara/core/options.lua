--- Leaders, native editor options, the statusline, and the Tree-sitter
--- eligibility gate.
---
--- Runs first in every mode (safe included), so it must not need plugins.
--- Defaults follow the previous NvChad workflow; `config.options` (option
--- name -> value) is applied afterwards and wins. An invalid entry is
--- reported once and skipped; the remaining options still apply.
--- See contracts.md, sections 2 and 13.
local M = {}

M.LEADER = " "
M.LOCAL_LEADER = "\\"
M.MATCHPAREN_TIMEOUT_MS = 20

---Default option values, applied through `vim.opt`.
M.DEFAULTS = {
  laststatus = 3,
  -- Tab labels name terminals cleanly, never by `term://` (UX2); with
  -- one tab page the tab line lists the open files (UX3).
  tabline = "%!v:lua.require'iara.core.statusline'.tabline()",
  showmode = false,
  splitkeep = "screen",
  clipboard = "unnamedplus",
  cursorline = true,
  cursorlineopt = "number",
  expandtab = true,
  shiftwidth = 2,
  tabstop = 2,
  softtabstop = 2,
  smartindent = true,
  -- Window chrome (UX3): no `~` past the end, thin separators, quiet
  -- diff filler, straight thin borders (V13) on every float that does
  -- not choose its own (LSP hover and signature, diagnostics; `iara.core.ui`).
  fillchars = {
    eob = " ",
    diff = "\u{2571}",
    fold = " ",
    foldsep = " ",
    foldopen = "\u{f0d7}",
    foldclose = "\u{f0da}",
  },
  winborder = require("iara.core.ui").BORDER,
  -- The native popup menu (insert and `:` completion) takes the float
  -- shape too, capped in width so long items do not span the screen
  -- (V3, design 2.4).
  pumborder = require("iara.core.ui").BORDER,
  pumheight = 12,
  pummaxwidth = 60,
  ignorecase = true,
  smartcase = true,
  mouse = "a",
  number = true,
  numberwidth = 2,
  ruler = false,
  signcolumn = "yes",
  splitbelow = true,
  splitright = true,
  timeoutlen = 400,
  undofile = true,
  -- Also the CursorHold delay that Gitsigns and LSP highlights rely on.
  updatetime = 250,
}

-- Remote plugin providers cost a startup probe and nothing here uses them.
local DISABLED_PROVIDERS = { "node", "perl", "python3", "ruby" }

local did_setup = false

local function report(message)
  vim.notify("Iara: " .. message, vim.log.levels.ERROR)
end

---Set one option; returns an error message instead of raising.
---@param name string
---@param value any
---@return string|nil problem
local function set_option(name, value)
  if type(name) ~= "string" then
    return "option names must be strings, got " .. vim.inspect(name)
  end
  local ok, problem = pcall(function()
    vim.opt[name] = value
  end)
  if not ok then
    return ("invalid option %s = %s: %s"):format(
      name,
      vim.inspect(value),
      (tostring(problem):gsub("^.-:%d+: ", ""))
    )
  end
end

---Apply a map of option values in name order, reporting each failure.
---@param values table<string, any>
---@return string[] problems
function M.apply(values)
  local names = vim.tbl_keys(values)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local problems = {}
  for _, name in ipairs(names) do
    local problem = set_option(name, values[name])
    if problem then
      table.insert(problems, problem)
    end
  end
  return problems
end

local function apply_list_defaults()
  -- No intro screen (the start screen replaces it), fewer completion
  -- messages.
  vim.opt.shortmess:append("sIc")
  -- h, l, and arrows wrap to the previous or next line.
  vim.opt.whichwrap:append("<>[]hl")
end

---Apply leaders, defaults, `config.options`, and the statusline once.
---@param config table Composed configuration.
function M.setup(config)
  if did_setup then
    return
  end
  did_setup = true
  -- Leaders come first: every later mapping reads them when defined.
  vim.g.mapleader = M.LEADER
  vim.g.maplocalleader = M.LOCAL_LEADER
  for _, provider in ipairs(DISABLED_PROVIDERS) do
    vim.g["loaded_" .. provider .. "_provider"] = 0
  end
  -- Built-in matchparen scans long lines for up to 300 ms per cursor move
  -- (measured about 265 ms on minified JSON); bound it to keep moving fast.
  vim.g.matchparen_timeout = M.MATCHPAREN_TIMEOUT_MS
  vim.g.matchparen_insert_timeout = M.MATCHPAREN_TIMEOUT_MS
  M.apply(M.DEFAULTS)
  apply_list_defaults()
  local user = type(config) == "table" and config.options or {}
  if type(user) ~= "table" then
    report("options must be a table of option values")
    user = {}
  end
  for _, problem in ipairs(M.apply(user)) do
    report(problem)
  end
  require("iara.core.float").setup()
  require("iara.core.statusline").setup()
  require("iara.core.tabline").setup(user.showtabline == nil)
  -- Native indent guides, unless the user chose 'list' themselves.
  require("iara.core.guides").setup(user.list == nil and user.listchars == nil)
  -- Native ftplugins start Tree-sitter without plugins, so its
  -- eligibility gate belongs to the safe steps as well.
  require("iara.core.treesitter").setup()
end

return M
