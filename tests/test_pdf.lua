local helpers = require("helpers")
local eq = MiniTest.expect.equality
local child = helpers.new_child()
local file, log

local function executable(path, body)
  helpers.write_file(path, "#!/bin/sh\nset -eu\n" .. body)
  assert(vim.uv.fs_chmod(path, 493))
end

local function setup()
  local dir = helpers.temp_dir()
  file = dir .. "/sample 100%.PDF"
  log = dir .. "/pages.log"
  helpers.write_file(file, "%PDF fixture")
  executable(
    dir .. "/pdfinfo",
    [[
test "$3" = "$IARA_TEST_PDF"
printf 'Title: Fixture\nPages: %s\n' "${IARA_TEST_PDF_PAGES:-3}"
]]
  )
  executable(
    dir .. "/pdftotext",
    [[
test "$6" = "$IARA_TEST_PDF"
printf '%s\n' "$2" >>"$IARA_TEST_PDF_LOG"
if [ "$2" = 2 ] && [ "${IARA_TEST_PDF_SLOW:-}" = yes ]; then sleep 5; fi
printf 'Text of page %s\n\f' "$2"
]]
  )
  child.restart({ "-u", helpers.minimal_init })
  child.lua(
    [[
    local dir, file, log = ...
    vim.env.PATH = dir .. ":" .. vim.env.PATH
    vim.env.IARA_TEST_PDF = file
    vim.env.IARA_TEST_PDF_LOG = log
    require("iara.features.pdf").setup()
  ]],
    { dir, file, log }
  )
end

local function lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function wait_page(page)
  local text = "Text of page " .. page
  eq(
    vim.wait(5000, function()
      return vim.tbl_contains(lines(), text)
    end, 20),
    true
  )
end

local function open()
  child.lua("vim.cmd('IaraPDF ' .. vim.fn.fnameescape(...))", { file })
end

local T = MiniTest.new_set({
  hooks = { pre_case = setup, post_once = child.stop },
})

T["IaraPDF opens the exact path and navigates a read-only copy"] = function()
  eq(child.lua_get("package.loaded['iara.features.pdf.view'] == nil"), true)
  open()
  wait_page(1)
  local buf = child.api.nvim_get_current_buf()
  eq(child.api.nvim_buf_get_name(buf), file)
  eq(child.bo.filetype, "iara-pdf")
  eq(child.bo.modifiable, false)
  child.type_keys("2j")
  wait_page(3)
  child.type_keys("j")
  eq(vim.fn.readfile(log), { "1", "3" })
  child.type_keys("gg")
  wait_page(1)
  child.type_keys("q")
  eq(child.api.nvim_buf_is_valid(buf), false)
  eq(vim.fn.readfile(file), { "%PDF fixture" })
end

T["the file picker opens PDFs and page changes cancel renders"] = function()
  child.lua(
    [[
    vim.env.IARA_TEST_PDF_SLOW = "yes"
    require("iara.features.picker.open").jump({ path = ... })
  ]],
    { file }
  )
  wait_page(1)
  child.type_keys("j")
  eq(
    vim.wait(2000, function()
      return #vim.fn.readfile(log) == 2
    end, 20),
    true
  )
  child.type_keys("j")
  wait_page(3)
  eq(vim.fn.readfile(log), { "1", "2", "3" })
end

T["jumps to a numbered text page by prompt or count"] = function()
  open()
  wait_page(1)
  child.lua([[
    vim.ui.input = function(_, callback) _G.answer_page = callback end
  ]])
  child.type_keys("gp")
  child.lua([[_G.answer_page(" 2 ")]])
  wait_page(2)
  child.type_keys("G")
  wait_page(3)
  child.type_keys("2G")
  wait_page(2)
  child.type_keys("gp")
  child.lua([[_G.answer_page(nil)]])
  wait_page(2)
  eq(vim.fn.readfile(log), { "1", "2", "3", "2" })
end

local function mock_poppler()
  executable(
    vim.fs.dirname(file) .. "/pdftoppm",
    [[
format=ppm
if [ "$5" = "-png" ]; then format=png; fi
prefix=
progress=no
for arg do
  path=$prefix
  prefix=$arg
  if [ "$arg" = -progress ]; then progress=yes; fi
done
test "$path" = "$IARA_TEST_PDF"
printf '%s %s\n' "$2" "$4" >>"$(dirname "$path")/renders.log"
if [ "$2" = "$4" ]; then
  printf '%s' "$2" >"$prefix.$format"
else
  if [ "${IARA_TEST_PDF_SLOW_BATCH:-}" = yes ]; then sleep 5; fi
  for page in $(seq "$2" "$4"); do
    if [ "${IARA_TEST_PDF_STREAM_BATCH:-}" = yes ]; then
      for attempt in $(seq 1 200); do
        if [ -f "$(dirname "$path")/release-$page" ]; then break; fi
        sleep .02
      done
    fi
    target="$prefix-$page.$format"
    printf '%s' "$page" >"$target"
    if [ "$progress" = yes ]; then
      printf '%s %s %s\n' "$page" "$4" "$target" >&2
    fi
  done
fi
]]
  )
end

