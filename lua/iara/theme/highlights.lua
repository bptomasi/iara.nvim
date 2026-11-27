--- Theme engine: turns a palette into highlight groups and terminal
--- colors. Pure data in, one pass of `nvim_set_hl` out; no plugin needed.
--- Group colors name palette slots or semantic roles (`iara.theme.roles`,
--- V1), whose contrast `readable` enforces by rule.
local M = {}

---@class IaraPalette
---@field type "dark"|"light"
---@field base_30 table<string, string> Named UI colors ("#rrggbb").
---@field base_16 table<string, string> base00..base0F ("#rrggbb").
---@field polish table<string, table>|nil Per-theme group overrides with
---  literal colors.
---@field identity IaraIdentity|nil Signature colors (`iara.theme.roles`).

-- Window and panel surfaces, including their ordinary text and frame
-- cells. Selection, diagnostics, and badges keep their own fills.
local TERMINAL_BACKGROUND_GROUPS = {
  Normal = true,
  NormalFloat = true,
  FloatBorder = true,
  FloatTitle = true,
  FloatFooter = true,
  IaraFloatBorderFocus = true,
  IaraFloatTitleFocus = true,
  IaraFloatFooterKey = true,
  IaraMantle = true,
  IaraBorder = true,
  IaraBorderFocus = true,
  WinSeparator = true,
  TabLine = true,
  TabLineFill = true,
  TabLineSel = true,
  WinBar = true,
  WinBarNC = true,
  IaraTabActive = true,
  IaraTabActiveBar = true,
  IaraTabFill = true,
  IaraTabInactive = true,
  IaraTabModified = true,
  IaraTabModifiedInactive = true,
  IaraWinbarBar = true,
  IaraWinbarIcon = true,
  IaraWinbarInactive = true,
  IaraWinbarModified = true,
  IaraWinbarName = true,
  IaraWinbarPath = true,
  IaraPanel = true,
  IaraPanelHeader = true,
  IaraPanelBarShell = true,
  IaraPanelBarAgent = true,
  IaraPanelBarFocus = true,
  IaraPanelTitle = true,
  IaraPanelCwd = true,
  IaraPanelRunning = true,
  IaraPanelStopping = true,
  IaraPanelExited = true,
  IaraPanelDone = true,
  IaraPanelKey = true,
  IaraPanelHint = true,
  NvimTreeNormal = true,
  NvimTreeNormalNC = true,
  NvimTreeEndOfBuffer = true,
  NvimTreeWinSeparator = true,
  IaraTreeBranch = true,
  IaraSearchTitle = true,
  IaraSearchCrumb = true,
  IaraSearchBorder = true,
  IaraSearchBorderFocus = true,
  IaraSearchCrumbSeparator = true,
  IaraSearchChip = true,
  IaraSearchSelectionGap = true,
  IaraSearchFooter = true,
  IaraSearchFooterKey = true,
  IaraAskMeta = true,
  IaraAskSpinner = true,
  IaraAskError = true,
  IaraAskPrompt = true,
  IaraContextLabel = true,
  IaraContextValue = true,
  IaraContextRule = true,
  Pmenu = true,
  PmenuKind = true,
  PmenuExtra = true,
  PmenuSbar = true,
  PmenuMatch = true,
  CmpPmenu = true,
  CmpDoc = true,
}

-- base_16 slot of terminal_color_0 .. terminal_color_15.
M.TERMINAL = {
  "base01",
  "base08",
  "base0B",
  "base0A",
  "base0D",
  "base0E",
  "base0C",
  "base05",
  "base03",
  "base08",
  "base0B",
  "base0A",
  "base0D",
  "base0E",
  "base0C",
  "base07",
}

local COLOR_KEYS = { "fg", "bg", "sp" }

local function channels(hex)
  return tonumber(hex:sub(2, 3), 16),
    tonumber(hex:sub(4, 5), 16),
    tonumber(hex:sub(6, 7), 16)
end

---`top` laid over `bottom` with `percent` opacity, as "#rrggbb".
---@param top string
---@param bottom string
---@param percent number 0..100
---@return string
function M.blend(top, bottom, percent)
  local share = percent / 100
  local r1, g1, b1 = channels(top)
  local r2, g2, b2 = channels(bottom)
  local function mix(a, b)
    return math.floor(a * share + b * (1 - share) + 0.5)
  end
  return ("#%02x%02x%02x"):format(mix(r1, r2), mix(g1, g2), mix(b1, b2))
end

