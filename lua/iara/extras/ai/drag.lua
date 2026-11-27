---Mouse movement for the two-window Ask AI popup.
local api = vim.api
local M = {}

-- A second grab at the last drop position can be counted as a click
-- in the same sequence. The title still acts as the drag handle.
local CLICK_PREFIXES = { "<Left", "<2-Left", "<3-Left", "<4-Left" }

local function grip_at(popup, mouse)
  local top = api.nvim_win_get_config(popup.win)
  local row, col = mouse.screenrow - 1, mouse.screencol - 1
  if row ~= top.row or col < top.col or col > top.col + top.width + 1 then
    return nil
  end
  local input = api.nvim_win_get_config(popup.input_win)
  return {
    offset = input.row - top.row,
    grab = col - top.col,
    width = top.width + 2,
    height = input.row - top.row + input.height + 1,
  }
end

local function clamp(value, limit)
  return math.max(0, math.min(value, limit))
end

local function move(popup, grip, mouse)
  if popup.closed or not api.nvim_win_is_valid(popup.input_win) then
    return
  end
  if not api.nvim_win_is_valid(popup.win) then
    return
  end
  local rows = vim.o.lines - vim.o.cmdheight
  local row = clamp(mouse.screenrow - 1, rows - grip.height)
  local col = clamp(mouse.screencol - 1 - grip.grab, vim.o.columns - grip.width)
  api.nvim_win_set_config(
    popup.win,
    { relative = "editor", row = row, col = col }
  )
  api.nvim_win_set_config(popup.input_win, {
    relative = "editor",
    row = row + grip.offset,
    col = col,
  })
end

local function map(buf, key, on_event)
  vim.keymap.set({ "n", "i", "x" }, key, function()
    if on_event(vim.fn.getmousepos()) then
      return ""
    end
    return key
  end, { buffer = buf, expr = true, nowait = true })
end

---Drag both windows from the top border. Other clicks keep their
---native behavior, including positioning the cursor in the question.
---@param popup IaraAiPopup
function M.setup(popup)
  local grip
  local function press(mouse)
    grip = grip_at(popup, mouse)
    return grip ~= nil
  end
  local function drag(mouse)
    local held = grip
    if held then
      -- Expression mappings cannot change windows under textlock.
      vim.schedule(function()
        move(popup, held, mouse)
      end)
    end
    return held ~= nil
  end
  local function release()
    local held = grip
    grip = nil
    return held ~= nil
  end
  for _, buf in ipairs({ popup.buf, popup.input_buf }) do
    for _, prefix in ipairs(CLICK_PREFIXES) do
      map(buf, prefix .. "Mouse>", press)
      map(buf, prefix .. "Drag>", drag)
      map(buf, prefix .. "Release>", release)
    end
  end
end

return M
