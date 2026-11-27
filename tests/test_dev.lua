local helpers = require("helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local FAKE_NVIM = [[#!/bin/sh
set -eu
case "$1" in
  --version) echo 'NVIM fixture';;
  --clean)
    test "$NVIM_APPNAME" = iara-dev-checkout
    test "$XDG_CONFIG_HOME" = "$XDG_DATA_HOME/config"
    current="$XDG_DATA_HOME/$NVIM_APPNAME/current"
    mkdir -p "$current"
    touch "$current/release.json"
    echo provisioned;;
  -u)
    printf '%s\n' "$NVIM_APPNAME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$@";;
  *) exit 1;;
esac
]]

local function fixture()
  local root = helpers.temp_dir()
  local dev = root .. "/checkout with spaces"
  local script = dev .. "/scripts/dev.sh"
  local nvim = root .. "/fake nvim"
  helpers.write_file(nvim, FAKE_NVIM)
  helpers.write_file(dev .. "/lazy-lock.json", "{}\n")
  helpers.write_file(dev .. "/parsers-lock.txt", "pins\n")
  vim.fn.mkdir(vim.fs.dirname(script), "p")
  assert(vim.uv.fs_copyfile(helpers.iara_dir .. "/scripts/dev.sh", script))
  assert(vim.uv.fs_chmod(script, 493))
  assert(vim.uv.fs_chmod(nvim, 493))
  return dev, script, helpers.isolated_env({ NVIM_BIN = nvim })
end

T["dev opens live files and reuses dependencies by pin"] = function()
  local checkout, script, env = fixture()
  local argv = { script, "--", "a file.lua" }
  local first = helpers.run(argv, { env = env })
  eq(first.code, 0)
  local lines = vim.split(vim.trim(first.stdout), "\n")
  eq(lines[1], "provisioned")
  eq(lines[2], "iara-dev-checkout")
  eq(lines[3], checkout .. "/.tools/dev/config")
  eq(vim.startswith(lines[4], checkout .. "/.tools/dev/deps/"), true)
  eq(
    vim.list_slice(lines, 5),
    { "-u", checkout .. "/init.lua", "--", "a file.lua" }
  )
  local second = helpers.run(argv, { env = env })
  eq(second.code, 0)
  eq(vim.trim(second.stdout), table.concat(vim.list_slice(lines, 2), "\n"))
  helpers.write_file(checkout .. "/parsers-lock.txt", "new pins\n")
  local third = helpers.run(argv, { env = env })
  eq(third.code, 0)
  eq(vim.startswith(third.stdout, "provisioned\n"), true)
  eq(vim.split(third.stdout, "\n")[4] ~= lines[4], true)
  eq(vim.uv.fs_stat(env.XDG_DATA_HOME .. "/iara-dev-checkout"), nil)
end

return T
