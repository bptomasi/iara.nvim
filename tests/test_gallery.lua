-- Color gallery (task V2): cell colors decoded from a real UI match the
-- theme's groups, renderers carry them exactly, the contrast audit lists
-- low-contrast text with its groups, and the command-line tool writes
-- its files for each scenario and theme.
local gallery = require("gallery")
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local WIDTH, HEIGHT = 120, 35

local INIT = [[
vim.opt.runtimepath:prepend(%q)
vim.o.swapfile = false
vim.o.shadafile = "NONE"
require("iara.theme").load(%q)
]]

local child = nil
-- A plain MiniTest child, for reading a theme's groups.
local plain_child = nil

local function start(theme)
  local init = helpers.temp_dir() .. "/init.lua"
  helpers.write_file(init, INIT:format(helpers.iara_dir, theme))
  child = gallery.start(WIDTH, HEIGHT, { init = init })
end

---Colors of `group` in the child, with Normal filling a missing color.
local function group_colors(name)
  return child:lua(
    [[
    local function get(group)
      return vim.api.nvim_get_hl(0, { name = group, link = false })
    end
    local hl, normal = get(...), get("Normal")
    return { fg = hl.fg or normal.fg, bg = hl.bg or normal.bg }
    ]],
    { name }
  )
end

---Show "hello world" with "world" highlighted by `group`.
local function show_hello(group)
  child:lua(
    [[
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world" })
    local ns = vim.api.nvim_create_namespace("gallery_test")
    vim.hl.range(0, ns, ..., { 0, 6 }, { 0, 11 })
    ]],
    { group }
  )
  return gallery.capture(child, "hello world")
end

---A one-row snapshot built by hand: `cells` is a list of { text, id }.
local function fake_snapshot(cells, attrs)
  local text, ids = {}, {}
  for index, cell in ipairs(cells) do
    text[index], ids[index] = cell[1], cell[2]
  end
  return {
    width = #cells,
    height = 1,
    text = { text },
    ids = { ids },
    attrs = attrs,
    defaults = { fg = 0xeeeeee, bg = 0x101010, sp = -1 },
  }
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      if child then
        child:stop()
        child = nil
      end
      if plain_child then
        plain_child.stop()
        plain_child = nil
      end
    end,
  },
})

T["cells"] = MiniTest.new_set({
  parametrize = { { "chocolate" }, { "github_light" } },
})

T["cells"]["carry the colors of the group that drew them"] = function(theme)
  start(theme)
  local snapshot = show_hello("Search")
  local row, col = gallery.find(snapshot, "world")
  local cell = gallery.cell(snapshot, row, col)
  local expected = group_colors("Search")
  eq({ fg = cell.style.fg, bg = cell.style.bg }, expected)
  eq(vim.tbl_contains(cell.style.groups, "Search"), true)
  -- Plain text uses the default colors, which are Normal's.
  local plain = gallery.cell(snapshot, gallery.find(snapshot, "hello"))
  eq({ fg = plain.style.fg, bg = plain.style.bg }, group_colors("Normal"))
end

T["the HTML gives each cell its exact colors and groups"] = function()
  start("chocolate")
  local snapshot = show_hello("Search")
  local cell = gallery.cell(snapshot, gallery.find(snapshot, "world"))
  local html = gallery.html(snapshot, { title = "hello" })
  local rule = (".h%d{color:%s;background:%s"):format(
    cell.id,
    gallery.hex(cell.style.fg),
    gallery.hex(cell.style.bg)
  )
  eq(html:find(rule, 1, true) ~= nil, true)
  local span = ('<span class="h%d" title="Search">world</span>'):format(cell.id)
  eq(html:find(span, 1, true) ~= nil, true)
  match(html, '<meta charset="utf%-8">')
  match(html, "Nerd Font")
  eq(html:find("@font-face", 1, true), nil)
end

T["scrolling keeps colors with their text"] = function()
  start("chocolate")
  child:lua([[
    local lines = {}
    for index = 1, 80 do
      lines[index] = "line " .. index
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("gallery_test")
    vim.hl.range(0, ns, "Search", { 39, 0 }, { 39, 7 })
  ]])
  gallery.capture(child, "line 33")
  child:input("30<C-e>")
  local snapshot = gallery.capture(child, "line 63")
  local row, col = gallery.find(snapshot, "line 40")
  eq(row, 10)
  eq(gallery.cell(snapshot, row, col).style.bg, group_colors("Search").bg)
  local other = gallery.cell(snapshot, gallery.find(snapshot, "line 41"))
  eq(other.style.bg, group_colors("Normal").bg)
end

