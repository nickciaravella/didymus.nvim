-- Helpers for all kinds of tests. Load them with `dofile()`.

local M = {}

--- Poll `check` until it is true. Use it for work in a different process, such as a child Neovim.
---@param check fun(): boolean
---@param what string|fun(): string The text of the timeout error.
function M.wait_for(check, what)
  for _ = 1, 500 do
    if check() then
      return
    end
    vim.uv.sleep(10)
  end
  error("timeout: " .. (type(what) == "function" and what() or what), 2)
end

return M
