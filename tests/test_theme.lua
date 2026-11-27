-- Themes (task U1): palettes, :colorscheme entry points, startup
-- precedence, the persisted choice, and the picker preview.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local WAIT_MS = 10000

local child = helpers.new_child()

local snacks_path
---Checkout of the locked snacks.nvim commit from the shared test mirror.
local function snacks_dir()
  if not snacks_path then
    local entry = lazy_fixture.release_entry("snacks.nvim")
    local mirror = lazy_fixture.url_format():format("folke/snacks.nvim")
    local dir = helpers.temp_dir() .. "/snacks.nvim"
    lazy_fixture.git({ "clone", "--quiet", mirror, dir })
    lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
    snacks_path = dir
  end
  return snacks_path
end

local function personal_file(body)
  local path = helpers.temp_dir() .. "/user.lua"
  helpers.write_file(path, body)
  return path
end

---Load the configuration from `personal_body` (nil: no personal file)
---and run the theme step, as startup does.
local function start(personal_body)
  local path = personal_body and personal_file(personal_body)
    or (helpers.temp_dir() .. "/missing.lua")
  child.lua(
    [[
    local loaded = require("iara.config").load({ personal_path = ... })
    require("iara.theme").setup(loaded.config)
  ]],
    { path }
  )
end

local function colors_name()
  return child.g.colors_name
end

local function hl_hex(name, key)
  local value = child.lua(
    [[
    local name, key = ...
    return vim.api.nvim_get_hl(0, { name = name, link = false })[key]
  ]],
    { name, key }
  )
  return value ~= vim.NIL and ("#%06x"):format(value) or nil
end

local function palette(name)
  return child.lua_get("require('iara.theme').palette(...)", { name })
end

local function state_file()
  return child.lua_get("require('iara.theme').state_path()")
end

local function messages()
  return child.cmd_capture("messages")
end

local state_home

---Restart the child with this case's state directory (stored choice).
local function restart()
  child.restart({ "-u", helpers.minimal_init })
  child.lua("vim.env.XDG_STATE_HOME = ...", { state_home })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state_home = helpers.temp_dir()
      restart()
    end,
    post_once = child.stop,
  },
})

T["the default theme is chocolate"] = function()
  start(nil)
  eq(colors_name(), "iara-chocolate")
  eq(child.lua_get("require('iara.theme').current()"), "chocolate")
  eq(hl_hex("Normal", "bg"), nil)
  eq(child.o.background, "dark")
end

-- Every group whose color comes from the palette, compared with what
-- Neovim reports after `:colorscheme iara-<name>`.
local CHECK_ALL = [[
local name = ...
vim.cmd.colorscheme("iara-" .. name)
local theme = require("iara.theme")
local groups, problems = require("iara.theme.highlights").resolve(
  theme.palette(name)
)
local wrong = vim.list_extend({}, problems)
for group, spec in pairs(groups) do
  local actual = vim.api.nvim_get_hl(0, { name = group, create = false })
  for _, key in ipairs({ "fg", "bg", "sp" }) do
    local want = spec[key] and spec[key] ~= "NONE"
      and tonumber(spec[key]:sub(2), 16)
    if want and actual[key] ~= want then
      table.insert(wrong, group .. "." .. key)
    end
  end
  if spec.link and actual.link ~= spec.link then
    table.insert(wrong, group .. ".link")
  end
end
return wrong
]]

