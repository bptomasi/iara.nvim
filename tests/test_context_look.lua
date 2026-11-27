-- Look of the agent context preview (V11, V13): plain title, size chip,
-- footer with the safety rule, and a summary drawn as virtual lines, while
-- the buffer still holds exactly the payload that `y` copies.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local preview = require("iara.extras.agents.preview")

local LIMIT = 128 * 1024

local function text(chunks)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, chunks))
end

local T = MiniTest.new_set()

T["size label counts bytes, then KiB, against the cap"] = function()
  eq(preview.size_label(512, LIMIT), "512 B of 128 KiB")
  eq(preview.size_label(3174, LIMIT), "3.1 KiB of 128 KiB")
end

---The chunk whose text is `wanted`, or nil.
local function chunk_of(chunks, wanted)
  for _, chunk in ipairs(chunks) do
    if chunk[1] == wanted then
      return chunk
    end
  end
end

local function chip(chunks)
  return chunks[#chunks - 1]
end

T["title spans the width with the title left and the chip right"] = function()
  local chunks = preview.title(60, 3174, LIMIT)
  eq(vim.api.nvim_strwidth(text(chunks)), 60)
  -- Idle groups: the window's focused frame remaps them (V13).
  eq(chunk_of(chunks, " Agent context ")[2], "FloatTitle")
  eq(chunks[1], { "\u{2500}", "FloatBorder" })
  eq(chunks[#chunks], { "\u{2500}", "FloatBorder" })
  eq(chip(chunks), { " 3.1 KiB of 128 KiB ", "IaraContextChip" })
end

T["chip warns above 80% of the cap and drops when narrow"] = function()
  local warn = preview.title(60, math.floor(LIMIT * 0.81), LIMIT)
  eq(chip(warn)[2], "IaraContextChipWarn")
  local calm = preview.title(60, math.floor(LIMIT * 0.8), LIMIT)
  eq(chip(calm)[2], "IaraContextChip")
  local narrow = preview.title(24, 10, LIMIT)
  eq(text(narrow), "\u{2500} Agent context ")
end

T["footer states the keys and that nothing is sent"] = function()
  local footer = preview.footer()
  eq(text(footer), " y copy · q close · (nothing is sent) ")
  eq(chunk_of(footer, "y")[2], "IaraFloatFooterKey")
end

T["summary describes the selection and diagnostics"] = function()
  local linewise = {
    mode = "linewise",
    path = "lua/a.lua",
    buffer_label = "lua/a.lua",
    range = { 11, 0, 24, 0 },
    unsaved = true,
  }
  eq(preview.summary(linewise), {
    { "Selection", "lua/a.lua:12-24  linewise, unsaved" },
  })
  local charwise = {
    mode = "charwise",
    buffer_label = "[No Name 3]",
    range = { 4, 2, 4, 9 },
    diagnostics = {},
  }
  eq(preview.summary(charwise), {
    { "Selection", "[No Name 3]:5  charwise" },
    { "Diagnostics", "none in the captured range" },
  })
  local reference = {
    mode = "reference",
    path = "b.lua",
    buffer_label = "b.lua",
    diagnostics = { {}, {} },
  }
  eq(preview.summary(reference), {
    { "Reference", "b.lua (read from disk)" },
    { "Diagnostics", "2 in the captured range" },
  })
end

-- Through the context module in a child --------------------------------

local child = helpers.new_child()

T["preview"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.o.columns, child.o.lines = 120, 35
    end,
    post_once = child.stop,
  },
})

local OPEN = [[
local ctx = require("iara.extras.agents.context")
vim.api.nvim_buf_set_lines(0, 0, -1, true, { "local x = 1", "return x" })
vim.bo.filetype = "lua"
vim.cmd("normal! ggVj")
local snap = assert(ctx.capture({ diagnostics = ... }))
vim.cmd("normal! \27")
assert(ctx.preview(snap))
local buf = vim.api.nvim_get_current_buf()
local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1,
  { details = true })
local virt = {}
for _, item in ipairs(marks) do
  for _, line in ipairs(item[4].virt_lines or {}) do
    local parts = {}
    for _, chunk in ipairs(line) do table.insert(parts, chunk[1]) end
    table.insert(virt, table.concat(parts))
  end
end
return {
  shown = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, true), "\n"),
  payload = ctx.format(snap),
  virt = virt,
  topfill = vim.fn.winsaveview().topfill,
  height = vim.api.nvim_win_get_height(0),
  lines = vim.api.nvim_buf_line_count(buf),
}
]]

T["preview"]["summary rows are virtual; the buffer is the payload"] = function()
  child.g.loaded_clipboard_provider = 1
  local result = child.lua(OPEN, { true })
  eq(result.shown, result.payload)
  eq(#result.virt, 3)
  match(
    result.virt[1],
    "^\u{25b8} Selection +%[No Name%] %(buffer %d+%):1%-2  linewise"
  )
  match(result.virt[2], "^\u{25b8} Diagnostics +none in the captured range")
  eq(result.virt[3]:gsub("\u{2500}", ""), "")
  eq(result.topfill, 3)
  eq(result.height, result.lines + 3)
  child.type_keys("y")
  eq(child.fn.getreg('"'), result.payload)
end

T["preview"]["without diagnostics there is one summary row"] = function()
  local result = child.lua(OPEN, { false })
  eq(#result.virt, 2)
  eq(result.topfill, 2)
end

return T
