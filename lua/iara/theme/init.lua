--- Themes: Iara-owned palettes applied as `:colorscheme iara-<name>`.
---
--- Startup theme precedence: `ui.theme` set explicitly by the personal
--- configuration (or a trusted project policy), then the theme last
--- chosen with `:IaraTheme` (stored in stdpath("state")/iara/theme), then
--- the default `ui.theme` ("chocolate"). An unknown name falls back to
--- chocolate with a warning. Runs as a safe step, so safe mode is
--- colored too. See contracts.md, section 13.
local M = {}

M.DEFAULT = "chocolate"

---Shipped palettes, one module each under `iara.theme.palettes`.
M.THEMES = {
  "catppuccin",
  "chocolate",
  "everforest",
  "github_dark",
  "github_light",
  "gruvbox",
  "gruvbox_light",
  "kanagawa",
  "nord",
  "onedark",
  "rosepine",
  "tokyonight",
}

M.PREFIX = "iara-"

local known = {}
for _, name in ipairs(M.THEMES) do
  known[name] = true
end

---@type string|nil
local current = nil
local did_setup = false
local terminal_background = false

local function notify(message, level)
  vim.notify("Iara: " .. message, level or vim.log.levels.WARN)
end

---@param name any
---@return boolean
function M.is_theme(name)
  return type(name) == "string" and known[name] == true
end

---Palette of a shipped theme.
---@param name string
---@return IaraPalette
function M.palette(name)
  if not M.is_theme(name) then
    error("unknown theme " .. vim.inspect(name), 2)
  end
  return require("iara.theme.palettes." .. name)
end

---Apply a palette directly; used by the `colors/iara-<name>.lua` files.
---Prefer `apply`, which goes through `:colorscheme`.
---@param name string Shipped theme name.
function M.load(name)
  local palette = M.palette(name)
  -- Without a loaded colorscheme the groups are still Neovim's defaults
  -- (startup), and `hi clear` would only cost time. It also unsets
  -- g:colors_name, so changing 'background' below does not reload the
  -- previous colorscheme.
  if vim.g.colors_name ~= nil then
    vim.cmd.highlight("clear")
  end
  if vim.o.background ~= palette.type then
    vim.o.background = palette.type
  end
  local highlights = require("iara.theme.highlights")
  local problems = highlights.apply(palette, terminal_background)
  vim.g.colors_name = M.PREFIX .. name
  current = name
  if #problems > 0 then
    notify(("theme %s: %s"):format(name, table.concat(problems, "; ")))
  end
end

local function known_or_default(name)
  if M.is_theme(name) then
    return name
  end
  notify(("unknown theme %s; using %s"):format(vim.inspect(name), M.DEFAULT))
  return M.DEFAULT
end

---Apply `name` through `:colorscheme`, so ColorScheme listeners run. An
---unknown name warns and applies the default theme.
---@param name string
---@return string applied The theme actually applied.
function M.apply(name)
  name = known_or_default(name)
  vim.cmd.colorscheme(M.PREFIX .. name)
  return name
end

---The Iara theme applied last, or nil when another colorscheme replaced
---it or none was applied.
---@return string|nil
function M.current()
  if vim.g.colors_name ~= (current and M.PREFIX .. current) then
    return nil
  end
  return current
end

---@return string path File holding the last theme chosen by the user.
function M.state_path()
  return vim.fn.stdpath("state") .. "/iara/theme"
end

---Theme stored by the last `:IaraTheme` choice, if readable.
---@return string|nil
function M.persisted()
  local file = io.open(M.state_path(), "r")
  if not file then
    return nil
  end
  local name = file:read("*l")
  file:close()
  return name and vim.trim(name) or nil
end

---Store `name` as the user's choice for later startups.
---@param name string
---@return boolean ok
---@return string|nil err
function M.persist(name)
  local path = M.state_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file, err = io.open(path, "w")
  if not file then
    return false, err
  end
  file:write(name, "\n")
  file:close()
  return true
end

---Apply a shipped theme and remember it. Unknown names change nothing.
---@param name string
---@return boolean ok
function M.set(name)
  if not M.is_theme(name) then
    notify(("unknown theme %s"):format(vim.inspect(name)))
    return false
  end
  M.apply(name)
  local ok, err = M.persist(name)
  if not ok then
    notify("cannot store the theme: " .. tostring(err))
  end
  return true
end

---Startup theme by precedence (see the module header).
---@param configured any `config.ui.theme`.
---@param explicit boolean Whether a configuration layer set it.
---@param persisted string|nil
---@return any name Validated later by `apply`.
function M.choose(configured, explicit, persisted)
  if explicit then
    return configured
  end
  return persisted or configured or M.DEFAULT
end

---Open the theme picker with live preview (`iara.theme.picker`).
function M.pick()
  require("iara.theme.picker").open()
end

local function complete(lead)
  return vim.tbl_filter(function(name)
    return vim.startswith(name, lead)
  end, M.THEMES)
end

local function define_command()
  vim.api.nvim_create_user_command("IaraTheme", function(args)
    if args.args == "" then
      M.pick()
    else
      M.set(args.args)
    end
  end, {
    nargs = "?",
    complete = complete,
    desc = "Choose the Iara theme",
  })
