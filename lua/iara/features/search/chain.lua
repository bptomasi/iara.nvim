--- Chained filters of the search picker (task UX1): a stack of steps,
--- each one a full search request. A file name step hands the files it
--- found to a content step, and a content step hands the files that
--- contain its matches to a new file name step, and so on; going back
--- restores the previous step's request.
---
--- A step hands over its files as the next request's `within` list
--- (contracts.md, section 9.5), which narrows the eligible inventory and
--- never widens it. Only collected records can be handed over: at most
--- 200 file names, or the files of at most 1,000 occurrences, and the
--- step says so when its lane was truncated. A file name step without a
--- query (a listing) hands over its glob and `within` instead, so every
--- eligible file it lists is searched, not only the 200 shown (UX1b:
--- with neither, the whole eligible set). Pure data; no UI.
local M = {}

---@class IaraSearchStep
---@field request IaraSearchRequest Full request of the step.
---@field handed integer|nil Files handed to the next step, when known.
---@field notice string|nil Limit disclosed when the step was handed in.

---@class IaraSearchChain
---@field steps IaraSearchStep[] Oldest first; the last one is current.

---@class IaraSearchHandOff
---@field request IaraSearchRequest Request of the next step.
---@field handed integer|nil Files handed over, when known.
---@field notice string|nil Disclosed limit of the hand-off.

local FILE_LIMIT = 200
local OCCURRENCE_LIMIT = 1000

---Fields whose absence must be sent explicitly to clear them.
local CLEARED = { glob = "", within = false }

---@param request IaraSearchRequest
---@return IaraSearchChain
function M.new(request)
  return { steps = { { request = vim.deepcopy(request) } } }
end

---@param chain IaraSearchChain
---@return IaraSearchStep
function M.current(chain)
  return chain.steps[#chain.steps]
end

---@param chain IaraSearchChain
---@return integer
function M.depth(chain)
  return #chain.steps
end

---Request changes that turn any session request into `request`,
---clearing the optional fields it does not set.
---@param request IaraSearchRequest
---@return IaraSearchRequest changes
function M.changes(request)
  local changes = vim.deepcopy(request)
  for field, cleared in pairs(CLEARED) do
    if changes[field] == nil then
      changes[field] = cleared
    end
  end
  return changes
end

---Count with thousands separators: 1234 -> "1,234".
---@param count integer
---@return string
function M.count_text(count)
  local text = tostring(count)
  local grouped = text:reverse():gsub("(%d%d%d)", "%1,")
  return (grouped:reverse():gsub("^,", ""))
end
local count_text = M.count_text

---A lane that is still working or failed cannot hand its files over.
---@return string|nil refusal
local function refusal(lane)
  if lane.state == "loading" then
    return "Results are still loading; try again in a moment."
  end
  if lane.state == "error" or lane.state == "incomplete" then
    local message = lane.error and lane.error.message or lane.state
    return "Cannot chain from failed results: " .. message
  end
  if lane.state == "cancelled" then
    return "Cannot chain from cancelled results."
  end
end

local function next_request(snapshot, changes)
  local request = vim.deepcopy(snapshot.request)
  request.focus = nil
  return vim.tbl_extend("force", request, changes)
end

---A listing (no query) hands over its glob and `within` unchanged: the
---next step searches every eligible file it lists, not only the rows
---shown, and `total` counts them all.
local function from_listing(snapshot)
  return {
    request = next_request(snapshot, { mode = "content", query = "" }),
    handed = snapshot.files.lane.total,
  }
end

local function from_file_names(snapshot)
  if snapshot.request.query == "" then
    return from_listing(snapshot)
  end
  local paths = {}
  for _, record in ipairs(snapshot.files.records) do
    table.insert(paths, record.path)
  end
  if #paths == 0 then
    return nil, "No files to search in; change the file filter first."
  end
  local hand_off = {
    request = next_request(snapshot, {
      mode = "content",
      query = "",
      within = paths,
    }),
    handed = #paths,
  }
  local lane = snapshot.files.lane
  if lane.state == "truncated" then
    local total = count_text(lane.total)
    hand_off.notice = ("Searching the best %d of %s files by name."):format(
      FILE_LIMIT,
      total
    )
  end
  return hand_off
end

local function from_content(snapshot)
  if snapshot.request.query == "" then
    return nil, "Type the text to search for first."
  end
  local paths = {}
  for _, group in ipairs(snapshot.content.groups) do
    table.insert(paths, group.path)
  end
  if #paths == 0 then
    return nil, "No files contain matches; nothing to filter."
  end
  local hand_off = {
    request = next_request(snapshot, {
      mode = "files",
      query = "",
      within = paths,
    }),
    handed = #paths,
  }
  if snapshot.content.lane.state == "truncated" then
    local limit = count_text(OCCURRENCE_LIMIT)
    hand_off.notice = ("Kept files of the first %s matches only."):format(limit)
  end
  return hand_off
end

---The next step built from the current step's results: content search
---in the files found by name, or a file name filter over the files that
---contain matches. A file name step without a query hands over its glob
---and `within` list unchanged, so no listing limit applies.
---@param snapshot IaraSearchSnapshot Of the current step.
---@return IaraSearchHandOff|nil hand_off
---@return string|nil refusal Why there is no next step.
function M.hand_off(snapshot)
  local content = snapshot.request.mode == "content"
  local lane = content and snapshot.content.lane or snapshot.files.lane
  local reason = refusal(lane)
  if reason then
    return nil, reason
  end
  if content then
    return from_content(snapshot)
  end
  return from_file_names(snapshot)
end

---Push the next step; the current step keeps `request` (its latest
---query and switches) for going back.
---@param chain IaraSearchChain
---@param request IaraSearchRequest Current request of the current step.
---@param hand_off IaraSearchHandOff
function M.push(chain, request, hand_off)
  local current = M.current(chain)
  current.request = vim.deepcopy(request)
  current.handed = hand_off.handed
  table.insert(chain.steps, {
    request = vim.deepcopy(hand_off.request),
    notice = hand_off.notice,
  })
end

---Drop the current step and return the previous step's request.
---@param chain IaraSearchChain
---@return IaraSearchRequest|nil request Nil on the first step.
function M.pop(chain)
  if #chain.steps < 2 then
    return nil
  end
  table.remove(chain.steps)
  local current = M.current(chain)
  current.handed = nil
  return vim.deepcopy(current.request)
end

local function quoted(text)
  return vim.fn.strtrans((text:gsub("\n", "\\n")))
end

local function step_label(request)
  if request.mode == "content" then
    local query = request.query
    return query == "" and "Contains" or "Contains: " .. quoted(query)
  end
  local parts = {}
  if request.glob then
    table.insert(parts, quoted(request.glob))
  end
  if request.query ~= "" then
    table.insert(parts, quoted(request.query))
  end
  if #parts == 0 then
    return "Files"
  end
  return "Files: " .. table.concat(parts, " ")
end

---Breadcrumb labels, oldest first. Earlier steps show how many files
---they handed on; the current step shows `query`, its live input.
---@param chain IaraSearchChain
---@param query string
---@return string[] labels
function M.crumbs(chain, query)
  local labels = {}
  for index, step in ipairs(chain.steps) do
    local request = step.request
    if index == #chain.steps then
      request = vim.tbl_extend("force", request, { query = query })
    end
    local label = step_label(request)
    if index < #chain.steps and step.handed then
      label = ("%s (%s)"):format(label, count_text(step.handed))
    end
    labels[index] = label
  end
  return labels
end

return M
