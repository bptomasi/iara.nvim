--- Read-only PDF buffer with native window scrolling and a small raster cache.
local source = require("iara.features.pdf.source")
local graphics = require("iara.features.pdf.graphics")
local layout = require("iara.features.pdf.layout")
local api = vim.api

local M = {}
local CACHE_PAGES = 6
local CACHE_BYTES = 24 * 1024 * 1024
local refresh
local go
local zoom_step = 25
local virtual_views = {}
local wheel_listener

local function unwatch_wheel(buf)
  virtual_views[buf] = nil
  if wheel_listener and not next(virtual_views) then
    vim.on_key(nil, wheel_listener)
    wheel_listener = nil
  end
end

local function replace(view, lines)
  local options = vim.bo[view.buf]
  options.modifiable = true
  api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  options.modified = false
  options.modifiable = false
end

local function show_text(view, body)
  local header = view.name
  if view.info then
    header = ("%s  ·  %d/%d  ·  j/k page  ·  q close"):format(
      header,
      view.page,
      view.info.count
    )
  end
  replace(view, vim.list_extend({ header, "" }, body))
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    api.nvim_win_set_cursor(win, { 1, 0 })
  end
end

local function text_page(view)
  if view.job then
    view.job:cancel("PDF page changed")
    return
  end
  local page = view.page
  show_text(view, { "Loading page…" })
  view.job = source.text(view.path, page, function(lines, err)
    view.job = nil
    if view.closed then
      return
    end
    if page ~= view.page then
      return text_page(view)
    end
    show_text(view, lines or { err or "Could not extract PDF text." })
  end)
end

local function clear_pictures(view)
  for win, pictures in pairs(view.pictures) do
    graphics.clear(pictures)
    view.pictures[win] = nil
  end
end

local function use_text(view, reason)
  clear_pictures(view)
  if view.pages then
    local win = vim.fn.win_findbuf(view.buf)[1]
    if win then
      view.page = layout.page_at(view.pages, api.nvim_win_get_cursor(win)[1])
    end
  end
  view.pages, view.graphical = nil, false
  unwatch_wheel(view.buf)
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    vim.w[win].iara_pdf_page = nil
  end
  if reason then
    vim.notify("Iara PDF: " .. tostring(reason), vim.log.levels.WARN)
  end
  vim.keymap.set("n", "j", function()
    go(view, view.page + vim.v.count1)
  end, { buffer = view.buf, desc = "Next PDF page" })
  vim.keymap.set("n", "k", function()
    go(view, view.page - vim.v.count1)
  end, { buffer = view.buf, desc = "Previous PDF page" })
  text_page(view)
end

local function enqueue(view)
  if view.closed or view.pending then
    return
  end
  view.pending = true
  vim.schedule(function()
    view.pending = false
    if view.graphical and not view.closed then
      refresh(view)
    end
  end)
end

local function raster_size(view, page)
  local slot = view.pages[page]
  local longest =
    math.max(slot.width * view.cell_width, slot.height * view.cell_height)
  return math.min(3072, math.max(1024, math.ceil(longest / 256) * 256))
end

local function discard(entry)
  graphics.forget(entry.path)
  vim.uv.fs_unlink(entry.path)
end

local function load_page(view, page)
  local size = raster_size(view, page)
  local prefix = ("%s/page-%d-%d"):format(view.dir, page, size)
  view.loading = page
  local format = view.virtual and "ppm" or "png"
  view.job = source.raster(
    view.path,
    page,
    prefix,
    size,
    function(path, err, bytes)
      view.job, view.loading = nil, nil
      if view.closed or not view.graphical then
        return
      end
      local previous = view.rasters[page]
      if err and not previous then
        return use_text(view, err)
      end
      if path then
        view.rasters[page] = {
          page = page,
          path = path,
          size = size,
          bytes = bytes,
          touched = view.tick,
        }
        if previous then
          graphics.retain(previous.path, path, previous.size)
          vim.uv.fs_unlink(previous.path)
        end
      elseif err and previous then
        -- A sharper raster is optional. Retain the page already in use.
        previous.failed_size = size
      end
      enqueue(view)
    end,
    format
  )
end

