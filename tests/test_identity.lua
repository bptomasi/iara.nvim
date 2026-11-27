-- Identity review (task V12): every Iara group the theme defines keeps a
-- neutral link under a foreign colorscheme, so no screen loses its text
-- when the user picks a colorscheme that knows nothing of Iara.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

-- Modules that link their own groups when they first draw (public
-- tables), and the groups linked by modules that keep the table local.
local MODULE_TABLES = {
  { "iara.core.float", "FALLBACK_LINKS" },
  { "iara.core.progress", "FALLBACK_LINKS" },
  { "iara.core.health_look", "FALLBACK_LINKS" },
  { "iara.features.terminal.header", "FALLBACK_LINKS" },
  { "iara.features.search.view", "HIGHLIGHTS" },
  { "iara.features.picker.modal", "HIGHLIGHTS" },
  { "iara.features.picker.layout", "HIGHLIGHTS" },
  { "iara.core.select", "HIGHLIGHTS" },
}
local MODULE_PATTERNS = {
  "^IaraContext", -- iara.extras.agents.preview
  "^IaraTheme", -- iara.theme.picker
  "^IaraTreeBranch$", -- iara.core.explorer
}

---Groups that some module links under a foreign colorscheme.
local function linked_somewhere()
  local linked = vim.deepcopy(require("iara.theme").FALLBACK_LINKS)
  for _, entry in ipairs(MODULE_TABLES) do
    for name in pairs(require(entry[1])[entry[2]]) do
      linked[name] = true
    end
  end
  return linked
end

T["every Iara group of the theme has a fallback link"] = function()
  local theme = require("iara.theme")
  local groups =
    require("iara.theme.highlights").resolve(theme.palette(theme.DEFAULT))
  local linked, missing = linked_somewhere(), {}
  for name in pairs(groups) do
    local by_module = vim.iter(MODULE_PATTERNS):any(function(pattern)
      return name:find(pattern) ~= nil
    end)
    if name:find("^Iara") and not linked[name] and not by_module then
      table.insert(missing, name)
    end
  end
  table.sort(missing)
  eq(missing, {})
end

T["a foreign colorscheme links the start, status, popup groups"] = function()
  child.lua([[require("iara.theme").setup({ ui = { theme = "chocolate" } })]])
  child.cmd("colorscheme default")
  local links = child.lua(
    [[
    local out = {}
    for _, name in ipairs(...) do
      out[name] = vim.api.nvim_get_hl(0, { name = name }).link or false
    end
    return out
  ]],
    {
      {
        "IaraStartWaveTide",
        "IaraStatusMark",
        "IaraWinbarName",
        "IaraAskPrompt",
        "IaraMarkdownProgress",
      },
    }
  )
  eq(links, {
    IaraStartWaveTide = "Special",
    IaraStatusMark = "StatusLine",
    IaraWinbarName = "WinBar",
    IaraAskPrompt = "Special",
    IaraMarkdownProgress = "DiagnosticInfo",
  })
end

return T
