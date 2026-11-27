-- The float language (tasks V3, V13): plain titles on a straight border
-- and key-hint footers that never exceed their width, focus shown by the
-- border color, the native popup menu's border, and the contrast of
-- every float group in all 12 palettes.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.lua([[
        require("iara.core.options").setup({})
        require("iara.core.lsp").setup()
        require("iara.theme").load("chocolate")
      ]])
    end,
    post_once = child.stop,
  },
})

local function title(...)
  return child.lua("return require('iara.core.float').title(...)", { ... })
end

local function footer(...)
  return child.lua("return require('iara.core.float').footer(...)", { ... })
end

local function width(chunks)
  return child.lua("return require('iara.core.float').width(...)", { chunks })
end

local function text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

-- Titles ---------------------------------------------------------------------

T["a focused title is accent text after a focused border dash"] = function()
  eq(title("Find files", true), {
    { "─", "IaraFloatBorderFocus" },
    { " Find files ", "IaraFloatTitleFocus" },
  })
end

T["an idle title is muted text after an idle border dash"] = function()
  eq(title("  Preview ", false), {
    { "─", "FloatBorder" },
    { " Preview ", "FloatTitle" },
  })
end

T["a blank title gives no chunks"] = function()
  eq(title("   ", true), {})
  eq(title("", false, 40), {})
end

T["a long title is cut with an ellipsis to its width"] = function()
  local chunks = title("src/components/Button.test.tsx", true, 20)
  eq(width(chunks), 20)
  eq(chunks[2], { " src/components/B… ", "IaraFloatTitleFocus" })
  -- A title that fits is not cut.
  eq(text(title("Themes", false, 20)), "─ Themes ")
end

T["titles never exceed their width"] = function()
  local overflow = child.lua([[
    local float = require("iara.core.float")
    local bad = {}
    for _, text in ipairs({ "x", "Find files", "Ünïcödé 名前 path" }) do
      for width = 0, 30 do
        local chunks = float.title(text, width % 2 == 0, width)
        if float.width(chunks) > width then
          table.insert(bad, text .. " @" .. width)
        end
      end
    end
    return bad
  ]])
  eq(overflow, {})
  -- Too narrow for the frame and one character: nothing is drawn.
  eq(title("Find files", true, 3), {})
end

T["wrapping and rules take the frame's focus color"] = function()
  local float = "require('iara.core.float')"
  eq(child.lua_get(float .. ".wrap_title({ { ' a ', 'X' } }, true)"), {
    { "─", "IaraFloatBorderFocus" },
    { " a ", "X" },
  })
  eq(child.lua_get(float .. ".rule(3)"), { "───", "FloatBorder" })
  eq(child.lua_get(float .. ".border(require('iara.core.ui').BOTTOM, true)"), {
    { "", "IaraFloatBorderFocus" },
    { "", "IaraFloatBorderFocus" },
    { "", "IaraFloatBorderFocus" },
    { "│", "IaraFloatBorderFocus" },
    { "┘", "IaraFloatBorderFocus" },
    { "─", "IaraFloatBorderFocus" },
    { "└", "IaraFloatBorderFocus" },
    { "│", "IaraFloatBorderFocus" },
  })
end

-- Footers --------------------------------------------------------------------

local HINTS = {
  { "⏎", "open" },
  { "^v", "split" },
  { "^g", "grep these" },
  { "Tab", "mark" },
}

T["a footer shows accent keys and muted descriptions"] = function()
  eq(footer({ { "⏎", "open" }, { "q", "close" } }, 80), {
    { " ", "FloatFooter" },
    { "⏎", "IaraFloatFooterKey" },
    { " open", "FloatFooter" },
    { " · ", "FloatFooter" },
    { "q", "IaraFloatFooterKey" },
    { " close", "FloatFooter" },
    { " ", "FloatFooter" },
  })
  eq(
    text(footer(HINTS, 80)),
    " ⏎ open · ^v split · ^g grep these · Tab mark "
  )
end

T["hints that do not fit are dropped from the right"] = function()
  local full = width(footer(HINTS, 80))
  eq(text(footer(HINTS, full - 1)), " ⏎ open · ^v split · ^g grep these ")
  eq(text(footer(HINTS, 19)), " ⏎ open · ^v split ")
  eq(text(footer(HINTS, 18)), " ⏎ open ")
  eq(text(footer(HINTS, 8)), " ⏎ open ")
  eq(footer(HINTS, 7), {})
  eq(footer({}, 80), {})
end

