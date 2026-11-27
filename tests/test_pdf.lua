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

local function mock_graphics()
  executable(
    vim.fs.dirname(file) .. "/pdftoppm",
    [[
format=ppm
if [ "$5" = "-png" ]; then format=png; fi
prefix=
for arg do path=$prefix; prefix=$arg; done
test "$path" = "$IARA_TEST_PDF"
printf '%s' "$2" >"$prefix.$format"
]]
  )
  child.lua([[
    local graphics = require("iara.features.pdf.graphics")
    graphics.available = function() return true end
    graphics.size = function()
      return { cell_height = 20, cell_width = 10 }
    end
    _G.drawings, _G.preview_tops = {}, {}
    graphics.picture = function(path, win, _, rect)
      local key = ("%d:%s"):format(win, vim.fs.basename(path))
      _G.drawings[key] = {
        path = path, win = win, rect = { x = rect.x, width = rect.width },
      }
      _G.preview_tops[key] = rect.topline
      return { clear = function()
        _G.drawings[key], _G.preview_tops[key] = nil, nil
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
  eq(child.lua_get("pdf_top()"), 5)
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

T["Sixel restores an unchanged image after window redraw"] = function()
  child.lua([[
    package.loaded["iara.features.pdf.sixel_cache"] = {
      prepare = function(_, width, height)
        return { raster = {
          width = width, height = height,
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
    local api = vim.api
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    _G.sixel.picture("fake", win, buf, {
      x = 1, y = 0, width = 4, height = 3,
    })
  ]])
  eq(child.lua_get("_G.frames"), 1)
  child.lua("_G.sixel.refresh()")
  eq(child.lua_get("_G.frames"), 1)
  child.lua([[
    _G.provider.on_win(nil, vim.api.nvim_get_current_win())
    _G.provider.on_end()
  ]])
  eq(child.lua_get("_G.frames"), 2)
end

T["Sixel keeps the frame while a visible page is pending"] = function()
  child.lua([[
    local api = vim.api
    local raster = { width = 40, height = 18,
      palette = "#0;2;100;100;100", bands = { "#0~", "#0~", "#0~" } }
    local waiting, complete = {}, { raster = raster }
    package.loaded["iara.features.pdf.sixel_cache"] = {
      prepare = function(path, _, _, ready)
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
    api.nvim_ui_send = function() _G.frames = (_G.frames or 0) + 1 end
    api.nvim_set_decoration_provider = function() end
    local sixel = require("iara.features.pdf.sixel")
    local function picture(path, y)
      return sixel.picture(path, api.nvim_get_current_win(), 1, {
        x = 1, y = y, width = 4, height = 1,
      })
    end
    local before = picture("before", 0)
    vim.schedule(function()
      before.clear()
      picture("pending", 0)
      picture("ready", 2)
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
      prepare = function()
        return { raster = { width = 40, height = 18,
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
      return cache.prepare(path, 2, 6, function() end, true)
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
  ppm:write("P6\n4 1\n255\n", black, white, black, white)
  ppm:close()

  local render = require("iara.features.pdf.sixel_gray")
  local bands = render(path, 2, 6, 4)
  eq(bands, "#63!2~$#0?~")
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