T["every palette sets its groups to the palette colors"] = function()
  local names = child.lua_get("require('iara.theme').THEMES")
  eq(#names >= 12, true)
  for _, name in ipairs(names) do
    eq({ name, child.lua(CHECK_ALL, { name }) }, { name, {} })
    local colors = palette(name)
    eq({ name, child.o.background }, { name, colors.type })
    eq(hl_hex("Normal", "fg"), colors.base_16.base05)
    eq(hl_hex("Normal", "bg"), colors.base_16.base00)
    eq(hl_hex("CursorLine", "bg"), colors.base_30.black2)
    local role = function(key)
      return child.lua(
        "local name, key = ...\n"
          .. "local palette = require('iara.theme').palette(name)\n"
          .. "return require('iara.theme.roles').resolve(palette)[key]",
        { name, key }
      )
    end
    -- V12 (V4's request): the bar is the chrome surface, design 2.1.
    eq(hl_hex("StatusLine", "bg"), role("mantle"))
    -- V8: diagnostics use the readable state role built on `red`.
    eq(hl_hex("DiagnosticError", "fg"), role("error"))
    eq(child.g.terminal_color_1, colors.base_16.base08)
    eq(child.g.terminal_color_15, colors.base_16.base07)
  end
end

T["the default terminal background covers the editor surfaces"] = function()
  start(nil)
  local colors = palette("chocolate")
  eq(hl_hex("Normal", "bg"), nil)
  eq(hl_hex("NormalNC", "bg"), nil)
  eq(hl_hex("Normal", "fg"), colors.base_16.base05)
  eq(hl_hex("TabLineFill", "bg"), nil)
  eq(hl_hex("IaraTabFill", "bg"), nil)
  eq(hl_hex("IaraTabActive", "bg"), nil)
  eq(hl_hex("IaraWinbarName", "bg"), nil)
  eq(hl_hex("NormalFloat", "bg"), nil)
end

T["setting a theme alone keeps the terminal background"] = function()
  start("return { ui = { theme = 'gruvbox' } }")
  eq(colors_name(), "iara-gruvbox")
  eq(hl_hex("Normal", "bg"), nil)
end

T["terminal background follows theme changes"] = function()
  start("return { ui = { terminal_background = false } }")
  eq(hl_hex("Normal", "bg"), palette("chocolate").base_16.base00)
  child.cmd("IaraToggleBackground")
  eq(hl_hex("Normal", "bg"), nil)
  child.cmd("IaraTheme gruvbox")
  eq(colors_name(), "iara-gruvbox")
  eq(hl_hex("Normal", "bg"), nil)
  eq(hl_hex("IaraTabFill", "bg"), nil)
  child.cmd("IaraToggleBackground")
  local colors = palette("gruvbox")
  eq(hl_hex("Normal", "bg"), colors.base_16.base00)
  eq(hl_hex("IaraTabActive", "bg"), colors.base_16.base00)
  eq(hl_hex("IaraWinbarName", "bg"), colors.base_16.base00)
end

T["the toggle applies to panel surfaces and keeps selection fills"] = function()
  start(nil)
  local surfaces = {
    "IaraPanel",
    "IaraPanelTitle",
    "NvimTreeNormal",
    "NvimTreeNormalNC",
    "NvimTreeEndOfBuffer",
    "IaraTreeBranch",
    "SnacksPicker",
    "IaraSearchBorderFocus",
    "IaraSearchSelectionGap",
    "WhichKeyNormal",
    "FloatBorder",
    "IaraAskPrompt",
    "IaraContextLabel",
    "Pmenu",
    "CmpPmenu",
    "CmpDoc",
  }
  local selection = hl_hex("IaraSearchSelection", "bg")
  eq(type(selection), "string")
  for _, group in ipairs(surfaces) do
    eq({ group, hl_hex(group, "bg") }, { group })
  end
  child.cmd("IaraToggleBackground")
  local mantle = palette("chocolate").base_30.darker_black
  for _, group in ipairs(surfaces) do
    eq({ group, hl_hex(group, "bg") }, { group, mantle })
  end
  eq(hl_hex("IaraSearchSelection", "bg"), selection)
end

T["restarting restores the configured background"] = function()
  local config = "return { ui = { terminal_background = false } }"
  start(config)
  child.cmd("IaraToggleBackground")
  eq(hl_hex("Normal", "bg"), nil)
  restart()
  start(config)
  eq(hl_hex("Normal", "bg"), palette("chocolate").base_16.base00)
end

T["light themes set a light background"] = function()
  child.cmd("colorscheme iara-gruvbox")
  eq(child.o.background, "dark")
  for _, name in ipairs({ "gruvbox_light", "github_light" }) do
    child.cmd("colorscheme iara-" .. name)
    eq(child.o.background, "light")
    eq(colors_name(), "iara-" .. name)
  end
end

T[":colorscheme iara-gruvbox applies it and fires ColorScheme"] = function()
  start(nil)
  child.lua([[
    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function(args) _G.seen = args.match end,
    })
  ]])
  child.cmd("colorscheme iara-gruvbox")
  eq(colors_name(), "iara-gruvbox")
  eq(child.lua_get("_G.seen"), "iara-gruvbox")
  eq(child.lua_get("require('iara.theme').current()"), "gruvbox")
  eq(hl_hex("Normal", "bg"), nil)
end

