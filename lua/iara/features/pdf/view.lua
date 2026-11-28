--- Read-only PDF buffer with native window scrolling and a small raster cache.
local source = require("iara.features.pdf.source")
local graphics = require("iara.features.pdf.graphics")
local layout = require("iara.features.pdf.layout")
local geometry = require("iara.features.pdf.geometry")
local detail = require("iara.features.pdf.detail")
local scrollbar = require("iara.features.pdf.scrollbar")
local raster_cache = require("iara.features.pdf.raster_cache")
local api = vim.api

local M = {}
local CACHE_PAGES = 6
local CACHE_BYTES = 24 * 1024 * 1024
local refresh
local go
local zoom_step = 25
local double_tap_ns = 180 * 1e6
local repeat_start_ns = 900 * 1e6
local repeat_idle_ns = 250 * 1e6
local tap_pause_ns = 130 * 1e6
local tap_pause_margin_ns = 45 * 1e6
local fast_scroll_rows = 4
local virtual_views = {}
local pointer_listener
local drag

local function unwatch_pointer(buf)
  virtual_views[buf] = nil
  if drag and drag.view.buf == buf then
    drag = nil
  end
  if pointer_listener and not next(virtual_views) then
    vim.on_key(nil, pointer_listener)
    pointer_listener = nil
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
    header = ("%s  ·  %d/%d  ·  j/k page  ·  gp go to  ·  q close"):format(
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

local function window_layout(view, win)
  if view.virtual then
    return view.panes[win]
  end
  return view
end

local function get_pane(view, win)
  local pane = view.panes[win]
  if not pane then
    pane = { zoom = 100, zoom_direction = 1 }
    view.panes[win] = pane
  end
  return pane
end

local function use_text(view, reason)
  clear_pictures(view)
  detail.close(view.detail, view.panes)
  local display = vim.fn.win_findbuf(view.buf)[1]
  local pane = display and window_layout(view, display)
  if pane and pane.pages then
    local row = view.virtual and view.tops[display]
      or api.nvim_win_get_cursor(display)[1]
    view.page = layout.page_at(pane.pages, row)
  end
  view.pages, view.panes, view.graphical = nil, {}, false
  unwatch_pointer(view.buf)
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

local function enqueue(view, moving)
  if view.closed or view.pending then
    return
  end
  view.pending = true
  local function update()
    view.pending = false
    if moving then
      view.motion_at = vim.uv.now()
    end
    if view.graphical and not view.closed then
      refresh(view)
    end
  end
  local remaining = view.motion_at and 16 - (vim.uv.now() - view.motion_at)
  if moving and remaining and remaining > 0 then
    vim.defer_fn(update, remaining)
  else
    vim.schedule(update)
  end
end

local function slot_size(view, slot)
  local longest =
    math.max(slot.width * view.cell_width, slot.height * view.cell_height)
  return math.min(
    geometry.raster_limit,
    math.max(1024, math.ceil(longest / 256) * 256)
  )
end

local function raster_size(view, page)
  return slot_size(view, view.slots[page])
end

local function adjacent_size(view, page)
  -- Keep idle batches cheap at high zoom. Visible pages can sharpen later.
  return math.min(1536, raster_size(view, page))
end

local function discard(entry)
  graphics.forget(entry.path)
  vim.uv.fs_unlink(entry.path)
end

local function raster_format(view)
  return view.virtual and "ppm" or "png"
end

local function raster_prefix(view, page, size)
  return ("%s/page-%d-%d"):format(view.dir, page, size)
end

local function store_page(view, page, size, path, bytes)
  local previous = view.rasters[page]
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
end

local function finish_page(view, page, request, path, err, bytes)
  view.job, view.loading = nil, nil
  if view.closed then
    return
  end
  if not view.graphical then
    return text_page(view)
  end
  local previous = view.rasters[page]
  if err and not previous and not request.optional then
    return use_text(view, err)
  end
  if path then
    store_page(view, page, request.size, path, bytes)
    local identity = request.identity
    if
      identity
      and identity == raster_cache.identity(view.path, request.format)
    then
      raster_cache.publish(identity, path, request.format, request.size, bytes)
    end
  elseif err and previous then
    previous.failed_size = request.size
  elseif err then
    view.prefetch_failed[page] = request.size
  end
  enqueue(view)
end

local function load_page(view, page, optional, size)
  size = size
    or (optional and adjacent_size(view, page) or raster_size(view, page))
  local prefix = raster_prefix(view, page, size)
  local format = raster_format(view)
  local identity = page == 1 and raster_cache.identity(view.path, format)
  if identity and not view.rasters[page] then
    -- A higher-resolution Poppler run must never overwrite the shared inode.
    local path = prefix .. "-cached." .. format
    local cached, bytes = raster_cache.link(identity, path, size, size * 0.75)
    if cached then
      store_page(view, page, cached, path, bytes)
      return enqueue(view)
    end
  end
  local request = {
    identity = identity,
    size = size,
    format = format,
    optional = optional,
  }
  view.loading = page
  view.job = source.raster(
    view.path,
    page,
    prefix,
    size,
    function(path, err, bytes)
      finish_page(view, page, request, path, err, bytes)
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

local function publish_batch_page(view, batch, page, raster)
  if batch.published[page] then
    return true
  end
  local target = raster_prefix(view, page, batch.size) .. "." .. batch.format
  if not raster or not vim.uv.fs_rename(raster.path, target) then
    return false
  end
  store_page(view, page, batch.size, target, raster.bytes)
  batch.published[page] = true
  while batch.published[batch.next] do
    batch.next = batch.next + 1
  end
  return true
end

local function batch_result(view, batch, pages)
  view.job, view.batch = nil, nil
  if not view.closed and view.graphical and not batch.cancelled then
    for page = batch.first, batch.last do
      if not publish_batch_page(view, batch, page, pages[page]) then
        view.prefetch_failed[page] = batch.size
      end
    end
  end
  vim.fn.delete(batch.dir, "rf")
  if not view.closed and not view.graphical then
    return text_page(view)
  end
  enqueue(view)
end

local function start_batch(view, first, last, size)
  local dir = vim.uv.fs_mkdtemp(view.dir .. "/batch-XXXXXX")
  if not dir then
    return load_page(view, first, true)
  end
  local batch = {
    dir = dir,
    first = first,
    last = last,
    next = first,
    published = {},
    size = size,
    format = raster_format(view),
  }
  local function on_page(page, raster)
    if not view.closed and view.graphical and not batch.cancelled then
      if publish_batch_page(view, batch, page, raster) then
        enqueue(view)
      end
    end
  end
  view.batch = batch
  view.job = source.batch(
    view.path,
    first,
    last,
    dir,
    size,
    batch.format,
    function(pages)
      batch_result(view, batch, pages)
    end,
    view.virtual and on_page or nil
  )
end

local function first_idle_page(view, queue, visible_count)
  for index = visible_count + 1, #queue do
    local page = queue[index]
    local size = adjacent_size(view, page)
    if not view.rasters[page] and view.prefetch_failed[page] ~= size then
      return page, size
    end
  end
end

local function scroll_delay(view)
  return view.scrolled_at and 120 - (vim.uv.now() - view.scrolled_at) or 0
end

local function wait_for_prefetch(view, first)
  if scroll_delay(view) > 0 then
    return false
  end
  local delay = view.virtual and 32 or 100
  if view.prefetch_first ~= first then
    view.prefetch_first, view.prefetch_at = first, vim.uv.now()
    vim.defer_fn(function()
      enqueue(view)
    end, delay + 2)
    return true
  end
  return vim.uv.now() - view.prefetch_at < delay
end

local function prefetch(view, queue, wanted, visible_count)
  local first, size = first_idle_page(view, queue, visible_count)
  if not first or wait_for_prefetch(view, first) then
    return
  end

  local last = first
  for page = first + 1, first + 2 do
    if
      not wanted[page]
      or view.rasters[page]
      or adjacent_size(view, page) ~= size
      or view.prefetch_failed[page] == size
    then
      break
    end
    last = page
  end
  if last > first and first ~= 1 then
    return start_batch(view, first, last, size)
  end
  -- While scrolling, replenish the lookahead in batches if the nearest
  -- page is already ready. Keep its slot free for anything visible.
  local next_page = queue[visible_count + 1]
  if
    first ~= next_page
    and view.rasters[next_page]
    and scroll_delay(view) > 0
  then
    return
  end
  load_page(view, first, true)
end

local function urgent_raster(view, queue, visible_count)
  for index = 1, visible_count do
    local page = queue[index]
    if not view.rasters[page] then
      return page
    end
  end
end

local function settle_after_scroll(view)
  local remaining = scroll_delay(view)
  if view.closed or remaining <= 0 then
    return false
  end
  if not view.settle_pending then
    view.settle_pending = true
    vim.defer_fn(function()
      view.settle_pending = false
      if not settle_after_scroll(view) then
        enqueue(view)
      end
    end, remaining)
  end
  return true
end

local function cancel_raster(view, wanted, urgent)
  if view.batch then
    local batch = view.batch
    local working = view.virtual and batch.next or nil
    local obsolete = batch.next <= batch.last and not wanted[batch.next]
    -- A streamed batch already working on the visible page can deliver it
    -- directly. A jump to a later page still takes priority over the batch.
    if (urgent and urgent ~= working) or view.zoom_at or obsolete then
      batch.cancelled = true
      view.job:cancel("PDF viewport moved")
    end
  elseif
    (urgent and urgent ~= view.loading)
    or not wanted[view.loading]
    or (view.rasters[view.loading] and scroll_delay(view) > 0)
  then
    view.job:cancel("PDF viewport moved")
  end
end

local function warm_next(view, page)
  local next_raster = view.rasters[page]
  local slot = view.slots[page]
  if next_raster and next_raster.warmed ~= slot then
    next_raster.warmed = slot
    graphics.warm(next_raster.path, slot)
  end
end

local function sharpen_page(view, queue, visible_count)
  for index = 1, visible_count do
    local page = queue[index]
    local entry = view.rasters[page]
    local size = raster_size(view, page)
    if
      size > entry.size
      and size ~= entry.failed_size
      and graphics.ready(entry.path, view.slots[page])
    then
      return scroll_delay(view) <= 0 and page or nil
    end
  end
end

local function request_pages(view, queue, wanted, visible_count)
  update_cache(view, wanted)
  local urgent = urgent_raster(view, queue, visible_count)
  if not urgent and not view.zoom_at then
    warm_next(view, queue[visible_count + 1])
  end
  if view.job then
    return cancel_raster(view, wanted, urgent)
  end
  if urgent then
    local size = scroll_delay(view) > 0 and adjacent_size(view, urgent) or nil
    return load_page(view, urgent, false, size)
  end
  if view.zoom_at or (view.detail and view.detail.work) then
    return
  end
  local sharpen = sharpen_page(view, queue, visible_count)
  if sharpen then
    return load_page(view, sharpen)
  end
  prefetch(view, queue, wanted, visible_count)
end

local function dimensions(windows)
  local cols, rows = math.huge, math.huge
  for _, win in ipairs(windows) do
    cols = math.min(cols, api.nvim_win_get_width(win))
    rows = math.min(rows, api.nvim_win_get_height(win))
  end
  return cols, math.max(1, rows - 3)
end

local function arrange_native(view, windows)
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
  local saved = {}
  for _, win in ipairs(windows) do
    saved[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  local previous = view.pages
  local pages, lines = layout.arrange(view.info, cols, rows, view.zoom)
  clear_pictures(view)
  view.pages, view.cols, view.rows = pages, cols, rows
  view.cell_width, view.cell_height = size.cell_width, size.cell_height
  view.layout_zoom = view.zoom
  replace(view, lines)
  for win, position in pairs(saved) do
    position.lnum = layout.relocate(previous, pages, position.lnum)
    position.topline = layout.relocate(previous, pages, position.topline)
    position.col, position.leftcol = 0, 0
    api.nvim_win_call(win, function()
      vim.fn.winrestview(position)
    end)
  end
end

local function arrange_pane(view, win, size)
  local pane = get_pane(view, win)
  local cols = api.nvim_win_get_width(win)
  local rows = math.max(1, api.nvim_win_get_height(win) - 3)
  if
    pane.cols == cols
    and pane.rows == rows
    and pane.cell_width == size.cell_width
    and pane.cell_height == size.cell_height
    and pane.layout_zoom == pane.zoom
  then
    return
  end
  local pages, _, last = layout.arrange(view.info, cols, rows, pane.zoom, true)
  detail.prune(pane)
  local previous = pane.pages or (view.anchor and view.anchor.pages)
  local top = view.tops[win] or (view.anchor and view.anchor.top) or 1
  pane.pages, pane.last_row = pages, last
  pane.cols, pane.rows, pane.layout_zoom = cols, rows, pane.zoom
  pane.cell_width, pane.cell_height = size.cell_width, size.cell_height
  view.tops[win] = layout.relocate(previous, pages, top)
end

local function arrange(view, windows)
  if not view.virtual then
    return arrange_native(view, windows)
  end
  local size = graphics.size()
  view.cell_width, view.cell_height = size.cell_width, size.cell_height
  for _, win in ipairs(windows) do
    arrange_pane(view, win, size)
  end
  if not view.virtual_grid then
    replace(view, { "" })
    view.virtual_grid = true
  end
end

local function topline(view, win)
  if view.virtual then
    return view.tops[win] or 1
  end
  return vim.fn.getwininfo(win)[1].topline
end

local function page_rect(view, win, slot, x, tile)
  local pane = view.panes[win]
  local rect = {
    x = x,
    y = slot.row - 1,
    width = slot.width,
    visible_width = slot.visible_width,
    offset = slot.offset,
    height = slot.height,
    scrollbar = pane and function()
      return pane.bar
    end or nil,
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
  }
  if tile then
    rect.y = rect.y + tile.crop.first
    rect.height = tile.crop.last - tile.crop.first
    rect.width, rect.offset = rect.visible_width, nil
    rect.on_error = function()
      detail.discard(tile)
      enqueue(view)
    end
  end
  return rect
end

local function draw_page(view, win, page, slot, pictures, tile)
  local raster = view.rasters[page]
  if not raster then
    return
  end
  local path = tile and tile.path or raster.path
  local x = math.floor((api.nvim_win_get_width(win) - slot.visible_width) / 2)
  local current = pictures[page]
  if
    current
    and current.x == x
    and current.path == path
    and current.slot == slot
    and current.offset == slot.offset
  then
    return
  end
  if current then
    current.image:clear()
  end
  local rect = page_rect(view, win, slot, x, tile)
  local picture = graphics.picture(path, win, view.buf, rect)
  pictures[page] = {
    x = x,
    image = picture,
    path = path,
    slot = slot,
    rect = rect,
    offset = slot.offset,
  }
end

local function set_page_counter(view, win, first)
  local counter = (" %d/%d "):format(first, view.info.count)
  if vim.w[win].iara_pdf_page ~= counter then
    vim.w[win].iara_pdf_page = counter
    vim.cmd.redrawstatus()
  end
end

local function clamp_zoom(value, virtual)
  return math.max(50, math.min(virtual and 600 or 300, value))
end

local function zoom_rect(view, win, pane, slot, width, height, visible)
  local offset = math.max(0, topline(view, win) - slot.row)
  local skip = math.max(0, math.floor(offset * height / slot.height + 0.5) - 1)
  return {
    width = width,
    height = height,
    visible_width = visible,
    offset = scrollbar.offset(width, visible, pane.pan),
    skip = skip,
    rows = api.nvim_win_get_height(win),
  }
end

local function prepare_zoom(view, win, pane, page)
  local entry = view.rasters[page]
  local slot = pane.pages[page]
  if
    entry.hint == slot
    or win ~= api.nvim_get_current_win()
    or scroll_delay(view) > 0
    or not graphics.ready(entry.path, slot)
  then
    return
  end
  entry.hint = slot
  local scale = clamp_zoom(pane.zoom + zoom_step * pane.zoom_direction, true)
  local ratio = view.info.ratios[page] or 210 / 297
  local width, height, visible =
    graphics.fit(ratio, math.max(1, pane.cols - 2), pane.rows, scale, true)
  if width == slot.width and height == slot.height then
    return
  end
  vim.defer_fn(function()
    if
      not view.closed
      and view.panes[win] == pane
      and pane.pages[page] == slot
      and view.rasters[page] == entry
      and api.nvim_get_current_win() == win
      and layout.page_at(pane.pages, topline(view, win)) == page
      and scroll_delay(view) <= 0
    then
      local rect = zoom_rect(view, win, pane, slot, width, height, visible)
      graphics.warm_zoom(entry.path, rect)
    elseif entry.hint == slot then
      entry.hint = nil
    end
  end, 100)
end

local function pane_scrollbar(pane, first, last)
  for page = first, last do
    local bar = scrollbar.track(pane.pages[page], pane.cols, pane.pan)
    if bar then
      return bar
    end
  end
end

local function sampled_pan(view, win, pane, top)
  local sample = pane.pan_sample
  if sample and sample.top == top and sample.pages == pane.pages then
    if sample.position == pane.pan then
      return pane.pan
    end
    for _, picture in pairs(view.pictures[win] or {}) do
      if not graphics.ready(picture.path, picture.rect) then
        -- Finish the current crop. The worker's completion will pick up
        -- the latest pointer position while the thumb keeps following it.
        return sample.position
      end
    end
  end
  pane.pan_sample = { top = top, pages = pane.pages, position = pane.pan }
  return pane.pan
end

local function visible_slots(view, win, pane, top, add)
  local height = api.nvim_win_get_height(win)
  local first = layout.page_at(pane.pages, top)
  if view.virtual and height > 2 then
    -- Only consider pages that still have space after reserving the bar.
    local last = layout.page_at(pane.pages, math.max(top, top + height - 3))
    pane.bar = pane_scrollbar(pane, first, last)
    height = height - (pane.bar and 1 or 0)
  else
    pane.bar = nil
  end
  local last = layout.page_at(pane.pages, math.max(top, top + height - 2))
  local position = view.virtual and sampled_pan(view, win, pane, top) or nil
  for page = first, last do
    local slot = pane.pages[page]
    slot.offset = scrollbar.offset(slot.width, slot.visible_width, position)
    add(page, slot, true)
  end
  return first, last
end

local function have_rasters(view, first, last)
  for page = first, last do
    if not view.rasters[page] then
      return false
    end
  end
  return true
end

local function draw_pages(view, win, pane, first, last, top)
  local pictures = view.pictures[win] or {}
  view.pictures[win] = pictures
  for page, picture in pairs(pictures) do
    if page < first or page > last then
      picture.image:clear()
      pictures[page] = nil
    end
  end
  local screen = view.detail
    and {
      top = top,
      rows = api.nvim_win_get_height(win) - (pane.bar and 1 or 0),
      cell = { cell_width = view.cell_width, cell_height = view.cell_height },
      settled = not view.zoom_at and scroll_delay(view) <= 0,
    }
  for page = first, last do
    local slot = pane.pages[page]
    local tile = screen
      and detail.picture(view.detail, pane, page, slot, screen)
    draw_page(view, win, page, slot, pictures, tile)
  end
end

local function window_pages(view, win, pane, add)
  local top = topline(view, win)
  local first, last = visible_slots(view, win, pane, top, add)
  detail.prune(pane, first, last)
  -- Preserve the last complete viewport until all visible pages exist.
  if view.virtual and not have_rasters(view, first, last) then
    return first - 1, last + 1
  end
  view.presented[win] = top
  if view.virtual and win == api.nvim_get_current_win() then
    view.anchor = { pages = pane.pages, top = top }
  end
  set_page_counter(view, win, first)
  draw_pages(view, win, pane, first, last, top)
  if view.virtual then
    prepare_zoom(view, win, pane, first)
  end
  return first - 1, last + 1
end

local function visible_windows(view)
  local windows = {}
  local preferred = scroll_delay(view) > 0 and view.scroll_win
    or api.nvim_get_current_win()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local config = api.nvim_win_get_config(win)
    if config.relative ~= "" and config.focusable then
      -- The picker returns focus before it finishes closing its floats.
      -- Wait for WinClosed before restoring graphics under those panels.
      return {}
    end
    if config.relative == "" and api.nvim_win_get_buf(win) == view.buf then
      if win == preferred then
        table.insert(windows, 1, win)
      else
        windows[#windows + 1] = win
      end
    end
  end
  return windows
end

local function draw_visible(view, windows, queue, add)
  local adjacent = {}
  for _, win in ipairs(windows) do
    local pane = window_layout(view, win)
    local before, after = window_pages(view, win, pane, add)
    for page = after, after + 2 do
      adjacent[#adjacent + 1] = { page = page, slot = pane.pages[page] }
    end
    adjacent[#adjacent + 1] = { page = before, slot = pane.pages[before] }
  end
  local visible_count = #queue
  for _, neighbor in ipairs(adjacent) do
    if neighbor.slot then
      add(neighbor.page, neighbor.slot, false)
    end
  end
  return visible_count
end

local function page_requests(view, windows)
  local queue, wanted, visible_pages = {}, {}, {}
  view.slots = {}
  local function add(page, slot, visible)
    local old = view.slots[page]
    if
      not old
      or (
        visible == visible_pages[page]
        and slot_size(view, slot) > slot_size(view, old)
      )
    then
      view.slots[page] = slot
    end
    visible_pages[page] = visible_pages[page] or visible
    if not wanted[page] then
      wanted[page] = true
      queue[#queue + 1] = page
    end
  end
  local ok, visible = pcall(draw_visible, view, windows, queue, add)
  if not ok then
    use_text(view, visible)
    return
  end
  return queue, wanted, visible
end

local function clear_window_pictures(view, win, pictures)
  graphics.clear(pictures)
  view.pictures[win] = nil
  local pane = view.panes[win]
  if not pane then
    return
  end
  pane.bar = nil
  if
    not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= view.buf
    or api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage()
  then
    detail.prune(pane)
  end
end

refresh = function(view)
  local windows = visible_windows(view)
  for win, pictures in pairs(view.pictures) do
    if not vim.tbl_contains(windows, win) then
      clear_window_pictures(view, win, pictures)
    end
  end
  if #windows == 0 then
    return
  end
  arrange(view, windows)
  local queue, wanted, visible = page_requests(view, windows)
  if not queue then
    return
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

local function mark_motion(view, win)
  view.scroll_win = win
  view.scrolled_at = vim.uv.now()
  settle_after_scroll(view)
  enqueue(view, true)
end

local function scroll_virtual(view, win, rows)
  local pane = view.panes[win]
  if not pane or not pane.pages or view.closed or not view.graphical then
    return
  end
  local top = topline(view, win)
  local height = api.nvim_win_get_height(win) - (pane.bar and 1 or 0)
  local limit = math.max(top, pane.last_row - height + 1)
  local target = math.max(1, math.min(top + rows, limit))
  if target ~= top then
    view.tops[win] = target
    mark_motion(view, win)
  end
end

local function move_pan(view, win, position)
  local pane = view.panes[win]
  if pane and pane.bar and pane.pan ~= position then
    pane.pan = position
    mark_motion(view, win)
  end
end

local function pan_by(view, win, amount)
  local pane = view.panes[win]
  if pane and pane.bar then
    local position = (pane.pan or 0.5) + amount / pane.bar.overflow
    move_pan(view, win, math.max(0, math.min(1, position)))
  end
end

local function content_origin(win)
  local info = vim.fn.getwininfo(win)[1]
  return vim.fn.screenpos(win, info.topline, 1)
end

local function drag_bar(mouse)
  local win = drag.win
  local pane = drag.view.panes[win]
  if
    not pane
    or not pane.bar
    or not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= drag.view.buf
  then
    drag = nil
    return
  end
  local col = mouse.screencol - content_origin(win).col + 1
  move_pan(drag.view, win, scrollbar.position(pane.bar, col, drag.grab))
end

local function press_bar(mouse, view)
  local win = mouse.winid
  local pane = view.panes[win]
  local bar = pane and pane.bar
  if not bar then
    return
  end
  local origin = content_origin(win)
  local col = mouse.screencol - origin.col + 1
  if
    mouse.screenrow ~= origin.row + api.nvim_win_get_height(win) - 1
    or col <= bar.x
    or col > bar.x + bar.width
  then
    return
  end
  local grab, on_thumb = scrollbar.drag_offset(bar, col)
  drag = { view = view, win = win, grab = grab }
  if not on_thumb then
    drag_bar(mouse)
  end
  return ""
end

local function wheel(view, win, axis, direction)
  view.scroll_key = nil
  local amount = tonumber(vim.o.mousescroll:match(axis .. ":(%d+)")) or 3
  if axis == "hor" then
    if not view.panes[win] or not view.panes[win].bar then
      return
    end
    pan_by(view, win, direction * amount)
  else
    scroll_virtual(view, win, direction * amount)
  end
  return ""
end

local function handle_pointer(key, events, buttons)
  if drag and (key == buttons.move or key == buttons.release) then
    drag_bar(vim.fn.getmousepos())
    if key == buttons.release then
      drag = nil
    end
    return ""
  end
  local event = events[key]
  if not event and key ~= buttons.press then
    return
  end
  local mouse = vim.fn.getmousepos()
  local win = mouse.winid
  local hovered = win ~= 0 and virtual_views[api.nvim_win_get_buf(win)]
  if hovered and event then
    return wheel(hovered, win, event[1], event[2])
  end
  if hovered then
    return press_bar(mouse, hovered)
  end
end

local function watch_pointer(view)
  virtual_views[view.buf] = view
  if pointer_listener then
    return
  end
  local events = {
    [vim.keycode("<ScrollWheelUp>")] = { "ver", -1 },
    [vim.keycode("<ScrollWheelDown>")] = { "ver", 1 },
    [vim.keycode("<ScrollWheelLeft>")] = { "hor", -1 },
    [vim.keycode("<ScrollWheelRight>")] = { "hor", 1 },
    [vim.keycode("<S-ScrollWheelUp>")] = { "hor", -1 },
    [vim.keycode("<S-ScrollWheelDown>")] = { "hor", 1 },
  }
  local press = vim.keycode("<LeftMouse>")
  local move = vim.keycode("<LeftDrag>")
  local release = vim.keycode("<LeftRelease>")
  local buttons = { press = press, move = move, release = release }
  pointer_listener = vim.on_key(function(key)
    return handle_pointer(key, events, buttons)
  end)
end

local function bind_pan(view)
  for lhs, direction in pairs({
    h = -1,
    l = 1,
    ["<Left>"] = -1,
    ["<Right>"] = 1,
  }) do
    vim.keymap.set("n", lhs, function()
      pan_by(view, api.nvim_get_current_win(), 3 * direction * vim.v.count1)
    end, { buffer = view.buf, desc = "Pan PDF horizontally" })
  end
end

local function scroll_key_phase(previous, gap)
  if previous.phase == "first" then
    if gap <= double_tap_ns then
      previous.pair_gap = gap
      return "pair"
    end
    return "normal"
  end
  if previous.phase == "pair" then
    -- A held key can also produce a quick pair. A pause before the next
    -- event distinguishes a tap followed by a new hold from steady repeats.
    local pause =
      math.max(tap_pause_ns, previous.pair_gap + tap_pause_margin_ns)
    return gap >= pause and "fast" or "normal"
  end
  return previous.phase
end

local function scroll_key_rows(view, win, direction)
  local count = vim.v.count
  if count > 0 then
    view.scroll_key = nil
    return count
  end

  local now, previous = vim.uv.hrtime(), view.scroll_key
  local gap = previous and now - previous.at
  local repeating = previous
    and (previous.phase == "fast" or previous.phase == "normal")
  local timeout = repeating and repeat_idle_ns or repeat_start_ns
  if
    not previous
    or previous.win ~= win
    or previous.direction ~= direction
    or gap > timeout
  then
    view.scroll_key =
      { win = win, direction = direction, at = now, phase = "first" }
    return 1
  end
  previous.phase, previous.at = scroll_key_phase(previous, gap), now
  return previous.phase == "fast" and fast_scroll_rows or 1
end

local function bind_scroll_keys(view)
  for key, direction in pairs({ j = 1, k = -1 }) do
    local native_key = direction > 0 and "<C-e>" or "<C-y>"
    local native_scroll = vim.keycode(native_key)
    vim.keymap.set("n", key, function()
      local win = api.nvim_get_current_win()
      local rows = scroll_key_rows(view, win, direction)
      if view.virtual then
        scroll_virtual(view, win, rows * direction)
      else
        vim.cmd.normal({ args = { rows .. native_scroll }, bang = true })
      end
    end, { buffer = view.buf, desc = "Scroll PDF" })
  end
end

local function virtual_keys(view)
  watch_pointer(view)
  bind_pan(view)
  local function bind(key, step, by_height)
    vim.keymap.set("n", key, function()
      view.scroll_key = nil
      local win = api.nvim_get_current_win()
      local height = by_height and math.max(1, api.nvim_win_get_height(win) - 2)
        or 1
      local rows = math.max(1, math.floor(height * math.abs(step)))
      scroll_virtual(view, win, rows * vim.v.count1 * (step > 0 and 1 or -1))
    end, { buffer = view.buf, desc = "Scroll PDF" })
  end
  for key, step in pairs({
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
  end, 160)
end

local function zoom(view, change)
  if not view.graphical then
    return
  end
  view.scroll_key = nil
  local pane = view.virtual and get_pane(view, api.nvim_get_current_win())
    or view
  local target = change and clamp_zoom(pane.zoom + change, view.virtual) or 100
  if not change then
    pane.pan = nil
  end
  if target ~= pane.zoom then
    pane.zoom_direction = (target >= pane.zoom or target == 100) and 1 or -1
    pane.zoom = target
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
  if not view.graphical then
    return use_text(view, reason)
  end
  bind_scroll_keys(view)
  if view.virtual then
    view.detail = detail.new(view.path, view.dir, function()
      enqueue(view)
    end)
    virtual_keys(view)
  end
  enqueue(view)
end

local function current_page(view)
  local win = api.nvim_get_current_win()
  local pane = window_layout(view, win)
  if not pane or not pane.pages then
    return view.page
  end
  return layout.page_at(pane.pages, topline(view, win))
end

go = function(view, target)
  if not view.info then
    return
  end
  view.scroll_key = nil
  local page = math.min(math.max(target, 1), view.info.count)
  local win = api.nvim_get_current_win()
  local pane = window_layout(view, win)
  if pane and pane.pages then
    local row = pane.pages[page].row
    if view.virtual then
      view.tops[win] = row
    else
      vim.fn.winrestview({ lnum = row, col = 0, topline = row })
    end
    enqueue(view)
  elseif page ~= view.page and not view.graphical then
    view.page = page
    text_page(view)
  end
end

local function prompt_page(view)
  if not view.info then
    return
  end
  local win, count = api.nvim_get_current_win(), view.info.count
  vim.ui.input(
    { prompt = ("PDF page (1–%d): "):format(count) },
    function(input)
      if
        not input
        or view.closed
        or not api.nvim_win_is_valid(win)
        or api.nvim_win_get_buf(win) ~= view.buf
      then
        return
      end
      local page = tonumber(input:match("^%s*(%d+)%s*$"))
      if not page or page < 1 or page > count then
        vim.notify(
          ("Enter a PDF page from 1 to %d."):format(count),
          vim.log.levels.WARN
        )
        return
      end
      api.nvim_win_call(win, function()
        go(view, page)
      end)
    end
  )
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
    local count = vim.v.count
    go(view, count > 0 and count or (view.info and view.info.count or 1))
  end, "Go to PDF page or last page")
  map("gp", function()
    prompt_page(view)
  end, "Go to PDF page by number")
  map("+", function()
    zoom(view, zoom_step * vim.v.count1)
  end, "Zoom in PDF")
  map("-", function()
    zoom(view, -zoom_step * vim.v.count1)
  end, "Zoom out PDF")
  map("0", function()
    zoom(view)
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
  options.list = false
  options.wrap = false
  options.scrolloff = 0
  options.sidescrolloff = 0
  api.nvim_win_call(win, function()
    vim.opt_local.fillchars:append({ eob = " " })
  end)
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
  detail.close(view.detail, view.panes)
  unwatch_pointer(view.buf)
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
      view.scroll_key = nil
      local win = vim.fn.win_findbuf(view.buf)[1]
      local pane = win and window_layout(view, win)
      if pane and pane.pages then
        if view.virtual then
          view.anchor = { pages = pane.pages, top = topline(view, win) }
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
      if args.event == "WinEnter" then
        view.scroll_key = nil
      end
      if args.event == "WinClosed" then
        local win = tonumber(args.match)
        local pane = view.panes[win]
        if pane then
          detail.prune(pane)
        end
        view.tops[win], view.presented[win], view.panes[win] = nil, nil, nil
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
    panes = {},
    tops = {},
    presented = {},
    pictures = {},
    rasters = {},
    prefetch_failed = {},
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
