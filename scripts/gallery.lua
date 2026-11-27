-- Color gallery (task V2): render screens of Iara, with the colors of
-- every cell, for the visual identity evidence.
--
-- Usage:
--   nvim --clean -l scripts/gallery.lua [options] SCENARIO...
--
-- SCENARIO is a built-in name (`start`, `find-files`) or the path of a
-- Lua file returning a scenario table (see `Scenario` below). Options:
--
--   --theme NAME   Iara theme; repeatable (default: chocolate and
--                  github_light).
--   --data DIR     Provisioned data directory (plugins), linked as the
--                  child's data directory. Without it the child has no
--                  plugins.
--   --out DIR      Output directory (default: a new temporary directory
--                  under $TMPDIR).
--   --size WxH     Screen size (default 120x35).
--   --appname NAME NVIM_APPNAME of the child (default iara-gallery).
--   --audit        Also print every style that draws text below 4.5:1.
--
-- Each scenario and theme gives NAME-THEME.html (the screen with exact
-- cell colors, a legend, and the contrast audit), NAME-THEME.ansi
-- (24-bit ANSI text for `cat`), NAME-THEME.txt (plain text), and
-- NAME-THEME.md (legend and audit as Markdown tables).
--
-- The child runs the real Iara configuration (`iara/init.lua`, linked as
-- its config directory) with temporary XDG directories; the theme is
-- chosen by writing it where `:IaraTheme` stores it. Nothing outside the
-- temporary and output directories is written, and nothing is fetched.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local iara_dir = vim.fn.fnamemodify(source, ":p:h:h")
dofile(iara_dir .. "/tests/minit.lua")

local gallery = require("gallery")

local DEFAULT_THEMES = { "chocolate", "github_light" }
local USAGE = "usage: nvim --clean -l scripts/gallery.lua"
  .. " [--theme NAME]... [--data DIR] [--out DIR] [--size WxH]"
  .. " [--appname NAME] [--audit] SCENARIO..."

