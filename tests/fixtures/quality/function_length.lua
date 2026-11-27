-- Function length: 40 lines pass, 41 lines fail.

-- 40 lines from `local function` to `end`: accepted.
local function exactly_forty()
  local total = 0
  total = total + 0
  total = total + 1
  total = total + 2
  total = total + 3
  total = total + 4
  total = total + 5
  total = total + 6
  total = total + 7
  total = total + 8
  total = total + 9
  total = total + 10
  total = total + 11
  total = total + 12
  total = total + 13
  total = total + 14
  total = total + 15
  total = total + 16
  total = total + 17
  total = total + 18
  total = total + 19
  total = total + 20
  total = total + 21
  total = total + 22
  total = total + 23
  total = total + 24
  total = total + 25
  total = total + 26
  total = total + 27
  total = total + 28
  total = total + 29
  total = total + 30
  total = total + 31
  total = total + 32
  total = total + 33
  total = total + 34
  total = total + 35
  return total
end

-- 41 lines: reported at its first line.
local function forty_one()
  local total = 0
  total = total + 0
  total = total + 1
  total = total + 2
  total = total + 3
  total = total + 4
  total = total + 5
  total = total + 6
  total = total + 7
  total = total + 8
  total = total + 9
  total = total + 10
  total = total + 11
  total = total + 12
  total = total + 13
  total = total + 14
  total = total + 15
  total = total + 16
  total = total + 17
  total = total + 18
  total = total + 19
  total = total + 20
  total = total + 21
  total = total + 22
  total = total + 23
  total = total + 24
  total = total + 25
  total = total + 26
  total = total + 27
  total = total + 28
  total = total + 29
  total = total + 30
  total = total + 31
  total = total + 32
  total = total + 33
  total = total + 34
  total = total + 35
  total = total + 36
  return total
end

-- Anonymous functions are measured too: 41 lines.
local handlers = {
  long_field = function()
    local total = 0
    total = total + 0
    total = total + 1
    total = total + 2
    total = total + 3
    total = total + 4
    total = total + 5
    total = total + 6
    total = total + 7
    total = total + 8
    total = total + 9
    total = total + 10
    total = total + 11
    total = total + 12
    total = total + 13
    total = total + 14
    total = total + 15
    total = total + 16
    total = total + 17
    total = total + 18
    total = total + 19
    total = total + 20
    total = total + 21
    total = total + 22
    total = total + 23
    total = total + 24
    total = total + 25
    total = total + 26
    total = total + 27
    total = total + 28
    total = total + 29
    total = total + 30
    total = total + 31
    total = total + 32
    total = total + 33
    total = total + 34
    total = total + 35
    total = total + 36
    return total
  end,
}

return { exactly_forty, forty_one, handlers }
