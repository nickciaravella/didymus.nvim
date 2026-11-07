local M = {}

---@type table
M.config = {}

---@param opts table?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, opts or {})
end

function M.command()
  vim.notify("didymus: not available yet", vim.log.levels.WARN)
end

return M