end

local function toggle_background()
  local name = M.current()
  if not name then
    notify("Choose an Iara theme to toggle the terminal background")
    return
  end
  terminal_background = not terminal_background
  M.apply(name)
  local source = terminal_background and "Terminal" or "Theme"
  notify(source .. " background active", vim.log.levels.INFO)
end

-- Iara-owned groups under a foreign colorscheme, which knows nothing of
-- them: neutral links, kept only where the colorscheme defines nothing.
local FALLBACK_LINKS = {
  IaraBreadcrumb = "Comment",
  IaraBreadcrumbSeparator = "Delimiter",
  IaraTabFill = "TabLineFill",
  IaraTabActive = "TabLineSel",
  IaraTabInactive = "TabLine",
  IaraTabModified = "TabLineSel",
  IaraTabModifiedInactive = "TabLine",
  IaraTabNumber = "TabLineSel",
  IaraStartText = "Comment",
  IaraStartIcon = "Special",
  IaraStartAction = "Normal",
  IaraStartKey = "Keyword",
  IaraStartFooter = "Comment",
}
-- Status line parts read as plain status line text; blocks stand out.
for _, name in ipairs({
  "Warn",
  "Conflict",
  "Root",
  "Running",
  "Exited",
  "File",
  "Modified",
  "Muted",
  "GitAdded",
  "GitChanged",
  "GitRemoved",
  "DiagError",
  "DiagWarn",
  "DiagInfo",
  "DiagHint",
  "Lsp",
  "Position",
}) do
  FALLBACK_LINKS["IaraStatus" .. name] = "StatusLine"
end
for _, name in ipairs({
  "Safe",
  "Terminal",
  "Agent",
  "RootIcon",
  "PositionIcon",
  "ModeNormal",
  "ModeInsert",
  "ModeVisual",
  "ModeReplace",
  "ModeCommand",
  "ModeSelect",
  "ModeTerminal",
  "ModeConfirm",
}) do
  FALLBACK_LINKS["IaraStatus" .. name] = "TabLineSel"
end
FALLBACK_LINKS.IaraStatusMark = "StatusLine"
-- Groups added by V4 (tab bar, winbar), V6 (start screen), AI1 (Ask
-- AI popup), and MD1 (Markdown states): requested by each task (V12).
for name, target in pairs({
  IaraTabActiveBar = "TabLineSel",
  IaraWinbarBar = "WinBar",
  IaraWinbarName = "WinBar",
  IaraWinbarModified = "WinBar",
  IaraWinbarIcon = "WinBarNC",
  IaraWinbarPath = "WinBarNC",
  IaraWinbarInactive = "WinBarNC",
  IaraStartWaveTide = "Special",
  IaraStartWaveMid = "Special",
  IaraStartWaveFoam = "Title",
  IaraStartMark = "Special",
  IaraStartBar = "Special",
  IaraStartCursor = "CursorLine",
  IaraStartSection = "Comment",
  IaraStartRule = "NonText",
  IaraStartFileIcon = "Comment",
  IaraStartFile = "Normal",
  IaraAskMeta = "Comment",
  IaraAskSpinner = "DiagnosticInfo",
  IaraAskError = "DiagnosticError",
  IaraAskQuestion = "Special",
  IaraAskPrompt = "Special",
  IaraMarkdownCodeLanguage = "Comment",
  IaraMarkdownStruck = "Comment",
  IaraMarkdownProgress = "DiagnosticInfo",
  IaraMarkdownCancelled = "NonText",
  IaraMarkdownForwarded = "Comment",
  IaraMarkdownImportant = "DiagnosticWarn",
  IaraMarkdownQuestion = "DiagnosticInfo",
}) do
  FALLBACK_LINKS[name] = target
end
-- Role groups (V1) link to the closest standard group.
for name, target in pairs(require("iara.theme.roles").FALLBACK_LINKS) do
  FALLBACK_LINKS[name] = target
end

---Iara-owned groups and their neutral links under a foreign colorscheme.
M.FALLBACK_LINKS = FALLBACK_LINKS

local function link_fallbacks()
  if M.current() then
    return
  end
  for name, target in pairs(FALLBACK_LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

---Apply the startup theme and define the theme commands once.
---@param config table Composed configuration.
function M.setup(config)
  if did_setup then
    return
  end
  did_setup = true
  local ui = type(config) == "table" and config.ui or nil
  local configured = type(ui) == "table" and ui.theme or nil
  terminal_background = type(ui) ~= "table" or ui.terminal_background ~= false
  local explicit = require("iara.config").is_explicit("ui.theme")
  -- Loaded directly: `:colorscheme` would search 'packpath' (several ms)
  -- and nothing listens to ColorScheme this early.
  M.load(known_or_default(M.choose(configured, explicit, M.persisted())))
  define_command()
  vim.api.nvim_create_user_command("IaraToggleBackground", toggle_background, {
    desc = "Toggle the default terminal background",
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("IaraTheme", { clear = true }),
    callback = link_fallbacks,
  })
end

return M
