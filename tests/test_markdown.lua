-- Markdown rendering (task MD1): render-markdown.nvim at its locked
-- commit renders headings, emphasis, tables, tasks, and callouts; the
-- cursor's line stays raw in every mode; the toggle and conservative
-- buffers turn rendering off; lazy.nvim loads the plugin for Markdown
-- only; the theme groups read on every palette. MD2: jumping through a
-- long note does not re-parse per row for hidden fence lines.
local helpers = require("helpers")
local lazy_fixture = require("lazy_fixture")

local eq = MiniTest.expect.equality

local theme = require("iara.theme")
local roles = require("iara.theme.roles")
local hl = require("iara.theme.highlights")

local SPEC = helpers.iara_dir .. "/lua/iara/plugins/render_markdown.lua"

local checkouts = {}

---Checkout of a locked plugin repository (once per test run).
---@param repo string "owner/name"
---@return string dir
local function checkout(repo)
  if checkouts[repo] then
    return checkouts[repo]
  end
  local name = vim.fs.basename(repo)
  local entry = lazy_fixture.release_entry(name)
  local dir = helpers.temp_dir() .. "/" .. name
  local mirror = lazy_fixture.url_format():format(repo)
  lazy_fixture.git({ "clone", "--quiet", mirror, dir })
  lazy_fixture.git({ "checkout", "--quiet", entry.commit }, dir)
  checkouts[repo] = dir
  return dir
end

local function plugin_dir()
  return checkout("MeanderingProgrammer/render-markdown.nvim")
end

local NOTE = {
  "# Iara notes",
  "",
  "Plain text with _italic_, **bold**, and ~~struck~~ words.",
  "",
  "| Palette | Type |",
  "| --- | ---: |",
  "| chocolate | dark |",
  "",
  "- [ ] Open task",
  "- [x] Done task",
  "- [/] Task in progress",
  "",
  "> [!NOTE]",
  "> A callout.",
}

local child = helpers.new_child()

---Start the child with the plugin on 'runtimepath' and Iara's setup.
local function start()
  child.restart({ "-u", helpers.minimal_init })
  child.o.lines, child.o.columns = 40, 100
  child.lua(
    [[
    vim.opt.runtimepath:prepend(...)
    require("iara.core.eligibility").setup({})
    require("iara.theme").apply("chocolate")
    vim.cmd("runtime plugin/render-markdown.lua")
    require("iara.features.markdown").setup()
  ]],
    { plugin_dir() }
  )
end

local T = MiniTest.new_set({
  hooks = { post_once = child.stop },
})

---Open `lines` as `name` (a Markdown file in a temporary directory).
local function open(lines, name)
  local path = helpers.temp_dir() .. "/" .. (name or "note.md")
  helpers.write_file(path, table.concat(lines, "\n") .. "\n")
  child.cmd("edit " .. vim.fn.fnameescape(path))
  return path
end

---Rendered extmarks of the current buffer once rendering settles:
---`{ { row, text }... }` with 1-based rows, `{}` when none.
local function marks()
  return child.lua_get([[(function()
    local ns = vim.api.nvim_get_namespaces()["render-markdown.nvim"]
    local function collect()
      local rows = {}
      local all = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1,
        { details = true })
      for _, mark in ipairs(all) do
        local row, texts = mark[2] + 1, {}
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          table.insert(texts, chunk[1])
        end
        for _, line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(line) do
            table.insert(texts, chunk[1])
          end
        end
        table.insert(rows, { row, table.concat(texts) })
      end
      return rows
    end
    -- Updates run on a later main-loop iteration (vim.schedule).
    vim.wait(150, function() return false end)
    return collect()
  end)()]])
end

---Virtual text of the marks on `row`, joined by "|".
local function row_text(marks_list, row)
  local texts = {}
  for _, mark in ipairs(marks_list) do
    if mark[1] == row then
      table.insert(texts, mark[2])
    end
  end
  return table.concat(texts, "|")
end

local function has(text, part)
  if not text:find(part, 1, true) then
    error(("%q lacks %q"):format(text, part), 2)
  end
end

local GLYPHS = require("iara.core.icons").MARKDOWN

---Move the cursor with a Normal-mode command, so CursorMoved fires.
local function go(row)
  child.type_keys(row .. "G")
end

---`rendering(bufnr)` of the feature as a string ("nil" before attach).
local function rendering(bufnr)
  local expr = "tostring(require('iara.features.markdown').rendering(%d))"
  return child.lua_get(expr:format(bufnr))
end

T["rendering"] = MiniTest.new_set({ hooks = { pre_case = start } })

