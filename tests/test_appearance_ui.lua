--- Start screen and status line through a real UI (UX3, V6): a child
--- `nvim --embed` started with or without a file argument, Iara's
--- options, theme, owners, and start screen, and stub commands for the
--- start screen's actions. With IARA_UX3_SNAPSHOTS set to a directory,
--- each screen is also written there for the evidence.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")
local ui_child = require("ui_child")

local eq = MiniTest.expect.equality

local WIDTH, HEIGHT = 120, 35

local START = "Find in files"
local TAGLINE = "Edit, search, and run in one place"
local BAR = "▎"

-- `%s`: the runtime path, Lua run before the start screen's setup (the
-- working directory, `v:oldfiles`), and the theme.
local INIT = [[
vim.g.iara_startup_hrtime = vim.uv.hrtime()
vim.opt.runtimepath:prepend(%q)
vim.o.swapfile = false
vim.o.shadafile = "NONE"
%s
local config = { options = {}, ui = {} }
if vim.g.iara_test_static_wave then
  config.ui.wave_animation = false
end
require("iara.core.options").setup(config)
require("iara.theme").load(%q)
require("iara.core.root").setup(config)
require("iara.core.eligibility").setup(config)
require("iara.core.reconcile").setup(config)
for _, name in ipairs({ "IaraFiles", "IaraGrep", "IaraTermToggle" }) do
  if vim.fn.exists(":" .. name) ~= 2 then
    vim.api.nvim_create_user_command(name, function()
      vim.g.ran = name
    end, {})
  end
end
require("iara.core.start").setup(config)
]]

local child = nil

local function rows(screen)
  return vim.split(screen, "\n", { plain = true })
end

local function snapshot(name, screen)
  local dir = vim.env.IARA_UX3_SNAPSHOTS
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(rows(screen), dir .. "/" .. name .. ".txt")
  end
end

local function has(screen, text)
  return screen:find(text, 1, true) ~= nil
end

---The first screen row containing `text`, and its number.
local function row_with(screen, text)
  for index, line in ipairs(rows(screen)) do
    if has(line, text) then
      return line, index
    end
  end
  return nil
end

local function wave_rows(screen)
  return vim.tbl_filter(function(line)
    return vim.fn.match(line, "[⠀-⣿]") >= 0
  end, rows(screen))
end

---The wave's horizontal bounds in cells (right exclusive) and height.
local function wave_bounds(screen)
  local art = wave_rows(screen)
  local left, right = math.huge, 0
  for _, line in ipairs(art) do
    left = math.min(left, #line:match("^ *"))
    right = math.max(right, vim.fn.strwidth((line:gsub(" *$", ""))))
  end
  return { left, right, #art }
end

---The first action's bounds, including the one-cell space after its key.
local function menu_bounds(screen)
  local line = row_with(screen, "Find files")
  return #line:match("^ *"), vim.fn.strwidth((line:gsub(" *$", ""))) + 1
end

---Wait until the buffer shows "local M = {}" and the status line
---(drawn in a later flush under load) names init.lua; return the screen.
local function wait_file_screen()
  child:wait(function(c)
    local screen = c:screen()
    return has(screen, "local M = {}")
      and has(rows(screen)[HEIGHT - 1], "init.lua")
  end)
  return child:screen()
end

---Wait until the screen shows `text` and the status line has been drawn
---(the last part of the start screen's flush); return the screen.
local function wait_start_screen(text)
  child:wait(function(c)
    local screen = c:screen()
    return has(screen, text) and has(rows(screen)[HEIGHT - 1], " NORMAL ")
  end)
  return child:screen()
end

---A project directory (real path) with `files` (name -> content).
local function project(files)
  local dir = assert(vim.uv.fs_realpath(helpers.temp_dir()))
  for name, content in pairs(files or {}) do
    helpers.write_file(dir .. "/" .. name, content)
  end
  return dir
end

---Start the child. `opts.file` is passed as an argument, `opts.cwd` is
---the working directory, `opts.oldfiles` becomes `v:oldfiles`,
---`opts.before` is Lua run before the setup, and
---`opts.theme_command` defines a `:IaraTheme` stub (the Themes action).
local function start(opts)
  opts = opts or {}
  local before = opts.animate and "" or "vim.g.iara_test_static_wave = true\n"
  if opts.theme_command then
    before = before .. "vim.api.nvim_create_user_command('IaraTheme', '', {})\n"
  end
  if opts.before then
    before = before .. opts.before .. "\n"
  end
  if opts.cwd then
    before = before .. ("vim.cmd.cd(%q)\n"):format(opts.cwd)
  end
  if opts.oldfiles then
    before = before
      .. ("vim.v.oldfiles = %s\n"):format(vim.inspect(opts.oldfiles))
  end
  local init = helpers.temp_dir() .. "/init.lua"
  local theme = opts.theme or "chocolate"
  helpers.write_file(init, INIT:format(helpers.iara_dir, before, theme))
  child = ui_child.start(opts.width or WIDTH, opts.height or HEIGHT, {
    init = init,
    args = opts.file and { opts.file } or nil,
  })
end

local function lua_file()
  local dir = project({ [".git/HEAD"] = "ref: refs/heads/main\n" })
  local path = dir .. "/init.lua"
  helpers.write_file(path, "local M = {}\n\nreturn M\n")
  return path
end

local function wait_for(predicate)
  return child:wait(function(c)
    return predicate(c)
  end)
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      if child then
        child:stop()
        child = nil
      end
    end,
  },
})

