-- Recursion, goto, and nested functions.

-- Expected cognitive complexity 15: exactly at the limit, accepted.
local function at_limit(node, visit)
  if not node then -- +1
    return
  end
  visit(node)
  for _, child in ipairs(node.children) do -- +1
    at_limit(child, visit) -- recursion +1
  end
  local function deep() -- nested function: nesting 1 inside
    if node.flag then -- +2 (nesting 1)
      if node.other then -- +3 (nesting 2)
        while true do -- +4 (nesting 3)
          goto continue -- +1
        end
        ::continue::
      end
    end
  end
  deep()
  return vim.tbl_map(function(item) -- nesting 1 inside
    if item then -- +2 (nesting 1)
      return item
    end
  end, node.children)
end

-- Expected cognitive complexity 16: the same plus one recursive call.
local function over_limit(node, visit)
  if not node then -- +1
    return
  end
  visit(node)
  for _, child in ipairs(node.children) do -- +1
    over_limit(child, visit) -- recursion +1
  end
  local function deep() -- nested function: nesting 1 inside
    if node.flag then -- +2 (nesting 1)
      if node.other then -- +3 (nesting 2)
        while true do -- +4 (nesting 3)
          goto continue -- +1
        end
        ::continue::
      end
    end
  end
  deep()
  over_limit(node.next, visit) -- recursion +1
  return vim.tbl_map(function(item) -- nesting 1 inside
    if item then -- +2 (nesting 1)
      return item
    end
  end, node.children)
end

local M = {}

-- Methods called through self count as recursion: expected 17.
function M:walk(depth)
  if depth > 0 then -- +1
    self:walk(depth - 1) -- recursion +1
    for _ = 1, depth do -- +2
      if depth % 2 == 0 then -- +3
        while depth > 10 do -- +4
          if depth > 20 then -- +5
            depth = depth - 1
          end
          depth = depth - 1
        end
      end
    end
    self:walk(depth - 2) -- recursion +1
  end
end

return { at_limit = at_limit, over_limit = over_limit, M = M }
