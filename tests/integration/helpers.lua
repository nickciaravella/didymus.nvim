-- Helpers for the integration tests. Load them with `dofile()`.

local M = {}

--- Restart `child` with plugins from `deps/`. `make deps` clones them.
---@param child MiniTest.child
---@param plugins string[]? The folders in `deps/`. Default `{ "snacks.nvim" }`.
function M.restart(child, plugins)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.o.columns, child.o.lines = 120, 40
  for _, plugin in ipairs(plugins or { "snacks.nvim" }) do
    child.lua("vim.opt.runtimepath:append(vim.fn.getcwd() .. '/deps/' .. ...)", { plugin })
  end
end

return M
