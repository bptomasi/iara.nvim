-- Completion, hover, signature, and which-key look (task V9, design 09
-- sections 3.7 and 3.8): readable kind and menu colors in every palette,
-- the menu row, the selection bar, the documentation title, titled LSP
-- floats, and which-key's order and frame.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local theme = require("iara.theme")
local roles = require("iara.theme.roles")
local hl = require("iara.theme.highlights")

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.o.lines, child.o.columns = 12, 60
    end,
    post_once = child.stop,
  },
})

-- Colors --------------------------------------------------------------------

---Resolved groups and roles of every shipped palette.
local function each_palette(check)
  for _, name in ipairs(theme.THEMES) do
    local palette = theme.palette(name)
    check(name, (hl.resolve(palette)), roles.resolve(palette))
  end
end

---Collect "<palette> <group> <ratio>" when `fg` is below `ratio` on any
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

T["kind icons stay readable on the menu and its selected row"] = function()
  local failures, kinds = {}, 0
  each_palette(function(name, groups, resolved)
    local surfaces = { resolved.mantle, resolved.overlay }
    for group, spec in pairs(groups) do
      if group:match("^CmpItemKind%u") then
        kinds = kinds + 1
        below(failures, name .. " " .. group, spec.fg, surfaces, 3)
      end
    end
  end)
  eq(failures, {})
  -- Every LSP kind has its own group in each palette.
  eq(kinds >= 25 * #theme.THEMES, true)
end

T["menu text and which-key keys meet the text contrast"] = function()
  local failures = {}
  local text = {
    "CmpItemAbbr",
    "CmpItemAbbrMatch",
    "CmpItemKind",
    "CmpItemMenu",
    "WhichKey",
    "WhichKeyGroup",
    "WhichKeyDesc",
    "WhichKeySeparator",
  }
  each_palette(function(name, groups, resolved)
    for _, group in ipairs(text) do
      local fg = groups[group].fg
      below(failures, name .. " " .. group, fg, { resolved.mantle }, 4.5)
    end
    -- The quiet texts also hold on the selected row.
    for _, group in ipairs({ "CmpItemKind", "CmpItemMenu" }) do
      local fg = groups[group].fg
      below(failures, name .. " " .. group, fg, { resolved.overlay }, 4.5)
    end
  end)
  eq(failures, {})
end

T["the selected row is a bold overlay, not a filled color"] = function()
  each_palette(function(name, groups, resolved)
    local sel = groups.CmpSel
    eq(
      { name, sel.bg, sel.fg, sel.bold },
      { name, resolved.overlay, nil, true }
    )
    eq({ name, groups.CmpPmenu.bg }, { name, resolved.mantle })
    -- One straight frame for every popup: the shared float frame.
    eq({ name, groups.CmpBorder.link }, { name, "FloatBorder" })
    eq({ name, groups.CmpDocBorder.link }, { name, "FloatBorder" })
    eq({ name, groups.WhichKeyBorder.link }, { name, "FloatBorder" })
    eq({ name, groups.CmpDoc.bg }, { name, resolved.mantle })
  end)
end

T["the active parameter is accent, bold, and underlined"] = function()
  each_palette(function(name, groups, resolved)
    local spec = groups.LspSignatureActiveParameter
    eq(
      { name, spec.fg, spec.bg, spec.bold, spec.underline },
      { name, resolved.accent, nil, true, true }
    )
  end)
end

-- Completion menu -------------------------------------------------------------

---The cmp spec loaded in the child with stub `cmp` modules: `selected`
---is what `cmp.get_selected_entry()` returns (`{ kind, source }`).
local function load_cmp_spec()
  child.lua([[
    local stub
    stub = setmetatable({}, {
      __index = function() return stub end,
      __call = function(_, opts) return opts or stub end,
    })
    _G.selected = nil
    package.loaded.luasnip = stub
    package.loaded.cmp = setmetatable({
      setup = function() end,
      get_selected_entry = function()
        if not _G.selected then return nil end
        return {
          source = { name = _G.selected.source },
          get_kind = function() return _G.selected.kind end,
        }
      end,
    }, { __index = stub })
    package.loaded["cmp.types"] = {
      lsp = { CompletionItemKind = { [3] = "Function", [15] = "Snippet" } },
    }
    _G.spec = dofile(vim.env.IARA_DIR .. "/lua/iara/plugins/cmp.lua")
    _G.spec.config(nil, {})
  ]])
end

T["menu rows show the icon, label, kind, and source"] = function()
  child.lua("vim.env.IARA_DIR = ...", { helpers.iara_dir })
  load_cmp_spec()
  local rows = child.lua_get([[(function()
    local opts = _G.spec.opts()
    local format = opts.formatting.format
    local function row(kind, source, abbr)
      local item = format({ source = { name = source } },
        { kind = kind, abbr = abbr })
      return { item.icon ~= "", item.icon_hl_group, item.kind,
        item.kind_hl_group, item.menu, item.abbr }
    end
    return {
      fields = opts.formatting.fields,
      snippet = row("Snippet", "luasnip", "fori"),
      other = row("Function", "my_source", ("x"):rep(50)),
    }
  end)()]])
  eq(rows.fields, { "icon", "abbr", "kind", "menu" })
  eq(rows.snippet, {
    true,
    "CmpItemKindSnippet",
    "Snippet",
    "CmpItemKind",
    "LuaSnip",
    "fori",
  })
  -- Unknown sources keep their name; long labels end in an ellipsis.
  eq(rows.other[5], "my_source")
  eq(rows.other[6], ("x"):rep(39) .. "\u{2026}")
end

T["menu and docs have one straight frame and no scrollbar"] = function()
  child.lua("vim.env.IARA_DIR = ...", { helpers.iara_dir })
  load_cmp_spec()
  local window = child.lua_get([[(function()
    local window = _G.spec.opts().window
    local function frame(opts)
      return { opts.border, opts.winhighlight:match("FloatBorder:(%w+)") }
    end
    return {
      menu = frame(window.completion),
      docs = frame(window.documentation),
      -- cmp draws both windows' scrollbars from this one option.
      scrollbar = window.completion.scrollbar,
    }
  end)()]])
  eq(window.menu, { "single", "CmpBorder" })
  eq(window.docs, { "single", "CmpDocBorder" })
  eq(window.scrollbar, false)
end

---A bordered float showing `lines` in a buffer of `filetype`.
local function open_float(filetype, lines)
  return child.lua_get(
    [[(function(filetype, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
    vim.bo[buf].filetype = filetype
    return vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 1, col = 2, width = 40,
      height = #lines, border = "single", style = "minimal",
    })
  end)(...)]],
    { filetype, lines }
  )