---WCAG 2 relative luminance of a "#rrggbb" color, 0 (black) to 1.
---@param hex string
---@return number
function M.luminance(hex)
  local function linear(value)
    local share = value / 255
    if share <= 0.03928 then
      return share / 12.92
    end
    return ((share + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = channels(hex)
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
end

---WCAG 2 contrast ratio of two "#rrggbb" colors, 1 to 21.
---@param a string
---@param b string
---@return number
function M.contrast(a, b)
  local high, low = M.luminance(a), M.luminance(b)
  if high < low then
    high, low = low, high
  end
  return (high + 0.05) / (low + 0.05)
end

---Lowest contrast of `color` against any of `surfaces`.
local function worst(color, surfaces)
  local lowest = math.huge
  for _, surface in ipairs(surfaces) do
    lowest = math.min(lowest, M.contrast(color, surface))
  end
  return lowest
end

---Black or white, whichever stands out more on every surface.
local function extreme(surfaces)
  local black, white = "#000000", "#ffffff"
  return worst(white, surfaces) >= worst(black, surfaces) and white or black
end

---`color` moved toward `target` in 5% steps until its contrast on every
---surface reaches `ratio`; `color` itself when it already does. A target
---that cannot reach the ratio is replaced by black or white, so the
---result always comes as close as the surfaces allow. Deterministic.
---@param color string "#rrggbb"
---@param bg string|string[] Surface or surfaces it is drawn on.
---@param ratio number Minimum contrast, such as 4.5 or 3.
---@param target string|nil Preferred direction (default black or white).
---@return string
function M.readable(color, bg, ratio, target)
  local surfaces = type(bg) == "table" and bg or { bg }
  if not target or worst(target, surfaces) < ratio then
    target = extreme(surfaces)
  end
  for step = 0, 20 do
    local candidate = M.blend(target, color, step * 5)
    if worst(candidate, surfaces) >= ratio then
      return candidate
    end
  end
  return target
end

---Hex value of a slot name, a role ("@accent", see `iara.theme.roles`),
---or a literal ("#rrggbb", "NONE").
local function slot(source, name)
  if name == "NONE" or name:sub(1, 1) == "#" then
    return name
  end
  if name:sub(1, 1) == "@" then
    return source.roles[name:sub(2)]
  end
  local palette = source.palette
  return palette.base_30[name] or palette.base_16[name]
end

---Hex value of a color: a slot or role name, a literal, or
---`{ top, bottom, percent }`, two of them blended (see `blend`).
local function color(source, value)
  if type(value) ~= "table" then
    return slot(source, value)
  end
  local top, bottom = slot(source, value[1]), slot(source, value[2])
  if not top or not bottom or type(value[3]) ~= "number" then
    return nil
  end
  return M.blend(top, bottom, value[3])
end

---@return table|nil spec, string|nil problem
local function resolve_spec(source, spec)
  local resolved = {}
  for key, value in pairs(spec) do
    resolved[key] = value
  end
  for _, key in ipairs(COLOR_KEYS) do
    if spec[key] ~= nil then
      resolved[key] = color(source, spec[key])
      if not resolved[key] then
        local shown = vim.inspect(spec[key], { newline = " ", indent = "" })
        return nil, ("unknown color %s = %s"):format(key, shown)
      end
    end
  end
  return resolved
end

local function resolve_into(groups, problems, source, specs)
  for name, spec in pairs(specs) do
    local resolved, problem = resolve_spec(source, spec)
    if resolved then
      groups[name] = resolved
    else
      table.insert(problems, name .. ": " .. problem)
    end
  end
end

---Resolve every group of `iara.theme.groups` against the palette and its
---roles, then the palette's polish. A group whose color slot or role is
---missing is left out and reported.
---@param palette IaraPalette
---@return table<string, table> groups Specs for nvim_set_hl.
---@return string[] problems
---@return table<string, string> roles The palette's roles, resolved once.
function M.resolve(palette)
  local groups, problems = {}, {}
  local source = {
    palette = palette,
    roles = require("iara.theme.roles").resolve(palette),
  }
  resolve_into(groups, problems, source, require("iara.theme.groups"))
  resolve_into(groups, problems, source, palette.polish or {})
  table.sort(problems)
  return groups, problems, source.roles
end

---Set every group and terminal color of `palette` in the global
---namespace. Callers clear previous highlights first.
---@param palette IaraPalette
---@param terminal_background boolean? Use the terminal default background.
---@return string[] problems Groups that could not be resolved.
function M.apply(palette, terminal_background)
  local groups, problems, roles = M.resolve(palette)
  local set_hl = vim.api.nvim_set_hl
  for name, spec in pairs(groups) do
    if terminal_background and TERMINAL_BACKGROUND_GROUPS[name] then
      spec.bg = "NONE"
    end
    set_hl(0, name, spec)
  end
  for index, slot in ipairs(M.TERMINAL) do
    vim.g["terminal_color_" .. (index - 1)] = palette.base_16[slot]
  end
  -- Keep ANSI black as a palette color for programs that request it.
  vim.g.terminal_color_0 = roles.mantle
  return problems
end

return M