T[":IaraTheme applies, stores, and completes theme names"] = function()
  start(nil)
  child.cmd("IaraTheme nord")
  eq(colors_name(), "iara-nord")
  eq(vim.fn.readfile(state_file()), { "nord" })
  local completion = child.fn.getcompletion("IaraTheme gru", "cmdline")
  eq(completion, { "gruvbox", "gruvbox_light" })
end

T[":IaraTheme refuses an unknown name and keeps the theme"] = function()
  start(nil)
  child.cmd("IaraTheme nope")
  eq(colors_name(), "iara-chocolate")
  eq(vim.fn.filereadable(state_file()), 0)
  match(messages(), 'Iara: unknown theme "nope"')
end

T["the stored choice is used at the next startup"] = function()
  start(nil)
  child.cmd("IaraTheme kanagawa")
  restart()
  start("return {}")
  eq(colors_name(), "iara-kanagawa")
end

T["an explicit personal ui.theme wins over the stored choice"] = function()
  helpers.write_file(state_file(), "nord\n")
  start("return { ui = { theme = 'gruvbox' } }")
  eq(colors_name(), "iara-gruvbox")
  eq(vim.fn.readfile(state_file()), { "nord" })
end

T["an unknown configured theme falls back to chocolate"] = function()
  start("return { ui = { theme = 'solarized_neon' } }")
  eq(colors_name(), "iara-chocolate")
  match(messages(), 'unknown theme "solarized_neon"; using chocolate')
end

T["an unknown stored theme falls back to chocolate"] = function()
  helpers.write_file(state_file(), "removed_theme\n")
  start(nil)
  eq(colors_name(), "iara-chocolate")
  match(messages(), 'unknown theme "removed_theme"')
end

T["safe mode applies the theme"] = function()
  local status = child.lua([[
    local status = require("iara").setup({ safe = true })
    local states = {}
    for _, step in ipairs(status.steps) do
      states[step.name] = step.state
    end
    return { mode = status.mode, theme = states["iara.theme"] }
  ]])
  eq(status, { mode = "safe", theme = "loaded" })
  eq(colors_name(), "iara-chocolate")
  local line = child.lua_get("require('iara.core.statusline').render()")
  match(line, "%%#IaraStatusSafe#%[safe%]%%%*")
  -- A warning chip (V12): the warn role, readable in light palettes.
  local warn = child.lua_get(
    "require('iara.theme.roles').resolve("
      .. "require('iara.theme').palette('chocolate')).warn"
  )
  eq(hl_hex("IaraStatusSafe", "bg"), warn)
end

T["Iara groups fall back to links under a foreign colorscheme"] = function()
  start(nil)
  child.cmd("colorscheme default")
  eq(child.lua_get("require('iara.theme').current()"), vim.NIL)
  local link = "vim.api.nvim_get_hl(0, { name = ... }).link"
  eq(child.lua_get(link, { "IaraStatusWarn" }), "StatusLine")
  eq(child.lua_get(link, { "IaraBreadcrumb" }), "Comment")
end

local function wait_colors(expected)
  local ok = child.lua(
    [[
    local ms, name = ...
    return vim.wait(ms, function() return vim.g.colors_name == name end)
  ]],
    { WAIT_MS, expected }
  )
  eq({ ok, colors_name() }, { true, expected })
end

local picker = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.o.columns, child.o.lines = 120, 40
      child.lua("vim.opt.runtimepath:prepend(...)", { snacks_dir() })
      start(nil)
      child.cmd("colorscheme iara-gruvbox")
      -- Every theme applied from here on, previews included.
      child.lua([[
        _G.applied = {}
        vim.api.nvim_create_autocmd("ColorScheme", { callback = function()
          table.insert(_G.applied, vim.g.colors_name)
        end })
      ]])
      child.lua("require('iara.theme').pick()")
    end,
  },
})
T["picker"] = picker

---Wait until the picker shows its list with the cursor on a theme;
---return that theme's name.
local function wait_shown()
  return child.lua(
    [[
    local ms = ...
    local name
    vim.wait(ms, function()
      local picker = Snacks.picker.get()[1]
      local item = picker and picker.list.win:valid() and picker:current()
      name = item and item.name
      return name ~= nil
    end)
    return name
  ]],
    { WAIT_MS }
  )
end

picker["opens on the current theme without previewing another"] = function()
  eq(wait_shown(), "gruvbox")
  -- Let any scheduled preview run before checking.
  child.lua("vim.wait(100)")
  eq(child.lua_get("_G.applied"), {})
  eq(colors_name(), "iara-gruvbox")
