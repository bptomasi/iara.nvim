--- Micro-benchmark for iara.features.search.fuzzy. Not part of the test
--- suite (the runner only collects tests/**/test_*.lua).
---
--- Usage: nvim --clean -l tests/bench_fuzzy.lua [PATH_COUNT]
---
--- Generates PATH_COUNT (default 100,000) deterministic synthetic paths,
--- then for each query records the duration of every individual `score`
--- call (after one warm-up pass) and of every scheduled `match` batch,
--- and prints a Markdown report.
--- Batches are timed by wrapping `vim.schedule`, which is how the matcher
--- re-enters the main loop; the final batch includes sorting the retained
--- matches and computing their positions.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local iara_dir = vim.fn.fnamemodify(source, ":p:h:h")
package.path = iara_dir .. "/lua/?.lua;" .. package.path

local fuzzy = require("iara.features.search.fuzzy")
local hrtime = vim.uv.hrtime

local QUERIES = { "a", "init", "srcmain", "comp/button", "fuzzylua", "qqxz" }

local DIRS = {
  "src",
  "lib",
  "components",
  "tests",
  "docs",
  "internal",
  "packages",
  "core",
  "utils",
  "vendor",
  "api",
  "services",
  "models",
  "views",
  "assets",
  "config",
}
local STEMS = {
  "main",
  "index",
  "button",
  "user_profile",
  "fuzzyMatcher",
  "init",
  "router",
  "search-panel",
  "data",
  "helpers",
  "README",
  "session_store",
}
local EXTS = { ".lua", ".ts", ".tsx", ".md", ".json", ".go", ".rs", ".py" }

---Deterministic linear congruential generator returning 1..n.
local seed = 12345
local function pick(list)
  seed = (seed * 1103515245 + 12345) % 2147483648
  return list[seed % #list + 1]
end

local function synthetic_paths(count)
  local paths = {}
  for index = 1, count do
    local parts = {}
    for depth = 1, 1 + index % 6 do
      parts[depth] = pick(DIRS)
    end
    parts[#parts + 1] = pick(STEMS) .. "_" .. index .. pick(EXTS)
    paths[index] = table.concat(parts, "/")
  end
  return paths
end

---Nearest-rank percentile of a sorted list of nanoseconds, in ms.
local function percentile(sorted, fraction)
  local rank = math.max(1, math.ceil(fraction * #sorted))
  return sorted[rank] / 1e6
end

local function summarize(samples)
  table.sort(samples)
  local total = 0
  for _, value in ipairs(samples) do
    total = total + value
  end
  return {
    count = #samples,
    p50 = percentile(samples, 0.5),
    p95 = percentile(samples, 0.95),
    p99 = percentile(samples, 0.99),
    max = samples[#samples] / 1e6,
    total = total / 1e6,
  }
end

-- Preallocated so that growing the sample table is not measured.
local new_table = require("table.new")

local function time_score_calls(query, paths)
  for _, path in ipairs(paths) do -- warm-up: JIT traces, caches
    fuzzy.score(query, path)
  end
  local samples, matched = new_table(#paths, 0), 0
  for index, path in ipairs(paths) do
    local start = hrtime()
    local value = fuzzy.score(query, path)
    samples[index] = hrtime() - start
    if value then
      matched = matched + 1
    end
  end
  return summarize(samples), matched
end

---Run one `match` and time every scheduled batch.
local function time_match(query, paths)
  local batches, done = {}, false
  local original = vim.schedule
  vim.schedule = function(fn)
    original(function()
      local start = hrtime()
      fn()
      batches[#batches + 1] = hrtime() - start
    end)
  end
  local start = hrtime()
  fuzzy.match(query, paths, {
    on_done = function()
      done = true
    end,
  })
  vim.wait(60000, function()
    return done
  end, 0)
  local wall = (hrtime() - start) / 1e6
  vim.schedule = original
  return summarize(batches), wall
end

---Long inputs at the 4 KiB path and 256-byte query limits.
local WORST_CASES = {
  {
    name = "256-byte query matching across a 4 KiB path",
    query = ("ab"):rep(128),
    path = ("ab/"):rep(1365) .. "x",
  },
  {
    name = "256-byte query failing at its last byte",
    query = ("a"):rep(255) .. "z",
    path = ("ab/"):rep(1365) .. "x",
  },
  {
    name = "Case-folded 256-byte query over a 4 KiB path",
    query = ("ab"):rep(128),
    path = ("AB/"):rep(1365) .. "x",
  },
}

local function time_worst_cases()
  local lines = {
    "| Case | p50 | max |",
    "| --- | ---: | ---: |",
  }
  for _, case in ipairs(WORST_CASES) do
    local samples = {}
    for index = 1, 1000 do
      local start = hrtime()
      fuzzy.score(case.query, case.path)
      samples[index] = hrtime() - start
    end
    local stats = summarize(samples)
    lines[#lines + 1] = ("| %s | %.4f | %.4f |"):format(
      case.name,
      stats.p50,
      stats.max
    )
  end
  return lines
end

local function row(cells)
  return "| " .. table.concat(cells, " | ") .. " |"
end

local function ms(value)
  return ("%.4f"):format(value)
end

local function report(paths)
  local calls = {
    row({ "Query", "Matches", "p50", "p95", "p99", "max", "sum" }),
    row({ "---", "---:", "---:", "---:", "---:", "---:", "---:" }),
  }
  local runs = {
    row({ "Query", "Batches", "p50", "p95", "p99", "max", "wall" }),
    row({ "---", "---:", "---:", "---:", "---:", "---:", "---:" }),
  }
  for _, query in ipairs(QUERIES) do
    local call, matched = time_score_calls(query, paths)
    local q = "`" .. query .. "`"
    calls[#calls + 1] = row({
      q,
      tostring(matched),
      ms(call.p50),
      ms(call.p95),
      ms(call.p99),
      ms(call.max),
      ms(call.total),
    })
    local batch, wall = time_match(query, paths)
    runs[#runs + 1] = row({
      q,
      tostring(batch.count),
      ms(batch.p50),
      ms(batch.p95),
      ms(batch.p99),
      ms(batch.max),
      ms(wall),
    })
  end
  return calls, runs
end

local count = tonumber(_G.arg and _G.arg[1]) or 100000
local paths = synthetic_paths(count)
local bytes = 0
for _, path in ipairs(paths) do
  bytes = bytes + #path
end
local calls, runs = report(paths)
local lines = {
  ("Paths: %d, %d bytes total, mean %.1f bytes."):format(
    count,
    bytes,
    bytes / count
  ),
  ("Neovim: %s."):format(tostring(vim.version())),
  "",
  "Per `score` call (ms):",
  "",
}
vim.list_extend(lines, calls)
vim.list_extend(lines, { "", "Per `match` batch (ms), wall time (ms):", "" })
vim.list_extend(lines, runs)
vim.list_extend(lines, { "", "Worst-case `score` calls, 1,000 each (ms):", "" })
vim.list_extend(lines, time_worst_cases())
io.stdout:write(table.concat(lines, "\n") .. "\n")