T["the audit lists low-contrast text with its groups"] = function()
  start("chocolate")
  child:lua([[
    local bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg
    vim.api.nvim_set_hl(0, "GalleryFaint", { fg = bg + 0x010101 })
  ]])
  local snapshot = show_hello("GalleryFaint")
  local audit = gallery.audit(snapshot)
  local faint = vim.tbl_filter(function(entry)
    return vim.tbl_contains(entry.groups, "GalleryFaint")
  end, audit)
  eq(#faint, 1)
  eq(faint[1].sample, "world")
  eq(faint[1].ratio < 1.1, true)
  match(gallery.markdown(audit), "| GalleryFaint | `#")
end

T["reverse swaps colors after defaults fill missing ones"] = function()
  local snapshot = fake_snapshot({ { "x", 1 } }, {
    [1] = { rgb = { foreground = 0x112233, reverse = true }, groups = {} },
  })
  local style = gallery.style(snapshot, 1)
  eq({ style.fg, style.bg }, { 0x101010, 0x112233 })
end

T["the audit ignores blank cells and readable text"] = function()
  local attrs = {
    [1] = { rgb = { foreground = 0x202020 }, groups = { "Low" } },
    [2] = { rgb = { foreground = 0x202020 }, groups = { "Blank" } },
  }
  local snapshot = fake_snapshot({
    { "a", 1 },
    { "b", 1 },
    { " ", 2 },
    { "c", 0 },
  }, attrs)
  local audit = gallery.audit(snapshot)
  eq(#audit, 1)
  eq(audit[1].groups, { "Low" })
  eq(audit[1].sample, "ab")
  eq(audit[1].cells, 2)
  -- With a threshold of 1 nothing is low.
  eq(gallery.audit(snapshot, 1), {})
end

T["contrast follows the WCAG 2 formula"] = function()
  eq(gallery.contrast(0x000000, 0xffffff), 21)
  eq(gallery.contrast(0x123456, 0x123456), 1)
  -- #767676 on white is the classic 4.54:1 gray.
  eq(math.floor(gallery.contrast(0x767676, 0xffffff) * 100), 454)
end

T["ANSI output sets 24-bit colors and attributes per run"] = function()
  local attrs = {
    [1] = { rgb = { foreground = 0x112233, bold = true }, groups = {} },
  }
  local snapshot = fake_snapshot({ { "a", 1 }, { "b", 1 }, { "c", 0 } }, attrs)
  local ansi = gallery.ansi(snapshot)
  local bold = "\27[0;38;2;17;34;51;48;2;16;16;16;1mab"
  local plain = "\27[0;38;2;238;238;238;48;2;16;16;16mc\27[0m\n"
  eq(ansi, bold .. plain)
end

-- Command-line tool ----------------------------------------------------------

local SCENARIO = [[
return {
  name = "hello",
  init = %q,
  project = { ["hello.txt"] = "hello gallery\n" },
  args = { "hello.txt" },
  expect = "hello gallery",
  quiet_ms = 100,
}
]]

---A scenario file whose child loads the persisted theme only.
local function scenario_file(dir)
  local init = dir .. "/init.lua"
  helpers.write_file(
    init,
    ("vim.opt.runtimepath:prepend(%q)\n"):format(helpers.iara_dir)
      .. 'local theme = require("iara.theme")\n'
      .. "theme.load(theme.persisted())\n"
  )
  local path = dir .. "/hello.lua"
  helpers.write_file(path, SCENARIO:format(init))
  return path
end

local function run_tool(args)
  local argv = { vim.v.progpath, "--clean", "-l" }
  table.insert(argv, helpers.iara_dir .. "/scripts/gallery.lua")
  return helpers.run(vim.list_extend(argv, args))
end

local function body_background(path)
  local html = table.concat(vim.fn.readfile(path), "\n")
  return html:match("body{[^}]*background:(#%x+)")
end

T["the tool writes every file for each scenario and theme"] = function()
  local dir = helpers.temp_dir()
  local out = dir .. "/out"
  local args = { "--out", out, "--theme", "chocolate" }
  vim.list_extend(args, { "--theme", "github_light" })
  local result = run_tool(vim.list_extend(args, { scenario_file(dir) }))
  eq(result.code, 0)
  -- One line per screen; under vim.system, Neovim's -l mode delivers
  -- Lua's stdout on stderr, so both are searched.
  local output = result.stdout .. result.stderr
  match(output, "hello%-chocolate: .*hello%-chocolate%.html")
  match(output, "hello%-github_light: .*hello%-github_light%.html")
  for _, theme in ipairs({ "chocolate", "github_light" }) do
    for _, ext in ipairs({ "html", "ansi", "txt", "md" }) do
      local path = ("%s/hello-%s.%s"):format(out, theme, ext)
      eq(vim.uv.fs_stat(path) ~= nil, true)
    end
    local text = vim.fn.readfile(("%s/hello-%s.txt"):format(out, theme))
    eq(vim.startswith(text[1], "hello gallery"), true)
    -- The page background is the theme's Normal background.
    plain_child = plain_child or helpers.new_child()
    plain_child.lua("require('iara.theme').load(...)", { theme })
    local bg =
      plain_child.lua_get("vim.api.nvim_get_hl(0, { name = 'Normal' }).bg")
    local page = ("%s/hello-%s.html"):format(out, theme)
    eq(body_background(page), gallery.hex(bg))
  end
  -- Temporary XDG directories are removed; only the outputs remain.
  eq(#vim.fn.readdir(out), 8)
end

T["the tool rejects unknown options and missing scenarios"] = function()
  local unknown = run_tool({ "--colour", "x", "start" })
  eq(unknown.code, 2)
  match(unknown.stderr, "unknown option %-%-colour")
  local missing = run_tool({ helpers.temp_dir() .. "/none.lua" })
  eq(missing.code, 2)
  match(missing.stderr, "cannot load scenario")
end

return T