T["rendering"]["draws headings, tables, tasks, and callouts"] = function()
  open(NOTE)
  go(3)
  local rows = marks()
  has(row_text(rows, 1), GLYPHS.headings[1])
  -- The table is framed by straight corners on the empty lines around.
  has(row_text(rows, 4), GLYPHS.table[1])
  has(row_text(rows, 8), GLYPHS.table[7])
  has(row_text(rows, 9), GLYPHS.unchecked)
  has(row_text(rows, 10), GLYPHS.checked)
  has(row_text(rows, 11), GLYPHS.progress)
  has(row_text(rows, 13), "Note")
  -- Emphasis markers are concealed outside the cursor's line.
  eq(child.wo.conceallevel, 3)
  eq(child.wo.concealcursor, "")
end

T["rendering"]["table columns line up on screen"] = function()
  open(NOTE)
  go(1)
  marks()
  local rows = child.lua_get([[(function()
    local rows = {}
    for row = 1, vim.o.lines do
      local cells = {}
      for col = 1, vim.o.columns do
        cells[#cells + 1] = vim.fn.screenstring(row, col)
      end
      rows[#rows + 1] = vim.trim(table.concat(cells))
    end
    return rows
  end)()]])
  local head, body
  for _, text in ipairs(rows) do
    head = head or (text:find("Palette", 1, true) and text)
    body = body or (text:find("chocolate", 1, true) and text)
  end
  -- The raw rows differ in width; the padded cells line up.
  eq(#NOTE[5] ~= #NOTE[7], true)
  eq(vim.fn.strdisplaywidth(head), vim.fn.strdisplaywidth(body))
  eq(vim.startswith(head, GLYPHS.table[10]), true)
end

T["rendering"]["the cursor's line shows raw text in Normal mode"] = function()
  open(NOTE)
  go(1)
  eq(row_text(marks(), 1):find(GLYPHS.headings[1], 1, true), nil)
  go(3)
  has(row_text(marks(), 1), GLYPHS.headings[1])
end

T["rendering"]["Insert mode shows the raw note"] = function()
  open(NOTE)
  go(9)
  has(row_text(marks(), 1), GLYPHS.headings[1])
  child.type_keys("A", " now")
  eq(child.fn.mode(), "i")
  eq(marks(), {})
  eq(child.wo.conceallevel, 0)
  -- Leaving Insert mode renders again.
  child.type_keys("<Esc>")
  has(row_text(marks(), 1), GLYPHS.headings[1])
  eq(child.wo.conceallevel, 3)
end

T["rendering"]["the toggle turns rendering off and on"] = function()
  open(NOTE)
  go(3)
  has(row_text(marks(), 1), GLYPHS.headings[1])
  child.cmd("IaraMarkdownToggle")
  eq(marks(), {})
  eq(child.wo.conceallevel, 0)
  eq(child.lua_get("require('iara.features.markdown').enabled()"), false)
  child.cmd("IaraMarkdownToggle")
  has(row_text(marks(), 1), GLYPHS.headings[1])
  eq(child.wo.conceallevel, 3)
end

T["rendering"]["the toggle applies to every Markdown buffer"] = function()
  open(NOTE, "first.md")
  local first = child.api.nvim_get_current_buf()
  open(NOTE, "second.md")
  child.cmd("IaraMarkdownToggle")
  eq(rendering(first), "false")
  child.cmd("buffer " .. first)
  go(3)
  eq(marks(), {})
end

T["rendering"]["conservative buffers stay raw until eligible"] = function()
  child.lua("require('iara.core.eligibility').LIMITS.max_line_bytes = 200")
  local lines = vim.list_extend({}, NOTE)
  table.insert(lines, string.rep("x", 300))
  open(lines)
  go(3)
  eq(marks(), {})
  local bufnr = child.api.nvim_get_current_buf()
  eq(rendering(bufnr), "false")
  -- Removing the long line makes the buffer eligible again.
  child.api.nvim_buf_set_lines(0, #lines - 1, #lines, true, {})
  local wait = "vim.wait(1000, function()"
    .. " return require('iara.features.markdown').rendering(%d) end)"
  child.lua(wait:format(bufnr))
  eq(rendering(bufnr), "true")
  has(row_text(marks(), 1), GLYPHS.headings[1])
end

T["rendering"]["buffers that are not files are never attached"] = function()
  child.lua([[
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "# Scratch", "" })
    vim.bo[bufnr].filetype = "markdown"
  ]])
  eq(marks(), {})
  eq(rendering(child.api.nvim_get_current_buf()), "nil")
end

-- Scrolling cost (task MD2) --------------------------------------------------

---A long note: `count` sections, each with a fenced code block.
local function long_note(count)
  local lines = {}
  for index = 1, count do
    vim.list_extend(lines, {
      "## Section " .. index,
      "",
      "Text with **bold** and `code`.",
      "",
      "```lua",
      "local value = " .. index,
      "```",
      "",
    })
  end
  return lines
end

---Open `lines` with Tree-sitter highlighting started before the plugin
---attaches, as Iara's FileType handler does.
local function open_highlighted(lines)
  local path = helpers.temp_dir() .. "/long.md"
  helpers.write_file(path, table.concat(lines, "\n") .. "\n")
  child.cmd("noautocmd edit " .. vim.fn.fnameescape(path))
  child.lua("vim.treesitter.start(0, 'markdown')")
  child.cmd("setfiletype markdown")
  marks()
end

local function highlighted()
  local expr = "vim.treesitter.highlighter.active[%d] ~= nil"
  return child.lua_get(expr:format(child.api.nvim_get_current_buf()))
end

---Tree-sitter parses while jumping every 100 lines through the buffer
---(`NGzz`, redrawn after each jump).
local function parses_while_jumping()
  return child.lua_get([[(function()
    local LanguageTree = require("vim.treesitter.languagetree")
    local parse, count = LanguageTree.parse, 0
    LanguageTree.parse = function(...)
      count = count + 1
      return parse(...)
    end
    local jumps = 0
    for row = 100, vim.api.nvim_buf_line_count(0), 100 do
      vim.cmd(("normal! %dGzz"):format(row))
      vim.cmd("redraw")
      jumps = jumps + 1
    end
    LanguageTree.parse = parse
    return { count = count, jumps = jumps }
  end)()]])
end

T["rendering"]["jumps through a long note parse once per redraw"] = function()
  open_highlighted(long_note(250))
  eq(highlighted(), true)
  local result = parses_while_jumping()
  -- Each redraw parses the visible range once; a highlighter that still
  -- expects hidden fence lines parses again for every row Neovim checks
  -- (hundreds per jump).
  eq(result.jumps, 20)
  eq(result.count <= 2 * result.jumps, true)
end

T["rendering"]["code fence lines stay visible"] = function()
  open_highlighted(long_note(3))
  eq(highlighted(), true)
  local flag = "vim.treesitter.query.get('markdown', 'highlights')"
    .. ".has_conceal_line"
  eq(child.lua_get(flag), false)
  go(1)
  marks()
  -- Rows 5 and 7 are the fences of the first block: concealed lines
  -- would take no screen height.
  local height = "vim.api.nvim_win_text_height(0, "
    .. "{ start_row = 4, end_row = 6 }).all"
  eq(child.lua_get(height), 3)
end

-- lazy.nvim loading ----------------------------------------------------------

T["lazy.nvim loads the plugin for Markdown only"] = function()
  child.restart({ "-u", helpers.minimal_init })
  local root = helpers.temp_dir()
  child.lua(
    [[
    local lazy_dir, plugin, spec_path, root = ...
    vim.g.mapleader = " "
    vim.opt.runtimepath:prepend(lazy_dir)
    local spec = dofile(spec_path)
    spec.dir, spec.name, spec[1] = plugin, "render-markdown.nvim", nil
    require("lazy").setup({ spec }, {
      root = root .. "/lazy",
      lockfile = root .. "/lock.json",
      state = root .. "/state.json",
      install = { missing = false },
      checker = { enabled = false },
      change_detection = { enabled = false },
      readme = { enabled = false },
      performance = { reset_packpath = false, rtp = { reset = false } },
    })
  ]],
    { checkout("folke/lazy.nvim"), plugin_dir(), SPEC, root }
  )
  local loaded = "package.loaded['render-markdown'] ~= nil"
  open({ "local value = 1" }, "code.lua")
  eq(child.lua_get(loaded), false)
  open(NOTE)
  eq(child.lua_get(loaded), true)
  go(3)
  has(row_text(marks(), 1), GLYPHS.headings[1])
  -- Space m r is the toggle in Markdown buffers.
  child.type_keys(" mr")
  eq(marks(), {})
end

T["the spec is lazy and declares the toggle"] = function()
  local spec = dofile(SPEC)
  eq(spec[1], "MeanderingProgrammer/render-markdown.nvim")
  eq(spec.ft, "markdown")
  eq(spec.event, nil)
  eq(spec.lazy, nil)
  eq(spec.cmd, "IaraMarkdownToggle")
  eq(
    { spec.keys[1][1], spec.keys[1].ft, spec.keys[1].desc },
    { "<leader>mr", "markdown", "Markdown render toggle" }
  )
  local which_key =
    dofile(helpers.iara_dir .. "/lua/iara/plugins/which_key.lua")
  local groups = {}
  for _, entry in ipairs(which_key.opts.spec) do
    groups[entry[1]] = entry.group
  end
  eq(groups["<leader>m"], "Markdown")
  local lock = lazy_fixture.release_entry("render-markdown.nvim")
  eq(#lock.commit, 40)
end

-- Colors ---------------------------------------------------------------------

---Collect "<palette> <label> <ratio>" when `fg` is below `ratio` on any
---of `surfaces`.
local function below(failures, label, fg, surfaces, ratio)
  for _, surface in ipairs(surfaces) do
    local value = hl.contrast(fg, surface)
    if value < ratio then
      table.insert(failures, ("%s %.2f < %.1f"):format(label, value, ratio))
      return
    end
  end
end

---Every shipped palette's resolved groups and roles.
local function each_palette(check)
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    local groups, problems = hl.resolve(palette)
    eq(problems, {})
    check(name, groups, roles.resolve(palette))
  end
end

T["headings read on their band and on the cursor line"] = function()
  local failures = {}
  each_palette(function(name, groups, r)
    for level = 1, 6 do
      local text = groups[("@markup.heading.%d.markdown"):format(level)]
      local icon = groups["RenderMarkdownH" .. level]
      local band = groups["RenderMarkdownH" .. level .. "Bg"].bg
      local label = ("%s H%d"):format(name, level)
      below(failures, label, text.fg, { band, r.base, r.cursorline }, 4.5)
      below(failures, label .. " icon", icon.fg, { band, r.base }, 3)
      eq(text.bold, true)
    end
  end)
  eq(failures, {})
end

T["heading levels have distinct colors"] = function()
  each_palette(function(name, groups)
    local seen = {}
    for level = 1, 6 do
      local fg = groups[("@markup.heading.%d.markdown"):format(level)].fg
      eq({ name, level, seen[fg] }, { name, level, nil })
      seen[fg] = level
    end
  end)
end

-- Text groups (4.5:1) and glyph groups (3:1) on the editor surface.
local TEXT_GROUPS = {
  "RenderMarkdownLink",
  "RenderMarkdownTableHead",
  "@markup.heading.markdown",
  "@markup.link.label.markdown_inline",
  "@markup.link.url.markdown_inline",
  "IaraMarkdownStruck",
}
local GLYPH_GROUPS = {
  "RenderMarkdownBullet",
  "RenderMarkdownQuote",
  "RenderMarkdownDash",
  "RenderMarkdownTableRow",
  "RenderMarkdownUnchecked",
  "RenderMarkdownChecked",
  "RenderMarkdownTodo",
  "IaraMarkdownProgress",
  "IaraMarkdownCancelled",
  "IaraMarkdownForwarded",
  "IaraMarkdownImportant",
  "IaraMarkdownQuestion",
}
local CALLOUTS = { "Success", "Info", "Hint", "Warn", "Error" }

T["markdown groups read on every palette"] = function()
  local failures = {}
  each_palette(function(name, groups, r)
    for _, group in ipairs(TEXT_GROUPS) do
      below(failures, name .. " " .. group, groups[group].fg, { r.base }, 4.5)
    end
    for _, group in ipairs(GLYPH_GROUPS) do
      below(failures, name .. " " .. group, groups[group].fg, { r.base }, 3)
    end
    for _, state in ipairs(CALLOUTS) do
      local fg = groups["RenderMarkdown" .. state].fg
      below(failures, name .. " " .. state, fg, { r.base }, 4.5)
    end
    -- Callouts sit on the editor surface, not a quote background.
    eq({ name, groups["@markup.quote.markdown"].bg }, { name, nil })
    local language = groups.IaraMarkdownCodeLanguage
    below(failures, name .. " language", language.fg, { language.bg }, 4.5)
    local info = groups.RenderMarkdownCodeInfo
    below(failures, name .. " code info", info.fg, { info.bg }, 4.5)
  end)
  eq(failures, {})
end

T["code blocks sit on the chrome surface"] = function()
  each_palette(function(name, groups, r)
    eq({ name, groups.RenderMarkdownCode.bg }, { name, r.mantle })
    eq({ name, groups.RenderMarkdownCodeBorder.bg }, { name, r.mantle })
  end)
end

return T
