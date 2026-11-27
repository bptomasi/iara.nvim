--- Signature help float (V9, FU-V12-3; design 09 section 3.8). The
--- native `vim.lsp.buf.signature_help` replaces its "1/2" count title
--- with any title it is given and has no footer, so Iara asks the
--- servers itself and draws the float language: an idle "Signature"
--- title, with several signatures the active index in the title
--- ("Signature 1/2") and a `C-s next` hint centered in the bottom
--- border. `<C-s>` inside the float shows the next signature, as the
--- native one does. Loaded on the first request, never at startup.
local M = {}

local METHOD = "textDocument/signatureHelp"

---Size limits, as for completion docs and hover.
M.MAX = { width = 80, height = 20 }

---Hint of the bottom border with several signatures.
M.HINTS = { { "C-s", "next" } }

local namespace = vim.api.nvim_create_namespace("iara.signature")

---Signatures of every answer, in client order, each with its client,
---and the position of the active one.
---@param results table<integer, { err: any, result: table|nil }>
---@return { [1]: vim.lsp.Client, [2]: table }[] signatures
---@return integer active
function M.collect(results)
  local signatures, active = {}, 1
  local ids = vim.tbl_keys(results)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local client = vim.lsp.get_client_by_id(id)
    local result = client and results[id].result or {}
    for index, signature in ipairs(result.signatures or {}) do
      signature.activeParameter = signature.activeParameter
        or result.activeParameter
      table.insert(signatures, { client, signature })
      if (result.activeSignature or 0) + 1 == index then
        active = #signatures
      end
    end
  end
  return signatures, active
end

---Title and footer chunks for signature `index` of `total`.
---@param index integer
---@param total integer
---@return table[] title
---@return table[]|nil footer Nil with one signature.
function M.frame(index, total)
  local float = require("iara.core.float")
  if total <= 1 then
    return float.title("Signature"), nil
  end
  local title = float.title(("Signature %d/%d"):format(index, total))
  return title, float.footer(M.HINTS, M.MAX.width)
end

---Markdown lines of one signature and its active parameter's range.
local function lines_of(state)
  local client, signature = unpack(state.signatures[state.index])
  local triggers = vim.tbl_get(
    client.server_capabilities,
    "signatureHelpProvider",
    "triggerCharacters"
  )
  return vim.lsp.util.convert_signature_help_to_markdown_lines(
    { signatures = { signature } },
    state.filetype,
    triggers
  )
end

---Show the signature after the current one in a new float, or in
---`update_win` when cycling.
local function show(state, update_win)
  state.index = state.index % #state.signatures + 1
  local lines, active = lines_of(state)
  if not lines then
    return
  end
  local title, footer = M.frame(state.index, #state.signatures)
  local buf, win = vim.lsp.util.open_floating_preview(lines, "markdown", {
    focus_id = METHOD,
    title = title,
    title_pos = "left",
    max_width = M.MAX.width,
    max_height = M.MAX.height,
    _update_win = update_win,
  })
  if footer and vim.api.nvim_win_get_config(win).border then
    vim.api.nvim_win_set_config(win, { footer = footer, footer_pos = "center" })
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if active then
    local first, last = { active[1], active[2] }, { active[3], active[4] }
    local group = "LspSignatureActiveParameter"
    vim.hl.range(buf, namespace, group, first, last)
  end
  return buf, win
end

---Open the float for `state`; with several signatures `<C-s>` in it
---shows the next one.
local function open(state)
  local buf, win = show(state)
  if not buf or #state.signatures < 2 then
    return
  end
  vim.keymap.set("n", "<C-s>", function()
    show(state, win)
  end, { buffer = buf, desc = "Next signature" })
end

---Ask the current buffer's servers for signature help and show it.
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local function params(client)
    return vim.lsp.util.make_position_params(0, client.offset_encoding)
  end
  vim.lsp.buf_request_all(bufnr, METHOD, params, function(results)
    local current = vim.api.nvim_get_current_buf() == bufnr
    if not current or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      return
    end
    local signatures, active = M.collect(results)
    if #signatures == 0 then
      vim.notify("No signature help available", vim.log.levels.INFO)
      return
    end
    open({
      signatures = signatures,
      index = active - 1,
      filetype = vim.bo[bufnr].filetype,
    })
  end)
end

return M
