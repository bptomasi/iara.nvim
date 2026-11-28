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
printf 'Title: Fixture\nPages: 3\n'
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

local function mock_poppler()
  executable(
    vim.fs.dirname(file) .. "/pdftoppm",
    [[
format=ppm
if [ "$5" = "-png" ]; then format=png; fi
prefix=
for arg do path=$prefix; prefix=$arg; done
test "$path" = "$IARA_TEST_PDF"
printf '%s %s\n' "$2" "$4" >>"$(dirname "$path")/renders.log"
if [ "$2" = "$4" ]; then
  printf '%s' "$2" >"$prefix.$format"
else
  if [ "${IARA_TEST_PDF_SLOW_BATCH:-}" = yes ]; then sleep 5; fi
  for page in $(seq "$2" "$4"); do
    printf '%s' "$page" >"$prefix-$page.$format"
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

T["Sixel encodes gray PPM and sends color to the converter"] = function()
  local dir = vim.fs.dirname(file)
  executable(
    dir .. "/img2sixel",
    [[printf '\033P0;0;0q"1;1;2;6#0;2;100;0;0#0~~\033\\']]
  )
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
  eq(
    vim.wait(5000, function()
      return child.lua_get("_G.gray.raster ~= nil and _G.color.raster ~= nil")
    end, 20),
    true
  )
  eq(child.lua_get("_G.gray.raster.bands"), { "#63!2~$#0~" })
  eq(child.lua_get("_G.color.raster.palette"), "#0;2;100;0;0")
end

T["Sixel enlarges the page and encodes only the center columns"] = function()
  local path = file .. ".ppm"
  local ppm = assert(io.open(path, "wb"))
  local black, white = "\0\0\0", "\255\255\255"
  ppm:write("P6\n4 1\n255\n", black, white, black, black)
  ppm:close()

  local render = require("iara.features.pdf.sixel_gray")
  local bands = render(path, 2, 6, 4)
  eq(bands, "#63!2~$#0?~")
  eq((render(path, 2, 6, 4, 1, 1, false, 0)), "#63!2~$#0~")
  eq((render(path, 2, 6, 4, 1, 1, false, 2)), "#63!2~$#0~~")
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

T["partial Sixel bands match the same portion of a whole page"] = function()
  local path = file .. ".ppm"
  local ppm = assert(io.open(path, "wb"))
  ppm:write("P6\n1 24\n255\n")
  for row = 0, 23 do
    ppm:write(string.char(row * 11):rep(3))
  end
  ppm:close()
  local render = require("iara.features.pdf.sixel_gray")
  local full = vim.split(assert(render(path, 4, 60, 4)), "-", { plain = true })
  local partial = render(path, 4, 60, 4, 4, 7, true)
  eq(partial, table.concat(full, "-", 4, 7))
end

T["Sixel slices retain colors and stay within viewport"] = function()
  local data = require("iara.features.pdf.sixel_data")
  local encoded = '\27P0;0;0q"1;1;8;24#0;2;0;0;0#1;2;100;100;100'
    .. "#1!8~-!8~#0$!8?-#1!8~-!8~\27\\"
  local raster = assert(data.decode(encoded))
  eq(raster.width, 8)
  local slice, height = data.slice(raster, 7, 13)
  eq(height, 12)
  eq(
    slice,
    '\27P0;1;0q"1;1;8;12#0;2;0;0;0#1;2;100;100;100'
      .. "#1!8~#0$!8?-#0#1!8~\27\\"
  )
  eq(data.slice(raster, 0, 5), nil)
end

return T
