--- An agent CLI in a terminal buffer.

---@class didymus.agent.backends.Terminal: didymus.agent.Backend
---@field private bufnr integer
---@field private job integer?
local Terminal = {}
Terminal.__index = Terminal

local M = {}

---@param opts didymus.agent.BackendOpts
---@return didymus.agent.Backend
function M.new(opts)
  local self = setmetatable({}, Terminal)
  local buf = vim.api.nvim_create_buf(false, true)
  -- nvim_buf_call() lets the job start with no window, so that a hidden start is possible.
  local ok, job = pcall(vim.api.nvim_buf_call, buf, function()
    return vim.fn.jobstart(opts.cmd, {
      term = true,
      cwd = opts.cwd,
      width = opts.width,
      height = opts.height,
      on_exit = function(_, code)
        self.job = nil
        -- In terminal mode, the next key after the exit deletes the buffer. Keep it for the user.
        if vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_mode().mode == "t" then
          vim.cmd.stopinsert()
        end
        opts.on_exit(code)
      end,
    })
  end)
  if not ok or job <= 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(ok and "the program is not executable" or job, 0)
  end
  self.bufnr, self.job = buf, job
  return self
end

---@return integer
function Terminal:buf()
  return self.bufnr
end

function Terminal:focus()
  vim.cmd.startinsert()
end

---@return boolean
function Terminal:is_running()
  return self.job ~= nil
end

--- Stop the job and delete the buffer.
function Terminal:stop()
  if self.job then
    vim.fn.jobstop(self.job)
    self.job = nil
  end
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
end

return M
