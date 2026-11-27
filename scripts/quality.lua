-- Measurable code quality criteria for Iara.
--
-- Usage: nvim --clean -l scripts/quality.lua [PATH...]
--
-- Each PATH is a file or directory. The default is the checkout root.
-- Directories expand to the text files Git tracks or would track there.
-- Explicit file arguments are always checked, even if excluded below.
--
-- Rules:
--   * every Lua function spans at most 40 lines, `function` to `end`;
--   * every outermost Lua function has cognitive complexity at most 15;
--   * every line of a text file has at most 80 characters.
--
-- Cognitive complexity follows the SonarSource definition adapted to Lua:
--   +1 plus the nesting level for if, for, while, and repeat;
--   +1 for each elseif and else, and for each goto;
--   +1 for each sequence of like boolean operators (`a and b and c` is
--      one sequence, `a and b or c` is two); parentheses do not break a
--      sequence;
--   +1 for each direct recursive call;
--   nesting grows inside those control structures and inside nested
--   functions. A nested function's complexity counts toward its outermost
--   enclosing function, which is the one reported.
--
-- Prints `path:line: message` diagnostics and exits 1 when any rule fails.

local LIMITS = { function_lines = 40, complexity = 15, line_chars = 80 }
local CHECKOUT = vim.fn.fnamemodify(arg[0], ":p:h:h")

local TEXT_EXTENSIONS = {
  lua = true,
  md = true,
  sh = true,
  toml = true,
  json = true,
  yaml = true,
  yml = true,
  txt = true,
  vim = true,
  scm = true,
}

-- Skipped when expanding directories, with the reason for each skip.
local EXCLUDED_PATTERNS = {
  -- Written by lazy.nvim with one entry per line; not edited by hand.
  "lazy%-lock%.json$",
  -- Inputs that violate the rules on purpose to test this checker.
  "tests/fixtures/quality/",
  -- Development tools downloaded by scripts/tools.sh.
  "^%.tools/",
  "^%.agents/",
  "^%.aws/",
  "^%.claude/",
  "^%.codex/",
  "^lua/user%.lua$",
}

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function is_excluded(relative)
  for _, pattern in ipairs(EXCLUDED_PATTERNS) do
    if relative:find(pattern) then
      return true
    end
  end
  return false
end

local function is_text_file(path, content)
  local extension = path:match("%.([%w]+)$")
  if extension then
    return TEXT_EXTENSIONS[extension] == true
  end
  -- Extensionless files count when they are scripts, such as bin/iara.
  return not path:match("/%.[^/]*$") and content:sub(1, 2) == "#!"
end

local function git_output(dir, args)
  local argv = vim.list_extend({ "git", "-C", dir }, args)
  local ok, process = pcall(vim.system, argv, { text = false })
  if not ok then
    return nil
  end
  local result = process:wait()
  return result.code == 0 and result.stdout or nil
end

local function inside(path, root)
  return path == root or vim.startswith(path, root .. "/")
end

local function git_files(dir)
  local root = vim.uv.fs_realpath(CHECKOUT)
  local path = vim.uv.fs_realpath(dir)
  if root and path and inside(path, root) then
    if not vim.uv.fs_lstat(root .. "/.git") then
      return nil
    end
    local top = git_output(path, { "rev-parse", "--show-toplevel" })
    if not top or not inside(top:gsub("\n$", ""), root) then
      return nil
    end
  end
  local output = git_output(dir, {
    "ls-files",
    "-z",
    "--cached",
    "--others",
    "--exclude-standard",
  })
  return output and vim.split(output, "\0", { trimempty = true })
end

local function walked_files(dir)
  local files = {}
  local opts = {
    depth = math.huge,
    skip = function(path)
      return vim.fs.basename(path) ~= ".git" and not is_excluded(path .. "/")
    end,
  }
  for name, kind in vim.fs.dir(dir, opts) do
    if kind == "file" then
      table.insert(files, name)
    end
  end
  return files
end

---Expand a directory into the text files to check.
local function directory_files(dir)
  local files = {}
  for _, relative in ipairs(git_files(dir) or walked_files(dir)) do
    local path = dir .. "/" .. relative
    local content = not is_excluded(relative) and read_file(path)
    if content and is_text_file(relative, content) then
      table.insert(files, path)
    end
  end
  return files
end

local function character_count(line)
  -- Counts UTF-8 code points: every byte that is not a continuation byte.
  local _, count = line:gsub("[^\128-\191]", "")
  return count
end

local function check_lines(path, content, report)
  local number = 0
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    local count = character_count(line:gsub("\r$", ""))
    if count > LIMITS.line_chars then
      report(
        path,
        number,
        ("line has %d characters (max %d)"):format(count, LIMITS.line_chars)
      )
    end
  end
end

local function node_text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

local FUNCTION_TYPES = {
  function_declaration = true,
  function_definition = true,
}

---Best-effort name of a function node, used in messages and to detect
---recursion.
local function function_name(node, source)
  local name = node:field("name")[1]
  if name then
    return node_text(name, source)
  end
  local parent = node:parent()
  if parent and parent:type() == "field" and parent:field("name")[1] then
    return node_text(parent:field("name")[1], source)
  end
  local statement = parent and parent:parent()
  if statement and statement:type() == "assignment_statement" then
    local variables = statement:named_child(0)
    local first = variables and variables:field("name")[1]
    return first and node_text(first, source) or nil
  end
  return nil
end

local function logical_operator(node)
  if node:type() ~= "binary_expression" then
    return nil
  end
  for child in node:iter_children() do
    local kind = child:type()
    if not child:named() and (kind == "and" or kind == "or") then
      return kind
    end
  end
  return nil