end

picker["the status line names the focused picker"] = function()
  wait_shown()
  local render = "require('iara.core.statusline').render()"
  local glyph = child.lua_get("require('iara.core.icons').ACTIONS.grep")
  -- The prompt has focus at open, then the list.
  local line = child.lua_get(render)
  eq(line:find(glyph .. " Themes ", 1, true) ~= nil, true)
  eq(line:find("[No Name]", 1, true), nil)
  child.lua("Snacks.picker.get()[1]:focus('list')")
  line = child.lua_get(render)
  eq(line:find(glyph .. " Themes ", 1, true) ~= nil, true)
end

picker["previews themes live and restores on cancel"] = function()
  wait_shown()
  child.type_keys("<Down>")
  wait_colors("iara-gruvbox_light")
  child.type_keys("<Esc>", "<Esc>")
  wait_colors("iara-gruvbox")
  eq(vim.fn.filereadable(state_file()), 0)
end

picker["confirming applies and stores the theme"] = function()
  wait_shown()
  child.type_keys("<Down>", "<Down>")
  wait_colors("iara-kanagawa")
  child.type_keys("<CR>")
  wait_colors("iara-kanagawa")
  local stored = child.lua(
    [[
    local ms, path = ...
    return vim.wait(ms, function() return vim.uv.fs_stat(path) ~= nil end)
  ]],
    { WAIT_MS, state_file() }
  )
  eq(stored, true)
  eq(vim.fn.readfile(state_file()), { "kanagawa" })
end

---Wait until the editor is in `mode` ("n" or "i").
local function wait_mode(mode)
  local ok = child.lua(
    [[
    local ms, mode = ...
    return vim.wait(ms, function()
      return vim.api.nvim_get_mode().mode == mode
    end)
  ]],
    { WAIT_MS, mode }
  )
  eq(ok, true)
end

---Text of the open theme picker: its footer, the prompt line's chip, and
---the border characters of its prompt and list windows.
local function picker_frame()
  return child.lua_get([[(function()
    local picker = Snacks.picker.get()[1]
    local function text(chunks)
      local parts = {}
      for _, chunk in ipairs(chunks or {}) do
        table.insert(parts, chunk[1])
      end
      return table.concat(parts)
    end
    local input = vim.api.nvim_win_get_config(picker.input.win.win)
    local list = vim.api.nvim_win_get_config(picker.list.win.win)
    local ns = vim.api.nvim_create_namespace("iara.picker.mode")
    local mark = vim.api.nvim_buf_get_extmark_by_id(picker.input.win.buf,
      ns, 1, { details = true })
    return {
      footer = text(list.footer),
      chip = text(mark[3] and mark[3].virt_text),
      title = text(input.title),
      input_border = input.border,
      list_border = list.border,
    }
  end)()]])
end

local function picker_open()
  return child.lua_get("#Snacks.picker.get() > 0")
end

picker["Esc keeps the picker open in Normal mode with list keys"] = function()
  wait_shown()
  child.type_keys("<Esc>")
  wait_mode("n")
  eq(picker_open(), true)
  local frame = picker_frame()
  eq(frame.chip, " NORMAL ")
  match(frame.footer, "j/k move · ⏎ apply · i insert · q cancel")
  -- Moving previews in Normal mode: j, a count, G, gg, k wrapping.
  child.type_keys("j")
  wait_colors("iara-gruvbox_light")
  child.type_keys("3", "j")
  wait_colors("iara-onedark")
  child.type_keys("G")
  wait_colors("iara-tokyonight")
  child.type_keys("g", "g")
  wait_colors("iara-catppuccin")
  child.type_keys("k")
  wait_colors("iara-tokyonight")
  -- Half of the 12 list rows up.
  child.type_keys("<C-u>")
  wait_colors("iara-gruvbox")
end

picker["q in Normal mode cancels and restores the theme"] = function()
  wait_shown()
  child.type_keys("<Esc>", "j", "j")
  wait_colors("iara-kanagawa")
  child.type_keys("q")
  wait_colors("iara-gruvbox")
  eq(picker_open(), false)
  eq(vim.fn.filereadable(state_file()), 0)
end

