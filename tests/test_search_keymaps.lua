-- Search mappings and commands (task S7), driven in a child Neovim with
-- a stubbed search UI that records each opened session.
local helpers = require("helpers")

local eq = MiniTest.expect.equality

local child = helpers.new_child()

---Replace the UI with a recorder and run the init order of the real
---distribution: core keymaps (personal entries), then this step.
---@param keymaps string Lua expression of `config.keymaps`.
local function setup(keymaps)
  child.lua(
    "vim.g.mapleader = ' '\n"
      .. "_G.opened = {}\n"
      .. "package.loaded['iara.features.search.ui'] = { open = "
      .. "function(session) table.insert(_G.opened, session) end }\n"
      .. "local config = { keymaps = "
      .. keymaps
      .. " }\n"
      .. "require('iara.core.keymaps').setup(config)\n"
      .. "require('iara.features.search.keymaps').setup(config)"
  )
end

---Request and root of every session the stub UI received.
local function opened()
  return child.lua([[
    local result = {}
    for _, session in ipairs(_G.opened) do
      local snapshot = session:snapshot()
      table.insert(result, {
        request = snapshot.request,
        root = snapshot.root.path,
      })
    end
    return result
  ]])
end

---Create a project (a directory with `.git`) holding one file.
---@return string root, string file
local function project()
  local root = vim.fs.normalize(assert(vim.uv.fs_realpath(helpers.temp_dir())))
  vim.fn.mkdir(root .. "/.git", "p")
  helpers.write_file(root .. "/main.txt", "text\n")
  return root, root .. "/main.txt"
end

local function edit(path)
  child.cmd("edit " .. vim.fn.fnameescape(path))
end

---Focus a floating scratch buffer like Snacks' picker input.
local function enter_picker_window()
  child.lua([[
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "snacks_picker_input"
    vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 1, col = 1, width = 20, height = 1,
    })
  ]])
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", helpers.minimal_init })
    end,
    post_once = child.stop,
  },
})

T["each mapping opens its own mode at the buffer's root"] = function()
  setup("{}")
  local root, file = project()
  edit(file)
  child.type_keys(" ff")
  child.type_keys(" fw")
  child.type_keys(" fa")
  local sessions = opened()
  eq(#sessions, 3)
  eq(sessions[1].request.mode, "files")
  eq(sessions[1].request.hidden, false)
  eq(sessions[2].request.mode, "content")
  eq(sessions[2].request.hidden, false)
  eq(sessions[3].request.mode, "files")
  eq(sessions[3].request.hidden, true)
  eq(sessions[3].request.ignored, true)
  for _, session in ipairs(sessions) do
    eq(session.root, root)
  end
end

T["Space fr resumes the last search"] = function()
  setup("{}")
  local _, file = project()
  edit(file)
  child.type_keys(" fr")
  eq(#opened(), 0)
  child.type_keys(" fw")
  child.type_keys(" fr")
  local sessions = opened()
  eq(#sessions, 2)
  eq(sessions[2].request.mode, "content")
end

T["mappings carry English descriptions in normal mode only"] = function()
  setup("{}")
  local function desc(lhs, mode)
    return child.lua_get(
      ("vim.fn.maparg(%q, %q, false, true).desc"):format(lhs, mode)
    )
  end
  eq(desc(" ff", "n"), "Find files")
  eq(desc(" fw", "n"), "Find in files (grep)")
  eq(desc(" fa", "n"), "Find files, including hidden and ignored")
  eq(desc(" fr", "n"), "Resume the last search")
  for _, mode in ipairs({ "i", "x", "o", "t" }) do
    eq(child.fn.maparg(" ff", mode), "")
  end
end

T["inside the picker the root comes from the invoking buffer"] = function()
  setup("{}")
  local root, file = project()
  local elsewhere = project()
  child.cmd("cd " .. vim.fn.fnameescape(elsewhere))
  edit(file)
  local editing = child.api.nvim_get_current_win()
  enter_picker_window()
  child.type_keys(" fw")
  local sessions = opened()
  eq(#sessions, 1)
  eq(sessions[1].root, root)
  eq(sessions[1].request.mode, "content")
  eq(child.api.nvim_get_current_win(), editing)
end

T["personal keymaps replace or remove the defaults"] = function()
  setup([[{
    ["n <leader>ff"] = { "<cmd>echo 'mine'<CR>", desc = "Mine" },
    ["n <leader>fa"] = false,
  }]])
  local _, file = project()
  edit(file)
  eq(child.fn.maparg(" ff", "n"), "<Cmd>echo 'mine'<CR>")
  eq(child.fn.maparg(" fa", "n"), "")
  child.type_keys(" ff")
  eq(#opened(), 0)
  child.type_keys(" fw")
  eq(#opened(), 1)
end

T["commands open a mode with a query and resume the last one"] = function()
  setup("{}")
  local root, file = project()
  edit(file)
  child.cmd("IaraSearchResume")
  eq(#opened(), 0)
  child.cmd("IaraFiles main")
  child.cmd("IaraGrep needle -- x")
  child.cmd("IaraSearchResume")
  local sessions = opened()
  eq(#sessions, 3)
  eq(sessions[1].request.mode, "files")
  eq(sessions[1].request.query, "main")
  eq(sessions[2].request.mode, "content")
  eq(sessions[2].request.query, "needle -- x")
  eq(sessions[3].request, sessions[2].request)
  eq(sessions[3].root, root)
end

T["the step is skipped when features.search is disabled"] = function()
  local function run(search)
    local personal = helpers.temp_dir() .. "/user.lua"
    helpers.write_file(
      personal,
      "return { features = { search = " .. search .. " } }"
    )
    child.restart({ "-u", helpers.minimal_init })
    return child.lua(
      [[
      vim.g.mapleader = " "
      local steps = require("iara").STEPS
      for i = #steps, 1, -1 do
        if steps[i].module ~= "iara.features.search.keymaps" then
          table.remove(steps, i)
        end
      end
      local status = require("iara").setup({
        personal_path = ...,
        project_dir = vim.fn.getcwd(),
      })
      return {
        state = status.steps[1].state,
        mapped = vim.fn.maparg(" ff", "n") ~= "",
        command = vim.fn.exists(":IaraGrep") == 2,
      }
    ]],
      { personal }
    )
  end
  eq(run("false"), { state = "disabled", mapped = false, command = false })
  eq(run("{}"), { state = "loaded", mapped = true, command = true })
end

return T
