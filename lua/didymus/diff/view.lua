--- The diff view of one review: the state, the attached buffers, and the display in the code window.
--- It calls the diff provider. It does not know about code hosts or threads.
--- See docs/architecture/diff.md#flows.

local config = require("didymus.config")
local providers = require("didymus.diff.provider")

--- The time in milliseconds before the progress message of `attach` shows.
local progress_delay = 500

---@class didymus.diff.ViewOpts
---@field tabpage integer The review tabpage.
---@field target didymus.diff.Target? Nil if the diff is not available.
---@field target_err string? Why the diff is not available, with no "didymus:" prefix.
---@field get_code_win fun(): integer? The code window, or nil if it is closed.
---@field on_show fun() Called each time the diff shows.

---@class didymus.diff.view.Attached
---@field file didymus.diff.File
---@field ready boolean True after `attach()` calls `cb` with no error.
---@field waiting fun(err: string?)[] The callbacks that wait for `attach()`.

---@class didymus.diff.view.Shown The buffer of the code window that has the diff, or waits for it.
---@field win integer
---@field buf integer
---@field number integer Only the callbacks of the newest display apply.

---@class didymus.diff.View
---@field shown boolean
---@field private opts didymus.diff.ViewOpts
---@field private provider didymus.diff.Provider?
---@field private provider_err string?
---@field private attached table<integer, didymus.diff.view.Attached>
---@field private display didymus.diff.view.Shown?
---@field private display_count integer
---@field private warned table<string, boolean> The provider errors that showed. Each one shows once.
---@field private update_scheduled boolean
---@field private group integer
local View = {}
View.__index = View

---@param opts didymus.diff.ViewOpts
---@return didymus.diff.View
function View.new(opts)
  local provider, provider_err = providers.get(config.options.diff.provider)
  local self = setmetatable({
    shown = false,
    opts = opts,
    provider = provider,
    provider_err = provider_err and ("%s (diff.provider)"):format(provider_err),
    attached = {},
    display_count = 0,
    warned = {},
    update_scheduled = false,
  }, View)
  self.group = vim.api.nvim_create_augroup(("didymus.diff.view.%d"):format(opts.tabpage), {})
  -- `:edit`, `gd`, `<CR>` in the panel: the code window can show a new buffer at any time.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = self.group,
    callback = function()
      self:schedule_update()
    end,
  })
  -- The provider can attach only in the current tabpage.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = self.group,
    callback = function()
      self:schedule_update()
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = self.group,
    callback = function(args)
      self:forget(args.buf)
    end,
  })
  return self
end

---@param message string
local function warn(message)
  vim.notify("didymus: " .. message, vim.log.levels.WARN)
end

--- Show an error of the provider. The same error shows only once in a review, so that a missing
--- tool does not give a warning for each file.
---@param path string
---@param err string
function View:warn_once(path, err)
  if not self.warned[err] then
    self.warned[err] = true
    warn(("cannot show the diff of %s: %s"):format(path, err))
  end
end

--- The file of the target that `buf` shows. Nil for a deleted file, because it is not in the
--- checkout.
---@param buf integer
---@return didymus.diff.File?
function View:find_file(buf)
  local target = self.opts.target
  local name = vim.api.nvim_buf_get_name(buf)
  local real_path = target and name ~= "" and vim.uv.fs_realpath(name)
  if not real_path then
    return
  end
  for _, file in ipairs(target.files) do
    if
      file.status ~= "deleted"
      and vim.uv.fs_realpath(vim.fs.joinpath(target.cwd, file.path)) == real_path
    then
      return file
    end
  end
end

---@param text string
---@param status "running"|"success"|"failed"
local function show_progress(text, status)
  vim.api.nvim_echo({ { text } }, false, {
    id = "didymus.diff.progress",
    kind = "progress",
    source = "didymus",
    title = "didymus",
    status = status,
  })
end

