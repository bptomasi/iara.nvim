-- One straight frame for every Iara float (tasks UX5, V13): the shared border
-- of `iara.core.ui`, native LSP and diagnostic floats, the plugin specs
-- that open their own floats, and border colors that stay visible on
-- every theme. Picker, terminal, and agent context frames are checked
-- in their own test files.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local STRAIGHT = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.lua([[
        require("iara.core.options").setup({})
        require("iara.core.lsp").setup()
      ]])
    end,
    post_once = child.stop,
  },
})

---Border characters of the newest floating window, or nil.
local function newest_float_border()
  return child.lua_get([[(function()
    local border
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        border = config.border
      end
    end
    return border
  end)()]])
end

T["floats without their own border are straight"] = function()
  eq(child.o.winborder, "single")
  -- LSP hover and signature help open through this helper.
  child.lua([[
    vim.lsp.util.open_floating_preview({ "hover text" }, "markdown", {})
  ]])
  eq(newest_float_border(), STRAIGHT)
end

T["diagnostic floats are straight"] = function()
  -- Read in the same call: the float closes on the next cursor event.
  local border = child.lua_get([[(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, true, { "local x = 1" })
    local ns = vim.api.nvim_create_namespace("test.borders")
    vim.diagnostic.set(ns, 0, {
      { lnum = 0, col = 0, message = "unused x", severity = 2 },
    })
    local _, win = vim.diagnostic.open_float()
    return vim.api.nvim_win_get_config(win).border
  end)()]])
  eq(border, STRAIGHT)
end

T["float options put padded titles on the straight border"] = function()
  local config = child.lua_get([[require("iara.core.ui").float({
    relative = "editor", row = 1, col = 1, width = 10, height = 2,
    title = " Name ", footer = "q close",
  })]])
  eq(config.border, "single")
  eq(config.title, " Name ")
  eq(config.footer, " q close ")
  -- An explicit border wins.
  eq(
    child.lua_get([[require("iara.core.ui").float({ border = "none" })
    .border]]),
    "none"
  )
end

T["a left title starts one border dash after the corner"] = function()
  local ui = child.lua_get([[(function()
    local ui = require("iara.core.ui")
    return {
      title = ui.left_title({ { " Find ", "IaraSearchTitle" } }),
      empty = ui.left_title({}),
    }
  end)()]])
  eq(ui.title, { { "─", "FloatBorder" }, { " Find ", "IaraSearchTitle" } })
  eq(ui.empty, {})
  local custom = [[require("iara.core.ui").left_title({ { "a", "A" } }, "B")]]
  eq(child.lua_get(custom), { { "─", "B" }, { "a", "A" } })
end

---A plugin spec from `lua/iara/plugins/`, with `require` stubs for the
---plugins its options call.
local function plugin_spec(name)
  return child.lua_get(
    [[(function(name)
    local stub
    stub = setmetatable({}, {
      __index = function() return stub end,
      __call = function(_, opts) return opts or stub end,
    })
    package.loaded.cmp = stub
    package.loaded.luasnip = stub
    local spec = require("iara.plugins." .. name)
    local opts = type(spec.opts) == "function" and spec.opts() or spec.opts
    -- Functions cannot cross RPC; keep the window options.
    return vim.json.decode(vim.json.encode({
      window = opts.window and {
        completion = { border = opts.window.completion.border },
        documentation = { border = opts.window.documentation.border },
      },
      win = opts.win,
      preview_config = opts.preview_config,
      ui = opts.ui,
    }))
  end)(...)]],
    { name }
  )
end

T["plugin floats use the shared straight border"] = function()
  local cmp = plugin_spec("cmp")
  eq(cmp.window.completion.border, "single")
  eq(cmp.window.documentation.border, "single")
  eq(plugin_spec("which_key").win.border, "single")
  eq(plugin_spec("gitsigns").preview_config.border, "single")
  eq(plugin_spec("mason").ui.border, "single")
  local lazy = child.lua_get([[require("iara.core.lazy").options({}, {
    root = "/x", lock = "/x/lock", iara = "/x" }).ui]])
  eq(lazy.border, "single")
end