T["footers show at most five hints and never exceed their width"] = function()
  local hints = {}
  for index = 1, 7 do
    table.insert(hints, { tostring(index), "hint" })
  end
  eq(#vim.split(vim.trim(text(footer(hints, 200))), " · "), 5)
  local custom = { key = "K", text = "D", max = 6 }
  local chunks = footer(hints, 200, custom)
  eq(#vim.split(vim.trim(text(chunks)), " · "), 6)
  eq({ chunks[2][2], chunks[3][2] }, { "K", "D" })
  local overflow = child.lua(
    [[
    local float = require("iara.core.float")
    local bad = {}
    for width = 0, 60 do
      if float.width(float.footer(..., width)) > width then
        table.insert(bad, width)
      end
    end
    return bad
  ]],
    { HINTS }
  )
  eq(overflow, {})
end

-- Frames ---------------------------------------------------------------------

---Open an LSP-style float (the path of hover and signature help) and
---return its window.
local function open_hover()
  return child.lua_get([[select(2, vim.lsp.util.open_floating_preview(
    { "function M.greet(name: string)" }, "markdown", {}))]])
end

local function winhighlight(win)
  return child.lua_get(
    ("vim.api.nvim_get_option_value('winhighlight', { win = %d })"):format(win)
  )
end

local FOCUS = "FloatBorder:IaraFloatBorderFocus,"
  .. "FloatTitle:IaraFloatTitleFocus"

T["an LSP float has an idle frame until entered, then focused"] = function()
  local win = open_hover()
  eq(child.lua_get(("vim.api.nvim_win_get_config(%d).border"):format(win)), {
    "┌",
    "─",
    "┐",
    "│",
    "┘",
    "─",
    "└",
    "│",
  })
  -- The preview hides its end-of-buffer filler through 'winhighlight'.
  local own = winhighlight(win)
  eq(own:find("FloatBorder", 1, true), nil)
  child.lua(("vim.api.nvim_set_current_win(%d)"):format(win))
  eq(winhighlight(win), own .. "," .. FOCUS)
  -- Leaving closes a hover; a float that stays returns to idle (below).
end

---Open a plain float without entering it and return its window.
local function open_float()
  return child.lua_get([[vim.api.nvim_open_win(
    vim.api.nvim_create_buf(false, true), false,
    { relative = "editor", row = 1, col = 1, width = 20, height = 2 })]])
end

T["focusing keeps the float's other highlights"] = function()
  local win = open_float()
  child.lua(
    ("vim.wo[%d].winhighlight = 'Normal:Pmenu,Search:None'"):format(win)
  )
  child.lua(("vim.api.nvim_set_current_win(%d)"):format(win))
  eq(winhighlight(win), "Normal:Pmenu,Search:None," .. FOCUS)
  child.cmd("wincmd p")
  eq(winhighlight(win), "Normal:Pmenu,Search:None")
end

T["floats that style their own frame and splits are untouched"] = function()
  -- Snacks windows map the title, pickers and cmp the border.
  for _, own in ipairs({ "FloatTitle:SnacksTitle", "FloatBorder:CmpBorder" }) do
    local float = open_float()
    child.lua(("vim.wo[%d].winhighlight = %q"):format(float, own))
    child.lua(("vim.api.nvim_set_current_win(%d)"):format(float))
    eq(winhighlight(float), own)
    child.cmd("wincmd p")
  end
  local win = open_float()
  child.lua(
    ("vim.wo[%d].winhighlight = 'FloatBorder:SnacksPickerBorder'"):format(win)
  )
  child.lua(("vim.api.nvim_set_current_win(%d)"):format(win))
  eq(winhighlight(win), "FloatBorder:SnacksPickerBorder")
  child.cmd("wincmd p | vsplit")
  eq(child.wo.winhighlight, "")
end

T["frames are subtle at rest and the accent when focused"] = function()
  local colors = child.lua([[
    local roles = require("iara.theme.roles")
    local r = roles.resolve(require("iara.theme").palette("chocolate"))
    local function fg(name)
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      return ("#%06x"):format(hl.fg)
    end
    return {
      border = fg("FloatBorder") == r.border,
      menu = fg("PmenuBorder") == r.border,
      focus = fg("IaraFloatBorderFocus") == r.border_focus,
      title = fg("IaraFloatTitleFocus") == r.accent,
      idle_title = fg("FloatTitle") == r.muted,
    }
  ]])
  eq(colors, {
    border = true,
    menu = true,
    focus = true,
    title = true,
    idle_title = true,
  })
end

---Screen attribute ids of the cells of `row` (1-based) from `first` to
---`last` columns.
local function attrs(screen, row, first, last)
  local ids = {}
  for col = first, last do
    table.insert(ids, screen.attr[row][col])
  end
  return ids
end

T["a focused float's whole frame and title dash share one color"] = function()
  child.o.lines, child.o.columns = 12, 40
  child.lua([[
    local float = require("iara.core.float")
    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true),
      true, require("iara.core.ui").float({ relative = "editor", row = 1,
      col = 1, width = 20, height = 2, title = float.title("Notes"),
      title_pos = "left" }))
  ]])
  local screen = child.get_screenshot()
  -- Row 2 is the top border: corner, dash, then the title text.
  eq(screen.text[2][2], "┌")
  eq(screen.text[2][3], "─")
  local frame = screen.attr[2][2]
  eq(attrs(screen, 2, 2, 3), { frame, frame })
  eq(screen.attr[3][2], frame)
  eq(screen.attr[2][5] ~= frame, true)
  -- Attribute ids are per screenshot: the idle frame is compared with
  -- its own title, and the focus entries are gone.
  local win = child.lua_get("vim.api.nvim_get_current_win()")
  child.cmd("wincmd p")
  eq(winhighlight(win):find("IaraFloatBorderFocus", 1, true), nil)
  local idle = child.get_screenshot()
  eq(idle.attr[2][3], idle.attr[2][2])
  eq(idle.attr[2][5] ~= idle.attr[2][2], true)