local function mock_graphics()
  mock_poppler()
  child.lua([[
    local graphics = require("iara.features.pdf.graphics")
    graphics.available = function() return true end
    graphics.size = function()
      return { cell_height = 20, cell_width = 10 }
    end
    _G.drawings, _G.preview_tops, _G.paint_controls = {}, {}, {}
    graphics.picture = function(path, win, _, rect)
      local key = ("%d:%s"):format(win, vim.fs.basename(path))
      _G.drawings[key] = {
        path = path, win = win, rect = {
          x = rect.x, width = rect.width, visible = rect.visible_width,
          offset = rect.offset,
          scrollbar = rect.scrollbar and rect.scrollbar(),
        },
      }
      _G.preview_tops[key] = rect.topline
      _G.paint_controls[key] = { bar = rect.scrollbar, ready = rect.on_ready }
      return { clear = function()
        _G.drawings[key], _G.preview_tops[key] = nil, nil
        _G.paint_controls[key] = nil
      end }
    end
    vim.o.laststatus = 3
  ]])
end

local function drawings()
  return child.lua_get("vim.tbl_values(_G.drawings)")
end

local function wait_drawings(predicate)
  eq(
    vim.wait(5000, function()
      return predicate(drawings())
    end, 20),
    true
  )
end

local graphical = MiniTest.new_set({ hooks = { pre_case = mock_graphics } })
T["graphics"] = graphical

graphical["the page prompt targets the original PDF split"] = function()
  child.lua([[require("iara.features.pdf.graphics").virtual_scroll =
    function() return true end]])
  open()
  local origin = child.api.nvim_get_current_win()
  child.cmd("vsplit")
  local other = child.api.nvim_get_current_win()
  wait_drawings(function(items)
    return #items == 2
  end)
  child.api.nvim_set_current_win(origin)
  child.lua([[
    vim.ui.input = function(_, callback) _G.answer_page = callback end
  ]])
  child.type_keys("gp")
  child.api.nvim_set_current_win(other)
  child.lua([[_G.answer_page("3")]])
  wait_drawings(function()
    return child.lua_get("vim.w[...].iara_pdf_page", { origin }) == " 3/3 "
  end)
  eq(child.lua_get("vim.w.iara_pdf_page"), " 1/3 ")
end

graphical["reuses page one and batches adjacent pages while idle"] = function()
  child.lua(
    [[
    local path = ...
    local cache = require("iara.features.pdf.raster_cache")
    local dir = require("iara.features.pdf.source").directory()
    local first = dir .. "/thumb.png"
    vim.fn.writefile({"cached"}, first)
    local key = cache.identity(path, "png")
    cache.release(cache.remember(key, dir, first, 2048, 7))
  ]],
    { file }
  )
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  eq(vim.fn.readfile(drawings()[1].path), { "cached" })
  local renders = vim.fs.dirname(file) .. "/renders.log"
  eq(
    vim.wait(3000, function()
      return vim.fn.filereadable(renders) == 1
    end, 20),
    true
  )
  eq(vim.fn.readfile(renders), { "2 3" })
  child.type_keys("q")
  helpers.write_file(file, "%PDF changed")
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  eq(vim.fn.readfile(drawings()[1].path), { "1" })
  eq(vim.fn.readfile(renders)[2], "1 1")
end

graphical["a visible page supersedes a running Poppler batch"] = function()
  child.lua([[vim.env.IARA_TEST_PDF_SLOW_BATCH = "yes"]])
  open()
  local renders = vim.fs.dirname(file) .. "/renders.log"
  eq(
    vim.wait(3000, function()
      return vim.fn.filereadable(renders) == 1 and #vim.fn.readfile(renders) > 1
    end, 20),
    true
  )
  eq(vim.fn.readfile(renders), { "1 1", "2 3" })
  child.type_keys("]p")
  wait_drawings(function(items)
    for _, item in ipairs(items) do
      if vim.fs.basename(item.path):match("^page%-2%-") then
        return true
      end
    end
  end)
  eq(vim.fn.readfile(renders)[3], "2 2")
end

graphical["Foot uses the next page before the batch finishes"] = function()
  child.lua([[
    vim.env.IARA_TEST_PDF_STREAM_BATCH = "yes"
    require("iara.features.pdf.graphics").virtual_scroll = function()
      return true
    end
  ]])
  open()
  local dir = vim.fs.dirname(file)
  local renders = dir .. "/renders.log"
  eq(
    vim.wait(3000, function()
      return vim.fn.filereadable(renders) == 1 and #vim.fn.readfile(renders) > 1
    end, 20),
    true
  )
  child.type_keys("]p")
  helpers.write_file(dir .. "/release-2", "ready")
  wait_drawings(function(items)
    for _, item in ipairs(items) do
      if vim.fs.basename(item.path):match("^page%-2%-") then
        return true
      end
    end
  end)
  eq(vim.fn.readfile(renders), { "1 1", "2 3" })
  eq(child.lua_get("vim.w.iara_pdf_page"), " 2/3 ")
  helpers.write_file(dir .. "/release-3", "ready")
end

graphical["scrolling batches pages when the next one is ready"] = function()
  child.lua([[
    vim.env.IARA_TEST_PDF_PAGES = "8"
    require("iara.features.pdf.graphics").virtual_scroll = function()
      return true
    end
  ]])
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  local dir = vim.fs.dirname(drawings()[1].path)
  eq(
    vim.wait(3000, function()
      return vim.fn.glob(dir .. "/page-4-*.ppm") ~= ""
    end, 10),
    true
  )
  child.lua([[
    local rows = vim.api.nvim_win_get_height(0) - 1
    vim.api.nvim_input("5j")
    vim.defer_fn(function() vim.api.nvim_input(rows .. "j") end, 45)
  ]])
  local renders = vim.fs.dirname(file) .. "/renders.log"
  eq(
    vim.wait(3000, function()
      return #vim.fn.readfile(renders) >= 3
    end, 10),
    true
  )
  eq(vim.list_slice(vim.fn.readfile(renders), 1, 3), { "1 1", "2 4", "5 6" })
