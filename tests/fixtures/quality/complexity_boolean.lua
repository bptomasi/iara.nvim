-- Boolean operator sequences: expected cognitive complexity 18.
local function classify(a, b, c, d, e)
  if a and b and c then -- if +1, one sequence +1
    return 1
  end
  if a or b or c then -- if +1, one sequence +1
    return 2
  end
  if a and b or c then -- if +1, two sequences +2
    return 3
  end
  if a and b or c and d then -- if +1, three sequences +3
    return 4
  end
  if (a and b) and (c and d) then -- if +1, parentheses keep one sequence +1
    return 5
  end
  local mixed = a or (b and c) or d -- or, and, or: three sequences +3
  return not (a and e) and mixed -- inner and +1, outer and +1
end

-- Eight like operators form one sequence: expected complexity 2.
local function all_present(t)
  if t.a and t.b and t.c and t.d and t.e and t.f and t.g and t.h and t.i then
    return true
  end
  return false
end

return { classify = classify, all_present = all_present }
