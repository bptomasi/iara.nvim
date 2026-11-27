--- Bounded Poppler requests shared by the viewer and the picker.
local proc = require("iara.core.proc")

local M = {}

local function run(path, argv, options, callback)
  return proc.spawn(argv, {
    cwd = vim.fs.dirname(path),
    env = { LC_ALL = "C" },
    timeout_ms = options.timeout,
    stdout = options.stdout,
    on_complete = function(result)
      if result.status == "exited" and result.code == 0 then
        callback(result.stdout or "")
      elseif result.status == "cancelled" then
        callback(nil, nil)
      elseif result.status == "timeout" then
        callback(nil, "PDF processing timed out.")
      else
        local message = result.error and result.error.message
        callback(
          nil,
          message
            or (result.stderr or ""):match("[^\r\n]+")
            or "Could not read PDF."
        )
      end
    end,
  })
end

local function page_ratios(output)
  local ratios = {}
  for page, w, h in
    output:gmatch("\nPage%s+(%d+) size:%s*([%d.]+) x ([%d.]+) pts")
  do
    local width, height = tonumber(w), tonumber(h)
    if width and height and width > 0 and height > 0 then
      ratios[tonumber(page)] = width / height
    end
  end
  for page, rotation in output:gmatch("\nPage%s+(%d+) rot:%s*(%-?%d+)") do
    local index = tonumber(page)
    if ratios[index] and tonumber(rotation) % 180 == 90 then
      ratios[index] = 1 / ratios[index]
    end
  end
  return ratios
end

function M.info(path, callback)
  return run(path, { "pdfinfo", "-l", "2147483647", path }, {
    timeout = 5000,
    stdout = { max_bytes = 4 * 1024 * 1024 },
  }, function(output, err)
    if not output then
      return callback(nil, err)
    end
    local count = tonumber(output:match("\nPages:%s*(%d+)"))
    if not count or count < 1 then
      return callback(nil, "Could not read PDF page count.")
    end
    local ratios = page_ratios(output)
    callback({ count = count, ratios = ratios })
  end)
end

function M.directory()
  return vim.uv.fs_mkdtemp(vim.fn.tempname() .. "-pdf-XXXXXX")
end

function M.raster(path, page, prefix, size, callback, format)
  local number = tostring(page)
  local ppm = format == "ppm"
  local output_path = prefix .. (ppm and ".ppm" or ".png")
  local argv = { "pdftoppm", "-f", number, "-l", number }
  if not ppm then
    argv[#argv + 1] = "-png"
  end
  vim.list_extend(
    argv,
    { "-singlefile", "-scale-to", tostring(size), path, prefix }
  )
  local options = { timeout = 15000, stdout = { mode = "discard" } }
  return run(path, argv, options, function(output, err)
    local info = output and vim.uv.fs_stat(output_path)
    if info then
      return callback(output_path, nil, info.size)
    end
    vim.uv.fs_unlink(output_path)
    callback(nil, err or (output and "Could not rasterize PDF page."))
  end)
end

function M.text(path, page, callback)
  local number = tostring(page)
  return run(path, {
    "pdftotext",
    "-f",
    number,
    "-l",
    number,
    "-layout",
    path,
    "-",
  }, { timeout = 15000 }, function(output, err)
    if not output then
      return callback(nil, err)
    end
    local clean = output:gsub("[%z\r\f]", "")
    local lines = vim.split(clean, "\n", { plain = true, trimempty = true })
    if #lines == 0 then
      lines = { "This page has no extractable text." }
    end
    callback(lines)
  end)
end

return M
