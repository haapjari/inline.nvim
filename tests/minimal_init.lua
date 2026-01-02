-- minimal init for running tests
-- run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- set up plugin path
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_dir)

-- find plenary (check common locations)
local plenary_paths = {
  vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/*/start/plenary.nvim"),
  "/usr/share/nvim/site/pack/packer/start/plenary.nvim",
}

for _, path in ipairs(plenary_paths) do
  local expanded = vim.fn.glob(path)
  if expanded ~= "" then
    vim.opt.rtp:prepend(expanded)
    break
  end
end

-- minimal settings
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
vim.o.backup = false