end

local function logical_parent(node)
  local parent = node:parent()
  while parent and parent:type() == "parenthesized_expression" do
    parent = parent:parent()
  end
  return parent and logical_operator(parent) ~= nil
end

local function collect_operators(node, operators)
  if node:type() == "parenthesized_expression" then
    collect_operators(node:named_child(0), operators)
    return
  end
  local operator = logical_operator(node)
  if not operator then
    return
  end
  collect_operators(node:field("left")[1], operators)
  table.insert(operators, operator)
  collect_operators(node:field("right")[1], operators)
end

---Number of runs of like operators in the boolean expression at `node`.
local function boolean_sequences(node)
  local operators = {}
  collect_operators(node, operators)
  local sequences = 0
  for index, operator in ipairs(operators) do
    if operator ~= operators[index - 1] then
      sequences = sequences + 1
    end
  end
  return sequences
end

local NESTING_STRUCTURES = {
  if_statement = true,
  for_statement = true,
  while_statement = true,
  repeat_statement = true,
}

local FLAT_INCREMENTS = {
  elseif_statement = true,
  else_statement = true,
  goto_statement = true,
}

local function is_recursive_call(node, context)
  if node:type() ~= "function_call" or not context.name then
    return false
  end
  local callee = node_text(node:field("name")[1], context.source)
  local method = context.name:match(":([%w_]+)$")
  return callee == context.name
    or (method ~= nil and callee == "self:" .. method)
end

---Increment contributed by `node` itself, given its nesting level.
local function node_increment(node, nesting, context)
  local kind = node:type()
  if NESTING_STRUCTURES[kind] then
    return 1 + nesting
  end
  if FLAT_INCREMENTS[kind] then
    return 1
  end
  if logical_operator(node) and not logical_parent(node) then
    return boolean_sequences(node)
  end
  if is_recursive_call(node, context) then
    return 1
  end
  return 0
end

local function complexity_of(node, nesting, context)
  local total = node_increment(node, nesting, context)
  local kind = node:type()
  local inner = nesting
  if NESTING_STRUCTURES[kind] or FUNCTION_TYPES[kind] then
    inner = nesting + 1
  end
  for child in node:iter_children() do
    if child:named() then
      total = total + complexity_of(child, inner, context)
    end
  end
  return total
end

---Cognitive complexity of an outermost function, including nested ones.
local function function_complexity(node, source)
  local context = { name = function_name(node, source), source = source }
  local total = 0
  for child in node:iter_children() do
    if child:named() then
      total = total + complexity_of(child, 0, context)
    end
  end
  return total
end

local function check_function(node, outermost, path, source, report)
  local start_row, _, end_row = node:range()
  local label = function_name(node, source) or "<anonymous>"
  local lines = end_row - start_row + 1
  if lines > LIMITS.function_lines then
    report(
      path,
      start_row + 1,
      ("function '%s' has %d lines (max %d)"):format(
        label,
        lines,
        LIMITS.function_lines
      )
    )
  end
  local score = outermost and function_complexity(node, source) or 0
  if score > LIMITS.complexity then
    local message = "function '%s' has cognitive complexity %d (max %d)"
    report(path, start_row + 1, message:format(label, score, LIMITS.complexity))
  end
end

local function visit_functions(node, inside_function, visitor)
  local is_function = FUNCTION_TYPES[node:type()] == true
  if is_function then
    visitor(node, not inside_function)
  end
  for child in node:iter_children() do
    if child:named() then
      visit_functions(child, inside_function or is_function, visitor)
    end
  end
end

local function first_error_row(root)
  local query = vim.treesitter.query.parse("lua", "(ERROR) @error")
  local next_capture = query:iter_captures(root, "")
  local _, node = next_capture()
  local row = (node or root):range()
  return row
end

local function check_lua(path, source, report)
  local parser = vim.treesitter.get_string_parser(source, "lua")
  local root = parser:parse()[1]:root()
  if root:has_error() then
    report(path, first_error_row(root) + 1, "syntax error")
    return
  end
  visit_functions(root, false, function(node, outermost)
    check_function(node, outermost, path, source, report)
  end)
end

local function collect_targets(args)
  if #args == 0 then
    args = { CHECKOUT }
  end
  local targets = {}
  for _, path in ipairs(args) do
    path = path:gsub("/+$", "")
    if vim.fn.isdirectory(path) == 1 then
      vim.list_extend(targets, directory_files(path))
    else
      table.insert(targets, path)
    end
  end
  return targets
end

local function check_file(path, report)
  local content = read_file(path)
  if not content then
    report(path, 0, "cannot read file")
    return
  end
  check_lines(path, content, report)
  if path:match("%.lua$") then
    check_lua(path, content, report)
  end
end

local function print_diagnostics(diagnostics, file_count)
  table.sort(diagnostics, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  for _, item in ipairs(diagnostics) do
    local path = vim.fn.fnamemodify(item.path, ":.")
    io.stdout:write(("%s:%d: %s\n"):format(path, item.line, item.message))
  end
  io.stdout:write(
    ("quality: %d files checked, %d problems\n"):format(
      file_count,
      #diagnostics
    )
  )
end

local function main(args)
  local diagnostics = {}
  local function report(path, line, message)
    table.insert(diagnostics, { path = path, line = line, message = message })
  end
  local targets = collect_targets(args)
  for _, path in ipairs(targets) do
    check_file(path, report)
  end
  print_diagnostics(diagnostics, #targets)
  return #diagnostics == 0 and 0 or 1
end

os.exit(main(arg or {}))
