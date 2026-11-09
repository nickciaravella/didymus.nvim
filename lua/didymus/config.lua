local M = {}

M.defaults = {
  agent = {
    cmd = "claude",
    view = "split", -- "split" or "float"
    backend = "terminal", -- "terminal" or "test"
    split = { width = 0.4 },
    float = { width = 0.85, height = 0.85 },
    keys = { focus = false, leave = false }, -- for example "<C-a>"
    input = {
      width = 60,
      max_height = 10,
      keys = { send = "<C-s>", append = "<C-y>", cancel = "q" },
    },
    terminal = { ready_delay = 500, submit_delay = 50 }, -- milliseconds
  },
  review = {
    picker = "snacks", -- "snacks", "test" or an adapter table. See lua/didymus/ui/picker/.
    provider = "github", -- "github", "test" or a provider table. See lua/didymus/review/provider/.
    input = {
      width = 60,
      max_height = 10,
      keys = { comment = "<C-s>", cancel = "q" },
    },
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
