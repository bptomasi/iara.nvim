-- Semantic color roles (task V1): every role in every palette, the
-- contrast rules of design 09 section 2.2, the readable engine, mode
-- colors, the identity defaults, the split group modules, and the role
-- groups under Iara and foreign colorschemes.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local theme = require("iara.theme")
local roles = require("iara.theme.roles")
local hl = require("iara.theme.highlights")

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

---Every shipped palette with its resolved roles.
local function each_palette(check)
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    check(name, palette, roles.resolve(palette))
  end
end

---Lowest contrast of `color` on any of `surfaces`.
local function worst(color, surfaces)
  local lowest = math.huge
  for _, surface in ipairs(surfaces) do
    lowest = math.min(lowest, hl.contrast(color, surface))
  end
  return lowest
end

---Collect "<palette> <what> <ratio>" for every pair below `ratio`.
local function below(failures, label, color, surfaces, ratio)
  local value = worst(color, surfaces)
  if value < ratio then
    table.insert(failures, ("%s %.2f < %.1f"):format(label, value, ratio))
  end
end

-- Roles -------------------------------------------------------------------

T["every role resolves to a color in every palette"] = function()
  eq(#theme.THEMES, 12)
  local missing = {}
  each_palette(function(name, _, resolved)
    for _, role in ipairs(roles.names()) do
      local value = resolved[role]
      if type(value) ~= "string" or not value:match("^#%x%x%x%x%x%x$") then
        table.insert(missing, name .. " " .. role)
      end
    end
  end)
  eq(missing, {})
end

T["text roles meet 4.5:1 and glyph roles 3:1 on base and mantle"] = function()
  local failures = {}
  each_palette(function(name, _, r)
    for role, ratio in pairs(roles.READABLE) do
      local label = name .. " " .. role
      below(failures, label, r[role], { r.base, r.mantle }, ratio)
    end
    below(failures, name .. " muted", r.muted, { r.base, r.mantle }, 4.5)
    -- Selected rows and the cursor line carry muted text and numbers.
    local rows = { r.base, r.mantle, r.cursorline, r.overlay }
    below(failures, name .. " subtle", r.subtle, rows, 3)
    below(failures, name .. " muted on rows", r.muted, rows, 4.5)
    below(failures, name .. " border_focus", r.border_focus, { r.mantle }, 3)
  end)
  eq(failures, {})
end

T["text on fills and states on their tints stay readable"] = function()
  local failures = {}
  each_palette(function(name, _, r)
    below(failures, name .. " on_accent", r.on_accent, { r.accent }, 4.5)
    for _, mode in ipairs(roles.MODES) do
      local fill, text = r["mode_" .. mode[1]], r["on_mode_" .. mode[1]]
      below(failures, name .. " mode " .. mode[1], text, { fill }, 4.5)
    end
    for _, state in ipairs(roles.STATES) do
      local role = state[1]
      local soft = r[role .. "_soft"]
      below(failures, name .. " " .. role, r[role], { soft }, 4.5)
    end
  end)
  eq(failures, {})
end

T["chocolate keeps its copper accent and teal tide exactly"] = function()
  local r = roles.resolve(theme.palette("chocolate"))
  eq({ r.accent, r.tide }, { "#d08b65", "#749689" })
  eq(r.border_focus, "#d08b65")
  eq(r.mode_normal, "#d08b65")
  eq(r.mode_insert, "#749689")
end

T["roles keep a palette's color when it is already readable"] = function()
  each_palette(function(name, palette, r)
    local identity = roles.identity(palette)
    local accent = palette.base_30[identity.accent]
    if worst(accent, { r.base, r.mantle }) >= 4.5 then
      eq({ name, r.accent }, { name, accent })
    end
  end)
end

T["low-contrast slots are fixed by rule in light palettes"] = function()
  local light = theme.palette("gruvbox_light")
  local r = roles.resolve(light)
  -- Orange is 2.7:1 on the light base; the role darkens it until 4.5:1.
  eq(hl.contrast(light.base_30.orange, r.base) < 4.5, true)
  eq(r.accent ~= light.base_30.orange, true)
  eq(worst(r.accent, { r.base, r.mantle }) >= 4.5, true)
  eq(hl.luminance(r.accent) < hl.luminance(light.base_30.orange), true)
end

T["a palette without identity gets the default accent and tide"] = function()
  local chocolate = theme.palette("chocolate")
  local bare = vim.deepcopy(chocolate)
  bare.identity = nil
  local r = roles.resolve(bare)
  eq(roles.identity(bare), { accent = "blue", tide = "teal" })
  eq(r.accent, chocolate.base_30.blue)
  eq(r.tide, chocolate.base_30.teal)
  -- A partial identity keeps its own field and defaults the other.
  bare = vim.deepcopy(chocolate)
  bare.identity = { accent = "red" }
  eq(roles.identity(bare), { accent = "red", tide = "teal" })
end

T["an identity may name a literal color"] = function()
  local palette = vim.deepcopy(theme.palette("chocolate"))
  palette.identity = { accent = "#e0a070", tide = "teal" }
  eq(roles.resolve(palette).accent, "#e0a070")
end

T["roles are computed once per palette"] = function()
  local palette = theme.palette("nord")
  eq(roles.resolve(palette) == roles.resolve(palette), true)
end

T["crust sits one step past mantle, away from base"] = function()
  each_palette(function(name, _, r)
    local base, mantle = hl.luminance(r.base), hl.luminance(r.mantle)
    local crust = hl.luminance(r.crust)
    local away = (mantle <= base) == (crust <= mantle)
    eq({ name, away, r.crust ~= r.mantle }, { name, true, true })
  end)
end

-- Modes -------------------------------------------------------------------

T["the eight mode colors differ in every palette"] = function()
  each_palette(function(name, _, r)
    local seen, clashes = {}, {}
    for _, mode in ipairs(roles.MODES) do
      local color = r["mode_" .. mode[1]]
      if seen[color] then
        table.insert(clashes, mode[1] .. "=" .. seen[color])
      end
      seen[color] = mode[1]
    end
    eq({ name, clashes }, { name, {} })
    eq({ name, r.mode_normal, r.mode_insert }, { name, r.accent, r.tide })
  end)
end

T["a mode that clashes with the identity takes its neighbor"] = function()
  local everforest = theme.palette("everforest")
  local r = roles.resolve(everforest)
  -- Everforest's accent is its green, so Terminal moves on.
  eq(r.mode_terminal, everforest.base_30.vibrant_green)
  -- Confirm's teal is the tide in every palette.
  each_palette(function(name, palette, resolved)
    local teal = palette.base_30.teal
    eq({ name, resolved.mode_confirm ~= teal }, { name, true })
  end)
end

-- Engine ------------------------------------------------------------------

T["contrast follows WCAG 2"] = function()
  eq(hl.contrast("#ffffff", "#000000"), 21)
  eq(hl.contrast("#000000", "#ffffff"), 21)
  eq(hl.contrast("#777777", "#777777"), 1)
  eq(math.floor(hl.contrast("#767676", "#ffffff") * 100) / 100, 4.54)
end

T["readable returns a color that already meets the ratio"] = function()
  eq(hl.readable("#ffffff", "#000000", 4.5), "#ffffff")
  eq(hl.readable("#595959", { "#ffffff", "#fafafa" }, 4.5), "#595959")
end

T["readable moves toward the target in 5% steps"] = function()
  local color, bg, target = "#605040", "#202020", "#e0e0e0"
  local result = hl.readable(color, bg, 4.5, target)
  eq(hl.contrast(result, bg) >= 4.5, true)
  local step
  for k = 1, 20 do
    if hl.blend(target, color, k * 5) == result then
      step = step or k
    end
  end
  eq(step ~= nil, true)
  -- The previous step is still too dark: the smallest move wins.
  eq(hl.contrast(hl.blend(target, color, (step - 1) * 5), bg) < 4.5, true)
  -- Deterministic.
  eq(hl.readable(color, bg, 4.5, target), result)
end

T["readable replaces a target that cannot reach the ratio"] = function()
  -- A dark target on a dark surface: the engine heads for white.
  local result = hl.readable("#303030", "#202020", 4.5, "#404040")
  eq(hl.contrast(result, "#202020") >= 4.5, true)
  -- On a light surface it heads for black.
  local dark = hl.readable("#d0d0d0", "#f0f0f0", 4.5)
  eq(hl.contrast(dark, "#f0f0f0") >= 4.5, true)
  eq(hl.luminance(dark) < hl.luminance("#d0d0d0"), true)
end

T["groups name roles and unknown roles are reported"] = function()
  local palette = vim.deepcopy(theme.palette("chocolate"))
  palette.polish = {
    TestRole = { fg = "@accent", bg = { "@tide", "@base", 50 } },
    TestMissing = { fg = "@nope" },
  }
  local groups, problems = hl.resolve(palette)
  local r = roles.resolve(palette)
  eq(groups.TestRole.fg, r.accent)
  eq(groups.TestRole.bg, hl.blend(r.tide, r.base, 50))
  eq(groups.TestMissing, nil)
  eq(problems, { 'TestMissing: unknown color fg = "@nope"' })
end

-- Group modules -----------------------------------------------------------

local MODULES = {
  "editor",
  "syntax",
  "floats",
  "status",
  "progress",
  "search",
  "start",
  "panels",
  "explorer",
  "health",
  "plugins",
  "ai",
  "markdown",
}

T["group modules are disjoint and merge into the group table"] = function()
  local dir = helpers.iara_dir .. "/lua/iara/theme/groups"
  local files = vim.fn.glob(dir .. "/*.lua", true, true)
  eq(#files, #MODULES + 1)
  local owner, merged = {}, require("iara.theme.groups")
  local duplicates, count = {}, 0
  for _, name in ipairs(MODULES) do
    for group in pairs(require("iara.theme.groups." .. name)) do
      if owner[group] then
        table.insert(duplicates, group)
      end
      owner[group] = name
      count = count + 1
      eq({ group, merged[group] ~= nil }, { group, true })
    end
  end
  for group in pairs(roles.GROUPS) do
    eq({ group, owner[group] }, { group, nil })
    count = count + 1
  end
  eq(duplicates, {})
  eq(vim.tbl_count(merged), count)
end

-- Groups migrated onto roles, with the surface their text is drawn on.
local MUTED_TEXT = {
  { "FloatFooter", "mantle" },
  { "CmpItemMenu", "base" },
  { "SnacksPickerDir", "mantle" },
  { "SnacksPickerTotals", "mantle" },
  { "IaraSearchDir", "mantle" },
  { "IaraSearchCount", "mantle" },
  { "IaraSearchCrumb", "bg" },
  { "IaraSearchFooter", "mantle" },
  { "IaraSearchPlaceholder", "mantle" },
  { "IaraSearchPromptNormal", "mantle" },
  { "IaraStartText", "base" },
  { "IaraStartFooter", "base" },
  { "DiagnosticInfo", "base" },
  { "IaraStatusDiagInfo", "bg" },
  { "DiagnosticVirtualTextInfo", "bg" },
  { "IaraSearchModeChip", "bg" },
  -- Accent titles, keys, and matches (the V2 gallery found 3.77:1).
  { "FloatTitle", "mantle" },
  { "IaraSearchTitle", "bg" },
  { "IaraSearchFooterKey", "mantle" },
  { "IaraSearchMatch", "mantle" },
  { "CmpItemAbbrMatch", "base" },
  { "IaraStartKey", "base" },
}

T["migrated text groups are readable in every palette"] = function()
  local failures = {}
  each_palette(function(name, palette, r)
    local groups = hl.resolve(palette)
    for _, entry in ipairs(MUTED_TEXT) do
      local spec = groups[entry[1]]
      local surface = entry[2] == "bg" and spec.bg or r[entry[2]]
      below(failures, name .. " " .. entry[1], spec.fg, { surface }, 4.5)
    end
    for mode in pairs({ Normal = 1, Insert = 1, Visual = 1, Command = 1 }) do
      local spec = groups["IaraStatusMode" .. mode]
      below(failures, name .. " mode " .. mode, spec.fg, { spec.bg }, 4.5)
    end
    local location = groups.IaraSearchLocation.fg
    below(failures, name .. " location", location, { r.mantle }, 3)
    -- Line numbers are glyphs (3:1), also on the cursor line.
    local surfaces = { r.base, r.cursorline }
    below(failures, name .. " LineNr", groups.LineNr.fg, surfaces, 3)
  end)
  eq(failures, {})
end

T["Info is blue and no longer the success green"] = function()
  each_palette(function(name, palette, r)
    local groups = hl.resolve(palette)
    eq({ name, groups.DiagnosticInfo.fg }, { name, r.info })
    eq({ name, r.info ~= r.ok }, { name, true })
  end)
  local chocolate = theme.palette("chocolate")
  eq(roles.resolve(chocolate).ok, chocolate.base_30.green)
end

-- Applied role groups ------------------------------------------------------

local function hl_get(name)
  return child.lua(
    [[
    local spec = vim.api.nvim_get_hl(0, { name = ..., link = false })
    local function hex(v) return v and ("#%06x"):format(v) end
    local link = vim.api.nvim_get_hl(0, { name = ... }).link
    return { fg = hex(spec.fg), bg = hex(spec.bg), link = link }
  ]],
    { name }
  )
end

T["role groups carry the roles of the applied theme"] = function()
  child.lua("require('iara.theme').apply('chocolate')")
  eq(hl_get("IaraAccent").fg, "#d08b65")
  eq(hl_get("IaraTide").fg, "#749689")
  eq(hl_get("IaraOnAccent").bg, "#d08b65")
  eq(hl_get("IaraMantle").bg, "#201d1c")
  eq(hl_get("IaraStatusModeNormal").bg, "#d08b65")
  child.lua("require('iara.theme').apply('github_light')")
  local r = roles.resolve(theme.palette("github_light"))
  eq(hl_get("IaraAccent").fg, r.accent)
  eq(hl_get("IaraMuted").fg, r.muted)
end

T["role groups link to standard groups under a foreign scheme"] = function()
  child.lua("require('iara.theme').setup({})")
  child.cmd("colorscheme default")
  local links = child.lua_get("require('iara.theme').FALLBACK_LINKS")
  for group, target in pairs(roles.FALLBACK_LINKS) do
    eq({ group, links[group] }, { group, target })
    eq({ group, hl_get(group).link }, { group, target })
  end
  eq(vim.tbl_count(roles.FALLBACK_LINKS), vim.tbl_count(roles.GROUPS))
end

return T