--- Attach the provider to `buf`, if it is not attached. Call `cb` when the provider has the hunks.
--- A buffer stays attached until the diff hides, so a return to a file is fast.
---@param buf integer
---@param file didymus.diff.File
---@param cb fun(err: string?)
function View:attach(buf, file, cb)
  local state = self.attached[buf]
  if state and state.ready then
    return cb(nil)
  end
  if state then
    table.insert(state.waiting, cb)
    return
  end
  state = { file = file, ready = false, waiting = { cb } }
  self.attached[buf] = state
  local text = ("get the diff of %s"):format(file.path)
  local finished, progress_shown = false, false
  vim.defer_fn(function()
    if not finished and self.attached[buf] == state then
      progress_shown = true
      show_progress(text, "running")
    end
  end, progress_delay)
  self.provider:attach(buf, file, self.opts.target, function(err)
    finished = true
    if progress_shown then
      show_progress(text, err and "failed" or "success")
    end
    -- The diff hid, or the buffer unloaded, before `cb`.
    if self.attached[buf] ~= state then
      return
    end
    if err then
      self.attached[buf] = nil
    else
      state.ready = true
    end
    for _, waiting_cb in ipairs(state.waiting) do
      waiting_cb(err)
    end
    state.waiting = {}
  end)
end

--- Remove the diff from the code window. Make the callbacks of the old display old.
function View:clear_display()
  local display = self.display
  self.display = nil
  self.display_count = self.display_count + 1
  if display and vim.api.nvim_win_is_valid(display.win) then
    self.provider:clear(display.win)
  end
end

--- Show the diff of the buffer of the code window, if it is a file of the target. Clear the old
--- display first.
function View:update()
  if not self.shown or vim.api.nvim_get_current_tabpage() ~= self.opts.tabpage then
    return
  end
  local win = self.opts.get_code_win()
  local buf = win and vim.api.nvim_win_get_buf(win)
  local display = self.display
  if display and display.win == win and display.buf == buf then
    return
  end
  self:clear_display()
  local file = buf and self:find_file(buf)
  if not (win and buf and file) then
    return
  end
  local number = self.display_count
  self.display = { win = win, buf = buf, number = number }
  local function is_current()
    return self.shown and self.display ~= nil and self.display.number == number
  end
  self:attach(buf, file, function(err)
    if not is_current() then
      return
    end
    if err then
      return self:warn_once(file.path, err)
    end
    self.provider:render({
      layout = "inline",
      sides = "both",
      file = file,
      target = self.opts.target --[[@as didymus.diff.Target]],
      head_win = win,
      head_buf = buf,
    }, function(render_err)
      if render_err and is_current() then
        self:warn_once(file.path, render_err)
      end
    end)
  end)
end

--- Update once after the events of one command, such as `BufWinEnter` and `TabEnter` of `:tab
--- sbuffer`. The code window of the session is correct only after the command.
function View:schedule_update()
  if self.update_scheduled or not self.shown then
    return
  end
  self.update_scheduled = true
  vim.schedule(function()
    self.update_scheduled = false
    self:update()
  end)
end

--- Forget an unloaded buffer. A new load of the file attaches again.
---@param buf integer
function View:forget(buf)
  if not self.attached[buf] then
    return
  end
  self.attached[buf] = nil
  if self.display and self.display.buf == buf then
    self:clear_display()
  end
  -- The provider must not change the buffer while it unloads.
  vim.schedule(function()
    self.provider:detach(buf)
  end)
end

--- Show the diff in the code window. If the provider or the target is not available, show why.
function View:show()
  if self.shown then
    return
  end
  if not self.provider then
    return warn(self.provider_err --[[@as string]])
  end
  if not self.opts.target then
    return warn(self.opts.target_err or "the diff is not available")
  end
  self.shown = true
  self.opts.on_show()
  self:update()
end

--- Remove the diff from the code window, and detach all buffers.
function View:hide()
  if not self.shown then
    return
  end
  self.shown = false
  self:clear_display()
  local attached = self.attached
  self.attached = {}
  for buf in pairs(attached) do
    self.provider:detach(buf)
  end
end

function View:toggle()
  if self.shown then
    self:hide()
  else
    self:show()
  end
end

--- Hide the diff, and stop to follow the code window. Call it when the review closes.
function View:close()
  self:hide()
  vim.api.nvim_del_augroup_by_id(self.group)
end

return View
