-- What the search pickers look like on a real 120x35 screen (task UX1):
-- a child `nvim --embed` with a UI attached, the pinned snacks.nvim and
-- nvim-web-devicons, an Iara theme, and a small project. Each case checks
-- the visible text; with IARA_UX1_SCREENS set to a file path, the grids
-- are also appended to that file.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")
local ui_child = require("ui_child")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local WIDTH, HEIGHT = 120, 35

local plugin_dirs = nil

---Checkouts of the locked snacks.nvim and nvim-web-devicons commits.
local function plugins()
  if plugin_dirs then
    return plugin_dirs
  end
  plugin_dirs = {}
  local repos = { "folke/snacks.nvim", "nvim-tree/nvim-web-devicons" }
  for _, repo in ipairs(repos) do
    local name = vim.fs.basename(repo)
    local entry = lazy_fixture.release_entry(name)
    local dir = helpers.temp_dir() .. "/" .. name
    local mirror = lazy_fixture.url_format():format(repo)
    lazy_fixture.git({ "clone", "--quiet", mirror, dir })
    lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
    table.insert(plugin_dirs, dir)
  end
  return plugin_dirs
end

local USE_EFFECT = table.concat({
  'import { useEffect, useState } from "react";',
  "",
  "export function Component() {",
  "  const [ready, setReady] = useState(false);",
  "  useEffect(() => setReady(true), []);",
  "  return ready;",
  "}",
}, "\n") .. "\n"

local PLAIN = "export const value = 1;\n"

local PROJECT = {
  ["src/components/Button.tsx"] = USE_EFFECT,
  ["src/components/Button.test.tsx"] = USE_EFFECT,
  ["src/components/Modal.tsx"] = PLAIN,
  ["src/components/Modal.test.tsx"] = USE_EFFECT,
  ["src/hooks/useFetch.ts"] = USE_EFFECT,
  ["src/hooks/useFetch.test.ts"] = USE_EFFECT,
  ["src/hooks/useDebounce.ts"] = PLAIN,
  ["src/hooks/useDebounce.test.ts"] = PLAIN,
  ["src/pages/Home.tsx"] = USE_EFFECT,
  ["src/pages/Settings.tsx"] = PLAIN,
  ["src/api/client.ts"] = PLAIN,
  ["src/api/client.test.ts"] = PLAIN,
  ["README.md"] = "# Demo\n\nA small project.\n",
  ["package.json"] = '{ "name": "demo" }\n',
}

local GENERATED = 230

---A project root with `.git`, the files above, and enough generated
---fixtures to truncate the file name list.
local function project()
  local root = vim.fs.normalize(assert(vim.uv.fs_realpath(helpers.temp_dir())))
  vim.fn.mkdir(root .. "/.git", "p")
  for path, content in pairs(PROJECT) do
    helpers.write_file(root .. "/" .. path, content)
  end
  for index = 1, GENERATED do
    local path = ("%s/generated/gen_%03d.json"):format(root, index)
    helpers.write_file(path, "{}\n")
  end
  return root
end

local child = nil

local function screen()
  return child:screen()
end

---Fail unless `text` contains `part` literally.
local function has(text, part)
  if not text:find(part, 1, true) then
    error(("screen lacks %q:\n%s"):format(part, text), 2)
  end
end

---A title as the screen shows it: plain text after a border dash
---(V13).
local function pill(text)
  return "─ " .. text .. " "
end

---The end of a preview title naming `path` (after its icon), followed
---by the border line.
local function preview_pill(path)
  return " " .. path .. " ─"
end

local function wait_screen(text)
  local found = child:wait(function(c)
    return c:screen():find(text, 1, true) ~= nil
  end)
  if not found then
    error(("screen never showed %q:\n%s"):format(text, screen()), 2)
  end
  return screen()
end