local function update_cache(view, wanted)
  local entries = {}
  for page, entry in pairs(view.rasters) do
    if wanted[page] then
      entry.touched = view.tick
    else
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    return a.touched > b.touched
  end)
  local bytes = 0
  for i, entry in ipairs(entries) do
    bytes = bytes + entry.bytes
    if i > CACHE_PAGES or bytes > CACHE_BYTES then
      discard(entry)
      view.rasters[entry.page] = nil
    end
  end
end

local function request_pages(view, queue, wanted, visible_count)
  update_cache(view, wanted)
  for _, page in ipairs(queue) do
    local entry = view.rasters[page]
    local slot = view.pages[page]
    if entry and entry.warmed ~= slot then
      entry.warmed = slot
      graphics.warm(entry.path, slot)
    end
  end
  if view.job then
    if not wanted[view.loading] then
      view.job:cancel("PDF viewport moved")
    end
    return
  end
  for _, page in ipairs(queue) do
    if not view.rasters[page] then
      return load_page(view, page)
    end
  end
  if view.zoom_at then
    return
  end
  for index = 1, visible_count do
    local page = queue[index]
    local entry = view.rasters[page]
    local size = raster_size(view, page)
    if
      size > entry.size
      and size ~= entry.failed_size
      and graphics.ready(entry.path, view.pages[page])
    then
      return load_page(view, page)
    end
  end
end

local function dimensions(windows)
  local cols, rows = math.huge, math.huge
  for _, win in ipairs(windows) do
    cols = math.min(cols, api.nvim_win_get_width(win))
    rows = math.min(rows, api.nvim_win_get_height(win))
  end
  return cols, math.max(1, rows - 3)
end

local function save_windows(view, windows)
  local saved = {}
  for _, win in ipairs(windows) do
    if view.virtual then
      saved[win] = { topline = view.tops[win] or view.hidden_top or 1 }
    else
      saved[win] = api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  return saved
end

local function restore_windows(view, saved, previous)
  local pages = view.pages
  for win, window_view in pairs(saved) do
    local top = layout.relocate(previous, pages, window_view.topline)
    if view.virtual then
      view.tops[win] = top
    else
      window_view.lnum = layout.relocate(previous, pages, window_view.lnum)
      window_view.topline = top
      window_view.col, window_view.leftcol = 0, 0
      api.nvim_win_call(win, function()
        vim.fn.winrestview(window_view)
      end)
    end
  end
end

local function arrange(view, windows)
  local cols, rows = dimensions(windows)
  local size = graphics.size()
  if
    view.cols == cols
    and view.rows == rows
    and view.cell_width == size.cell_width
    and view.cell_height == size.cell_height
    and view.layout_zoom == view.zoom
  then
    return
  end
  local saved = save_windows(view, windows)
  local previous = view.pages
  local pages, lines, last =
    layout.arrange(view.info, cols, rows, view.zoom, view.virtual)
  clear_pictures(view)
  view.pages, view.cols, view.rows = pages, cols, rows
  view.cell_width, view.cell_height = size.cell_width, size.cell_height
  view.layout_zoom, view.last_row = view.zoom, last
  if not view.virtual or not previous then
    replace(view, view.virtual and { "" } or lines)
  end
  restore_windows(view, saved, previous)
end

local function topline(view, win)
  if view.virtual then
    return view.tops[win] or view.hidden_top or 1
  end
  return vim.fn.getwininfo(win)[1].topline
end

local function draw_page(view, win, page, pictures)
  local raster = view.rasters[page]
  if not raster then
    return
  end
  local slot = view.pages[page]
  local x = math.floor((api.nvim_win_get_width(win) - slot.visible_width) / 2)
  local current = pictures[page]
  if current and current.x == x and current.path == raster.path then
    return
  end
  if current then
    current.image:clear()
  end
  local picture = graphics.picture(raster.path, win, view.buf, {
    x = x,
    y = slot.row - 1,
    width = slot.width,
    visible_width = slot.visible_width,
    height = slot.height,
    topline = view.virtual and function()
      return view.presented[win]
    end or nil,
    on_ready = function()
      enqueue(view)
    end,
    on_error = function(reason)
      if not view.closed and view.graphical then
        use_text(view, reason)
      end
    end,
  })
  pictures[page] = { x = x, image = picture, path = raster.path }