picker["l in Normal mode applies and stores the theme"] = function()
  wait_shown()
  child.type_keys("<Esc>", "j")
  wait_colors("iara-gruvbox_light")
  child.type_keys("l")
  local stored = child.lua(
    [[
    local ms, path = ...
    return vim.wait(ms, function() return vim.uv.fs_stat(path) ~= nil end)
  ]],
    { WAIT_MS, state_file() }
  )
  eq(stored, true)
  eq(vim.fn.readfile(state_file()), { "gruvbox_light" })
  eq(colors_name(), "iara-gruvbox_light")
  eq(picker_open(), false)
end

picker["i returns to typing, which filters and previews"] = function()
  wait_shown()
  child.type_keys("<Esc>")
  wait_mode("n")
  child.type_keys("a")
  wait_mode("i")
  eq(picker_frame().chip, "")
  match(picker_frame().footer, "⏎ apply · Esc normal")
  child.type_keys("n", "o", "r", "d")
  wait_colors("iara-nord")
  child.type_keys("<Esc>", "o")
  wait_colors("iara-nord")
  eq(picker_open(), false)
end

picker["the frame is straight with its title on the top edge"] = function()
  wait_shown()
  local frame = picker_frame()
  eq(frame.title, "─ Themes ")
  local function chars(border)
    return vim.tbl_map(function(cell)
      return type(cell) == "table" and cell[1] or cell
    end, border)
  end
  eq(
    chars(frame.input_border),
    { "┌", "─", "┐", "│", "┤", "─", "├", "│" }
  )
  eq(
    chars(frame.list_border),
    { "", "", "", "│", "┘", "─", "└", "│" }
  )
  -- The only pane has the focus: its frame is the focus color.
  eq(frame.input_border[1][2], "IaraSearchBorderFocus")
end

picker["rows show type, the stored mark, and swatches"] = function()
  wait_shown()
  local rows = child.lua([[
    local picker = Snacks.picker.get()[1]
    local buf = picker.list.win.buf
    return vim.api.nvim_buf_get_lines(buf, 0, 2, false)
  ]])
  -- Snacks leads every row with a blank selection column.
  eq(rows[1], " catppuccin     dark    " .. ("██ "):rep(8))
  -- No theme stored yet: gruvbox (active at open) carries the mark.
  local gruvbox = child.lua([[
    local picker = Snacks.picker.get()[1]
    local buf = picker.list.win.buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, line in ipairs(lines) do
      if vim.startswith(line, " gruvbox ") then
        return line
      end
    end
  ]])
  eq(vim.startswith(gruvbox, " gruvbox        dark  ✓ ██"), true)
  local column = "vim.wo[Snacks.picker.get()[1].list.win.win].statuscolumn"
  local bar = "require('iara.features.picker.layout').BAR"
  eq(child.lua_get(column), child.lua_get(bar))
end

picker["swatches show each palette's roles and survive previews"] = function()
  wait_shown()
  local check = [[
    local picker = require("iara.theme.picker")
    local theme = require("iara.theme")
    local roles = require("iara.theme.roles")
    local wrong = {}
    for _, name in ipairs(theme.THEMES) do
      local resolved = roles.resolve(theme.palette(name))
      for index, role in ipairs(picker.SWATCH_ROLES) do
        local group = picker.swatch_group(name, index)
        local hl = vim.api.nvim_get_hl(0, { name = group })
        if not hl.fg or ("#%06x"):format(hl.fg) ~= resolved[role] then
          table.insert(wrong, group)
        end
      end
    end
    return wrong
  ]]
  eq(child.lua(check), {})
  local group = "require('iara.theme.picker').swatch_group('github_light', 3)"
  eq(child.lua_get(group), "IaraThemeSwatchGithubLight3")
  -- A live preview runs :hi clear; the swatches are defined again.
  child.type_keys("<Down>")
  wait_colors("iara-gruvbox_light")
  eq(child.lua(check), {})
end

T["without Snacks the picker uses vim.ui.select"] = function()
  start(nil)
  child.lua([[
    vim.ui.select = function(items, _, on_choice)
      _G.offered = items
      on_choice(_G.answer)
    end
  ]])
  child.lua("require('iara.theme').pick()")
  eq(colors_name(), "iara-chocolate")
  eq(child.lua_get("#_G.offered"), 12)
  child.lua("_G.answer = 'onedark'; require('iara.theme').pick()")
  eq(colors_name(), "iara-onedark")
  eq(vim.fn.readfile(state_file()), { "onedark" })
end

return T