T["without files Iara opens on the start screen"] = function()
  local dir = project({ [".git/HEAD"] = "ref: refs/heads/main\n" })
  start({ cwd = dir })
  local screen = wait_start_screen(START)
  snapshot("start", screen)
  local expected_text = { TAGLINE, "Find files", START }
  for _, text in ipairs(expected_text) do
    eq({ text, has(screen, text) }, { text, true })
  end
  -- Hidden: no :IaraTheme in this child.
  eq(has(screen, "Themes"), false)
  -- Each action ends in its key chip.
  eq(row_with(screen, "Find in files"):match("%s%s(%a)%s*$"), "w")
  local footer = vim.trim(row_with(screen, "∿"))
  local name, version = vim.fs.basename(dir), vim.version()
  local expected = ("∿  %s  ·  main  ·  nvim %d.%d.%d  ·  "):format(
    name,
    version.major,
    version.minor,
    version.patch
  )
  eq(footer:sub(1, #expected), expected)
  eq(footer:sub(#expected + 1):match("^%d+ ms$") ~= nil, true)
  eq(has(rows(screen)[HEIGHT - 1], " NORMAL "), true)
  eq(child:lua("return vim.bo.filetype"), "iara-start")
  eq(child:lua("return vim.wo.number"), false)
end

T["the wave and tagline are centered on the menu"] = function()
  start()
  local screen = wait_start_screen(START)
  local left, right = menu_bounds(screen)
  eq(left, (WIDTH - 50) / 2)
  eq(right - left, 50)
  eq(wave_bounds(screen), { left, right, 15 })
  local art = wave_rows(screen)
  for _, line in ipairs(vim.list_slice(art, #art - 2)) do
    eq(vim.fn.strwidth((line:gsub(" *$", ""))), right)
  end
  local tagline = row_with(screen, TAGLINE)
  eq(#tagline:match("^ *") - left, (right - left - #TAGLINE) / 2)
  for _, line in ipairs(rows(screen)) do
    eq(vim.trim(line) == "iara", false)
  end
end

local function wave_changed(art, timeout)
  return vim.wait(timeout, function()
    return not vim.deep_equal(wave_rows(child:screen()), art)
  end, 10)
end

local function toggle_wave()
  child:lua("vim.cmd.IaraToggleWaveAnimation(); vim.cmd.redraw()")
end

local function wave_in_pane(screen, first_col, width)
  local art = {}
  for _, line in ipairs(wave_rows(screen)) do
    art[#art + 1] = vim.fn.strcharpart(line, first_col, width)
  end
  return table.concat(art, "\n")
end

T["wave motion changes the screen without editing the buffer"] = function()
  start({ animate = true })
  wait_start_screen(START)
  child:input("j")
  eq(
    wait_for(function(c)
      return has(row_with(c:screen(), START) or "", BAR)
    end),
    true
  )
  local screen = child:screen()
  local tick = child:lua("return vim.b.changedtick")
  eq(wave_changed(wave_rows(screen), 2500), true)
  eq(wave_bounds(child:screen()), wave_bounds(screen))
  eq(child:lua("return vim.b.changedtick"), tick)
  eq(has(row_with(child:screen(), START), BAR), true)
  toggle_wave()
  eq(wave_changed(wave_rows(child:screen()), 600), false)
  toggle_wave()
  eq(wave_changed(wave_rows(child:screen()), 2500), true)
end

T["the visible wave keeps moving while a floating panel has focus"] = function()
  start({ animate = true })
  wait_start_screen(START)
  local panel_has_focus = child:lua([[
      local api = vim.api
      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, false, { "Panel shortcuts" })
      local panel = api.nvim_open_win(buf, true, {
        relative = "editor", row = 30, col = 0, width = 100, height = 3,
      })
      return api.nvim_get_current_win() == panel
    ]])
  eq(panel_has_focus, true)
  local screen = child:wait_screen("Panel shortcuts")
  eq(has(screen, START), true)
  eq(#wave_rows(screen) > 0, true)
  eq(wave_changed(wave_rows(screen), 2500), true)
  eq(child:lua("return vim.api.nvim_win_get_config(0).relative"), "editor")
end

T["both panes animate while an Ex command is being edited"] = function()
  start({ animate = true, width = 160, height = 46 })
  child:wait_screen(START)
  child:lua("vim.cmd.vsplit()")
  local prompt = ":echomsg 123"
  child:input(prompt)
  local screen = child:wait_screen(prompt)
  eq(has(screen, prompt), true)
  local left = wave_in_pane(screen, 0, 80)
  local right = wave_in_pane(screen, 80, 80)
  local changes = 0
  local animated = vim.wait(1000, function()
    local current = child:screen()
    local next_left = wave_in_pane(current, 0, 80)
    local next_right = wave_in_pane(current, 80, 80)
    if has(current, prompt) and left ~= next_left and right ~= next_right then
      left, right = next_left, next_right
      changes = changes + 1
    end
    return changes >= 3
  end, 10)
  child:input("4<CR>")
  eq(animated, true)
  eq(
    wait_for(function(c)
      return c:lua("return vim.fn.getcmdtype() == ''")
    end),
    true
  )
  local messages = child:lua("return vim.fn.execute('messages')")
  eq(has(messages, "1234"), true)
end

T["the wave stops on another tab and moves again on return"] = function()
  start({ animate = true })
  wait_start_screen(START)
  local marks = [[
    local buf = require("iara.core.start").buffer()
    local ns = vim.api.nvim_get_namespaces()["iara.start.motion"]
    return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  ]]
  eq(child:lua(marks) > 0, true)
  child:lua("vim.cmd.tabnew()")
  eq(child:lua(marks), 0)
  child:lua("vim.cmd.tabprevious()")
  local screen = child:wait_screen(START)
  eq(wave_changed(wave_rows(screen), 2500), true)
  eq(child:lua(marks) > 0, true)
end

-- The raised shoulder sits above the hollow to the left of the foam.
local function shoulder_row(art)
  for index, line in ipairs(art) do
    local shoulder = vim.fn.strcharpart(vim.trim(line), 16, 8)
    if vim.fn.match(shoulder, "[⠁-⣿]") >= 0 then
      return index
    end
  end
  return 0
end

T["each artwork size keeps moving through the loop"] = function()
  for _, variant in ipairs(require("iara.core.start_wave")) do
    local frames = variant.frames
    eq(#frames, 216)
    -- The three-row artwork can hold a pose for a few ticks.
    local limit = #variant.still == 3 and 4 or 1
    local previous, held = nil, 0
    for index = 1, #frames + limit do
      local pose = table.concat(frames[(index - 1) % #frames + 1], "\n")
      held = pose == previous and held + 1 or 1
      eq(held <= limit, true)
      previous = pose
    end
  end
end

local function changed_cells(before, after)
  local count = 0
  for row, previous in ipairs(before) do
    local old = previous:gsub("[123]", "")
    local new = after[row]:gsub("[123]", "")
    -- The tone-free cells are three-byte Braille glyphs.
    for offset = 1, math.max(#old, #new), 3 do
      if old:sub(offset, offset + 2) ~= new:sub(offset, offset + 2) then
        count = count + 1
      end
    end
  end
  return count
end

T["the wave moves in small steps through the loop seam"] = function()
  local frames = require("iara.core.start_wave")[1].frames
  eq(changed_cells(frames[#frames], frames[1]) <= 28, true)
  for index = 2, #frames do
    eq(changed_cells(frames[index - 1], frames[index]) <= 65, true)
  end
end

T["the foreground keeps moving in small steps"] = function()
  local frames = require("iara.core.start_wave")[1].frames
  local previous = vim.list_slice(frames[#frames], 12)
  local moving = 0
  for _, frame in ipairs(frames) do
    local foreground = vim.list_slice(frame, 12)
    local cells = changed_cells(previous, foreground)
    eq(cells <= 18, true)
    if cells > 0 then
      moving = moving + 1
    end
    previous = foreground
  end
  eq(moving >= 200, true)
end

local function has_fixed_dots(frames, top, bottom, left, right)
  local masks = {}
  local width = right - left
  for _, frame in ipairs(frames) do
    for row = top, bottom do
      local art = frame[row]:gsub("[123]", "")
      for column = left, right - 1 do
        local index = (row - top) * width + column - left + 1
        local glyph = vim.fn.strcharpart(art, column, 1)
        local dots = math.max(0, vim.fn.char2nr(glyph) - 0x2800)
        masks[index] = bit.band(masks[index] or 0xFF, dots)
      end
    end
  end
  return vim.iter(masks):any(function(dots)
    return dots ~= 0
  end)
end

T["the far swell above the foreground has no permanently lit dots"] = function()
  local frames = require("iara.core.start_wave")[1].frames
  eq(has_fixed_dots(frames, 6, 10, 38, 50), false)
end

local function spans_trough(art)
  for row = 6, 12 do
    local sheet = vim.fn.strcharpart(art[row], 24, 6)
    if vim.fn.match(sheet, "[⠁-⣿]") < 0 then
      return false
    end
  end
  return true
end

T["the crest flexes above the trough and Fuji stays fixed"] = function()
  local frames = require("iara.core.start_wave")[1].frames
  local silhouettes = {}
  for _, frame in ipairs(frames) do
    local art = vim.tbl_map(function(line)
      return (line:gsub("[123]", ""))
    end, frame)
    local shoulder = shoulder_row(art)
    eq(shoulder >= 1 and shoulder <= 3, true)
    eq(spans_trough(art), false)
    eq(vim.fn.strcharpart(art[10], 30, 3), "⢀⣴⣄")
    silhouettes[table.concat(art, "\n", 1, 4)] = true
  end
  eq(vim.tbl_count(silhouettes) > 10, true)
end

T["the foreground stays free of a bright foam wake"] = function()
  local frames = require("iara.core.start_wave")[1].frames
  for _, frame in ipairs(frames) do
    for _, line in ipairs(vim.list_slice(frame, 12)) do
      eq(line:find("3", 1, true), nil)
    end
  end
end

T["a configured still wave can be animated during the session"] = function()
  start()
  local still = wave_rows(wait_start_screen(START))
  eq(has(still[10], "⢀⣴⣄"), true)
  eq(wave_changed(still, 600), false)
  toggle_wave()
  eq(wave_changed(still, 2500), true)
  toggle_wave()
  eq(
    wait_for(function(c)
      return vim.deep_equal(wave_rows(c:screen()), still)
    end),
    true
  )
end

T["the wave pauses when Neovim loses focus and resumes on return"] = function()
  start({ animate = true })
  wait_start_screen(START)
  child:lua("vim.api.nvim_exec_autocmds('FocusLost', {}); vim.cmd.redraw()")
  eq(wave_changed(wave_rows(child:screen()), 600), false)
  child:lua("vim.api.nvim_exec_autocmds('FocusGained', {}); vim.cmd.redraw()")
  eq(wave_changed(wave_rows(child:screen()), 2500), true)
end

T["resize events with unchanged geometry keep the buffer"] = function()
  start({ animate = true })
  wait_start_screen(START)
  local tick = child:lua("return vim.b.changedtick")
  child:lua([[
      vim.api.nvim_exec_autocmds("WinResized", { group = "IaraStart" })
      vim.api.nvim_exec_autocmds("VimResized", { group = "IaraStart" })
    ]])
  eq(child:lua("return vim.b.changedtick"), tick)
end

T["a start screen key runs its action"] = function()
  start()
  child:wait_screen(START)
  child:input("w")
  eq(
    wait_for(function(c)
      return c:lua("return vim.g.ran") == "IaraGrep"
    end),
    true
  )
end

T["j and k move the cursor bar and Enter runs the action"] = function()
  start()
  local screen = wait_start_screen(START)
  eq(has(row_with(screen, "Find files"), BAR), true)
  eq(has(row_with(screen, "Find in files"), BAR), false)
  -- k on the first row stays there.
  child:input("k")
  child:input("j")
  wait_for(function(c)
    return has(row_with(c:screen(), "Find in files"), BAR)
  end)
  screen = child:screen()
  eq(has(row_with(screen, "Find in files"), BAR), true)
  eq(has(row_with(screen, "Find files"), BAR), false)
  local _, row = row_with(screen, "Find in files")
  eq(child:lua("return vim.api.nvim_win_get_cursor(0)[1]"), row)
  child:input("<CR>")
  eq(
    wait_for(function(c)
      return c:lua("return vim.g.ran") == "IaraGrep"
    end),
    true
  )
end

---A project with seven readable files, and `v:oldfiles` mixing them with
---a missing file, a directory, and a file outside the project.
local function recent_setup()
  local dir = project({ [".git/HEAD"] = "ref: refs/heads/main\n" })
  local outside = project({ ["x.lua"] = "" })
  local names = { "a.lua", "b.md", "c.lua", "d.lua", "e.lua", "f.lua" }
  for _, name in ipairs(names) do
    helpers.write_file(dir .. "/src/" .. name, name .. "\n")
  end
  vim.fn.mkdir(dir .. "/src/sub", "p")
  local oldfiles = {
    dir .. "/src/a.lua",
    dir .. "/gone.lua",
    outside .. "/x.lua",
    dir .. "/src/sub",
  }
  for index = 2, #names do
    table.insert(oldfiles, dir .. "/src/" .. names[index])
  end
  return dir, oldfiles
end

T["the wave stays aligned with actions and recent files on resize"] = function()
  local dir, oldfiles = recent_setup()
  start({ cwd = dir, oldfiles = oldfiles, height = 52 })
  local screen = child:wait_screen("∿")
  local left, right = menu_bounds(screen)
  eq(wave_bounds(screen), { left, right, 15 })
  eq(has(screen, "src/e.lua"), true)
  eq(has(screen, "Quit"), true)
  snapshot("start-full-wave", screen)

  child:resize(40, 52)
  wait_for(function(c)
    return wave_bounds(c:screen())[3] == 6
  end)
  screen = child:screen()
  left, right = menu_bounds(screen)
  eq({ left, right }, { 1, 39 })
  eq(wave_bounds(screen), { left, right, 6 })
  local recent = row_with(screen, "Recent in")
  eq(vim.fn.strwidth((recent:gsub(" *$", ""))), right)
  eq(has(screen, "src/e.lua"), true)

  child:resize(26, 52)
  wait_for(function(c)
    local narrow = c:screen()
    return wave_bounds(narrow)[3] == 0 and not has(narrow, TAGLINE)
  end)
  eq(has(child:screen(), "Quit"), true)
end

T["recent project files are listed and digits open them"] = function()
  local dir, oldfiles = recent_setup()
  start({ cwd = dir, oldfiles = oldfiles })
  local screen = wait_start_screen("Recent in")
  snapshot("start-recent", screen)
  eq(has(screen, "Recent in " .. vim.fs.basename(dir)), true)
  local expected = { "a.lua", "b.md", "c.lua", "d.lua", "e.lua" }
  for index, name in ipairs(expected) do
    local line = vim.trim(row_with(screen, "src/" .. name) or "")
    eq({ name, line:sub(-#tostring(index)) }, { name, tostring(index) })
  end
  for _, absent in ipairs({ "gone.lua", "x.lua", "src/sub", "f.lua" }) do
    eq({ absent, has(screen, absent) }, { absent, false })
  end
  child:input("2")
  eq(
    wait_for(function(c)
      return c:lua("return vim.api.nvim_buf_get_name(0)") == dir .. "/src/b.md"
    end),
    true
  )
  eq(child:lua("return require('iara.core.start').buffer()"), vim.NIL)
end

T["wide rule glyphs keep the recent section within the menu"] = function()
  local dir, oldfiles = recent_setup()
  start({
    cwd = dir,
    oldfiles = oldfiles,
    before = "vim.fn.setcellwidths({ { 0x2500, 0x2500, 2 } })",
  })
  wait_start_screen("Recent in")
  local widths = child:lua([[
    local widths = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      local action = line:find("Find files", 1, true)
      local recent = line:find("Recent in", 1, true)
      if action or recent then
        widths[#widths + 1] = vim.api.nvim_strwidth(line)
      end
    end
    return widths
  ]])
  local right = (WIDTH + 50) / 2
  eq(widths, { right, right })
end

T["Enter on a recent file opens it"] = function()
  local dir, oldfiles = recent_setup()
  start({ cwd = dir, oldfiles = oldfiles })
  child:wait_screen("Recent in")
  child:input("G")
  wait_for(function(c)
    return has(row_with(c:screen(), "src/e.lua") or "", BAR)
  end)
  child:input("<CR>")
  eq(
    wait_for(function(c)
      return c:lua("return vim.api.nvim_buf_get_name(0)") == dir .. "/src/e.lua"
    end),
    true
  )
end

T["the footer leaves out a detached branch"] = function()
  local dir = project({ [".git/HEAD"] = ("0"):rep(40) .. "\n" })
  start({ cwd = dir })
  local screen = wait_start_screen(START)
  local footer = vim.trim(row_with(screen, "∿"))
  eq(
    vim.startswith(footer, "∿  " .. vim.fs.basename(dir) .. "  ·  nvim "),
    true
  )
end

T["small screens drop the recent files, then the tagline"] = function()
  local dir, oldfiles = recent_setup()
  local opts = { cwd = dir, oldfiles = oldfiles, theme_command = true }
  start(vim.tbl_extend("force", opts, { width = 80, height = 23 }))
  local screen = child:wait_screen("∿")
  snapshot("start-80x23", screen)
  eq(has(screen, "Recent in"), false)
  eq(has(screen, TAGLINE), true)
  local _, top = row_with(screen, wave_rows(screen)[1])
  eq(wave_bounds(screen), { 15, 65, 6 })
  local _, bottom = row_with(screen, "∿")
  -- Centered vertically in the 21-row window: equal margins, +-1.
  eq(math.abs((top - 1) - (21 - bottom)) <= 1, true)
  -- Shorter: the tagline goes; the selection survives the redraw.
  child:input("jjjj")
  wait_for(function(c)
    return has(row_with(c:screen(), "Terminal") or "", BAR)
  end)
  child:resize(80, 16)
  wait_for(function(c)
    return wave_bounds(c:screen())[3] == 3
  end)
  screen = child:screen()
  eq(wave_bounds(screen), { 15, 65, 3 })
  eq(has(screen, TAGLINE), false)
  eq(has(screen, "Quit"), true)
  eq(has(row_with(screen, "Terminal"), BAR), true)
  child:resize(80, 13)
  wait_for(function(c)
    return wave_bounds(c:screen())[3] == 0
  end)
  eq(has(child:screen(), "Quit"), true)
  eq(has(row_with(child:screen(), "Terminal"), BAR), true)
end

-- Start groups, the surface their text is drawn on (a role, or the
-- group's own background), and the minimum: text 4.5:1, glyphs 3:1.
local START_CONTRAST = {
  { "IaraStartText", "base", 4.5 },
  { "IaraStartAction", "base", 4.5 },
  { "IaraStartAction", "overlay", 4.5 },
  { "IaraStartFile", "base", 4.5 },
  { "IaraStartFile", "overlay", 4.5 },
  { "IaraStartSection", "base", 4.5 },
  { "IaraStartFooter", "base", 4.5 },
  { "IaraStartKey", "own", 4.5 },
  { "IaraStartIcon", "overlay", 3 },
  { "IaraStartFileIcon", "overlay", 3 },
  { "IaraStartBar", "own", 3 },
  { "IaraStartMark", "base", 3 },
  { "IaraStartWaveTide", "base", 3 },
  { "IaraStartWaveMid", "base", 3 },
  { "IaraStartWaveFoam", "base", 3 },
}

T["start groups are readable in every palette"] = function()
  local theme = require("iara.theme")
  local hl = require("iara.theme.highlights")
  local roles = require("iara.theme.roles")
  local low = {}
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, role = hl.resolve(palette), roles.resolve(palette)
    for _, entry in ipairs(START_CONTRAST) do
      local spec = groups[entry[1]]
      local bg = entry[2] == "own" and spec.bg or role[entry[2]]
      if hl.contrast(spec.fg, bg) < entry[3] then
        table.insert(low, ("%s %s on %s"):format(name, entry[1], entry[2]))
      end
    end
  end
  eq(low, {})
end

---A checkout of a locked plugin for an embedded UI test.
local function pinned_plugin(repo)
  local name = vim.fs.basename(repo)
  local entry = lazy_fixture.release_entry(name)
  local dir = helpers.temp_dir() .. "/" .. name
  local mirror = lazy_fixture.url_format():format(repo)
  lazy_fixture.git({ "clone", "--quiet", mirror, dir })
  lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
  return dir
end

local REAL_WHICH_KEY = [[
vim.opt.runtimepath:prepend(%q)
vim.g.mapleader = " "
vim.keymap.set("n", "<leader>ff", "<Nop>", { desc = "Find files shortcut" })
local spec = require("iara.plugins.which_key")
spec.config(nil, spec.opts)
]]

T["the wave redraws while Which-key waits for another key"] = function()
  local dir = pinned_plugin("folke/which-key.nvim")
  start({ animate = true, before = REAL_WHICH_KEY:format(dir) })
  wait_start_screen(START)
  child:input(":WhichKey<CR>")
  local hint = "Esc close"
  eq(has(child:wait_screen(hint), hint), true)
  local previous = wave_rows(child:screen())
  local frames = 0
  local advanced = vim.wait(1000, function()
    local screen = child:screen()
    local wave = wave_rows(screen)
    if has(screen, hint) and not vim.deep_equal(wave, previous) then
      frames = frames + 1
      previous = wave
    end
    return frames >= 3
  end, 10)
  child:input("<Esc>")
  eq(advanced, true)
  eq(
    wait_for(function(c)
      return not has(c:screen(), hint)
    end),
    true
  )
end

-- Defines the real :IaraFiles over the pinned snacks.nvim.
local REAL_FILES = [[
vim.opt.runtimepath:prepend(%q)
vim.api.nvim_create_user_command("IaraFiles", function()
  require("iara.features.search").open({ mode = "files" })
end, {})
]]

-- Windows of the current tab page: file name (tail) of each normal
-- buffer, and whether any window still shows the start screen.
local WINDOWS = [[
local files, start = {}, false
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local buf = vim.api.nvim_win_get_buf(win)
  start = start or vim.bo[buf].filetype == "iara-start"
  if vim.bo[buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(buf)
    table.insert(files, vim.fn.fnamemodify(name, ":t"))
  end
end
table.sort(files)
return { files = files, start = start }
]]

---From the start screen, open Find files, type `query`, press `keys`,
---and wait until the start buffer is gone; return the windows.
local function open_from_find_files(query, keys)
  local dir = project({
    [".git/HEAD"] = "ref: refs/heads/main\n",
    ["src/target.lua"] = "local target = true\n",
    ["src/target_two.lua"] = "local two = true\n",
  })
  local snacks = pinned_plugin("folke/snacks.nvim")
  start({ cwd = dir, before = REAL_FILES:format(snacks) })
  child:wait_screen(START)
  local start_buf = child:lua("return vim.api.nvim_get_current_buf()")
  child:input("f")
  child:wait_screen("Find files")
  child:input(query)
  child:wait_screen("src/target_two.lua")
  child:input(keys)
  child:wait_screen("local target = true")
  wait_for(function(c)
    local valid = "return vim.api.nvim_buf_is_valid(...)"
    return c:lua(valid, { start_buf }) == false
  end)
  return child:lua(WINDOWS)
end

T["a file opened from Find files replaces the start screen"] = function()
  eq(open_from_find_files("target", "<CR>"), {
    files = { "target.lua" },
    start = false,
  })
end

T["files sent to the quickfix list leave no start screen split"] = function()
  -- Two selected files open as a quickfix list, whose `:cfirst` cannot
  -- use the start screen's window and splits a new one.
  local windows = open_from_find_files("target", "<Tab><Tab><CR>")
  eq(windows, { files = { "target.lua" }, start = false })
end

T["a file opened in another window closes the start screen"] = function()
  start()
  child:wait_screen(START)
  child:lua("vim.cmd('botright split ' .. vim.fn.fnameescape(...))", {
    lua_file(),
  })
  wait_for(function(c)
    return c:lua(WINDOWS).start == false
  end)
  eq(child:lua(WINDOWS), { files = { "init.lua" }, start = false })
end

T["opening a file closes the start screen"] = function()
  start()
  child:wait_screen(START)
  local start_buf = child:lua("return vim.api.nvim_get_current_buf()")
  child:lua("vim.cmd.edit(...)", { lua_file() })
  local screen = child:wait_screen("local M = {}")
  eq(has(screen, START), false)
  eq(child:lua("return vim.api.nvim_buf_is_valid(...)", { start_buf }), false)
  -- The window options are the usual ones again.
  eq(child:lua("return vim.wo.number"), true)
  eq(child:lua("return vim.wo.signcolumn"), "yes")
end

T["typing i starts editing a new buffer"] = function()
  start()
  child:wait_screen(START)
  child:input("iZ")
  eq(
    wait_for(function(c)
      return c:lua("return vim.api.nvim_get_current_line()") == "Z"
    end),
    true
  )
  eq(child:lua("return vim.api.nvim_get_mode().mode"), "i")
  eq(has(child:screen(), START), false)
  eq(child:lua("return vim.bo.filetype"), "")
end

T["a file argument opens the file without the start screen"] = function()
  start({ file = lua_file(), animate = true })
  local screen = wait_file_screen()
  eq(has(screen, START), false)
  -- Nothing of the screen ran: no autocmds, no buffer, no project lookup.
  eq(child:lua("return vim.fn.exists('#IaraStartup')"), 0)
  eq(child:lua("return package.loaded['iara.core.start_motion']"), vim.NIL)
  eq(child:lua("return vim.fn.exists('#IaraStart')"), 0)
  eq(child:lua("return require('iara.core.start').buffer()"), vim.NIL)
  local status = rows(screen)[HEIGHT - 1]
  eq(has(status, " NORMAL "), true)
  eq(has(status, "init.lua"), true)
  snapshot("file-dark", screen)
end

T["a light theme draws the same status line"] = function()
  start({ file = lua_file(), theme = "github_light" })
  local screen = wait_file_screen()
  eq(child:lua("return vim.o.background"), "light")
  eq(has(rows(screen)[HEIGHT - 1], "init.lua"), true)
  snapshot("file-light", screen)
end

return T