---WCAG contrast ratio of two "#rrggbb" colors.
local function contrast(a, b)
  local function luminance(hex)
    local function channel(index)
      local c = tonumber(hex:sub(index, index + 1), 16) / 255
      return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * channel(2) + 0.7152 * channel(4) + 0.0722 * channel(6)
  end
  local high, low = luminance(a), luminance(b)
  if high < low then
    high, low = low, high
  end
  return (high + 0.05) / (low + 0.05)
end

T["frames and titles stay visible on every theme"] = function()
  local colors = child.lua_get([[(function()
    local result = {}
    local function hex(name, key)
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      return hl[key] and ("#%06x"):format(hl[key])
    end
    for _, name in ipairs(require("iara.theme").THEMES) do
      require("iara.theme").apply(name)
      result[name] = {
        border = hex("FloatBorder", "fg"),
        focus = hex("IaraFloatBorderFocus", "fg"),
        border_bg = hex("FloatBorder", "bg"),
        float_bg = hex("NormalFloat", "bg"),
        title = hex("FloatTitle", "fg"),
        title_bg = hex("FloatTitle", "bg"),
        picker_title = hex("SnacksPickerTitle", "fg"),
        input_border = hex("SnacksPickerInputBorder", "fg"),
        which_key_title = hex("WhichKeyTitle", "fg"),
      }
    end
    return result
  end)()]])
  for name, c in pairs(colors) do
    local label = name .. ": "
    -- The focused frame is at least 3:1 on the float background; the
    -- idle frame is quieter but still drawn (V13).
    local focus = contrast(c.focus, c.float_bg)
    eq(label .. tostring(focus >= 3), label .. "true")
    local idle = contrast(c.border, c.float_bg)
    eq(label .. tostring(idle > 1.2 and idle < focus), label .. "true")
    -- Titles are text on the border line: one background for every
    -- border cell (V13); one border color across the picker.
    eq(label .. c.border_bg, label .. c.float_bg)
    eq(label .. c.title_bg, label .. c.float_bg)
    eq(label .. c.picker_title, label .. c.title)
    eq(label .. c.which_key_title, label .. c.title)
    eq(label .. c.input_border, label .. c.border)
  end
end

-- Rounded corners and round or arrow caps leave part of their cell in a
-- second color (design 09, section 7); none may appear in Iara's UI.
local ROUND = {
  "╭",
  "╮",
  "╰",
  "╯",
  "\u{e0b6}",
  "\u{e0b4}",
  "\u{e0b0}",
  "\u{e0b2}",
}

---The same glyphs as Lua escapes, as `iara.core.icons` writes glyphs.
local ROUND_ESCAPES = {
  "\\u{256d}",
  "\\u{256e}",
  "\\u{2570}",
  "\\u{256f}",
  "\\u{e0b6}",
  "\\u{e0b4}",
  "\\u{e0b0}",
  "\\u{e0b2}",
}

T["no Iara source draws a rounded corner or a cap"] = function()
  local found = {}
  local root = helpers.iara_dir .. "/lua/iara"
  for _, path in ipairs(vim.fn.globpath(root, "**/*.lua", true, true)) do
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    for index, glyph in ipairs(ROUND) do
      local escape = ROUND_ESCAPES[index]:lower()
      if
        source:find(glyph, 1, true) or source:lower():find(escape, 1, true)
      then
        table.insert(found, vim.fs.basename(path) .. " " .. index)
      end
    end
  end
  eq(found, {})
end

T["no rounded glyph or cap reaches the screen"] = function()
  child.o.lines, child.o.columns = 24, 80
  child.lua([[
    require("iara.theme").load("chocolate")
    require("iara.core.statusline").setup()
    require("iara.core.select").setup()
    vim.lsp.util.open_floating_preview({ "hover text" }, "markdown", {})
    vim.ui.select({ "a", "b" }, { prompt = "Pick" }, function() end)
  ]])
  local screen = tostring(child.get_screenshot())
  eq(screen:find("┌─ Pick ", 1, true) ~= nil, true)
  eq(screen:find(" NORMAL ", 1, true) ~= nil, true)
  for _, glyph in ipairs(ROUND) do
    eq(screen:find(glyph, 1, true), nil)
  end
end

return T