end

---Screen text of row `row` (1-based), as one string.
local function screen_row(row)
  return table.concat(child.get_screenshot().text[row])
end

T["the selected menu row is led by an accent bar"] = function()
  child.lua("vim.env.IARA_DIR = ...", { helpers.iara_dir })
  load_cmp_spec()
  local win = open_float("cmp_menu", { " one", " two", " three" })
  child.lua(
    [[
    local win = ...
    vim.wo[win].cursorline = true
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.cmd.redraw()
  ]],
    { win }
  )
  -- Rows: 2 is the top border, 3-5 are "one", "two", "three".
  match(screen_row(4), "│\u{258e}two")
  match(screen_row(3), "│ one")
  -- Nothing selected: cmp turns the cursor line off, and the bar goes.
  child.lua("vim.wo[...].cursorline = false; vim.cmd.redraw()", { win })
  match(screen_row(4), "│ two")
end

T["other floats get no selection bar"] = function()
  child.lua("vim.env.IARA_DIR = ...", { helpers.iara_dir })
  load_cmp_spec()
  local win = open_float("markdown", { " one", " two" })
  child.lua("vim.wo[...].cursorline = true; vim.cmd.redraw()", { win })
  match(screen_row(3), "│ one")
end

---Text of an idle title of the float language (V3, V13): one dash after
---the corner, then the padded text.
local function title_of(text)
  return "─ " .. text .. " "
end

---Title text of `win`, once a scheduled title change has run.
local function title_text(win)
  child.lua("vim.cmd.redraw()")
  child.lua("vim.wait(20)")
  local title = child.lua_get("vim.api.nvim_win_get_config(...).title", { win })
  if type(title) ~= "table" then
    return nil
  end
  local parts = {}
  for _, chunk in ipairs(title) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

T["the documentation window names the kind and source"] = function()
  child.lua("vim.env.IARA_DIR = ...", { helpers.iara_dir })
  load_cmp_spec()
  child.lua("_G.selected = { kind = 15, source = 'luasnip' }")
  local win = open_float("cmp_docs", { "for i, x in ipairs(t)" })
  eq(title_text(win), title_of("Snippet \u{b7} LuaSnip"))
  -- A new selection renames it when cmp writes its documentation.
  child.lua(
    [[
    _G.selected = { kind = 3, source = "nvim_lsp" }
    local buf = vim.api.nvim_win_get_buf(...)
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, { "format(text)" })
  ]],
    { win }
  )
  eq(title_text(win), title_of("Function \u{b7} LSP"))
end

-- LSP floats ----------------------------------------------------------------

