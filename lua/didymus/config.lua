local M = {}

M.defaults = {
  agent = {
    cmd = "claude",
    view = "split", -- "split" or "float"
    backend = "terminal", -- "terminal" or "test"
    split = { width = 0.4 },
    float = { width = 0.85, height = 0.85 },
    keys = { focus = false, leave = false }, -- for example "<C-a>"
    terminal = { ready_delay = 500, submit_delay = 50 }, -- milliseconds
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
