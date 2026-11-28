--- Bounded Poppler requests shared by the viewer and the picker.
local proc = require("iara.core.proc")

local M = {}

local function run(path, argv, options, callback)
  return proc.spawn(argv, {
    cwd = vim.fs.dirname(path),
    env = { LC_ALL = "C" },
    timeout_ms = options.timeout,
    stdout = options.stdout,
    stderr = options.stderr,
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

local function raster_command(path, first, last, prefix, size, format, progress)
  local argv = { "pdftoppm", "-f", tostring(first), "-l", tostring(last) }
  if format ~= "ppm" then
    argv[#argv + 1] = "-png"
  end
  if first == last then
    argv[#argv + 1] = "-singlefile"
  end
  if progress then
    argv[#argv + 1] = "-progress"
  end
  return vim.list_extend(argv, { "-scale-to", tostring(size), path, prefix })
end

local raster_options = { timeout = 15000, stdout = { mode = "discard" } }

function M.raster(path, page, prefix, size, callback, format)
  local output_path = prefix .. (format == "ppm" and ".ppm" or ".png")
  local argv = raster_command(path, page, page, prefix, size, format)
  return run(path, argv, raster_options, function(output, err)
    local info = output and vim.uv.fs_stat(output_path)
    if info then
      return callback(output_path, nil, info.size)
    end
    vim.uv.fs_unlink(output_path)
    callback(nil, err or (output and "Could not rasterize PDF page."))
  end)
end

local function batch_page(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "file" then
    return { path = path, bytes = stat.size }
  end
end

local function batch_files(dir, first, last, format)
  local pages = {}
  local files = vim.uv.fs_scandir(dir)
  if not files then
    return pages
  end
  while true do
    local name = vim.uv.fs_scandir_next(files)
    if not name then
      break
    end
    local page = tonumber(name:match("^page%-(%d+)%." .. format .. "$"))
    if page and page >= first and page <= last then
      pages[page] = batch_page(dir .. "/" .. name)
    end
  end
  return pages
end

local function progress_stream(dir, first, last, format, on_page)
  local prefix = dir .. "/"
  local name = "^page%-(%d+)%." .. format .. "$"
  local function publish(line)
    -- Poppler prints the output path on stderr after closing the page file.
    local number, file = line:match("^(%d+)%s+%d+%s+(.+)$")
    local page = tonumber(number)
    if not page or page < first or page > last then
      return
    end
    if vim.startswith(file, prefix) then
      local index = tonumber(file:sub(#prefix + 1):match(name))
      local raster = index == page and batch_page(file)
      if raster then
        on_page(page, raster)
      end
    end
  end
  return {
    mode = "lines",
    on_data = function(lines)
      for _, line in ipairs(lines) do
        publish(line)
      end
    end,
  }
end

---Read only the numbered outputs from this job's own temporary directory.
function M.batch(path, first, last, dir, size, format, callback, on_page)
  local argv =
    raster_command(path, first, last, dir .. "/page", size, format, on_page)
  local options = vim.tbl_extend("force", {}, raster_options)
  if on_page then
    options.stderr = progress_stream(dir, first, last, format, on_page)
  end
  return run(path, argv, options, function(output)
    callback(output and batch_files(dir, first, last, format) or {})
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