end

local function set_page_counter(view, win, first)
  local counter = (" %d/%d "):format(first, view.info.count)
  if vim.w[win].iara_pdf_page ~= counter then
    vim.w[win].iara_pdf_page = counter
    vim.cmd.redrawstatus()
  end
end

local function prepare_zoom(view, win, page)
  local entry = view.rasters[page]
  local slot = view.pages[page]
  if
    entry.hint == slot
    or win ~= api.nvim_get_current_win()
    or not graphics.ready(entry.path, slot)
  then
    return
  end
  entry.hint = slot
  local direction = view.zoom_direction or 1
  local scale = math.max(50, math.min(300, view.zoom + direction * zoom_step))
  local ratio = view.info.ratios[page] or 210 / 297
  local width, height, visible =
    graphics.fit(ratio, math.max(1, view.cols - 2), view.rows, scale, true)
  if width == slot.width and height == slot.height then
    return
  end
  vim.defer_fn(function()
    if
      not view.closed
      and view.pages
      and view.pages[page] == slot
      and view.rasters[page] == entry
      and api.nvim_get_current_win() == win
    then
      graphics.warm_zoom(entry.path, {
        width = width,
        height = height,
        visible_width = visible,
      })
    end
  end, 100)
end

local function window_pages(view, win, add)
  local top = topline(view, win)
  local first = layout.page_at(view.pages, top)
  local bottom = top + api.nvim_win_get_height(win) - 1
  local last = layout.page_at(view.pages, math.max(top, bottom - 1))
  for page = first, last do
    add(page)
  end
  -- A jump may outrun prefetch. Keep the current frame until Poppler
  -- supplies the first page of the new viewport.
  if view.virtual and not view.rasters[first] then
    return first - 1, last + 1
  end
  view.presented[win] = top
  set_page_counter(view, win, first)
  local pictures = view.pictures[win] or {}
  view.pictures[win] = pictures
  for page, picture in pairs(pictures) do
    if page < first or page > last then
      picture.image:clear()
      pictures[page] = nil
    end
  end
  for page = first, last do
    draw_page(view, win, page, pictures)
  end
  if view.virtual then
    prepare_zoom(view, win, first)
  end
  return first - 1, last + 1
end