---Child code starting an in-process fake server that answers hover and
---signature help in the current buffer.
local FAKE_SERVER = [[
    local function respond(callback, result)
      vim.schedule(function() callback(nil, result) end)
    end
    local RESULTS = {
      initialize = { capabilities = {
        hoverProvider = true,
        signatureHelpProvider = { triggerCharacters = { "(" } },
      } },
      ["textDocument/hover"] = { contents = {
        kind = "markdown", value = "Greets someone.",
      } },
      ["textDocument/signatureHelp"] = {
        signatures = { {
          label = "greet(name, polite)",
          parameters = { { label = "name" }, { label = "polite" } },
        } },
        activeSignature = 0,
        activeParameter = 1,
      },
    }
    local function server(dispatchers)
      local closing = false
      return {
        request = function(method, _, callback)
          local signatures = method == "textDocument/signatureHelp"
            and _G.fake_signature_help
          respond(callback, signatures or RESULTS[method])
          return true, 1
        end,
        notify = function(method)
          closing = closing or method == "exit"
          return true
        end,
        is_closing = function() return closing end,
        terminate = function() closing = true end,
      }
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, true, { "greet(name, polite)" })
    vim.lsp.start({ name = "fake_ls", cmd = server })
]]

---Start the fake server and wait until it is attached.
local function start_fake_server()
  child.lua(FAKE_SERVER)
  local attached = child.lua_get([[vim.wait(2000, function()
    return #vim.lsp.get_clients({ bufnr = 0 }) > 0
  end)]])
  eq(attached, true)
end

---Title text of the newest float, waiting for it to open.
local function newest_float_title()
  child.lua([[vim.wait(2000, function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        return true
      end
    end
  end)]])
  return child.lua_get([[(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        local parts = {}
        for _, chunk in ipairs(config.title or {}) do
          table.insert(parts, chunk[1])
        end
        return { text = table.concat(parts), pos = config.title_pos }
      end
    end
  end)()]])
end

T["hover floats are titled with the answering servers"] = function()
  child.lua([[require("iara.core.options").setup({})]])
  start_fake_server()
  child.lua([[require("iara.core.lsp").hover()]])
  local glyph = child.lua_get([[require("iara.core.icons").LSP]])
  eq(
    newest_float_title(),
    { text = title_of(glyph .. " fake_ls"), pos = "left" }
  )
end

T["hover has no title when no server answers"] = function()
  eq(child.lua_get([[require("iara.core.lsp").hover_title(0)]]), vim.NIL)
end

T["signature help floats are titled and mark the parameter"] = function()
  child.lua([[require("iara.core.options").setup({})]])
  start_fake_server()
  child.lua([[require("iara.core.lsp").signature_help()]])
  eq(newest_float_title(), { text = title_of("Signature"), pos = "left" })
  local marked = child.lua_get([[(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1,
          { details = true })
        for _, mark in ipairs(marks) do
          if mark[4].hl_group == "LspSignatureActiveParameter" then
            local line = vim.api.nvim_buf_get_lines(buf, mark[2],
              mark[2] + 1, true)[1]
            return line:sub(mark[3] + 1, mark[4].end_col)
          end
        end
      end
    end
  end)()]])
  eq(marked, "polite")
  -- One signature: nothing to cycle, so no count and no hint.
  eq(
    child.lua_get([[(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        return config.footer or false
      end
    end
  end)()]]),
    false
  )
end

---Title, footer, and text of the newest float, once it shows
---`title`.
local function signature_float(title)
  return child.lua(
    [[
    local want = ...
    local function text(chunks)
      local parts = {}
      for _, chunk in ipairs(chunks or {}) do
        table.insert(parts, chunk[1])
      end
      return table.concat(parts)
    end
    local found
    vim.wait(2000, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(win)
        if config.relative ~= "" and text(config.title) == want then
          local buf = vim.api.nvim_win_get_buf(win)
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
          found = { win = win, footer = text(config.footer),
            line = table.concat(lines, "\n") }
          return true
        end
      end
    end)
    return found
  ]],
    { title }
  )
end

T["several signatures show the active index and a next hint"] = function()
  child.lua([[require("iara.core.options").setup({})]])
  start_fake_server()
  child.lua([[_G.fake_signature_help = {
    signatures = {
      { label = "greet(name)", parameters = { { label = "name" } } },
      { label = "greet(name, polite)",
        parameters = { { label = "name" }, { label = "polite" } } },
    },
    activeSignature = 1,
    activeParameter = 0,
  }]])
  child.lua([[require("iara.core.lsp").signature_help()]])
  local second = signature_float(title_of("Signature 2/2"))
  eq(type(second), "table")
  eq(second.footer, " C-s next ")
  match(second.line, "greet%(name, polite%)")
  -- `<C-s>` in the float shows the next one, wrapping to the first.
  child.api.nvim_set_current_win(second.win)
  -- Fed as typed keys; `type_keys` would fail on the silenced E31 that
  -- the Markdown ftplugin's undo leaves in v:errmsg when the float's
  -- filetype is set again (the native float does the same).
  child.lua([[vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "xt", false)]])
  local first = signature_float(title_of("Signature 1/2"))
  eq(type(first), "table")
  eq(first.win, second.win)
  eq(first.footer, " C-s next ")
  match(first.line, "greet%(name%)")
