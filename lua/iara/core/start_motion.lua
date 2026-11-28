--- Render wave frames over the static start screen with virtual text.
--- A stopped screen has no timer or animation marks. The underlying
--- buffer and its menu selection stay intact when a frame advances.
local M = {}

local FRAME_MS = 25
local namespace = vim.api.nvim_create_namespace("iara.start.motion")
local active
local cover

---Stop playback and reveal the static wave.
function M.stop()
  local previous = active
  if not previous then
    return
  end
  active = nil
  previous.timer:stop()
  previous.timer:close()
  if vim.api.nvim_buf_is_valid(previous.buf) then
    vim.api.nvim_buf_clear_namespace(previous.buf, namespace, 0, -1)
  end
end

local function mark_row(animation, index, chunks)
  animation.ids[index] = vim.api.nvim_buf_set_extmark(
    animation.buf,
    namespace,
    animation.row + index - 1,
    animation.col,
    {
      id = animation.ids[index],
      virt_text = chunks,
      virt_text_pos = "overlay",
      priority = 20,
    }
  )
end

local function same_row(row, previous)
  if not previous or #row ~= #previous then
    return false
  end
  for index, chunk in ipairs(row) do
    local last = previous[index]
    if chunk[1] ~= last[1] or chunk[2] ~= last[2] then
      return false
    end
  end
  return true
end

local function paint(animation)
  if active ~= animation then
    return
  end
  animation.frame = animation.frame % animation.count + 1
  local frame = animation.frames[animation.frame]
  if not frame then
    frame = animation.render(animation.frame)
    animation.frames[animation.frame] = frame
  end
  local previous = animation.previous
  local changed = false
  for index, chunks in ipairs(frame) do
    if not previous or not same_row(chunks, previous[index]) then
      mark_row(animation, index, chunks)
      changed = true
    end
  end
  animation.previous = frame
  return changed
end

local function waiting_for_input()
  return vim.fn.state("S") ~= "" or vim.fn.getcmdtype() ~= ""
end

local function tick(animation)
  if animation.paused or not paint(animation) or not waiting_for_input() then
    return
  end
  -- A nested input wait or the command line can keep changed extmarks
  -- pending even while timers run.
  if vim.api.nvim__redraw then
    vim.api.nvim__redraw({ buf = animation.buf, valid = true, flush = true })
  else
    vim.cmd.redraw()
  end
end

local function covered(animation)
  local win = cover and vim.fn.bufwinid(animation.buf)
  if not win or win == -1 then
    return false
  end
  local row, col = unpack(vim.fn.win_screenpos(win))
  local bottom = row + vim.api.nvim_win_get_height(win)
  local right = col + vim.api.nvim_win_get_width(win)
  for _, rect in ipairs(cover) do
    if
      rect.row < bottom
      and rect.row + rect.rows > row
      and rect.col < right
      and rect.col + rect.cols > col
    then
      return true
    end
  end
  return false
end

local function sync_timer(animation)
  animation.paused = covered(animation)
  if animation.paused then
    animation.timer:stop()
  elseif not animation.timer:is_active() then
    animation.timer:start(FRAME_MS, FRAME_MS, animation.tick)
  end
end

---Avoid updating extmarks under a terminal graphic that covers this window.
function M.set_cover(rectangles)
  cover = rectangles
  if active then
    sync_timer(active)
  end
end

---Show the first motion frame and cache later frames as needed.
---@param buf integer Start screen buffer.
---@param row integer Zero-based first wave row.
---@param col integer Zero-based byte column.
---@param count integer Number of frames in the motion loop.
---@param render fun(frame: integer): string[][][] Per-row highlight chunks.
function M.play(buf, row, col, count, render)
  if active then
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  local animation = {
    buf = buf,
    row = row,
    col = col,
    count = count,
    render = render,
    frame = 0,
    frames = {},
    ids = {},
    timer = timer,
  }
  animation.tick = vim.schedule_wrap(function()
    tick(animation)
  end)
  active = animation
  timer:unref()
  paint(animation)
  sync_timer(animation)
end

return M
