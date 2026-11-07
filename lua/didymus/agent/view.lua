local config = require("didymus.config")

---@alias didymus.agent.ViewKind "split"

---@class didymus.agent.View
---@field win integer?
local View = {}
View.__index = View

---@return didymus.agent.View
function View.new()
  return setmetatable({}, View)
end

---@param size number A size below 1 is a fraction of `total`.
---@param total integer
---@return integer
local function resolve_size(size, total)
  return size < 1 and math.floor(total * size) or size
end

--- The size of the window that `show()` opens.
---@param kind didymus.agent.ViewKind
---@return integer width
---@return integer height
function View.size(kind) ---@diagnostic disable-line: unused-local
  local width = resolve_size(config.options.agent.split.width, vim.o.columns)
  return width, vim.o.lines - vim.o.cmdheight - 1
end

---@param buf integer
---@param kind didymus.agent.ViewKind
---@return integer win
function View:show(buf, kind)
  if self:is_visible() then
    vim.api.nvim_win_set_buf(self.win, buf)
    vim.api.nvim_set_current_win(self.win)
    return self.win
  end
  self:hide()
  local width = View.size(kind)
  self.win = vim.api.nvim_open_win(buf, true, { split = "right", win = -1, width = width })
  -- The TermOpen defaults go to the window that started the job, not to this window.
  local wo = vim.wo[self.win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.winfixwidth = true
  return self.win
end

--- Close the window. The buffer stays.
function View:hide()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    if not pcall(vim.api.nvim_win_close, self.win, true) then
      vim.notify(
        "didymus: cannot hide the agent, because it is the last window",
        vim.log.levels.WARN
      )
      return
    end
  end
  self.win = nil
end

---@return boolean
function View:is_visible()
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and vim.api.nvim_win_get_tabpage(self.win) == vim.api.nvim_get_current_tabpage()
end

return View
