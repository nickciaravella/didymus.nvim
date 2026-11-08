local M = {}

M.defaults = {
  agent = {
    cmd = "claude",
    split = { width = 0.4 },
    terminal = { ready_delay = 500, submit_delay = 50 }, -- milliseconds
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
