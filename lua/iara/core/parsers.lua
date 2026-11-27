--- Pinned Tree-sitter parsers that Neovim does not bundle.
---
--- `parsers-lock.txt` pins each grammar's repository and commit. Builds
--- (scripts/parsers.sh, called by scripts/bootstrap.lua) write a runtime
--- directory holding `parser/<lang>.so` and `stamps/<lang>`, the commit a
--- parser was built from. An installation keeps its parsers in its
--- current release under stdpath("data"); a development checkout under
--- `.tools/`. Reading this
--- state never runs a process. See contracts.md, section 13.
local M = {}

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local IARA_DIR = vim.fn.fnamemodify(source, ":p:h:h:h:h")

---The parser lock shipped with the release.
M.LOCK = IARA_DIR .. "/parsers-lock.txt"

---Development parsers built by `scripts/parsers.sh` without arguments.
M.DEV_RUNTIME = IARA_DIR .. "/.tools/treesitter"

---@class IaraParserPin
---@field lang string Tree-sitter language, for example "yaml".
---@field repo string GitHub "owner/repository".
---@field commit string Full commit hash.
---@field tag string? Release tag, for reference only.

local KEYS = { repo = true, commit = true, tag = true }

local function lock_error(message)
  return { code = "lock_invalid", message = message }
end

local function read_text(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

---@return string|nil problem
local function pin_problem(pin)
  if not pin.lang:match("^[%w_]+$") then
    return "invalid language name " .. vim.inspect(pin.lang)
  end
  if not (pin.repo or ""):match("^[%w._-]+/[%w._-]+$") then
    return "parser " .. pin.lang .. " needs repo <owner/repository>"
  end
  if not (pin.commit or ""):match("^" .. ("%x"):rep(40) .. "$") then
    return "parser " .. pin.lang .. " needs a full 40-character commit"
  end
end

---Apply one "key value" line to the pins being collected.
---@return string|nil problem
local function apply_line(pins, key, value)
  if key == "parser" then
    for _, pin in ipairs(pins) do
      if pin.lang == value then
        return "parser " .. value .. " is listed twice"
      end
    end
    table.insert(pins, { lang = value })
  elseif KEYS[key] and #pins > 0 then
    pins[#pins][key] = value
  else
    return "unexpected line: " .. key .. " " .. value
  end
end

---Apply one line of the lock; blank lines and comments do nothing.
---@return string|nil problem
local function parse_line(pins, line)
  local text = vim.trim(line)
  if text == "" or vim.startswith(text, "#") then
    return nil
  end
  local key, value = text:match("^(%S+)%s+(%S+)$")
  if not key then
    return "malformed line: " .. text
  end
  return apply_line(pins, key, value)
end

---Parse a parser lock. Error codes: "lock_missing", "lock_invalid".
---@param path string? Defaults to M.LOCK.
---@return IaraParserPin[]|nil pins In file order.
---@return IaraError|nil err
function M.read_lock(path)
  path = path or M.LOCK
  local text = read_text(path)
  if not text then
    return nil, { code = "lock_missing", message = "cannot read " .. path }
  end
  local pins = {}
  for line in vim.gsplit(text, "\n", { plain = true }) do
    local problem = parse_line(pins, line)
    if problem then
      return nil, lock_error(path .. ": " .. problem)
    end
  end
  for _, pin in ipairs(pins) do
    local problem = pin_problem(pin)
    if problem then
      return nil, lock_error(path .. ": " .. problem)
    end
  end
  return pins
end

---Runtime directory of the installation's parsers: inside the current
---release, or stdpath("data")/treesitter for an installation made before
---releases existed.
---@return string
function M.runtime_dir()
  return require("iara.core.lazy").paths().parsers
end

---Runtime for parsers installed by nvim-treesitter, shared across releases.
---@return string
function M.extra_runtime()
  return vim.fn.stdpath("data") .. "/iara-treesitter"
end

---Directories to put on 'runtimepath', installation first.
---@return string[]
function M.runtime_dirs()
  return { M.runtime_dir(), M.DEV_RUNTIME }
end

---Path of the compiled parser of `lang` below a runtime directory.
---@param dir string
---@param lang string
---@return string
function M.parser_path(dir, lang)
  return dir .. "/parser/" .. lang .. ".so"
end

---Commit the parser of `lang` in `dir` was built from: nil when the
---parser is missing, "unknown" when it has no readable stamp.
---@param dir string
---@param lang string
---@return string|nil
function M.installed_commit(dir, lang)
  if not vim.uv.fs_stat(M.parser_path(dir, lang)) then
    return nil
  end
  local stamp = read_text(dir .. "/stamps/" .. lang)
  return stamp and vim.trim(stamp):match("^%x+$") or "unknown"
end

return M
