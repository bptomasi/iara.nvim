-- Git hunks in the sign column. Gitsigns' own automatic attach is off:
-- Iara attaches only eligible file buffers, so conservative buffers start
-- no Git work, and detaches buffers that leave the eligible state.
-- `on_attach` refuses ineligible buffers as a second guard.

local function hunk_keymaps(bufnr)
  local gitsigns = require("gitsigns")
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc })
  end
  local function jump(direction, native)
    return function()
      if vim.wo.diff then
        vim.cmd.normal({ native, bang = true })
      else
        gitsigns.nav_hunk(direction)
      end
    end
  end
  map("]c", jump("next", "]c"), "Next hunk")
  map("[c", jump("prev", "[c"), "Previous hunk")
  map("<leader>gp", gitsigns.preview_hunk, "Preview hunk")
  map("<leader>gs", gitsigns.stage_hunk, "Stage hunk")
  map("<leader>gr", gitsigns.reset_hunk, "Reset hunk (discards changes)")
  map("<leader>gb", gitsigns.blame_line, "Blame line")
end

local function is_file_buffer(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

---Gitsigns' plugin file runs setup() with defaults (automatic attach)
---before Iara's setup; attaches started then finish under this check.
local function accept_attach(bufnr)
  if not require("iara.core.eligibility").is_eligible(bufnr) then
    return false
  end
  hunk_keymaps(bufnr)
end

---Sign glyphs of `iara.core.icons`, the same for unstaged and staged
---hunks (staged ones are dimmed by Gitsigns).
local function signs()
  local glyphs = require("iara.core.icons").GIT_SIGNS
  local result = {}
  for name, text in pairs(glyphs) do
    result[name] = { text = text }
  end
  return result
end

local function update(bufnr)
  if not is_file_buffer(bufnr) then
    return
  end
  local gitsigns = require("gitsigns")
  if require("iara.core.eligibility").is_eligible(bufnr) then
    gitsigns.attach(bufnr)
  else
    gitsigns.detach(bufnr)
  end
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup("IaraGitsigns", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufReadPost", "BufNewFile", "BufWritePost", "BufFilePost" },
    {
      group = group,
      callback = function(args)
        update(args.buf)
      end,
    }
  )
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IaraEligibilityChanged",
    callback = function(args)
      update(args.data.bufnr)
    end,
  })
end

return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    auto_attach = false,
    signs = signs(),
    signs_staged = signs(),
    preview_config = { border = require("iara.core.ui").BORDER },
    on_attach = accept_attach,
  },
  config = function(_, opts)
    require("gitsigns").setup(opts)
    create_autocmds()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        update(bufnr)
      end
    end
  end,
}