---@class gallery.Scenario
---@field name string Output file prefix; `[A-Za-z0-9_-]`.
---@field init string|nil Init file of the child (default Iara's).
---@field project table<string, string>|nil Files of the child's working
---  directory (path relative to it, content).
---@field args string[]|nil Arguments after the options (files to open).
---@field run fun(child: UiChild)|nil Drives the child after startup.
---@field expect string Text on screen when it is ready to capture.
---@field quiet_ms integer|nil Unchanged screen time before the capture.

local DEMO = table.concat({
  'import { useEffect, useState } from "react";',
  "",
  "export function Component() {",
  "  const [ready, setReady] = useState(false);",
  "  useEffect(() => setReady(true), []);",
  "  return ready;",
  "}",
}, "\n") .. "\n"

local DEMO_PROJECT = {
  [".git/HEAD"] = "ref: refs/heads/main\n",
  ["README.md"] = "# Demo\n\nA small project.\n",
  ["package.json"] = '{ "name": "demo" }\n',
  ["src/api/client.ts"] = "export const value = 1;\n",
  ["src/api/client.test.ts"] = "export const value = 1;\n",
  ["src/components/Button.tsx"] = DEMO,
  ["src/components/Button.test.tsx"] = DEMO,
  ["src/hooks/useFetch.ts"] = DEMO,
  ["src/hooks/useFetch.test.ts"] = DEMO,
  ["src/pages/Home.tsx"] = DEMO,
}

---@type table<string, gallery.Scenario>
local BUILTIN = {
  start = {
    name = "start",
    project = DEMO_PROJECT,
    expect = "Find files",
    -- Capture a complete frame between animation ticks.
    quiet_ms = 50,
  },
  ["find-files"] = {
    name = "find-files",
    project = DEMO_PROJECT,
    args = { "src/pages/Home.tsx" },
    run = function(child)
      child:wait_screen("useEffect")
      child:input("<Space>ff")
      child:wait_screen("Find files")
      child:input("test")
    end,
    expect = "3 files",
    quiet_ms = 600,
  },
}

local function fail(message)
  io.stderr:write("gallery: ", message, "\n")
  os.exit(2)
end

---@param path string
---@return gallery.Scenario
local function load_scenario(path)
  if BUILTIN[path] then
    return BUILTIN[path]
  end
  local ok, scenario = pcall(dofile, path)
  if not ok or type(scenario) ~= "table" then
    fail(("cannot load scenario %s: %s"):format(path, tostring(scenario)))
  end
  if type(scenario.name) ~= "string" or scenario.name:find("[^%w_-]") then
    fail(path .. ": name must use [A-Za-z0-9_-]")
  end
  if type(scenario.expect) ~= "string" then
    fail(path .. ": expect must be a string")
  end
  return scenario
end

local OPTIONS = {
  ["--theme"] = function(opts, value)
    table.insert(opts.themes, value)
  end,
  ["--data"] = function(opts, value)
    opts.data = vim.fs.normalize(vim.fn.fnamemodify(value, ":p"))
  end,
  ["--out"] = function(opts, value)
    opts.out = vim.fs.normalize(vim.fn.fnamemodify(value, ":p"))
  end,
  ["--appname"] = function(opts, value)
    opts.appname = value
  end,
  ["--size"] = function(opts, value)
    local width, height = value:match("^(%d+)x(%d+)$")
    opts.width, opts.height = tonumber(width), tonumber(height)
  end,
}

---@param argv string[]
local function parse(argv)
  local opts = { themes = {}, scenarios = {}, appname = "iara-gallery" }
  local index = 1
  while index <= #argv do
    local arg = argv[index]
    if OPTIONS[arg] and argv[index + 1] then
      OPTIONS[arg](opts, argv[index + 1])
      index = index + 1
    elseif arg == "--audit" then
      opts.audit = true
    elseif arg:sub(1, 2) == "--" then
      fail("unknown option " .. arg .. "\n" .. USAGE)
    else
      table.insert(opts.scenarios, load_scenario(arg))
    end
    index = index + 1
  end
  return opts
end

local function check(opts)
  if #opts.scenarios == 0 then
    fail(USAGE)
  end
  if not opts.width then
    opts.width, opts.height = 120, 35
  end
  if #opts.themes == 0 then
    opts.themes = DEFAULT_THEMES
  end
  if not opts.appname:find("^[%w_.-]+$") then
    fail("--appname must use [A-Za-z0-9_.-]")
  end
  local tmp = vim.env.TMPDIR or "/tmp"
  opts.out = opts.out
    or assert(vim.uv.fs_mkdtemp(tmp .. "/iara-gallery-XXXXXX"))
  vim.fn.mkdir(opts.out, "p")
end

local function write(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

---Temporary XDG directories for one child: Iara as the config
---directory, `data` (if any) as the data directory, and the theme where
---`:IaraTheme` stores it. Sets them in this process's environment, which
---`ui_child` passes on.
local function prepare_env(opts, theme)
  local root = assert(vim.uv.fs_mkdtemp(opts.out .. "/.run-XXXXXX"))
  local app = opts.appname
  for _, kind in ipairs({ "config", "data", "state", "cache" }) do
    vim.fn.mkdir(root .. "/" .. kind, "p")
    vim.env["XDG_" .. kind:upper() .. "_HOME"] = root .. "/" .. kind
  end
  assert(vim.uv.fs_symlink(iara_dir, ("%s/config/%s"):format(root, app)))
  if opts.data then
    assert(vim.uv.fs_symlink(opts.data, ("%s/data/%s"):format(root, app)))
  end
  vim.fn.mkdir(("%s/state/%s/iara"):format(root, app), "p")
  write(("%s/state/%s/iara/theme"):format(root, app), theme .. "\n")
  vim.env.NVIM_APPNAME = app
  return root
end

local function write_project(root, files)
  local dir = root .. "/demo"
  vim.fn.mkdir(dir, "p")
  for path, content in pairs(files or {}) do
    local full = dir .. "/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    write(full, content)
  end
  return dir
end

---Start the child in `cwd` (inherited from this process).
local function start_child(opts, scenario, cwd)
  local previous = vim.fn.getcwd()
  vim.fn.chdir(cwd)
  local ok, child = pcall(gallery.start, opts.width, opts.height, {
    init = scenario.init or (iara_dir .. "/init.lua"),
    args = scenario.args,
  })
  vim.fn.chdir(previous)
  if not ok then
    error(child, 0)
  end
  return child
end

local function capture(opts, scenario, theme)
  local root = prepare_env(opts, theme)
  local child =
    start_child(opts, scenario, write_project(root, scenario.project))
  local ok, result = pcall(function()
    if scenario.run then
      scenario.run(child)
    end
    return gallery.capture(child, scenario.expect, scenario.quiet_ms)
  end)
  child:stop()
  if vim.fn.delete(root, "rf") ~= 0 then
    io.stderr:write("gallery: cannot remove ", root, "\n")
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local MARKDOWN = [[
## %s

### Legend

%s

### Contrast below 4.5:1

%s
]]

---Write the four files of one screen; return its audit.
local function save(opts, name, snapshot)
  local audit = gallery.audit(snapshot)
  local legend = gallery.legend(snapshot)
  local base = ("%s/%s"):format(opts.out, name)
  local page = { title = name, audit = audit }
  write(base .. ".html", gallery.html(snapshot, page))
  write(base .. ".ansi", gallery.ansi(snapshot))
  write(base .. ".txt", gallery.text(snapshot) .. "\n")
  local tables = { gallery.markdown(legend), gallery.markdown(audit) }
  write(base .. ".md", MARKDOWN:format(name, unpack(tables)))
  print(
    ("%s: %s.html (%d styles, %d below 4.5:1)"):format(
      name,
      base,
      #legend,
      #audit
    )
  )
  if opts.audit and #audit > 0 then
    io.stdout:write(tables[2], "\n")
  end
end

local function main(argv)
  local opts = parse(argv)
  check(opts)
  local failed = false
  for _, scenario in ipairs(opts.scenarios) do
    for _, theme in ipairs(opts.themes) do
      local name = scenario.name .. "-" .. theme
      local ok, snapshot = pcall(capture, opts, scenario, theme)
      if ok then
        save(opts, name, snapshot)
      else
        failed = true
        io.stderr:write(("gallery: %s failed: %s\n"):format(name, snapshot))
      end
    end
  end
  return failed and 1 or 0
end

local code = main(_G.arg)
io.stdout:flush()
os.exit(code)
