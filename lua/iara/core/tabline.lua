--- Tab line (UX3). With one tab page it lists the open files (listed
--- buffers that name a file, plus the current buffer) as clickable labels
--- with an icon and a modified dot, like a buffer bar; with several tab
--- pages it labels each tab by its current window: the clean terminal or
--- agent title (UX2) or the file name. The current label joins the editor
--- background behind an accent bar (V4); the others sit on the `crust`
--- fill. A modified dot is the accent on the current label and the
--- warning color on the others (red would read as an error).
---
--- The tab line is drawn again only when Neovim redraws it (buffer,
--- window, and tab changes, the first modification), not per keystroke.
---
--- 'showtabline' follows the content: shown while there are two or more
--- files or tab pages, hidden otherwise, unless the user set the option
--- in `config.options`.
local icons = require("iara.core.icons")

local M = {}

---Accent bar before the current label (U+258E).
M.BAR = icons.START.bar

local did_setup = false
local pending = false

local function literal(text)
  return (text:gsub("%%", "%%%%"))
end

local function listed_buffers(limit)
  local current = vim.api.nvim_get_current_buf()
  local list = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local options = vim.bo[bufnr]
    local ordinary = options.buflisted and options.buftype == ""
    if
      ordinary and (bufnr == current or vim.api.nvim_buf_get_name(bufnr) ~= "")
    then
      table.insert(list, bufnr)
      if limit and #list == limit then
        break
      end
    end
  end
  return list
end

---Files the buffer bar lists, including the current unnamed file.
---@return integer[]
function M.buffers()
  return listed_buffers()
end

---Icon and name of a buffer: the clean title of a terminal or agent,
---else the file name.
local function describe(bufnr)
  local terminal = require("iara.core.statusline").terminal_of(bufnr)
  if terminal then
    local glyph = terminal.kind == "agent" and icons.AGENT or icons.TERMINAL
    return glyph, terminal.title
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return icons.FILE, "[No Name]"
  end
  return icons.file(name), vim.fn.fnamemodify(name, ":t")
end

---One label: " icon name ● " in the active or inactive colors; the
---active one has an accent bar (`BAR`) before its icon.
---@return string text, integer width
local function label(bufnr, active)
  local glyph, name = describe(bufnr)
  local group = active and "IaraTabActive" or "IaraTabInactive"
  local text = ("%s %s "):format(glyph, name)
  local width = vim.api.nvim_strwidth(text) + (active and 2 or 1)
  local out = "%#" .. group .. "# "
  if active then
    out = out .. "%#IaraTabActiveBar#" .. M.BAR .. "%#" .. group .. "#"
  end
  out = out .. literal(text)
  if vim.bo[bufnr].modified then
    local mark = active and "IaraTabModified" or "IaraTabModifiedInactive"
    out = out .. "%#" .. mark .. "#" .. icons.MODIFIED .. " "
    width = width + 2
  end
  return out, width
end

---Labels that fit in `columns`, widening around the current one.
---@param items { text: string, width: integer }[]
---@param current integer Index of the current label.
---@param columns integer
---@return string
function M.fit(items, current, columns)
  local first, last = current, current
  local used = items[current] and items[current].width or 0
  local grew = true
  while grew do
    grew = false
    local after = items[last + 1]
    if after and used + after.width <= columns then
      last, used, grew = last + 1, used + after.width, true
    end
    local before = items[first - 1]
    if before and used + before.width <= columns then
      first, used, grew = first - 1, used + before.width, true
    end
  end
  local parts = {}
  for index = first, last do
    table.insert(parts, items[index].text)
  end
  return table.concat(parts)
end

local function buffer_bar()
  local current = vim.api.nvim_get_current_buf()
  local items, index = {}, 1
  for position, bufnr in ipairs(M.buffers()) do
    local text, width = label(bufnr, bufnr == current)
    -- A click selects the buffer (%N@...@ calls the handler).
    text = ("%%%d@v:lua.require'iara.core.tabline'.click@"):format(bufnr)
      .. text
      .. "%X"
    table.insert(items, { text = text, width = width })
    if bufnr == current then
      index = position
    end
  end
  return M.fit(items, index, vim.o.columns)
end

local function tab_bar()
  local current = vim.api.nvim_get_current_tabpage()
  local items, index = {}, 1
  for number, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local win = vim.api.nvim_tabpage_get_win(tabpage)
    local bufnr = vim.api.nvim_win_get_buf(win)
    local ok, text, width = pcall(label, bufnr, tabpage == current)
    if not ok then
      text, width = "%#IaraTabInactive# ? ", 3
    end
    table.insert(
      items,
      { text = ("%%%dT"):format(number) .. text, width = width }
    )
    if tabpage == current then
      index = number
    end
  end
  return M.fit(items, index, vim.o.columns)
end

---Tab line text: the buffer bar with one tab page, else one label per
---tab page; never a `term://` name.
---@return string
function M.render()
  local ok, text = pcall(function()
    if #vim.api.nvim_list_tabpages() > 1 then
      return tab_bar()
    end
    return buffer_bar()
  end)
  return (ok and text or "") .. "%#IaraTabFill#%T"
end

---Click handler of a buffer label: show that buffer.
---@param bufnr integer
function M.click(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_current_buf(bufnr)
  end
end

---'showtabline' for the current content: 2 with two or more files or
---tab pages, else 1 (the native rule: only with several tab pages).
---@return integer
function M.wanted_showtabline()
  local several = #vim.api.nvim_list_tabpages() > 1 or #listed_buffers(2) > 1
  return several and 2 or 1
end

local function update()
  pending = false
  local wanted = M.wanted_showtabline()
  if vim.o.showtabline ~= wanted then
    vim.o.showtabline = wanted
  end
end

local function schedule_update()
  if not pending then
    -- A batch may add or remove many buffers before their state settles.
    pending = true
    vim.schedule(update)
  end
end

---Follow the number of files and tab pages with 'showtabline', unless
---`manage` is false (the user configured the option).
---@param manage boolean|nil Defaults to true.
function M.setup(manage)
  if did_setup or manage == false then
    return
  end
  did_setup = true
  vim.api.nvim_create_autocmd(
    { "BufAdd", "BufDelete", "BufFilePost", "TabNew", "TabClosed" },
    {
      group = vim.api.nvim_create_augroup("IaraTabline", { clear = true }),
      callback = schedule_update,
    }
  )
end

return M