-- Spinner frames, matched as whole glyphs: a byte class of their UTF-8
-- bytes would also match box-drawing lines (same lead byte).
local SPINNER =
  { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---Whether `text` shows a spinner frame.
local function spinning(text)
  for _, frame in ipairs(SPINNER) do
    if text:find(frame, 1, true) then
      return true
    end
  end
  return false
end

---Wait until no spinner shows and the preview shows line 1 of a file
---(or its placeholder), then return the screen.
local function settled()
  child:wait(function(c)
    local text = c:screen()
    -- "Nothing selected" counts only while no row is selected: with a
    -- selected row the preview is still on its way.
    local empty = text:find("Nothing selected", 1, true)
      and not text:find("│▎", 1, true)
    local previewed = text:find("│%s+1 %S") ~= nil or empty
    return previewed and not spinning(text)
  end)
  return screen()
end

local function wait_gone(text)
  local gone = child:wait(function(c)
    return c:screen():find(text, 1, true) == nil
  end)
  if not gone then
    error(("screen still shows %q:\n%s"):format(text, screen()), 2)
  end
end

---Append the screen to the evidence file named by IARA_UX1_SCREENS (or
---the variable `env`).
local function record(name, env)
  local out = vim.env[env or "IARA_UX1_SCREENS"]
  if not out or out == "" then
    return
  end
  local file = assert(io.open(out, "a"))
  file:write(("### %s\n\n```text\n%s\n```\n\n"):format(name, screen()))
  file:close()
end

local function start(theme)
  child = ui_child.start(WIDTH, HEIGHT)
  child:lua(
    [[
    local dirs, theme, file = ...
    for _, dir in ipairs(dirs) do
      vim.opt.runtimepath:prepend(dir)
    end
    vim.cmd.colorscheme("iara-" .. theme)
    vim.cmd.edit(vim.fn.fnameescape(file))
    ]],
    { plugins(), theme, project() .. "/src/pages/Home.tsx" }
  )
end

---Open a search and type `query` into its prompt.
local function search(request, query)
  child:lua("require('iara.features.search').open(...)", { request })
  wait_screen(request.mode == "content" and "Find in files" or "Find files")
  if query then
    child:input(query)
  end
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      start("chocolate")
    end,
    post_case = function()
      child:stop()
    end,
  },
})

T["an empty Find files lists the project's files"] = function()
  search({ mode = "files" })
  wait_screen("244 files")
  local text = settled()
  -- The file being edited first, then shallow paths before deep ones.
  local order = {}
  for _, path in ipairs({
    "src/pages/Home.tsx  ",
    "README.md",
    "package.json",
    "generated/gen_001.json",
  }) do
    table.insert(order, text:find(path, 1, true) or 0)
  end
  eq(order[1] > 0, true)
  eq(order, vim.fn.sort(vim.list_slice(order), "n"))
  has(text, preview_pill("src/pages/Home.tsx"))
  match(text, "⏎ open")
  match(text, "C%-g grep files")
  for _, debug in ipairs({ "Best 200", "idle", "0/200", "|", "glob:" }) do
    eq(text:find(debug, 1, true), nil)
  end
  record("Find files, empty query (UX1b)")
end

T["an empty Find in files shows a placeholder"] = function()
  search({ mode = "content" })
  wait_screen("Type to search inside files")
  local text = wait_screen("Nothing selected")
  match(text, "Find in files")
  eq(text:find("matches", 1, true), nil)
end

T["Find files lists names with a count and a preview"] = function()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  local text = settled()
  match(text, "src/hooks/useFetch%.test%.ts")
  -- The preview of the first row is titled with its path.
  match(text, " src/[%w/]+%.test%.tsx? ─")
  record("Find files with results")
end

T["Find in files groups matches by file with locations"] = function()
  search({ mode = "content" }, "useEffect")
  wait_screen("12 matches in 6 files")
  local text = settled()
  match(text, "src/hooks/useFetch%.ts%s+2")
  match(text, "1:10%s+import { useEffect, useState }")
  match(text, "C%-g filter names")
  record("Find in files with results")
end

