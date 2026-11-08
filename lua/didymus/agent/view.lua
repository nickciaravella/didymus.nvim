local config = require("didymus.config")
local layout = require("didymus.ui.layout")

---@alias didymus.agent.ViewKind "float"|"split"

---@class didymus.agent.View
---@field win integer?
---@field kind didymus.agent.ViewKind? The kind of the last window that `show()` opened.
---@field private resize_autocmd integer?
local View = {}
View.__index = View

---@type table<didymus.agent.ViewKind, true>
View.kinds = { float = true, split = true }

---@return didymus.agent.View
function View.new()
  return setmetatable({}, View)
end

--- The size of the window that `show()` opens. The float can be smaller, if its border does not fit.
---@param kind didymus.agent.ViewKind
---@return integer width
---@return integer height
function View.size(kind)
  local area = layout.editor_area()
  if kind == "float" then
    local float = config.options.agent.float
    return layout.resolve_size(float.width, area.width),
      layout.resolve_size(float.height, area.height)
  end
  -- The split has a status line.
  return layout.resolve_size(config.options.agent.split.width, area.width), area.height - 1
end

---@param win integer
local function fit_float(win)
  local width, height = View.size("float")
  local border = vim.api.nvim_win_get_config(win).border
  local win_config = layout.center(layout.editor_area(), width, height, border)
  win_config.relative = "editor"
  vim.api.nvim_win_set_config(win, win_config)
end

---@param buf integer
---@param kind didymus.agent.ViewKind
---@return integer win
local function open_win(buf, kind)
  local width, height = View.size(kind)
  local win
  if kind == "float" then
    -- The border comes from 'winborder'. Its size is known only after the float opens.
    win = vim.api.nvim_open_win(
      buf,
      true,
      { relative = "editor", row = 0, col = 0, width = width, height = height }
    )
    fit_float(win)
  else
    win = vim.api.nvim_open_win(buf, true, { split = "right", win = -1, width = width })
    vim.wo[win][0].winfixwidth = true
  end
  -- The TermOpen defaults go to the window that started the job, not to this window.
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  return win
end

---@param win integer?
---@return boolean closed False if `win` is the last window.
local function close_win(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  if pcall(vim.api.nvim_win_close, win, true) then
    return true
  end
  vim.notify("didymus: cannot hide the agent, because it is the last window", vim.log.levels.WARN)
  return false
end

--- Show `buf` in a window of `kind`, and focus it. If a window of the other kind shows `buf`,
--- close it.
---@param buf integer
---@param kind didymus.agent.ViewKind
---@return integer win
function View:show(buf, kind)
  if self:is_visible(kind) then
    vim.api.nvim_win_set_buf(self.win, buf)
    vim.api.nvim_set_current_win(self.win)
    return self.win
  end
  local old_win = self.win
  self:stop_resize()
  -- Open the new window first, so that the old window is not the last window.
  self.win, self.kind = open_win(buf, kind), kind
  close_win(old_win)
  if kind == "float" then
    self.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        if not (self.kind == "float" and self.win and vim.api.nvim_win_is_valid(self.win)) then
          self.resize_autocmd = nil
          return true
        end
        fit_float(self.win)
      end,
    })
  end
  return self.win
end

---@private
function View:stop_resize()
  if self.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, self.resize_autocmd)
    self.resize_autocmd = nil
  end
end

--- Close the window. The buffer stays.
function View:hide()
  if close_win(self.win) then
    self:stop_resize()
    self.win = nil
  end
end

--- With `kind`, true only if the window of that kind is visible.
---@param kind didymus.agent.ViewKind?
---@return boolean
function View:is_visible(kind)
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and vim.api.nvim_win_get_tabpage(self.win) == vim.api.nvim_get_current_tabpage()
    and (kind == nil or kind == self.kind)
end

return View
