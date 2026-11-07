local config = require("didymus.config")

local M = {}

M.config = config.options

---@param opts table?
function M.setup(opts)
  config.setup(opts)
  M.config = config.options
end

return M