local function visible_windows(view)
  local windows = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local config = api.nvim_win_get_config(win)
    if config.relative ~= "" and config.focusable then
      -- The picker returns focus before it finishes closing its floats.
      -- Wait for WinClosed before restoring graphics under those panels.
      return {}
    end
    if config.relative == "" and api.nvim_win_get_buf(win) == view.buf then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local function draw_visible(view, windows, queue, add)
  local adjacent = {}
  for _, win in ipairs(windows) do
    local before, after = window_pages(view, win, add)
    adjacent[#adjacent + 1] = after
    adjacent[#adjacent + 1] = before
  end
  local visible_count = #queue
  for _, page in ipairs(adjacent) do
    if page >= 1 and page <= view.info.count then
      add(page)
    end
  end
  return visible_count
end

refresh = function(view)
  local windows = visible_windows(view)
  for win, pictures in pairs(view.pictures) do
    if not vim.tbl_contains(windows, win) then
      graphics.clear(pictures)
      view.pictures[win] = nil
    end
  end
  if #windows == 0 then
    return
  end
  arrange(view, windows)
  local queue, wanted = {}, {}
  local ok, visible = pcall(draw_visible, view, windows, queue, function(page)
    if not wanted[page] then
      wanted[page] = true
      queue[#queue + 1] = page
    end
  end)
  if not ok then
    return use_text(view, visible)
  end
  view.tick = view.tick + 1
  request_pages(view, queue, wanted, visible)
  if view.repair then
    view.repair = false
    for _, win in ipairs(windows) do
      graphics.invalidate(win)
    end
  end
  graphics.refresh()
end

local function scroll_virtual(view, win, rows)
  if not view.pages or view.closed or not view.graphical then
    return
  end
  local top = topline(view, win)
  local limit = math.max(top, view.last_row - api.nvim_win_get_height(win) + 1)
  local target = math.max(1, math.min(top + rows, limit))
  if target ~= top then
    view.tops[win] = target
    enqueue(view)
  end
end

local function watch_wheel(view)
  virtual_views[view.buf] = view
  if wheel_listener then
    return
  end
  local wheel = {
    [vim.keycode("<ScrollWheelUp>")] = -1,
    [vim.keycode("<ScrollWheelDown>")] = 1,
  }
  wheel_listener = vim.on_key(function(key)
    local direction = wheel[key]
    if not direction then
      return
    end
    local win = vim.fn.getmousepos().winid
    local hovered = win ~= 0 and virtual_views[api.nvim_win_get_buf(win)]
    if hovered then
      local amount = tonumber(vim.o.mousescroll:match("ver:(%d+)")) or 3
      vim.schedule(function()
        if
          api.nvim_win_is_valid(win)
          and api.nvim_win_get_buf(win) == hovered.buf
        then
          scroll_virtual(hovered, win, direction * amount)
        end
      end)
      return ""
    end
  end)
end

local function virtual_keys(view)
  watch_wheel(view)
  local function bind(key, step, by_height)
    vim.keymap.set("n", key, function()
      local win = api.nvim_get_current_win()
      local height = by_height and math.max(1, api.nvim_win_get_height(win) - 2)
        or 1
      local rows = math.max(1, math.floor(height * math.abs(step)))
      scroll_virtual(view, win, rows * vim.v.count1 * (step > 0 and 1 or -1))
    end, { buffer = view.buf, desc = "Scroll PDF" })
  end
  for key, step in pairs({
    j = 1,
    k = -1,
    ["<Down>"] = 1,
    ["<Up>"] = -1,
    ["<C-e>"] = 1,
    ["<C-y>"] = -1,
  }) do
    bind(key, step, false)
  end
  for key, step in pairs({
    ["<C-d>"] = 0.5,
    ["<C-u>"] = -0.5,
    ["<C-f>"] = 1,
    ["<C-b>"] = -1,
    ["<PageDown>"] = 1,
    ["<PageUp>"] = -1,
  }) do
    bind(key, step, true)
  end
end

local function defer_pdf_detail(view)
  -- Reuse existing rasters during repeated zoom steps. Only ask Poppler for
  -- extra detail after the input settles, so it cannot evict active encodings.
  local stamp = vim.uv.hrtime()
  view.zoom_at = stamp
  if view.job and view.rasters[view.loading] then
    view.job:cancel("PDF zoom changed")
  end
  vim.defer_fn(function()
    if view.zoom_at == stamp then
      view.zoom_at = nil
      enqueue(view)
    end
  end, 300)
end

local function zoom(view, scale)
  if not view.graphical then
    return
  end
  local target = math.max(50, math.min(300, scale))
  if target ~= view.zoom then
    view.zoom_direction = (target >= view.zoom or target == 100) and 1 or -1
    view.zoom = target
    if view.virtual then
      defer_pdf_detail(view)
    end
    enqueue(view)
  end
end

local function start(view, info, err)
  if not info then
    return show_text(view, { err or "Could not read PDF." })
  end
  view.info = info
  local available, reason = graphics.available()
  if available and graphics.size() then
    view.dir, reason = source.directory()
  end
  view.graphical = view.dir ~= nil
  view.virtual = view.graphical and graphics.virtual_scroll()
  if view.virtual then
    virtual_keys(view)
    enqueue(view)
  elseif view.graphical then
    vim.keymap.set(
      "n",
      "j",
      "<C-e>",
      { buffer = view.buf, desc = "Scroll down" }
    )
    vim.keymap.set("n", "k", "<C-y>", { buffer = view.buf, desc = "Scroll up" })
    enqueue(view)
  else
    use_text(view, reason)
  end
end

local function current_page(view)
  if not view.pages then
    return view.page
  end
  return layout.page_at(view.pages, topline(view, api.nvim_get_current_win()))
end

go = function(view, target)
  if not view.info then
    return
  end
  local page = math.min(math.max(target, 1), view.info.count)
  if view.pages then
    local row = view.pages[page].row
    if view.virtual then
      view.tops[api.nvim_get_current_win()] = row
    else
      vim.fn.winrestview({ lnum = row, col = 0, topline = row })
    end
    enqueue(view)
  elseif page ~= view.page then
    view.page = page
    text_page(view)
  end
end

local function map_keys(view)
  local function map(lhs, action, desc)
    vim.keymap.set("n", lhs, action, { buffer = view.buf, desc = desc })
  end
  map("]p", function()
    go(view, current_page(view) + vim.v.count1)
  end, "Next PDF page")
  map("[p", function()
    go(view, current_page(view) - vim.v.count1)
  end, "Previous PDF page")
  map("gg", function()
    go(view, 1)
  end, "First PDF page")
  map("G", function()
    go(view, view.info and view.info.count or 1)
  end, "Last PDF page")
  map("+", function()
    zoom(view, view.zoom + zoom_step * vim.v.count1)
  end, "Zoom in PDF")
  map("-", function()
    zoom(view, view.zoom - zoom_step * vim.v.count1)
  end, "Zoom out PDF")
  map("0", function()
    zoom(view, 100)
  end, "Reset PDF zoom")
  map("q", function()
    api.nvim_buf_delete(view.buf, {})
  end, "Close PDF")
end

local function window_options(win)
  local options = vim.wo[win][0]
  options.number = false
  options.relativenumber = false
  options.signcolumn = "no"
  options.foldcolumn = "0"
  options.foldenable = false
  options.statuscolumn = ""
  options.cursorline = false
  options.wrap = false
  options.scrolloff = 0
  options.sidescrolloff = 0
end

local function prepare_windows(view)
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    window_options(win)
  end
end

local function close(view)
  if view.closed then
    return
  end
  view.closed = true
  unwatch_wheel(view.buf)
  if view.job then
    view.job:cancel("PDF closed")
  end
  clear_pictures(view)
  if view.dir then
    for _, entry in pairs(view.rasters) do
      graphics.forget(entry.path)
    end
    vim.fn.delete(view.dir, "rf")
  end
  api.nvim_del_augroup_by_id(view.group)
end

local function watch_buffer(view)
  api.nvim_create_autocmd("BufWinEnter", {
    group = view.group,
    buffer = view.buf,
    callback = function()
      prepare_windows(view)
      local win = vim.fn.win_findbuf(view.buf)[1]
      if win and view.hidden_position then
        local position = view.hidden_position
        view.hidden_position = nil
        api.nvim_win_call(win, function()
          vim.fn.winrestview(position)
        end)
      end
      enqueue(view)
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = view.group,
    buffer = view.buf,
    callback = function()
      local win = vim.fn.win_findbuf(view.buf)[1]
      if win and view.pages then
        if view.virtual then
          view.hidden_top = topline(view, win)
        else
          view.hidden_position = api.nvim_win_call(win, vim.fn.winsaveview)
        end
      end
      enqueue(view)
    end,
  })
end

local function watch(view)
  view.group = api.nvim_create_augroup("IaraPDF" .. view.buf, { clear = true })
  watch_buffer(view)
  api.nvim_create_autocmd({
    "WinResized",
    "WinScrolled",
    "WinEnter",
    "WinClosed",
    "TabEnter",
    "VimResized",
  }, {
    group = view.group,
    callback = function(args)
      if args.event == "WinClosed" then
        local win = tonumber(args.match)
        view.tops[win], view.presented[win] = nil, nil
        view.repair = true
      end
      if view.graphical then
        enqueue(view)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = view.group,
    buffer = view.buf,
    callback = function()
      close(view)
    end,
  })
end

function M.open(bufnr)
  local path = api.nvim_buf_get_name(bufnr)
  local view = {
    path = path,
    buf = bufnr,
    name = vim.fn.strtrans(vim.fs.basename(path)),
    page = 1,
    zoom = 100,
    tops = {},
    presented = {},
    pictures = {},
    rasters = {},
    tick = 0,
  }
  local options = vim.bo[bufnr]
  options.buftype = "nofile"
  options.bufhidden = "hide"
  options.swapfile = false
  options.filetype = "iara-pdf"
  show_text(view, { "Reading PDF…" })
  prepare_windows(view)
  map_keys(view)
  watch(view)
  view.job = source.info(path, function(info, err)
    view.job = nil
    if not view.closed then
      start(view, info, err)
    end
  end)
end

return M
