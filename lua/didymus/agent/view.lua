local config = require("didymus.config")
local layout = require("didymus.ui.layout")

---@alias didymus.agent.ViewKind "float"|"split"

---@class didymus.agent.View
---@field win integer?
---@field kind didymus.agent.ViewKind? The kind of the last window that `show()` opened.
---@field private origin_win integer? The window before `show()`.
---@field private augroup integer
local View = {}
View.__index = View

---@type table<didymus.agent.ViewKind, true>
View.kinds = { float = true, split = true }

local view_count = 0

---@return didymus.agent.View
function View.new()
  view_count = view_count + 1
  local augroup = vim.api.nvim_create_augroup(("didymus.agent.view.%d"):format(view_count), {})
  return setmetatable({ augroup = augroup }, View)
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
    vim.api.nvim_set_hl(0, "DidymusAgentFloat", { link = "Normal", default = true })
    -- The inside has the code background. Without a border, nothing separates it from the code.
    local no_border = vim.o.winborder == "" or vim.o.winborder == "none"
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 0,
      col = 0,
      width = width,
      height = height,
      border = no_border and "rounded" or nil,
    })
    -- The size of a border from 'winborder' is known only after the float opens.
    fit_float(win)
    vim.wo[win][0].winhighlight = "NormalFloat:DidymusAgentFloat"
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
  local current_win = vim.api.nvim_get_current_win()
  if current_win ~= self.win then
    self.origin_win = current_win
  end
  local leave_key = config.options.agent.keys.leave
  if leave_key then
    vim.keymap.set({ "n", "t" }, leave_key, function()
      self:leave()
    end, { buffer = buf, desc = "didymus: leave the agent" })
  end

  if self:is_visible(kind) then
    vim.api.nvim_win_set_buf(self.win, buf)
    vim.api.nvim_set_current_win(self.win)
    return self.win
  end
  local old_win = self.win
  vim.api.nvim_clear_autocmds({ group = self.augroup })
  -- Open the new window first, so that the old window is not the last window.
  self.win, self.kind = open_win(buf, kind), kind
  close_win(old_win)
  if kind == "float" then
    self:watch_float()
  end
  return self.win
end

--- Fit the float when the editor size changes. Hide it when the focus leaves it.
---@private
function View:watch_float()
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if self:is_visible("float") then
        fit_float(self.win --[[@as integer]])
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.augroup,
    callback = function()
      if vim.api.nvim_get_current_win() ~= self.win then
        return
      end
      -- The window layout cannot change in WinLeave.
      vim.schedule(function()
        if self:is_visible("float") and vim.api.nvim_get_current_win() ~= self.win then
          self:hide()
        end
      end)
    end,
  })
end

--- Go back to the window before the agent. A float hides when the focus leaves it.
function View:leave()
  if vim.api.nvim_get_current_win() ~= self.win then
    return
  end
  pcall(vim.cmd.wincmd, "p")
  local origin = self.origin_win
  if
    vim.api.nvim_get_current_win() == self.win
    and origin
    and vim.api.nvim_win_is_valid(origin)
    and vim.api.nvim_win_get_tabpage(origin) == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_set_current_win(origin)
  end
end

--- Close the window. The buffer stays.
function View:hide()
  if close_win(self.win) then
    vim.api.nvim_clear_autocmds({ group = self.augroup })
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
