-- LSP progress (task V5): an in-process fake server sends `$/progress`
-- notifications through Neovim's own handler, so the segment is driven
-- by real `LspProgress` events.
local helpers = require("helpers")

local eq = MiniTest.expect.equality
local match = helpers.expect_match

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
      child.lua([[
        require("iara.theme").load("chocolate")
        _G.progress = require("iara.core.progress")
        progress.DONE_MS = 300
        progress.setup()
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

---Start an in-process server named `name` attached to the current
---buffer; `_G.send(name, token, value)` sends it a progress value.
local function start_server(name)
  child.lua(
    [[
    local name = ...
    _G.dispatchers = _G.dispatchers or {}
    local function server(dispatchers)
      _G.dispatchers[name] = dispatchers
      local closing = false
      return {
        request = function(method, _, callback)
          local result = method == "initialize" and { capabilities = {} }
          vim.schedule(function() callback(nil, result or nil) end)
          return true, 1
        end,
        notify = function() return true end,
        is_closing = function() return closing end,
        terminate = function()
          closing = true
          vim.schedule(function() dispatchers.on_exit(0, 15) end)
        end,
      }
    end
    local id = vim.lsp.start({ name = name, cmd = server })
    vim.wait(5000, function()
      local client = vim.lsp.get_client_by_id(id)
      return client ~= nil and client.initialized
    end)
    _G.send = function(server_name, token, value)
      local params = { token = token, value = value }
      _G.dispatchers[server_name].notification("$/progress", params)
    end
  ]],
    { name }
  )
end

local function send(name, token, value)
  child.lua("_G.send(...)", { name, token, value })
end

---The segment as drawn at `columns` wide (highlight items removed).
local function segment(columns)
  child.o.columns = columns or 120
  return child.lua([[
    local text = progress.statusline()
    return vim.api.nvim_eval_statusline(text, { maxwidth = 200 }).str
  ]])
end

local function wait_ms(ms)
  child.lua("vim.wait(...)", { ms })
end

---Active libuv timers in the child.
local function active_timers()
  return child.lua([[
    local count = 0
    vim.uv.walk(function(handle)
      if handle:get_type() == "timer" and handle:is_active() then
        count = count + 1
      end
    end)
    return count
  ]])
end

local BEGIN = { kind = "begin", title = "Indexing", percentage = 0 }

T["begin, report, and end drive the segment, then ready fades"] = function()
  start_server("fake_ls")
  eq(segment(), "")
  send("fake_ls", "index", BEGIN)
  eq(segment(), "⠙ fake_ls  Indexing 0% ────────────")
  send("fake_ls", "index", { kind = "report", percentage = 42 })
  eq(
    segment(120),
    "⠹ fake_ls  Indexing 42% ━━━━━───────"
  )
  -- Narrower windows drop the bar, then the percent.
  eq(segment(100), "⠹ fake_ls  Indexing 42%")
  eq(segment(80), "⠹ fake_ls  Indexing")
  send("fake_ls", "index", { kind = "end" })
  eq(segment(120), "✓ fake_ls ready")
  eq(child.lua_get("progress.state()"), { client = "fake_ls", done = true })
  wait_ms(400)
  eq(segment(120), "")
  eq(child.lua_get("progress.state()"), vim.NIL)
end

T["the spinner moves only when an event arrives"] = function()
  start_server("fake_ls")
  send("fake_ls", "index", BEGIN)
  local first = segment()
  wait_ms(300)
  eq(segment(), first)
  send("fake_ls", "index", { kind = "report", message = "1/3" })
  local second = segment()
  eq(vim.fn.strcharpart(second, 1), vim.fn.strcharpart(first, 1))
  eq(second ~= first, true)
  eq(child.lua_get("progress.state().message"), "1/3")
end

T["two clients show the most recent progress"] = function()
  start_server("alpha_ls")
  start_server("beta_ls")
  send("alpha_ls", "a", { kind = "begin", title = "Loading" })
  send("beta_ls", "b", { kind = "begin", title = "Checking" })
  match(segment(), "beta_ls  Checking")
  send("alpha_ls", "a", { kind = "report", percentage = 10 })
  match(segment(), "alpha_ls  Loading 10%%")
  -- One client ending leaves the other one's progress, not "ready".
  send("alpha_ls", "a", { kind = "end" })
  match(segment(), "beta_ls  Checking")
  send("beta_ls", "b", { kind = "end" })
  eq(segment(), "✓ beta_ls ready")
end

T["no timer runs while no progress is active"] = function()
  start_server("fake_ls")
  wait_ms(200)
  local idle = active_timers()
  send("fake_ls", "index", BEGIN)
  send("fake_ls", "index", { kind = "report", percentage = 5 })
  -- Past the throttle interval a silent server leaves no timer running.
  wait_ms(200)
  eq(active_timers(), idle)
  send("fake_ls", "index", { kind = "end" })
  eq(active_timers(), idle + 1)
  wait_ms(400)
  eq(active_timers(), idle)
  eq(segment(), "")
end

T["changes are announced at most ten times a second"] = function()
  start_server("fake_ls")
  child.lua([[
    _G.announced = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = progress.EVENT,
      callback = function()
        table.insert(_G.announced, vim.uv.hrtime() / 1e6)
      end,
    })
  ]])
  send("fake_ls", "index", BEGIN)
  -- A chatty server: 60 reports, one every 10 ms.
  child.lua([[
    for percent = 1, 60 do
      _G.send("fake_ls", "index", { kind = "report", percentage = percent })
      vim.wait(10)
    end
    vim.wait(200)
  ]])
  local times = child.lua_get("_G.announced")
  eq(#times >= 4 and #times <= 9, true)
  for i = 2, #times do
    eq(times[i] - times[i - 1] >= 90, true)
  end
  -- The last report is the one shown once the burst settles.
  match(segment(), "Indexing 60%%")
end

T["a client that stops without ending its progress is dropped"] = function()
  start_server("fake_ls")
  send("fake_ls", "index", BEGIN)
  match(segment(), "fake_ls")
  child.lua([[
    for _, client in ipairs(vim.lsp.get_clients()) do client:stop(true) end
    vim.wait(2000, function() return progress.state() == nil end)
  ]])
  eq(segment(), "")
end

T["titles are cut and shown literally"] = function()
  start_server("fake_ls")
  local title = "100% of a very long workspace scan title"
  send("fake_ls", "index", { kind = "begin", title = title })
  local text = segment(80)
  match(text, "fake_ls  100%% of a very long wor…$")
  eq(vim.fn.strdisplaywidth(text:match("  (.*)$")), 24)
  -- Values that are not progress objects are ignored.
  send("fake_ls", "other", "plain value")
  match(segment(80), "100%% of a very")
end

T["core progress messages show when no server reports progress"] = function()
  child.lua([[
    _G.id = vim.api.nvim_echo({ { "building" } }, false, {
      kind = "progress", source = "test", title = "build",
      status = "running", percent = 40,
    })
  ]])
  match(segment(), "^%S+ 40%%%(1%)$")
  child.lua([[
    vim.api.nvim_echo({ { "built" } }, false, {
      id = _G.id, kind = "progress", source = "test", title = "build",
      status = "success", percent = 100,
    })
  ]])
  eq(segment(), "")
end

-- Colors -----------------------------------------------------------------

-- Text groups need 4.5:1 and the spinner and bar glyphs 3:1 on the
-- status line background.
local CONTRAST = [[
local hl = require("iara.theme.highlights")
local theme = require("iara.theme")
local need = {
  IaraProgressClient = 4.5, IaraProgressTitle = 4.5,
  IaraProgressDone = 4.5, IaraProgressSpinner = 3, IaraProgressBar = 3,
  IaraProgressBarTrack = 3,
}
local low = {}
for _, name in ipairs(theme.THEMES) do
  local groups = hl.resolve(theme.palette(name))
  for group, ratio in pairs(need) do
    local spec = groups[group]
    local value = hl.contrast(spec.fg, spec.bg)
    if value < ratio then
      table.insert(low, ("%s %s %.2f"):format(name, group, value))
    end
  end
end
table.sort(low)
return low
]]

T["progress groups are readable in every palette"] = function()
  eq(child.lua(CONTRAST), {})
end

T["progress groups link to the status line under a foreign theme"] = function()
  child.cmd("colorscheme default")
  local links = child.lua_get("progress.FALLBACK_LINKS")
  for group, target in pairs(links) do
    local spec = child.lua_get("vim.api.nvim_get_hl(0, { name = ... })", {
      group,
    })
    eq({ group, spec.link }, { group, target })
  end
  child.lua("require('iara.theme').load('chocolate')")
  local spinner =
    child.lua_get("vim.api.nvim_get_hl(0, { name = 'IaraProgressSpinner' })")
  eq(spinner.link, nil)
  eq(spinner.fg ~= nil, true)
end

return T
