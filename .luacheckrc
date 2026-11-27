files["tests/**/*.lua"] = { read_globals = { "MiniTest" } }
files["scripts/test_runner.lua"] = { read_globals = { "MiniTest" } }

return {
  std = "luajit",
  globals = { "vim" },
  codes = true,
  quiet = 1,
  exclude_files = {
    -- Deliberately malformed or unused Lua for the quality checker tests.
    "tests/fixtures/quality/**",
    -- Machine-specific configuration loaded by Iara.
    "lua/user.lua",
  },
}
