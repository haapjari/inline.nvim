-- luacheck configuration for inline.nvim
-- https://luacheck.readthedocs.io/en/stable/config.html

-- global settings
std = "luajit"
max_line_length = 120
max_code_line_length = 100
max_string_line_length = 120
max_comment_line_length = 120

-- neovim globals
globals = {
  "vim",
}

-- read-only globals (standard lua + neovim)
read_globals = {
  "vim",
  "describe",
  "it",
  "before_each",
  "after_each",
  "assert",
  "pending",
  "spy",
  "stub",
  "mock",
}

-- files to check
include_files = {
  "lua/**/*.lua",
  "tests/**/*.lua",
}

-- files to ignore
exclude_files = {
  "lua/**/vendor/**",
  "_output/**",
}

-- per-file overrides
files["tests/**/*_spec.lua"] = {
  -- test files can have longer lines for assertions
  max_line_length = 150,
  max_code_line_length = 150,
}

-- warning codes to ignore globally
-- see: https://luacheck.readthedocs.io/en/stable/warnings.html
ignore = {
  "212/_.*",  -- unused argument starting with underscore
  "213",      -- unused loop variable
}

-- codes to treat as errors (not warnings)
-- none by default, all issues are warnings
