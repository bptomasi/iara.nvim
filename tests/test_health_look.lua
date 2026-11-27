-- Look of the `:checkhealth` buffer (V11): module headers with counts,
-- report glyphs, muted advice, and groups readable in every theme.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local look = require("iara.core.health_look")

local OK = "- \u{2705} OK "
local WARN = "- \u{26a0}\u{fe0f} WARNING "
local ERROR = "- \u{274c} ERROR "
local RULE = ("="):rep(78)

---A health buffer as `vim.health` writes it: two modules.
local LINES = {
  RULE,
  "iara:" .. (" "):rep(66) .. "1 \u{26a0}\u{fe0f}  1 \u{274c}",
  "",
  "Mode ~",
  OK .. "full mode",
  "- NVIM_APPNAME: iara",
  "",
  "Plugins ~",
  WARN .. "lazy.nvim is at abc",
  "  - ADVICE:",
  "    - Restore it with :Lazy restore",
  ERROR .. "missing plugins: a, b",
  OK .. "release lock",
  "  continued message line",
  "",
  RULE,
  "vim.lsp:" .. (" "):rep(69) .. "\u{2705}",
  "",
  "Active ~",
  OK .. "no clients",
}

---Marks at `row` (0-based) of the decorations of LINES.
local function marks_at(marks, row)
  return vim.tbl_filter(function(item)
    return item.row == row
  end, marks)
end

local function virt_text(item)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, item.opts.virt_text))
end

local T = MiniTest.new_set()

T["decorations"] = MiniTest.new_set()

T["decorations"]["count each module's own reports in its header"] = function()
  local marks = look.decorations(LINES)
  local iara = marks_at(marks, 1)[1]
  match(virt_text(iara), "^\u{223f} iara \u{2500}")
  match(virt_text(iara), " 2 ok \u{b7} 1 warning \u{b7} 1 error *$")
  local lsp = marks_at(marks, 16)[1]
  match(virt_text(lsp), "^vim%.lsp \u{2500}")
  match(virt_text(lsp), " 1 ok \u{b7} 0 warnings \u{b7} 0 errors *$")
  eq(lsp.opts.virt_text_pos, "overlay")
end

T["decorations"]["headers cover the rule and the whole title"] = function()
  local marks = look.decorations(LINES)
  for _, row in ipairs({ 1, 16 }) do
    local width = vim.api.nvim_strwidth(virt_text(marks_at(marks, row)[1]))
    local title = vim.api.nvim_strwidth(LINES[row + 1])
    eq(width, math.max(look.WIDTH, title))
  end
  local wide = { RULE, "x:" .. (" "):rep(90) .. "\u{2705}" }
  local header = look.decorations(wide)[2]
  eq(vim.api.nvim_strwidth(virt_text(header)), vim.api.nvim_strwidth(wide[2]))
end

T["decorations"]["hide the rule and advice label lines"] = function()
  local marks = look.decorations(LINES)
  eq(marks_at(marks, 0)[1].opts.conceal_lines, "")
  eq(marks_at(marks, 15)[1].opts.conceal_lines, "")
  eq(marks_at(marks, 9)[1].opts.conceal_lines, "")
end

T["decorations"]["show one colored glyph per report state"] = function()
  local marks = look.decorations(LINES)
  local cases = {
    { 4, "\u{2713}", "IaraHealthOk", #OK - 1 },
    { 8, "\u{25b2}", "IaraHealthWarn", #WARN - 1 },
    { 11, "\u{2717}", "IaraHealthError", #ERROR - 1 },
  }
  for _, case in ipairs(cases) do
    local item = marks_at(marks, case[1])[1]
    eq(item.col, 0)
    eq(item.opts.conceal, case[2])
    eq(item.opts.hl_group, case[3])
    eq(item.opts.end_col, case[4])
  end
end

T["decorations"]["mute advice behind an arrow and style headings"] = function()
  local marks = look.decorations(LINES)
  local advice = marks_at(marks, 10)
  eq(advice[1].col, 4)
  eq(advice[1].opts.conceal, "\u{2192}")
  eq(advice[2].opts.hl_group, "IaraHealthAdvice")
  eq(advice[2].opts.end_col, #LINES[11])
  local heading = marks_at(marks, 7)
  eq(heading[1].opts, { end_col = 7, hl_group = "IaraHealthHeading" })
  eq(heading[2].opts.conceal, "")
  eq(#marks_at(marks, 13), 0)
end

T["decorations"]["the Iara mark appears only on the iara module"] = function()
  local marks = look.decorations(LINES)
  eq(virt_text(marks_at(marks, 16)[1]):find("\u{223f}", 1, true), nil)
end

T["counts_text pluralizes"] = function()
  eq(
    look.counts_text({ ok = 1, warn = 2, error = 0 }),
    "1 ok \u{b7} 2 warnings \u{b7} 0 errors"
  )
end

-- A real `:checkhealth iara` in a child --------------------------------

local child = helpers.new_child()

T["checkhealth"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

T["checkhealth"]["header counts match the reports written"] = function()
  child.cmd("checkhealth iara")
  local result = child.lua([[
    local look = require("iara.core.health_look")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local counts = { ok = 0, warn = 0, error = 0 }
    for _, line in ipairs(lines) do
      for _, state in ipairs(look.STATES) do
        if vim.startswith(line, state.prefix .. " ") then
          counts[state.key] = counts[state.key] + 1
        end
      end
    end
    local marks = vim.api.nvim_buf_get_extmarks(0, look.NAMESPACE, 0, -1,
      { details = true })
    local header
    for _, item in ipairs(marks) do
      if item[4].virt_text then
        header = table.concat(vim.tbl_map(function(c)
          return c[1]
        end, item[4].virt_text))
        break
      end
    end
    return { counts = counts, header = header, total = #lines,
      conceal = vim.wo.conceallevel, number = vim.wo.number }
  ]])
  local expected = look.counts_text(result.counts)
  match(result.header, "^\u{223f} iara ")
  eq(result.header:sub(-#expected), expected)
  eq(result.counts.warn > 0, true)
  eq(result.conceal, 2)
  eq(result.number, false)
end

T["checkhealth"]["keeps the report text as Neovim wrote it"] = function()
  child.cmd("checkhealth iara")
  local text = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  match(text, "WARNING Iara did not start")
  match(text, "\nMode ~\n")
  match(text, "\nExternal tools ~\n")
end

-- Groups ----------------------------------------------------------------

local function groups_of(name)
  local palette = require("iara.theme").palette(name)
  local groups = require("iara.theme.highlights").resolve(palette)
  return groups, require("iara.theme.roles").resolve(palette)
end

T["state, heading, and advice text is readable in every theme"] = function()
  local contrast = require("iara.theme.highlights").contrast
  for _, name in ipairs(require("iara.theme").THEMES) do
    local groups, roles = groups_of(name)
    for _, group in ipairs({
      "IaraHealthOk",
      "IaraHealthWarn",
      "IaraHealthError",
      "IaraHealthHeading",
      "IaraHealthAdvice",
      "IaraHealthMark",
    }) do
      local ratio = contrast(groups[group].fg, roles.base)
      eq({ name, group, ratio >= 4.5 }, { name, group, true })
    end
  end
end

T["checkhealth"]["fallback links exist under a foreign theme"] = function()
  child.cmd("colorscheme default")
  child.lua("require('iara.core.health_look').apply(0)")
  for group in pairs(look.FALLBACK_LINKS) do
    local hl = child.api.nvim_get_hl(0, { name = group })
    eq({ group, hl.link ~= nil }, { group, true })
  end
end

return T