end

-- which-key -----------------------------------------------------------------

---which-key's options from the spec, with the sort applied to `items` as
---which-key applies its sorters: the first one that differs decides.
local function which_key_sorted(items)
  local opts =
    dofile(helpers.iara_dir .. "/lua/iara/plugins/which_key.lua").opts
  local first = opts.sort[1]
  table.sort(items, function(a, b)
    local aa, bb = first(a), first(b)
    if aa ~= bb then
      return aa < bb
    end
    return a.key < b.key
  end)
  return opts, vim.tbl_map(function(item)
    return item.key
  end, items)
end

T["which-key lists groups before single mappings"] = function()
  local _, keys = which_key_sorted({
    { key = "b", group = false },
    { key = "y", group = true },
    { key = "a", group = true },
    { key = "e" },
  })
  eq(keys, { "a", "y", "b", "e" })
end

T["which-key is a bottom frame titled by the prefix"] = function()
  local opts = which_key_sorted({})
  eq(opts.preset, "classic")
  eq(opts.win.border, "single")
  eq({ opts.win.title, opts.win.title_pos }, { true, "left" })
  -- No separator glyph: alignment carries the relation.
  eq(opts.icons.separator, "")
  eq(opts.icons.group, "\u{25b8} ")
end

T["which-key keeps its hints in the bottom border"] = function()
  local opts = which_key_sorted({})
  eq(opts.show_help, false)
  eq(opts.win.footer_pos, "center")
  local text = table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, opts.win.footer))
  eq(text, " Esc close · BS back ")
  eq(opts.win.footer[2], { "Esc", "IaraFloatFooterKey" })
end

T["which-key's prefix title starts one dash after the corner"] = function()
  local spec = dofile(helpers.iara_dir .. "/lua/iara/plugins/which_key.lua")
  local saved = {
    package.loaded["which-key"],
    package.loaded["which-key.view"],
  }
  local trail = {
    { " ", "WhichKeyTitle" },
    { "Space", "WhichKeyTitle" },
    { " ", "WhichKeyTitle" },
  }
  local view = {
    trail = function()
      return vim.deepcopy(trail)
    end,
  }
  package.loaded["which-key"] = { setup = function() end }
  package.loaded["which-key.view"] = view
  local ok, problem = pcall(spec.config, nil, spec.opts)
  package.loaded["which-key"], package.loaded["which-key.view"] =
    saved[1], saved[2]
  eq({ ok, problem }, { true, nil })
  local title = view.trail({}, { title = true })
  eq(title[1], { "─", "FloatBorder" })
  eq(vim.list_slice(title, 2, 4), trail)
  eq(#title, 4)
  -- Trails outside the title (the keys message) stay as they were.
  eq(view.trail({}), trail)
end

-- which-key with stand-ins for its modules: which buffers it sets up,
-- and when (S11).
local FAKE_WHICH_KEY = [[
_G.got = {}
local Buf = { bufs = {} }
Buf.get = function(opts)
  local buf = opts and opts.buf or vim.api.nvim_get_current_buf()
  table.insert(_G.got, buf)
  Buf.bufs[buf] = true
  return { buf = buf }
end
package.loaded["which-key"] = { setup = function() end }
package.loaded["which-key.view"] = { trail = function() return {} end }
package.loaded["which-key.buf"] = Buf
local spec = dofile(...)
spec.config(nil, spec.opts)
_G.Buf = Buf
_G.enter = function(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = filetype
  vim.api.nvim_set_current_buf(buf)
  return buf, Buf.get()
end
]]

T["which-key sets up picker buffers after the picker is drawn"] = function()
  child.lua(
    FAKE_WHICH_KEY,
    { helpers.iara_dir .. "/lua/iara/plugins/which_key.lua" }
  )
  -- An ordinary buffer is set up when entered.
  local plain =
    child.lua("local buf, mode = enter('lua') return { buf, mode ~= nil }")
  eq(plain[2], true)
  eq(child.lua_get("_G.got"), { plain[1] })
  -- A picker buffer is answered nil at once, set up a moment later.
  local list = child.lua(
    "local buf, mode = enter('snacks_picker_list') return { buf, mode == nil }"
  )
  eq(list[2], true)
  eq(child.lua_get("#_G.got"), 1)
  child.lua("Buf.get()")
  eq(child.lua_get("#_G.got"), 1)
  vim.wait(200, function()
    return child.lua_get("#_G.got") == 2
  end, 10)
  eq(child.lua_get("_G.got"), { plain[1], list[1] })
  -- Once set up, it is answered at once.
  eq(child.lua_get("Buf.get() ~= nil"), true)
end

return T
