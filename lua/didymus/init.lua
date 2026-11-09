local config = require("didymus.config")

--- The public API of didymus.nvim.
local M = {}

M.config = config.options

--- The key of `agent.keys.focus` that the last `setup()` mapped.
---@type string?
local focus_key

---@param opts table?
function M.setup(opts)
  config.setup(opts)
  M.config = config.options

  if focus_key then
    pcall(vim.keymap.del, "n", focus_key)
    focus_key = nil
  end
  local key = config.options.agent.keys.focus
  if key then
    vim.keymap.set("n", key, function()
      require("didymus.agent").focus()
    end, { desc = "didymus: show and focus the agent" })
    focus_key = key
  end
end

return M
