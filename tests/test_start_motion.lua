local motion = require("iara.core.start_motion")
local eq = MiniTest.expect.equality
local api = vim.api
local original = api.nvim_buf_set_extmark
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      api.nvim_buf_set_extmark = original
      motion.stop()
      motion.set_cover(nil)
    end,
  },
})

T["repaints only rows whose text or highlight changed"] = function()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "", "" })
  local rows = {}
  api.nvim_buf_set_extmark = function(target, ns, row, col, opts)
    table.insert(rows, row)
    return original(target, ns, row, col, opts)
  end
  motion.play(buf, 0, 0, 3, function(frame)
    return {
      { { "wave", "Normal" } },
      { { "foam", frame == 3 and "Comment" or "Normal" } },
    }
  end)
  eq(
    vim.wait(1000, function()
      return #rows >= 4
    end, 1),
    true
  )
  eq(rows, { 0, 1, 1, 1 })
  motion.stop()
  local ns = api.nvim_get_namespaces()["iara.start.motion"]
  eq(api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), {})
  api.nvim_buf_delete(buf, { force = true })
end

T["pauses motion when the preview intersects its window"] = function()
  local buf = api.nvim_get_current_buf()
  local count = 0
  motion.set_cover({ { row = 1, col = 1, rows = 5, cols = 5 } })
  motion.play(buf, 0, 0, 3, function(frame)
    count = count + 1
    return { { { tostring(frame), "Normal" } } }
  end)
  eq(
    vim.wait(100, function()
      return count > 1
    end, 10),
    false
  )
  motion.set_cover({ { row = 1, col = vim.o.columns + 1, rows = 5, cols = 5 } })
  eq(
    vim.wait(1000, function()
      return count > 1
    end, 10),
    true
  )
end

return T
