-- Helpers for the integration tests. Load them with `dofile()`.

local M = {}

--- Restart `child` with snacks.nvim from `deps/`. `make deps` clones it.
---@param child MiniTest.child
function M.restart(child)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.o.columns, child.o.lines = 120, 40
  child.lua('vim.opt.runtimepath:append(vim.fn.getcwd() .. "/deps/snacks.nvim")')
end

return M
