-- Nesting increments: expected cognitive complexity 16.
local function nested_loops(items, limit)
  local total = 0
  for _, item in ipairs(items) do -- +1 (nesting 0)
    if item.enabled then -- +2 (nesting 1)
      while total < limit do -- +3 (nesting 2)
        if item.weight > 0 then -- +4 (nesting 3)
          total = total + item.weight
        else -- +1
          break
        end
        repeat -- +4 (nesting 3)
          total = total + 1
        until total % 2 == 0
      end
    elseif item.fallback then -- +1
      total = total + 1
    end
  end
  return total
end

-- The same structures without nesting: expected complexity 7, accepted.
local function flat_sequence(items, limit)
  local total = 0
  for _ in ipairs(items) do -- +1
    total = total + 1
  end
  while total < limit do -- +1
    total = total + 1
  end
  repeat -- +1
    total = total - 1
  until total < limit
  if total > 0 then -- +1
    total = 0
  elseif total < 0 then -- +1
    total = 1
  else -- +1
    total = 2
  end
  if limit then -- +1
    return total
  end
end

return { nested_loops = nested_loops, flat_sequence = flat_sequence }
