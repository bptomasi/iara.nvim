--- LSP progress for the status line (task V5, design 09 section 3.10).
---
--- An `LspProgress` autocmd keeps the latest begin/report state of each
--- progress token and a cached status-line string per width tier. The
--- most recent token of any client is shown: a spinner, the client, the
--- title, the percent (>= `WIDTH_PERCENT` columns), and a bar (>=
--- `WIDTH_BAR` columns). Spinner frames advance only when an event
--- arrives, so a silent server shows a still frame and no timer runs.
--- When the last token ends, "✓ <client> ready" shows for `DONE_MS`,
--- then the segment is empty. Core progress messages (`nvim_echo` with
--- `kind = "progress"`) show through `vim.ui.progress_status()` while
--- no LSP progress is active.
---
--- Changes are announced with `User IaraProgressChanged` at most once
--- per `INTERVAL_MS` (10 Hz): a chatty server cannot redraw the status
--- line faster than that.
local M = {}

---Spinner frames, one step per progress event.
M.SPINNER =
  { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.DONE_GLYPH = "✓"
M.BAR_FILLED = "━"
M.BAR_EMPTY = "─"
---Cells of the progress bar.
M.BAR_WIDTH = 12
---Longest title shown, in display cells; longer ones end in "…".
M.TITLE_WIDTH = 24
---Columns from which the percent, then the bar, are shown.
M.WIDTH_PERCENT = 100
M.WIDTH_BAR = 120
---How long "ready" stays after the last token ends.
M.DONE_MS = 2000
---Shortest time between two change announcements (10 Hz).
M.INTERVAL_MS = 100
---User event pattern announcing a new segment text.
M.EVENT = "IaraProgressChanged"

---Highlight groups and their links under a foreign colorscheme.
M.FALLBACK_LINKS = {
  IaraProgressSpinner = "StatusLine",
  IaraProgressClient = "StatusLine",
  IaraProgressTitle = "StatusLine",
  IaraProgressBar = "StatusLine",
  IaraProgressBarTrack = "StatusLine",
  IaraProgressDone = "StatusLine",
}

---@class IaraProgressEntry
---@field client string Client name.
---@field title string|nil
---@field message string|nil
---@field percent integer|nil 0-100.
---@field seq integer Order of the entry's last event.

---Active tokens by "<client id>:<token>".
---@type table<string, IaraProgressEntry>
local active = {}
---Client name shown as ready, or nil.
---@type string|nil
local done = nil
local done_timer = nil
local throttle_timer = nil
local last_announce = -math.huge
local seq = 0
local frame = 1
---Segment text by width tier, cleared on each change.
---@type table<string, string>
local cache = {}
local did_setup = false

---Escape text for literal display inside a statusline expression.
local function literal(text)
  return (text:gsub("%%", "%%%%"))
end

local function colored(group, text)
  return "%#" .. group .. "#" .. text .. "%*"
end

local function cancel(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---Most recent active entry, or nil.
---@return IaraProgressEntry|nil
local function latest()
  local found = nil
  for _, entry in pairs(active) do
    if not found or entry.seq > found.seq then
      found = entry
    end
  end
  return found
end

---Title cut to `TITLE_WIDTH` display cells.
local function short(title)
  if vim.fn.strdisplaywidth(title) <= M.TITLE_WIDTH then
    return title
  end
  local cut = vim.fn.strcharpart(title, 0, M.TITLE_WIDTH - 1)
  while vim.fn.strdisplaywidth(cut) > M.TITLE_WIDTH - 1 do
    cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
  end
  return cut .. "…"
end

---Bar of `BAR_WIDTH` cells, filled in proportion to `percent`.
local function bar(percent)
  local filled = math.floor(M.BAR_WIDTH * percent / 100 + 0.5)
  return colored("IaraProgressBar", M.BAR_FILLED:rep(filled))
    .. colored("IaraProgressBarTrack", M.BAR_EMPTY:rep(M.BAR_WIDTH - filled))
end

local function spinner()
  return colored("IaraProgressSpinner", M.SPINNER[frame])
end

---Segment of an active entry for a width tier.
---@param entry IaraProgressEntry
---@param tier "compact"|"percent"|"bar"
local function active_text(entry, tier)
  local text = spinner()
    .. " "
    .. colored("IaraProgressClient", literal(entry.client))
  local details = {}
  if entry.title and entry.title ~= "" then
    table.insert(details, literal(short(entry.title)))
  end
  if entry.percent and tier ~= "compact" then
    table.insert(details, entry.percent .. "%%")
  end
  if #details > 0 then
    local joined = table.concat(details, " ")
    text = text .. "  " .. colored("IaraProgressTitle", joined)
  end
  if entry.percent and tier == "bar" then
    text = text .. " " .. bar(entry.percent)
  end
  return text
end

---Core progress messages summarized by Neovim, or "".
local function core_text()
  local status = vim.trim(vim.ui.progress_status())
  if status == "" then
    return ""
  end
  return spinner() .. " " .. colored("IaraProgressTitle", status)
end

---Uncached segment for a width tier.
local function build(tier)
  local entry = latest()
  if entry then
    return active_text(entry, tier)
  end
  if done then
    local text = M.DONE_GLYPH .. " " .. literal(done) .. " ready"
    return colored("IaraProgressDone", text)
  end
  return core_text()
end

local function tier_of(columns)
  if columns >= M.WIDTH_BAR then
    return "bar"
  end
  return columns >= M.WIDTH_PERCENT and "percent" or "compact"
end

local function announce()
  last_announce = vim.uv.now()
  cache = {}
  vim.api.nvim_exec_autocmds("User", { pattern = M.EVENT, modeline = false })
end

---Announce now, or once at the end of the current 10 Hz interval.
local function changed()
  cache = {}
  if throttle_timer then
    return
  end
  local wait = M.INTERVAL_MS - (vim.uv.now() - last_announce)
  if wait <= 0 then
    announce()
    return
  end
  throttle_timer = vim.defer_fn(function()
    throttle_timer = nil
    announce()
  end, wait)
end

---Show "ready" for `client` until `DONE_MS` passes.
local function finish(client)
  cancel(done_timer)
  done = client
  done_timer = vim.defer_fn(function()
    done_timer = nil
    done = nil
    changed()
  end, M.DONE_MS)
end

---Keep the state of one `$/progress` notification.
---@param client_id integer
---@param params table `lsp.ProgressParams`
local function record(client_id, params)
  local value = params.value
  local client = vim.lsp.get_client_by_id(client_id)
  if type(value) ~= "table" or not client then
    return
  end
  local key = client_id .. ":" .. tostring(params.token)
  if value.kind == "end" then
    active[key] = nil
    if not latest() then
      finish(client.name)
    end
  else
    local entry = active[key] or { client = client.name }
    entry.title = value.title or entry.title
    entry.message = value.message or entry.message
    entry.percent = tonumber(value.percentage) or entry.percent
    seq = seq + 1
    entry.seq = seq
    active[key] = entry
    cancel(done_timer)
    done_timer, done = nil, nil
  end
  frame = frame % #M.SPINNER + 1
  changed()
end

---Forget the tokens of clients that stopped without ending them.
local function prune()
  local removed = false
  for key in pairs(active) do
    local id = tonumber(key:match("^(%d+):"))
    local client = vim.lsp.get_client_by_id(id)
    if not client or client:is_stopped() then
      active[key] = nil
      removed = true
    end
  end
  if removed then
    changed()
  end
end

local function link_fallbacks()
  for name, target in pairs(M.FALLBACK_LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local function create_autocmds(group)
  local autocmd = vim.api.nvim_create_autocmd
  autocmd("LspProgress", {
    group = group,
    callback = function(args)
      record(args.data.client_id, args.data.params)
    end,
  })
  autocmd("LspDetach", {
    group = group,
    callback = function()
      vim.schedule(prune)
    end,
  })
  autocmd("Progress", {
    group = group,
    callback = function()
      frame = frame % #M.SPINNER + 1
      changed()
    end,
  })
  autocmd("ColorScheme", { group = group, callback = link_fallbacks })
end

---Track LSP and core progress, once. `statusline()` calls it.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  -- Starts Neovim's own Progress tracking before ours, so our handler
  -- reads the summary after it has been updated.
  vim.ui.progress_status()
  link_fallbacks()
  create_autocmds(vim.api.nvim_create_augroup("IaraProgress", {}))
end

---Status-line segment for the current width (highlight items
---included, "%" escaped), "" when nothing is in progress. Cached until
---the next change.
---@return string
function M.statusline()
  M.setup()
  local tier = tier_of(vim.o.columns)
  local text = cache[tier]
  if not text then
    text = build(tier)
    cache[tier] = text
  end
  return text
end

---What the segment shows: the most recent active token, else the
---client shown as ready, else nil.
---@return { client: string, title: string|nil, message: string|nil,
---  percent: integer|nil, done: boolean }|nil
function M.state()
  local entry = latest()
  if entry then
    return {
      client = entry.client,
      title = entry.title,
      message = entry.message,
      percent = entry.percent,
      done = false,
    }
  end
  return done and { client = done, done = true } or nil
end

return M