end

graphical["scrolls across pages and reuses rasters"] = function()
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  local first = drawings()[1].path
  child.type_keys("5j")
  wait_drawings(function(items)
    return #items == 2
  end)
  eq(child.fn.line("w0"), 6)
  eq(child.lua_get("vim.w.iara_pdf_page"), " 1/3 ")
  eq(lines()[1]:match("%S"), nil)
  child.type_keys("]p")
  eq(child.lua_get("vim.w.iara_pdf_page"), " 2/3 ")
  eq(vim.fn.filereadable(first), 1)
  child.type_keys("q")
  eq(vim.fn.isdirectory(vim.fs.dirname(first)), 0)
end

graphical["keeps the scroll position when switching buffers"] = function()
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  local buf = child.api.nvim_get_current_buf()
  child.type_keys("5j")
  child.cmd("enew")
  wait_drawings(function(items)
    return #items == 0
  end)
  eq(child.api.nvim_buf_is_loaded(buf), true)
  child.cmd("buffer " .. buf)
  wait_drawings(function(items)
    return #items == 2
  end)
  eq(child.fn.line("w0"), 6)
end

graphical["centers each split and restores images after a float"] = function()
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  child.cmd("vsplit")
  wait_drawings(function(items)
    return #items == 2 and items[1].win ~= items[2].win
  end)
  for _, item in ipairs(drawings()) do
    local width = child.api.nvim_win_get_width(item.win)
    eq(item.rect.x, math.floor((width - item.rect.width) / 2))
  end
  local pdf_win = child.api.nvim_get_current_win()
  child.lua([[
    _G.overlay = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true),
      true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
  ]])
  wait_drawings(function(items)
    return #items == 0
  end)
  child.api.nvim_set_current_win(pdf_win)
  eq(#drawings(), 0)
  child.lua("vim.api.nvim_win_close(_G.overlay, true)")
  wait_drawings(function(items)
    return #items == 2
  end)
end

graphical["Sixel scroll and zoom leave the editor grid still"] = function()
  child.lua([[
    require("iara.features.pdf.graphics").virtual_scroll = function()
      return true
    end
    _G.pdf_top = function()
      local _, read = next(_G.preview_tops)
      return read and read()
    end
  ]])
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  local width = drawings()[1].rect.width
  child.type_keys("4j")
  eq(
    vim.wait(1000, function()
      return child.lua_get("pdf_top()") == 5
    end, 10),
    true
  )
  eq(child.fn.line("w0"), 1)
  eq(child.api.nvim_buf_line_count(0), 1)
  child.type_keys("+")
  wait_drawings(function(items)
    return #items == 1 and items[1].rect.width > width
  end)
  eq(child.lua_get("pdf_top()"), 6)
  child.type_keys("0")
  wait_drawings(function(items)
    return #items >= 1 and items[1].rect.width == width
  end)
  eq(child.lua_get("pdf_top()"), 5)
  eq(child.fn.line("w0"), 1)
end

local function detail_path()
  for _, item in ipairs(drawings()) do
    if vim.fs.basename(item.path):match("^detail%-") then
      return item.path
    end
  end
end

graphical["large zoom reuses a native crop during a short scroll"] = function()
  child.o.lines = 45
  child.lua([[
    require("iara.features.pdf.graphics").virtual_scroll =
      function() return true end
  ]])
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  child.type_keys("99+")
  wait_drawings(detail_path)
  local first_crop = detail_path()
  child.type_keys("j")
  wait_drawings(function()
    return child.lua_get([[select(2, next(_G.preview_tops))() == 2]])
  end)
  eq(detail_path(), first_crop)
  child.type_keys("999h")
  wait_drawings(function()
    local path = detail_path()
    return path and path ~= first_crop
  end)
  eq(vim.fn.filereadable(first_crop), 1)
  local second_crop = detail_path()
  child.type_keys("0")
  wait_drawings(function()
    return #drawings() > 0 and not detail_path()
  end)
  eq(vim.fn.filereadable(second_crop), 1)
  child.type_keys("99+")
  wait_drawings(function()
    return detail_path() == first_crop
  end)
  child.type_keys("q")
  eq(vim.fn.filereadable(first_crop), 0)
  eq(vim.fn.filereadable(second_crop), 0)
end

local function second_page_row()
  return child.lua_get([[(function()
    local layout = require("iara.features.pdf.layout")
    local cols = vim.api.nvim_win_get_width(0)
    local rows = vim.api.nvim_win_get_height(0) - 3
    local info = { count = 3, ratios = {} }
    local pages = layout.arrange(info, cols, rows, 600, true)
    return pages[2].row
  end)()]])
end

graphical["high zoom warms the next page before settling there"] = function()
  child.o.lines = 45
  child.lua([[
    require("iara.features.pdf.graphics").virtual_scroll =
      function() return true end
  ]])
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  child.type_keys("99+")
  wait_drawings(detail_path)
  local current = detail_path()
  local ahead = vim.fs.joinpath(vim.fs.dirname(current), "detail-2.ppm")
  local page_two = second_page_row()
  local near = page_two - child.api.nvim_win_get_height(0) - 3
  child.type_keys((near - 1) .. "j")
  eq(
    vim.wait(1000, function()
      return vim.fn.filereadable(ahead) == 1
    end, 10),
    true
  )
  eq(detail_path(), nil)
  child.type_keys((page_two - near) .. "j")
  wait_drawings(function()
    return detail_path() == ahead
  end)
end

T["retired PDF crops stay within the byte budget"] = function()
  local result = child.lua([[
    local source = require("iara.features.pdf.source")
    local detail = require("iara.features.pdf.detail")
    local dir = assert(source.directory())
    local state = detail.new("input.pdf", dir, function() end)
    source.crop = function(_, _, prefix, _, done)
      local path = prefix .. ".ppm"
      vim.fn.writefile({ "crop" }, path)
      vim.schedule(function() done(path, nil, 16 * 1024 * 1024) end)
      return { cancel = function() end }
    end
    local pane = {}
    local slot = { row = 1, width = 100, visible_width = 80, height = 400 }
    local screen = {
      top = 1, rows = 30, settled = true,
      cell = { cell_width = 10, cell_height = 20 },
    }
    for page = 1, 2 do
      detail.picture(state, pane, page, slot, screen)
      assert(vim.wait(500, function() return state.work == nil end, 5))
      detail.prune(state, pane)
    end
    local counts = {
      #state.cache, state.bytes, vim.fn.filereadable(dir .. "/detail-1.ppm"),
      vim.fn.filereadable(dir .. "/detail-2.ppm"),
    }
    detail.close(state, { pane })
    vim.fn.delete(dir, "rf")
    return counts
  ]])
  eq(result, { 1, 16 * 1024 * 1024, 0, 1 })
end

graphical["quick pairs keep PDF scrolling fast until a pause"] = function()
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  child.type_keys("jj")
  eq(child.fn.line("w0"), 3)
  child.lua([[
    vim.defer_fn(function() vim.api.nvim_input("j") end, 350)
  ]])
  wait_drawings(function()
    return child.fn.line("w0") == 7
  end)
  child.type_keys("j")
  eq(child.fn.line("w0"), 11)
  child.lua([[
    vim.defer_fn(function() vim.api.nvim_input("j") end, 350)
  ]])
  wait_drawings(function()
    return child.fn.line("w0") == 12
  end)
  child.type_keys("kk")
  eq(child.fn.line("w0"), 10)
  child.lua([[
    vim.defer_fn(function() vim.api.nvim_input("k") end, 350)
  ]])
  wait_drawings(function()
    return child.fn.line("w0") == 6
  end)
  child.type_keys("k")
  eq(child.fn.line("w0"), 2)
  child.type_keys("3j")
  eq(child.fn.line("w0"), 5)
end

graphical["holding a PDF scroll key keeps the normal repeat step"] = function()
  child.lua([[
    require("iara.features.pdf.graphics").virtual_scroll = function()
      return true
    end
    _G.pdf_top = function()
      local _, read = next(_G.preview_tops)
      return read and read()
    end
  ]])
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  child.type_keys("j")
  wait_drawings(function()
    return child.lua_get("pdf_top()") == 2
  end)
  child.lua([[
    vim.defer_fn(function() vim.api.nvim_input("jjjj") end, 350)
  ]])
  wait_drawings(function()
    return child.lua_get("pdf_top()") == 6
  end)
  child.type_keys("kk")
  wait_drawings(function()
    return child.lua_get("pdf_top()") == 4
  end)
end

graphical["early autorepeat stays at the normal PDF speed"] = function()
  open()
  wait_drawings(function(items)
    return #items == 1
  end)
  child.type_keys("j")
  eq(child.fn.line("w0"), 2)
  child.lua([[
    for i = 0, 3 do
      vim.defer_fn(function() vim.api.nvim_input("j") end, 70 + 30 * i)
    end
    vim.defer_fn(function() _G.repeat_complete = true end, 200)
  ]])
  wait_drawings(function()
    return child.lua_get("_G.repeat_complete == true")
  end)
  eq(child.fn.line("w0"), 6)
end

local function wait_frames(count)
  eq(
    vim.wait(1000, function()
      return child.lua_get("_G.frames") == count
    end, 10),
    true
  )
end

local function split_sizes()
  local widths = {}
  for _, drawing in ipairs(drawings()) do
    widths[drawing.win] = drawing.rect.width
  end
  return widths
end

graphical["PDF zoom and its limits belong to the focused split"] = function()
  child.lua([[require("iara.features.pdf.graphics").virtual_scroll =
    function() return true end]])
  open()
  child.cmd("rightbelow vsplit")
  child.cmd("aboveleft split")
  wait_drawings(function(items)
    return #items == 3
  end)
  local focus = child.api.nvim_get_current_win()
  local base = split_sizes()
  local other = next(base, focus) or next(base)
  child.type_keys("99+")
  wait_drawings(function(items)
    return #items >= 2 and split_sizes()[focus] > base[focus]
  end)
  local maximum = split_sizes()[focus]
  eq(maximum <= 6 * child.api.nvim_win_get_width(focus), true)
  eq(maximum > 3 * base[focus], true)
  for _, drawing in ipairs(drawings()) do
    local width = child.api.nvim_win_get_width(drawing.win)
    eq(drawing.rect.x + drawing.rect.visible <= width, true)
  end
  eq(split_sizes()[other], base[other])
  child.type_keys("99+")
  eq(split_sizes()[focus], maximum)
  child.api.nvim_set_current_win(other)
  child.type_keys("2-")
  wait_drawings(function(items)
    return #items >= 2 and split_sizes()[other] < base[other]
  end)
  eq(split_sizes()[focus], maximum)
  child.type_keys("0")
  wait_drawings(function(items)
    return #items >= 2 and split_sizes()[other] == base[other]
  end)
  eq(split_sizes()[focus], maximum)
end

local function drawing_in(win)
  for _, drawing in ipairs(drawings()) do
    if drawing.win == win then
      return drawing.rect
    end
  end
end

graphical["the thumb tracks input while a crop finishes"] = function()
  child.lua([[require("iara.features.pdf.graphics").virtual_scroll =
    function() return true end]])
  open()
  local win = child.api.nvim_get_current_win()
  wait_drawings(function(items)
    return #items > 0
  end)
  child.type_keys("99+")
  wait_drawings(function()
    return drawing_in(win) and drawing_in(win).scrollbar
  end)
  local offset = drawing_in(win).offset
  child.lua([[require("iara.features.pdf.graphics").ready =
    function() return false end]])
  child.type_keys("999h")
  eq(
    vim.wait(1000, function()
      return child.lua_get([[select(2, next(_G.paint_controls)).bar().start]])
        == 0
    end, 10),
    true
  )
  eq(drawing_in(win).offset, offset)
  child.lua([[
    require("iara.features.pdf.graphics").ready = function() return true end
    select(2, next(_G.paint_controls)).ready()
  ]])
  wait_drawings(function()
    return drawing_in(win).offset == 0
  end)
end

graphical["h and l pan only the zoomed split within page bounds"] = function()
  child.lua([[require("iara.features.pdf.graphics").virtual_scroll =
    function() return true end]])
  open()
  child.cmd("vsplit")
  wait_drawings(function(items)
    return #items == 2
  end)
  local win = child.api.nvim_get_current_win()
  child.type_keys("99+")
  wait_drawings(function()
    return drawing_in(win) and drawing_in(win).scrollbar
  end)
  local extended = drawing_in(win)
  eq(extended.offset > 0, true)
  child.type_keys("999h")
  wait_drawings(function()
    return drawing_in(win).offset == 0
  end)
  child.type_keys("999l")
  wait_drawings(function()
    return drawing_in(win).offset == extended.width - extended.visible
  end)
  for _, drawing in ipairs(drawings()) do
    if drawing.win ~= win then
      eq(drawing.rect.offset, 0)
      eq(drawing.rect.scrollbar, nil)
    end
  end
  child.type_keys("0")
  wait_drawings(function()
    return drawing_in(win) and not drawing_in(win).scrollbar
  end)
end

T["scrollbar drag keeps its grab point and clamps"] = function()
  local scrollbar = require("iara.features.pdf.scrollbar")
  local track = scrollbar.track({ width = 100, visible_width = 40 }, 42, 0.5)
  eq({ track.x, track.start, track.thumb }, { 1, 12, 16 })
  eq(scrollbar.offset(100, 40, 0.5), 30)
  local grab, held = scrollbar.drag_offset(track, 17)
  eq({ grab, held }, { 3, true })
  eq(scrollbar.position(track, 17, grab), 0.5)
  eq(scrollbar.position(track, -10, grab), 0)
  eq(scrollbar.position(track, 90, grab), 1)
  eq(scrollbar.track({ width = 40, visible_width = 40 }, 42), nil)
end

T["Sixel repairs preview damage outside its window redraw"] = function()
  child.lua([[
    package.loaded["iara.features.pdf.sixel_cache"] = {
      want = function() end, drop = function() end,
      hold = function() end, release = function() end,
      prepare = function(_, shape)
        local height = shape.height
        return { height = height, raster = {
          width = shape.width, height = height,
          palette = "#0;2;100;100;100",
          bands = vim.split(("#0~ "):rep(height / 6), " ", {
            trimempty = true,
          }),
        } }
      end,
    }
    package.loaded["image/utils/term"] = {
      get_size = function() return { cell_width = 10, cell_height = 18 } end,
    }
    _G.frames = 0
    vim.api.nvim_ui_send = function() _G.frames = _G.frames + 1 end
    vim.api.nvim_set_decoration_provider = function(_, provider)
      _G.provider = provider
    end
    _G.sixel = require("iara.features.pdf.sixel")
    local win = vim.api.nvim_get_current_win()
    _G.sixel.picture("fake", win, 1, {
      x = 1, y = 0, width = 4, height = 3, preview = true,
    })
  ]])
  eq(child.lua_get("_G.frames"), 1)
  child.lua("for _ = 1, 3 do _G.provider.on_end() end")
  eq(child.lua_get("_G.frames"), 1)
  wait_frames(2)
  child.lua([[
    _G.provider.on_win(nil, vim.api.nvim_get_current_win())
    _G.provider.on_end()
  ]])
  eq(child.lua_get("_G.frames"), 3)
end

T["Sixel keeps the frame while the next page is pending"] = function()
  child.lua([[
    local win = vim.api.nvim_get_current_win()
    local raster = { width = 40, height = 18,
      palette = "#0;2;100;100;100", bands = { "#0~", "#0~", "#0~" } }
    local waiting, complete = { height = 18 }, { height = 18, raster = raster }
    package.loaded["iara.features.pdf.sixel_cache"] = {
      want = function() end, drop = function() end,
      hold = function() end, release = function() end,
      prepare = function(path, _, ready)
        if path == "pending" then
          _G.complete = function()
            waiting.raster = raster
            ready()
          end
          return waiting
        end
        return complete
      end,
    }
    package.loaded["image/utils/term"] = {
      get_size = function() return { cell_width = 10, cell_height = 18 } end,
    }
    vim.api.nvim_ui_send = function() _G.frames = (_G.frames or 0) + 1 end
    vim.api.nvim_set_decoration_provider = function() end
    local function picture(path, y)
      local rect = { x = 1, y = y, width = 4, height = 1 }
      return require("iara.features.pdf.sixel").picture(path, win, 1, rect)
    end
    local before = picture("before", 0)
    vim.schedule(function()
      before.clear()
      picture("ready", 0)
      picture("pending", 2)
    end)
  ]])
  eq(child.lua_get("_G.frames"), 1)
  child.lua("_G.complete()")
  eq(child.lua_get("_G.frames"), 2)
end

T["Sixel clears the terminal grid before painting after a split"] = function()
  child.lua([[
    local api = vim.api
    package.loaded["iara.features.pdf.sixel_cache"] = {
      want = function() end, drop = function() end,
      hold = function() end, release = function() end,
      prepare = function()
        return { height = 18, raster = { width = 40, height = 18,
          palette = "#0;2;100;100;100", bands = { "#0~", "#0~", "#0~" } } }
      end,
    }
    package.loaded["image/utils/term"] = {
      get_size = function() return { cell_width = 10, cell_height = 18 } end,
    }
    _G.output = {}
    local normal = vim.cmd.normal
    vim.cmd.normal = function(opts)
      table.insert(_G.output, opts.args[1])
      normal(opts)
    end
    api.nvim_ui_send = function(bytes) table.insert(_G.output, bytes) end
    api.nvim_set_decoration_provider = function() end
    _G.sixel = require("iara.features.pdf.sixel")
    _G.sixel.picture("fake", api.nvim_get_current_win(), 1, {
      x = 1, y = 0, width = 4, height = 1,
    })
  ]])
  child.lua([[
    _G.output = {}
    vim.cmd.vsplit()
    _G.sixel.refresh()
  ]])
  local events = child.lua_get("_G.output")
  eq(#events, 2)
  eq(events[1], "\12")
  eq(events[2]:find("\27P0;1;0q", 1, true) ~= nil, true)
end

local function prepare_sixel_sources(dir)
  child.lua(
    [[
    local dir = ...
    local cache = require("iara.features.pdf.sixel_cache")
    local function picture(name, first_pixel)
      local path = dir .. "/" .. name .. ".ppm"
      local f = assert(io.open(path, "wb"))
      f:write("P6\n2 1\n255\n", first_pixel, "\255\255\255")
      f:close()
      local shape = { width = 2, height = 6, page_width = 2 }
      return cache.warm(path, shape, 1, function() end)
    end
    _G.gray = picture("gray", "\0\0\0")
    _G.color = picture("color", "\255\0\0")
  ]],
    { dir }
  )
end

T["Sixel encodes grayscale and reuses color detection"] = function()
  prepare_sixel_sources(vim.fs.dirname(file))
  eq(
    vim.wait(5000, function()
      return child.lua_get("_G.gray.raster ~= nil and _G.color.raster ~= nil")
    end, 20),
    true
  )
  eq(child.lua_get("_G.gray.raster.bands"), { "#63!2~$#0~" })
  eq(child.lua_get("_G.color.raster.bands"), { "#63!2~$#214~" })
  child.lua([[
    local cache = require("iara.features.pdf.sixel_cache")
    local shape = { width = 3, height = 6, page_width = 3 }
    _G.second_crop = cache.warm(_G.color.path, shape, 1, function() end)
  ]])
  eq(
    vim.wait(5000, function()
      return child.lua_get("_G.second_crop.raster ~= nil")
    end, 20),
    true
  )
  eq(child.lua_get("_G.second_crop.gray"), false)
end

local function mock_scroll_compositor(cell_height)
  child.lua(
    [[
    local cell_height = ...
    local api = vim.api
    local raster = { width = 40, height = 720, palette = "#0;2;100;100;100",
      bands = vim.split(("#0!40~ "):rep(120), " ", { trimempty = true }) }
    package.loaded["iara.features.pdf.sixel_cache"] = {
      want = function() end, drop = function() end,
      hold = function() end, release = function() end,
      prepare = function()
        return { height = raster.height, raster = raster }
      end,
    }
    package.loaded["image/utils/term"] = {
      get_size = function()
        return { cell_width = 10, cell_height = cell_height }
      end,
    }
    api.nvim_set_decoration_provider = function() end
    api.nvim_ui_send = function(bytes) _G.last_frame = bytes end
    local sixel = require("iara.features.pdf.sixel")
    local top = 2
    _G.shift_pdf = function(delta)
      top, _G.last_frame = top + delta, ""
      sixel.refresh()
    end
    local win = api.nvim_get_current_win()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    sixel.picture("fake", win, api.nvim_get_current_buf(), {
      x = 1, y = 0, width = 4, height = 40,
      topline = function() return top end,
    })
  ]],
    { cell_height or 18 }
  )
end

local function sent(fragment)
  return child.lua(
    "local text = ...; return _G.last_frame:find(text, 1, true) ~= nil",
    { fragment }
  )
end

T["Sixel sends only the edge when the old rows match"] = function()
  mock_scroll_compositor()
  child.lua("_G.shift_pdf(2)")
  local height = child.api.nvim_win_get_height(0)
  local erase = ("\27[1;1;2;%d$z"):format(child.o.columns)
  eq(sent(erase .. ("\27[1;%dr\27[2S\27[r"):format(height)), true)
  eq(sent('q"1;1;40;36'), true)
  child.lua("_G.shift_pdf(-2)")
  eq(sent("\27[2T\27[r"), true)
  eq(sent('q"1;1;40;36'), true)
end

T["Sixel reuses pixels on repeated one-row scrolls at 31 px"] = function()
  mock_scroll_compositor(31)
  for _ = 1, 8 do
    child.lua("_G.shift_pdf(1)")
    eq(sent("\27[1S\27[r"), true)
    child.lua("_G.shift_pdf(0)")
  end
  child.lua("_G.shift_pdf(-1)")
  eq(sent("\27[1T\27[r"), true)
  eq(sent("\27P0;1;0q"), true)
end

T["Sixel sends a smaller aligned strip during downward scrolling"] = function()
  local data = require("iara.features.pdf.sixel_data")
  local scroll = require("iara.features.pdf.sixel_scroll")
  local raster = {
    width = 40,
    height = 1200,
    palette = "#0;2;100;100;100",
    bands = vim.split(("#0!40~ "):rep(200), " ", { trimempty = true }),
  }
  local function region(skip)
    local first, last = data.bounds(raster.height, skip, 560)
    local slice = {
      row = 1,
      col = 2,
      rows = 20,
      cols = 4,
      height = 560,
      cell = 28,
      skip = skip,
      frame = assert(data.capture(raster, first, last)),
    }
    return {
      row = 1,
      height = 20,
      width = 80,
      document = skip / 28 + 1,
      slices = { slice },
    }
  end
  local before, after = region(0), region(224)
  local update = assert(scroll.update(before, after))
  local slice = after.slices[1]
  local exact = assert(data.pack_rows(slice.frame, 532, 252))
  local aligned = assert(data.pack_rows(slice.frame, 504, 280))
  eq(#aligned < #exact, true)
  eq(update:find("\27[11;2H" .. aligned, 1, true) ~= nil, true)
end

T["Sixel repacks exact rows across a color band boundary"] = function()
  local data = require("iara.features.pdf.sixel_data")
  local raster = {
    width = 2,
    height = 12,
    palette = "#1;2;100;0;0#2;2;0;0;100",
    bands = { "#1!2~", "#2!2~" },
  }
  local frame = assert(data.capture(raster, 1, 2))
  eq(
    data.pack_rows(frame, 4, 5),
    '\27P0;1;0q"1;1;2;5#1;2;100;0;0#2;2;0;0;100#1!2B$#2!2[\27\\'
  )
  eq(
    data.pack_rows(frame, 0, 2),
    '\27P0;1;0q"1;1;2;2#1;2;100;0;0#2;2;0;0;100#1!2B\27\\'
  )
  eq(data.pack_rows(frame, 0, 12), (data.pack(frame, 1, 2)))
  eq(data.pack_rows(frame, 9, 4), nil)
end

T["Sixel can shift bands larger than its reusable buffer"] = function()
  local data = require("iara.features.pdf.sixel_data")
  local palette = "#1;2;100;100;100"
  local plane = "$#1" .. ("~KFD"):rep(768)
  local raster = { width = 3072, palette = palette, bands = { plane:rep(24) } }
  local frame = assert(data.capture(raster, 1, 1))
  local clipped = "$#1" .. ("B?B@"):rep(768)
  local expected = '\27P0;1;0q"1;1;3072;2' .. palette .. clipped:rep(24)
  eq(data.pack_rows(frame, 0, 2), expected .. "\27\\")
end

T["Sixel leaves overlays and side-by-side splits in place"] = function()
  mock_scroll_compositor()
  child.lua([[
    _G.float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true),
      false, { relative = "editor", row = 1, col = 1, width = 5, height = 3,
        focusable = false })
    _G.shift_pdf(2)
  ]])
  eq(sent("\27[2S\27[r"), false)
  child.lua([[
    vim.api.nvim_win_close(_G.float, true)
    vim.cmd.vsplit()
    _G.shift_pdf(2)
  ]])
  eq(sent("\27[2S\27[r"), false)
  eq(sent("\27P0;1;0q"), true)
end

T["Sixel enlarges the page and encodes only the center columns"] = function()
  local path = file .. ".ppm"
  local ppm = assert(io.open(path, "wb"))
  local black, white = "\0\0\0", "\255\255\255"
  ppm:write("P6\n4 1\n255\n", black, white, black, black)
  ppm:close()

  local render = require("iara.features.pdf.sixel_ppm")
  local bands = render(path, 2, 6, 4)
  eq(bands, "#63!2~$#0?~")
  eq((render(path, 2, 6, 4, 1, 1, true, 0)), "#63!2~$#0~")
  eq((render(path, 2, 6, 4, 1, 1, true, 2)), "#63!2~$#0~~")
end

T["Sixel starts the current zoom while two superseded jobs drain"] = function()
  child.lua([[
    _G.jobs = {}
    package.loaded["iara.features.pdf.sixel_encode"] = {
      start = function(entry, task)
        _G.jobs[#_G.jobs + 1] = { entry.path, task.first, task.last }
      end,
    }
    local cache = require("iara.features.pdf.sixel_cache")
    _G.cache = cache
    _G.request = function(path)
      local shape = { width = 720, height = 2400, page_width = 720 }
      local entry = cache.prepare(path, shape, function() end)
      cache.want(entry, path, 150, 240, true)
    end
    _G.request("old-a")
    _G.request("old-b")
  ]])
  eq(child.lua_get("#_G.jobs"), 2)
  child.lua([[
    _G.cache.forget("old-a")
    _G.cache.forget("old-b")
    _G.request("current")
  ]])
  eq(child.lua_get("_G.jobs[3]"), { "current", 150, 240 })
end

T["Sixel keeps an in-flight encode ahead of a moving viewport"] = function()
  child.lua([[
    _G.jobs = {}
    package.loaded["iara.features.pdf.sixel_encode"] = {
      start = function(_, task) table.insert(_G.jobs, task) end,
    }
    local cache = require("iara.features.pdf.sixel_cache")
    local shape = { width = 720, height = 1200, page_width = 720 }
    local entry = cache.prepare("scroll", shape, function() end)
    entry.raster = { bands = vim.split(("band "):rep(40), " ") }
    entry.raster.bands[41] = nil
    _G.visible_bands = function(first, last)
      cache.want(entry, "viewport", first, last, true)
    end
    _G.visible_bands(1, 40)
  ]])
  eq(child.lua_get("{_G.jobs[1].first, _G.jobs[1].last}"), { 41, 64 })
  child.lua("_G.visible_bands(9, 40)")
  eq(child.lua_get("{#_G.jobs, _G.jobs[1].cancelled == true}"), { 1, false })
  child.lua("_G.visible_bands(25, 50)")
  eq(child.lua_get("_G.jobs[1].priority"), 2)
  child.lua("_G.visible_bands(130, 169)")
  eq(child.lua_get("_G.jobs[1].cancelled"), true)
  eq(child.lua_get("{_G.jobs[2].first, _G.jobs[2].last}"), { 130, 169 })
end

T["partial Sixel bands match the same portion of a whole page"] = function()
  local path = file .. ".ppm"
  local ppm = assert(io.open(path, "wb"))
  ppm:write("P6\n1 24\n255\n")
  for row = 0, 23 do
    ppm:write(string.char(row * 11):rep(3))
  end
  ppm:close()
  local render = require("iara.features.pdf.sixel_ppm")
  local full = vim.split(assert(render(path, 4, 60, 4)), "-", { plain = true })
  local partial = render(path, 4, 60, 4, 4, 7, true)
  eq(partial, table.concat(full, "-", 4, 7))
end

T["partial color bands keep the palette and rightmost pixel"] = function()
  local path = file .. ".ppm"
  local ppm = assert(io.open(path, "wb"))
  local white, yellow = "\255\255\255", "\255\255\0"
  ppm:write("P6\n2 24\n255\n")
  ppm:write((white .. yellow):rep(12), (white .. white):rep(12))
  ppm:close()
  local render = require("iara.features.pdf.sixel_ppm")
  local full, palette, grayscale = render(path, 1, 24, 2, 1, 4, nil, 1)
  eq(grayscale, false)
  eq(full, "#63!1~$#239~-#63!1~$#239~-#63!1~-#63!1~")
  local partial, colors = render(path, 1, 24, 2, 2, 3, false, 1)
  eq(partial, "#63!1~$#239~-#63!1~")
  eq(colors, palette)
end

T["blank bands separate ink without carrying pixel masks"] = function()
  local path = file .. ".ppm"
  local ppm = assert(io.open(path, "wb"))
  local white = "\255\255\255"
  ppm:write("P6\n2 18\n255\n")
  for row = 0, 17 do
    local first = (row < 6 or row == 14) and "\0\0\0" or white
    ppm:write(first, white)
  end
  ppm:close()
  local render = require("iara.features.pdf.sixel_ppm")
  eq((render(path, 2, 18, 2)), "#63!2~$#0~-#63!2~-#63!2~$#0C")
end

T["Sixel slices retain colors and stay within viewport"] = function()
  local data = require("iara.features.pdf.sixel_data")
  local encoded = '\27P0;0;0q"1;1;8;24#0;2;0;0;0#1;2;100;100;100'
    .. "#1!8~-!8~#0$!8?-#1!8~-!8~\27\\"
  local raster = assert(data.decode(encoded))
  eq(raster.width, 8)
  local first, last = data.bounds(raster.height, 7, 13)
  local frame = assert(data.capture(raster, first, last))
  local slice, height = data.pack(frame, first, last)
  eq(height, 12)
  eq(
    slice,
    '\27P0;1;0q"1;1;8;12#0;2;0;0;0#1;2;100;100;100'
      .. "#1!8~#0$!8?-#0#1!8~\27\\"
  )
  eq(data.bounds(raster.height, 0, 5), nil)
  raster.bands[2] = nil
  eq((data.pack(frame, 2, 3)), slice)
end

return T