T["a two-step chain shows its breadcrumb"] = function()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  child:input("<C-g>")
  wait_screen("Files: test (5)")
  child:input("useEffect")
  wait_screen("6 matches in 3 files")
  local text = settled()
  has(text, "─ Files: test (5) › Contains: useEffect ─")
  match(text, "C%-o back")
  record("Chain: file names, then content")
  child:input("<C-o>")
  wait_screen("5 files")
  wait_gone("Contains")
end

T["a truncated file list says so in one line"] = function()
  search({ mode = "files" }, "gen_")
  wait_screen("200 of 230 files")
  local text = settled()
  match(text, "Best 200 of 230 names shown; type to narrow%.")
  record("Truncation notice")
end

T["switch chips appear only when not at their default"] = function()
  search({ mode = "content", hidden = true, regex = true }, "use")
  local text = wait_screen("matches in")
  has(text, "─ Find in files · hidden · regex ─")
  eq(text:find("ignored", 1, true), nil)
  eq(text:find("case", 1, true), nil)
end

---Columns of the top-left corners (`┌`) on the picker's top border.
local function pane_corners(text)
  for line in vim.gsplit(text, "\n") do
    local first = line:find("┌", 1, true)
    if first then
      local second = line:find("┌", first + 1, true)
      return vim.fn.strdisplaywidth(line:sub(1, first - 1)),
        second and vim.fn.strdisplaywidth(line:sub(1, second - 1))
    end
  end
end

T["Esc shows the list keys in Normal mode, in equal panes"] = function()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  settled()
  child:input("<Esc>")
  local text = wait_screen("NORMAL")
  match(text, "❮")
  match(text, "j/k move · i insert · ⏎ open")
  -- The list and the preview are equally wide, side by side.
  local left, right = pane_corners(text)
  eq(right - left, (WIDTH - 2 * left) / 2)
  child:input("j")
  wait_screen(preview_pill("src/components/Button.test.tsx"))
  wait_screen("│  1 import")
  record("Find files in Normal mode (UX4)", "IARA_UX4_SCREENS")
  child:input("i")
  wait_gone("NORMAL")
  match(screen(), "⏎ open · C%-g grep files")
end

T["Find in files in Normal mode skips file headers"] = function()
  search({ mode = "content" }, "useEffect")
  wait_screen("12 matches in 6 files")
  settled()
  child:input("<Esc>")
  wait_screen("NORMAL")
  -- The last record, not a file header, takes the cursor: the preview
  -- shows the last group's file at line 5.
  local last_group = nil
  for path in screen():gmatch("(src/[%w/.]+)%s+2 │") do
    last_group = path
  end
  child:input("G")
  wait_screen(preview_pill(last_group .. ":5"))
  child:wait(function(c)
    return c:screen():find("│%s+5   useEffect") ~= nil
  end)
  record("Find in files in Normal mode after G (UX4)", "IARA_UX4_SCREENS")
  child:input("q")
  wait_gone("NORMAL")
end

T["the light theme renders the same picker"] = function()
  child:stop()
  start("github_light")
  search({ mode = "content" }, "useEffect")
  wait_screen("12 matches in 6 files")
  settled()
  eq(child:lua("return vim.o.background"), "light")
  -- The focused title is the light palette's accent role.
  local colors = child:lua([[
    local hl = vim.api.nvim_get_hl(0, { name = "IaraSearchTitle" })
    local palette = require("iara.theme.palettes.github_light")
    local roles = require("iara.theme.roles").resolve(palette)
    return { ("#%06x"):format(hl.fg), roles.accent }
  ]])
  eq(colors[1], colors[2])
  record("Find in files, light theme (github_light)")
end

---Fail when the screen shows a rounded corner, a round cap, or a
---Powerline arrow: Iara draws only straight frames (V13).
local function expect_straight(text)
  for _, glyph in ipairs({
    "╭",
    "╮",
    "╰",
    "╯",
    "\u{e0b6}",
    "\u{e0b4}",
    "\u{e0b0}",
    "\u{e0b2}",
  }) do
    eq(text:find(glyph, 1, true), nil)
  end
end

