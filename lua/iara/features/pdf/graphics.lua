--- Show Poppler's PNG in a PDF buffer using the host terminal protocol.
local M = {}
local api = vim.api
local image
local sixel

local function backend()
  if #api.nvim_list_uis() == 0 or vim.uv.guess_handle(1) ~= "tty" then
    return
  end
  local term = vim.env.TERM or ""
  local program = vim.env.TERM_PROGRAM
  if term == "foot" or term == "foot-extra" then
    return "sixel"
  end
  if
    vim.env.KITTY_WINDOW_ID
    or vim.env.GHOSTTY_RESOURCES_DIR
    or term == "xterm-kitty"
    or term == "xterm-ghostty"
    or program == "ghostty"
    or program == "WezTerm"
  then
    return "kitty"
  end
end

function M.options()
  return {
    backend = backend() or "kitty",
    processor = "magick_cli",
    integrations = {
      markdown = { enabled = false },
      asciidoc = { enabled = false },
      neorg = { enabled = false },
      rst = { enabled = false },
      typst = { enabled = false },
      syslang = { enabled = false },
    },
    hijack_file_patterns = {},
    max_width_window_percentage = 100,
    max_height_window_percentage = 100,
    window_overlap_clear_enabled = true,
  }
end

function M.available()
  local protocol = backend()
  if not protocol or vim.fn.executable("pdftoppm") == 0 then
    return false
  end
  if vim.fn.executable("magick") == 0 and vim.fn.executable("convert") == 0 then
    return false
  end
  if not image then
    local ok, plugin = pcall(require, "image")
    if not ok then
      return false, plugin
    end
    image = plugin
  end
  if protocol == "sixel" and not sixel then
    sixel = require("iara.features.pdf.sixel")
  end
  return true
end

function M.virtual_scroll()
  return sixel ~= nil
end

function M.warm(path, rect)
  if sixel then
    sixel.warm(path, rect)
  end
end

function M.refresh()
  if sixel then
    sixel.refresh()
  end
end

function M.invalidate(win)
  if sixel then
    sixel.invalidate(win)
  end
end

function M.forget(path)
  if sixel then
    sixel.forget(path)
  end
end

function M.ready(path, rect)
  return not sixel or sixel.ready(path, rect)
end

function M.warm_zoom(path, rect)
  if sixel then
    sixel.warm_zoom(path, rect)
  end
end

function M.retain(path, replacement, max_size)
  if sixel then
    sixel.retain(path, replacement, max_size)
  end
end

--- Use the same measured cell aspect ratio as the terminal renderer.
function M.size()
  return require("image/utils/term").get_size()
end

function M.fit(ratio, cols, rows, zoom, crop)
  local size = M.size()
  local cells = ratio * size.cell_height / size.cell_width
  local available = cols
  if zoom and zoom ~= 100 then
    local scale = zoom / 100
    local fitted = math.min(rows, cols / cells)
    rows = math.max(1, math.ceil(fitted * scale))
    cols = math.max(1, math.floor(fitted * scale * cells))
    if not crop then
      cols = math.min(cols, available)
    end
  end
  local width = math.max(1, math.min(cols, math.floor(rows * cells)))
  local height = math.max(1, math.min(rows, math.ceil(width / cells)))
  return width, height, math.min(width, available)
end

function M.picture(path, win, buf, rect)
  if sixel then
    return sixel.picture(path, win, buf, rect)
  end
  local picture = assert(
    image.from_file(path, {
      window = win,
      buffer = buf,
      x = rect.x,
      y = rect.y,
      width = rect.width,
      height = rect.height,
      max_height_window_percentage = math.huge,
      overlap = rect.height + 1,
    }),
    "image.nvim could not open the rendered page"
  )
  picture:render()
  return picture
end

function M.clear(pictures)
  for page, picture in pairs(pictures) do
    picture.image:clear()
    pictures[page] = nil
  end
end

return M