end

T["the native popup menu is straight and width-capped"] = function()
  eq(child.o.pumborder, "single")
  eq(child.o.pummaxwidth, 60)
  child.o.lines, child.o.columns = 20, 60
  child.type_keys(":colorscheme ", "<Tab>")
  local screen = tostring(child.get_screenshot())
  eq(screen:find("┌", 1, true) ~= nil, true)
  eq(screen:find("┘", 1, true) ~= nil, true)
  eq(screen:find("╭", 1, true), nil)
  child.type_keys("<Esc>")
end

T["float groups link to standard ones under a foreign scheme"] = function()
  child.cmd("colorscheme default")
  local links = child.lua([[
    local out = {}
    for name in pairs(require("iara.core.float").FALLBACK_LINKS) do
      out[name] = vim.api.nvim_get_hl(0, { name = name }).link
    end
    return out
  ]])
  eq(links, child.lua_get("require('iara.core.float').FALLBACK_LINKS"))
end

-- Contrast -------------------------------------------------------------------

-- Text pairs: { group, minimum } with the background the group draws on
-- (its own bg). The focused border is checked against the float
-- surface; the idle border is decoration (design 09, section 7).
local TEXT = {
  { "NormalFloat", 4.5 },
  { "FloatTitle", 4.5 },
  { "FloatFooter", 4.5 },
  { "IaraFloatTitleFocus", 4.5 },
  { "IaraFloatFooterKey", 4.5 },
  { "Pmenu", 4.5 },
  { "PmenuSel", 4.5 },
  { "PmenuKind", 4.5 },
  { "PmenuKindSel", 4.5 },
  { "PmenuMatch", 4.5 },
  { "PmenuExtra", 3 },
  { "PmenuExtraSel", 3 },
  { "PmenuMatchSel", 3 },
  { "IaraFloatBorderFocus", 3 },
}

T["float text is readable in every palette"] = function()
  local low = child.lua(
    [[
    local theme = require("iara.theme")
    local hl = require("iara.theme.highlights")
    local low = {}
    for _, name in ipairs(theme.THEMES) do
      local groups = hl.resolve(theme.palette(name))
      for _, pair in ipairs(...) do
        local spec = groups[pair[1] ]
        local ratio = hl.contrast(spec.fg, spec.bg)
        if ratio < pair[2] then
          table.insert(low, ("%s %s %.2f"):format(name, pair[1], ratio))
        end
      end
    end
    return low
  ]],
    { TEXT }
  )
  eq(low, {})
end

T["frame and title cells share the float surface in every palette"] = function()
  local bad = child.lua([[
    local theme = require("iara.theme")
    local hl = require("iara.theme.highlights")
    local bad = {}
    for _, name in ipairs(theme.THEMES) do
      local g = hl.resolve(theme.palette(name))
      local surface = g.NormalFloat.bg
      -- One border color: the menu's frame is the float's.
      local one = g.PmenuBorder.link == "FloatBorder"
        and g.FloatBorder.bg == surface
      -- Titles and focused frames are text on the float surface: no
      -- cell of the border line has a second background.
      local cells = g.FloatTitle.bg == surface
        and g.IaraFloatTitleFocus.bg == surface
        and g.IaraFloatBorderFocus.bg == surface
        and g.FloatFooter.bg == surface
        and g.IaraFloatFooterKey.bg == surface
      if not (one and cells) then
        table.insert(bad, name)
      end
    end
    return bad
  ]])
  eq(bad, {})
end

return T