T["frames are straight with inline titles (UX5, V13)"] = function()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  local text = settled()
  expect_straight(text)
  -- Titles sit on the top edges; the frames touch corner to corner.
  has(text, "┌" .. pill("Find files") .. "──")
  has(text, "──┐┌─ ")
  -- The separator under the prompt joins the frame's sides.
  has(text, "├──")
  has(text, "──┤│")
  has(text, "──┘└──")
  record("Find files with straight frames (V13)", "IARA_UX5_SCREENS")
  child:stop()
  start("github_light")
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  text = settled()
  expect_straight(text)
  has(text, "┌" .. pill("Find files") .. "──")
  record("Find files, light theme (V13)", "IARA_UX5_SCREENS")
end

T["the theme picker has Vim keys and a straight frame (UX5)"] = function()
  child:lua("require('iara.theme').pick()")
  wait_screen(pill("Themes"))
  child:input("<Esc>")
  wait_screen("NORMAL")
  -- The list opens on the stored theme (chocolate); each `j` previews
  -- the next one. Waiting for each preview keeps the keys in order.
  local function previews(name)
    local shown = child:wait(function(c)
      return c:lua("return vim.g.colors_name") == name
    end)
    eq(shown, true)
  end
  child:input("j")
  previews("iara-everforest")
  child:input("j")
  previews("iara-github_dark")
  wait_screen("j/k move · ⏎ apply · i insert")
  local text = screen()
  expect_straight(text)
  has(text, "┌" .. pill("Themes") .. "──")
  has(text, "├──")
  has(text, "──┤")
  match(text, "❮")
  record("Theme picker in Normal mode (UX5)", "IARA_UX5_SCREENS")
  child:input("q")
  wait_gone("Themes")
  eq(child:lua("return vim.g.colors_name"), "iara-chocolate")
end

---Rows of the screen that contain `text`.
local function rows_with(text, part)
  local found = {}
  for line in vim.gsplit(text, "\n") do
    if line:find(part, 1, true) then
      table.insert(found, line)
    end
  end
  return found
end

