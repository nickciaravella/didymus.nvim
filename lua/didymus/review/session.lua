--- One open review: the change, its tabpage, the files panel and the state of `HEAD` before the
--- review.

local panel = require("didymus.review.panel")

---@class didymus.review.SessionOpts
---@field change didymus.review.Change
---@field label string The name of the change in messages, such as "#12".
---@field adapter didymus.picker.Adapter The picker of the files panel.
---@field cwd string
---@field merge_base string? Nil if git could not find it.
---@field old_branch string? The branch before the review. Nil if `HEAD` was detached.
---@field old_head string? The sha of `HEAD` before the review.
---@field on_close fun(session: didymus.review.Session) Called once, when the tabpage closes.

---@class didymus.review.Session
---@field change didymus.review.Change
---@field label string
---@field threads didymus.review.Thread[]
---@field cwd string
---@field merge_base string?
---@field old_branch string?
---@field old_head string?
---@field tabpage integer
---@field private adapter didymus.picker.Adapter
---@field private panel didymus.picker.Panel?
---@field private code_win integer The window of the tabpage that shows the files of the change.
---@field private on_close fun(session: didymus.review.Session)
local Session = {}
Session.__index = Session

--- Open the review tabpage and the files panel, and make the tabpage current.
---@param opts didymus.review.SessionOpts
---@return didymus.review.Session
function Session.new(opts)
  local self = setmetatable({
    change = opts.change,
    label = opts.label,
    threads = {},
    adapter = opts.adapter,
    cwd = opts.cwd,
    merge_base = opts.merge_base,
    old_branch = opts.old_branch,
    old_head = opts.old_head,
    on_close = opts.on_close,
  }, Session)
  -- An unlisted scratch buffer, so that the close leaves no "[No Name]" buffer.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("tab sbuffer " .. buf)
  self.tabpage = vim.api.nvim_get_current_tabpage()
  self.code_win = vim.api.nvim_get_current_win()

  -- The user can close the tabpage with `:tabclose`. That also ends the review.
  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function()
      if vim.api.nvim_tabpage_is_valid(self.tabpage) then
        return
      end
      self:hide_files()
      self.on_close(self)
      return true
    end,
  })
  self:show_files()
  return self
end

---@return boolean
function Session:is_open()
  return vim.api.nvim_tabpage_is_valid(self.tabpage)
end

--- Go to the review tabpage.
function Session:focus()
  if self:is_open() then
    vim.api.nvim_set_current_tabpage(self.tabpage)
  end
end

---@return boolean
function Session:is_panel_open()
  return self.panel ~= nil and self.panel:is_open()
end

--- Show the files panel in the review tabpage, and focus it.
function Session:show_files()
  if not self:is_open() then
    return
  end
  self:focus()
  if self:is_panel_open() then
    return self.panel:focus()
  end
  local ok, result = pcall(panel.open, self.adapter, self)
  if not ok then
    -- The review stays open without the panel. The snacks adapter gives an error if snacks.nvim
    -- is not available.
    vim.notify(tostring(result), vim.log.levels.ERROR)
    return
  end
  self.panel = result
end

function Session:hide_files()
  if self:is_panel_open() then
    self.panel:close()
  end
end

--- In the review tabpage, show the files panel or hide it. From a different tabpage, go to the
--- review tabpage and show the panel.
function Session:toggle_files()
  if vim.api.nvim_get_current_tabpage() == self.tabpage and self:is_panel_open() then
    self:hide_files()
  else
    self:show_files()
  end
end

---@param win integer
---@param path string
---@return boolean
local function shows_file(win, path)
  local real_path = vim.uv.fs_realpath(path)
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  return real_path ~= nil and name ~= "" and vim.uv.fs_realpath(name) == real_path
end

--- Put the cursor of `win` on the first non-blank character of `line`. A line after the end goes
--- to the last line, because the file in the checkout can be different from the change head.
---@param win integer
---@param line integer
local function set_cursor(win, line)
  local buf = vim.api.nvim_win_get_buf(win)
  line = math.min(line, vim.api.nvim_buf_line_count(buf))
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, true)[1]
  vim.api.nvim_win_set_cursor(win, { line, (text:find("%S") or 1) - 1 })
end

--- Open a file of the change in the code window at `line`, and focus that window. If the user
--- closed the code window, open a new one on the right.
---@param path string Relative to `cwd`.
---@param line integer
function Session:open_file(path, line)
  if not self:is_open() then
    return
  end
  local previous_win = vim.api.nvim_get_current_win()
  self:focus()
  local full_path = vim.fs.joinpath(self.cwd, path)
  ---@type vim.api.keyset.cmd?
  local command = { cmd = "edit", args = { full_path }, magic = { file = false } }
  if
    vim.api.nvim_win_is_valid(self.code_win)
    and vim.api.nvim_win_get_tabpage(self.code_win) == self.tabpage
  then
    vim.api.nvim_set_current_win(self.code_win)
    -- `:edit` of the file in the window gives E37 if the buffer is modified.
    if shows_file(self.code_win, full_path) then
      command = nil
    end
  else
    command.mods = { split = "botright" }
    command.cmd = "vsplit"
  end
  if command then
    local ok, err = pcall(vim.api.nvim_cmd, command, {})
    if not ok then
      -- For example E37, if 'hidden' is off and the code window has a modified buffer.
      if vim.api.nvim_win_is_valid(previous_win) then
        vim.api.nvim_set_current_win(previous_win)
      end
      local message = tostring(err):gsub("^Vim:", "")
      vim.notify(("didymus: cannot open %s: %s"):format(path, message), vim.log.levels.ERROR)
      return
    end
  end
  self.code_win = vim.api.nvim_get_current_win()
  set_cursor(self.code_win, line)
end

--- Close the files panel and the review tabpage. `on_close` then ends the review.
function Session:close()
  if not self:is_open() then
    return
  end
  self:hide_files()
  -- Neovim cannot close the last tabpage.
  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd.tabnew()
  end
  local ok, err = pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(self.tabpage))
  if not ok then
    vim.notify("didymus: cannot close the review tabpage: " .. err, vim.log.levels.ERROR)
  end
end

return Session
