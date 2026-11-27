--- Map document pages to native buffer rows so ordinary window scrolling
--- can show the end of one page and the start of the next at the same time.
local graphics = require("iara.features.pdf.graphics")

local M = {}

function M.page_at(pages, row)
  local first, last = 1, #pages
  while first < last do
    local middle = math.ceil((first + last) / 2)
    if pages[middle].row <= row then
      first = middle
    else
      last = middle - 1
    end
  end
  return first
end

function M.arrange(info, cols, rows, zoom, virtual)
  local pages, lines = {}, {}
  local row = 1
  local available = math.max(1, cols - 2)
  -- The Kitty renderer uses byte coordinates on visible anchor lines.
  local anchor = (" "):rep(vim.o.columns)
  for page = 1, info.count do
    local ratio = info.ratios[page] or 210 / 297
    local width, height, visible =
      graphics.fit(ratio, available, rows, zoom, virtual)
    pages[page] = {
      row = row,
      width = width,
      height = height,
      visible_width = visible,
    }
    row = row + height + 2
    if not virtual then
      lines[#lines + 1] = anchor
      for _ = 1, height + 1 do
        lines[#lines + 1] = ""
      end
    end
  end
  return pages, lines, row - 1
end

function M.relocate(before, after, row)
  if not before then
    return 1
  end
  local page = M.page_at(before, row)
  local old, new = before[page], after[page]
  local offset = math.min(row - old.row, old.height)
  return new.row + math.floor(offset * new.height / old.height + 0.5)
end

return M