T["the selected row has a bar and previews end without tildes"] = function()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  local text = settled()
  -- Exactly one list row carries the bar, the one being previewed.
  local bars = rows_with(text, "│▎")
  eq(#bars, 1)
  match(bars[1], "%.test%.tsx?")
  -- A five-line file leaves the rest of the preview blank (V10).
  eq(text:find("│~", 1, true), nil)
  child:input("<C-n>")
  child:wait(function(c)
    return rows_with(c:screen(), "│▎")[1] ~= bars[1]
  end)
  eq(#rows_with(screen(), "│▎"), 1)
  record("Find files with the selection bar (V10)", "IARA_V10_SCREENS")
end

T["a chain shows its breadcrumb, chips, and a titled occurrence"] = function()
  search({ mode = "files", hidden = true }, "test")
  wait_screen("5 files")
  child:input("<C-g>")
  wait_screen("Files: test (5)")
  child:input("useEffect")
  wait_screen("6 matches in 3 files")
  local text = settled()
  has(text, " › Contains: useEffect · hidden ─")
  match(text, ":%d+ ─")
  record("Find in files after a chain (V10)", "IARA_V10_SCREENS")
end

T["the theme picker shows types, the mark, and swatches"] = function()
  child:lua("require('iara.theme').pick()")
  wait_screen(pill("Themes"))
  local text =
    wait_screen("██ ██ ██ ██ ██ ██ ██ ██")
  match(text, "chocolate%s+dark%s+✓ ██")
  match(text, "github_light%s+light%s+██")
  record("Theme picker with swatches (V10)", "IARA_V10_SCREENS")
  child:input("<Esc><Esc>")
  wait_gone("Themes")
end

---Windows of the current tab page that are not floating, with the
---names of their buffers relative to the project, and the listed
---buffers and quickfix size.
local function layout_state()
  return child:lua([[
    local root = vim.fn.getcwd()
    local function name(buf)
      local path = vim.api.nvim_buf_get_name(buf)
      return vim.fs.relpath(root, path) or vim.bo[buf].filetype
    end
    local wins, listed = {}, {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        table.insert(wins, name(vim.api.nvim_win_get_buf(win)))
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buflisted then
        table.insert(listed, name(buf))
      end
    end
    table.sort(listed)
    return {
      wins = wins,
      listed = listed,
      quickfix = vim.fn.getqflist({ size = 0 }).size,
      start = require("iara.core.start").buffer() ~= nil,
    }
  ]])
end

---Show the start screen in the only window, from the project root.
local function start_screen()
  child:lua([[
    vim.cmd("silent! only")
    vim.cmd.cd(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(
      vim.api.nvim_buf_get_name(0)))))
    vim.cmd("enew")
    require("iara.core.start").open()
  ]])
end

T["Enter from the start screen opens the file in its window"] = function()
  start_screen()
  search({ mode = "files" }, "Modal.test")
  wait_screen("1 file")
  settled()
  child:input("<CR>")
  wait_gone("Find files")
  local state = layout_state()
  eq(state.wins, { "src/components/Modal.test.tsx" })
  eq(state.quickfix, 0)
  eq(state.start, false)
end

T["Enter with a selection opens every file, no quickfix"] = function()
  start_screen()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  settled()
  -- Select the first two rows; the cursor then rests on the third.
  child:input("<Tab><Tab>")
  wait_screen("2 selected")
  local under = child:lua([[
    local picker = require("snacks").picker.get()[1]
    return picker:current({ resolve = false }).iara.path
  ]])
  child:input("<CR>")
  wait_gone("Find files")
  local state = layout_state()
  -- One editing window shows the row under the cursor.
  eq(state.wins, { under })
  eq(state.quickfix, 0)
  eq(state.start, false)
  eq(vim.tbl_contains(state.listed, under), true)
  eq(#state.listed >= 3, true)
end

---Borders of every open float: the straight pieces Iara draws, or a
---description of any other border.
local function float_borders()
  return child:lua([[
    local ui = require("iara.core.ui")
    local known = { [table.concat(ui.CHARS)] = "straight",
      [table.concat(ui.TOP)] = "top", [table.concat(ui.BOTTOM)] = "bottom" }
    local found = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      local border = type(config.border) == "table" and config.border or {}
      local chars = table.concat(vim.tbl_map(function(cell)
        return type(cell) == "table" and cell[1] or cell
      end, border))
      if config.relative ~= "" and chars:find("[^ ]") then
        table.insert(found, known[chars] or chars)
      end
    end
    table.sort(found)
    return found
  ]])
end

T["each pane has one straight frame and no other border"] = function()
  search({ mode = "files" }, "test")
  wait_screen("5 files")
  settled()
  -- The results frame (prompt top, list bottom) and the preview only:
  -- no box, backdrop, or square border around them.
  eq(float_borders(), { "bottom", "straight", "top" })
  child:input("<Esc><Esc>")
  wait_gone("Find files")
  child:lua("require('iara.theme').pick()")
  wait_screen(pill("Themes"))
  eq(float_borders(), { "bottom", "top" })
  child:input("<Esc><Esc>")
  wait_gone("Themes")
  child:lua([[
    require("iara.core.select").setup()
    vim.ui.select({ "a", "b" }, { prompt = "Pick" }, function() end)
  ]])
  wait_screen("1-9 pick")
  eq(float_borders(), { "straight" })
end

T["vim.ui.select shows the Iara float"] = function()
  child:lua([[
    require("iara.core.select").setup()
    vim.ui.select({ "Copy source location", "Cancel" }, {
      prompt = "Copy source location?",
    }, function(item) _G.chosen = item end)
  ]])
  local text = wait_screen(pill("Copy source location?"))
  expect_straight(text)
  has(text, " 1  Copy source location")
  has(text, "│▎ 1  Copy")
  has(text, "⏎ choose · 1-9 pick · q cancel")
  record("Select presenter (V10)", "IARA_V10_SCREENS")
  child:input("2")
  wait_gone("1-9 pick")
  eq(child:lua("return _G.chosen"), "Cancel")
end

return T
