--- The diff view of one review: the state, the attached buffers, and the display in the code window.
--- It calls the diff provider. It does not know about code hosts or threads.
--- See docs/architecture/diff.md#flows.

local config = require("didymus.config")
local hunks = require("didymus.diff.hunks")
local providers = require("didymus.diff.provider")

--- The time in milliseconds before the progress message of `attach` shows.
local progress_delay = 500

---@class didymus.diff.ViewOpts
---@field tabpage integer The review tabpage.
---@field target didymus.diff.Target? Nil if the diff is not available.
---@field target_err string? Why the diff is not available, with no "didymus:" prefix.
---@field get_code_win fun(): integer? The code window, or nil if it is closed.
---@field open_file fun(path: string, line: integer, opts: { keepjumps: boolean? }?): boolean Open a file of the target in the code window at `line`, and focus that window. False if it did not open. Then the error shows.
---@field on_show fun() Called each time the diff shows.

---@class didymus.diff.view.Attached
---@field file didymus.diff.File
---@field ready boolean True after `attach()` calls `cb` with no error.
---@field waiting fun(err: string?)[] The callbacks that wait for `attach()`.

---@class didymus.diff.view.Shown The buffer of the code window that has the diff, or waits for it.
---@field win integer
---@field buf integer
---@field number integer Only the callbacks of the newest display apply.

---@class didymus.diff.view.Jump The newest `next` or `prev`. Only its callbacks apply.
---@field buf integer? The buffer whose `attach()` the jump waits for. The jump shows its error.

---@class didymus.diff.view.Start The code window before a jump to a different file.
---@field win integer
---@field buf integer
---@field cursor integer[]

---@class didymus.diff.View
---@field shown boolean
---@field private opts didymus.diff.ViewOpts
---@field private provider didymus.diff.Provider?
---@field private provider_err string?
---@field private attached table<integer, didymus.diff.view.Attached>
---@field private display didymus.diff.view.Shown?
---@field private display_count integer
---@field private warned table<string, boolean> The provider errors that showed. Each one shows once.
---@field private jump didymus.diff.view.Jump?
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

---@param path string
---@param err string
function View:warn_error(path, err)
  self.warned[err] = true
  warn(("cannot show the diff of %s: %s"):format(path, err))
end

--- Show an error of the provider. The same error shows only once in a review, so that a missing
--- tool does not give a warning for each file.
---@param path string
---@param err string
function View:warn_once(path, err)
  if not self.warned[err] then
    self:warn_error(path, err)
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
      -- A jump that waits for this buffer shows the error itself.
      if self.jump and self.jump.buf == buf then
        return
      end
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

--- Put the cursor of `win` on the first non-blank character of `line`.
---@param win integer
---@param line integer
local function set_cursor(win, line)
  local buf = vim.api.nvim_win_get_buf(win)
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, true)[1]
  vim.api.nvim_win_set_cursor(win, { line, (text:find("%S") or 1) - 1 })
end

--- The stop of the hunks of `buf` after `line` in `direction`, or nil.
---@param file_hunks didymus.diff.Hunk[]
---@param buf integer
---@param line integer
---@param direction 1|-1
---@return integer?
local function find_stop(file_hunks, buf, line, direction)
  local opts = { line = line, side = "head", line_count = vim.api.nvim_buf_line_count(buf) }
  local find = direction > 0 and hunks.next or hunks.prev
  return (find(file_hunks, opts))
end

--- Show the code window again as it was before the jump. Do not change the jumplist.
---@param start didymus.diff.view.Start
---@return boolean restored
local function restore(start)
  if not (vim.api.nvim_win_is_valid(start.win) and vim.api.nvim_buf_is_valid(start.buf)) then
    return false
  end
  vim.api.nvim_set_current_win(start.win)
  local ok = pcall(vim.api.nvim_cmd, {
    cmd = "buffer",
    count = start.buf,
    mods = { keepjumps = true, keepalt = true },
  }, {})
  return ok and pcall(vim.api.nvim_win_set_cursor, start.win, start.cursor)
end

--- An attached buffer of `file` that has its hunks, or nil.
---@param file didymus.diff.File
---@return integer?
function View:find_ready_buf(file)
  for buf, state in pairs(self.attached) do
    if state.ready and state.file == file and vim.api.nvim_buf_is_valid(buf) then
      return buf
    end
  end
end

--- The files of the target after `file` in `direction`. With no file, all files. A deleted file is
--- not in the checkout, so it has no hunks.
---@param file didymus.diff.File?
---@param direction 1|-1
---@return didymus.diff.File[]
function View:get_next_files(file, direction)
  local target_files = (self.opts.target --[[@as didymus.diff.Target]]).files
  local first, last = 1, #target_files
  if direction < 0 then
    first, last = last, first
  end
  local files = {}
  for index = first, last, direction do
    local target_file = target_files[index]
    if target_file == file then
      files = {}
    elseif target_file.status ~= "deleted" then
      table.insert(files, target_file)
    end
  end
  return files
end

--- Go to the next or the previous hunk of the provider in the code window, also in the next files of
--- the target. Do not wrap. See docs/architecture/diff.md#navigation.
---@param direction 1|-1
function View:go_to(direction)
  if not self.shown then
    if not self.provider then
      return warn(self.provider_err --[[@as string]])
    elseif not self.opts.target then
      return warn(self.opts.target_err or "the diff is not available")
    end
    return warn("the diff is hidden")
  end
  ---@type didymus.diff.view.Jump
  local jump = {}
  self.jump = jump
  local start_win = self.opts.get_code_win()
  local start_buf = start_win and vim.api.nvim_win_get_buf(start_win)
  local start_file = start_buf and self:find_file(start_buf)
  ---@type didymus.diff.view.Start?
  local start
  -- A file that the jump opened only to get its hunks.
  local opened = false

  local function is_current()
    return self.shown
      and self.jump == jump
      and vim.api.nvim_get_current_tabpage() == self.opts.tabpage
  end

  --- Wait for the hunks of `buf`. Stop the jump if the code window shows a different buffer. An
  --- error of `attach()` shows each time, because the user gave the command.
  ---@param buf integer
  ---@param file didymus.diff.File
  ---@param cb fun(file_hunks: didymus.diff.Hunk[]?) Nil after an error.
  local function wait_for_hunks(buf, file, cb)
    jump.buf = buf
    self:attach(buf, file, function(err)
      local win = self.opts.get_code_win()
      if not (is_current() and win and vim.api.nvim_win_get_buf(win) == buf) then
        if self.jump == jump then
          self.jump = nil
        end
        return
      end
      jump.buf = nil
      if err then
        self:warn_error(file.path, err)
        return cb(nil)
      end
      cb(self.provider:hunks(buf) or {})
    end)
  end

  --- Open `path` at `line`. Only the start position goes into the jumplist.
  ---@param path string
  ---@param line integer
  local function land(path, line)
    self.jump = nil
    local restored = opened and start ~= nil and restore(start)
    self.opts.open_file(path, line, { keepjumps = opened and not restored })
  end

  local name = direction > 0 and "next" or "previous"
  local files = self:get_next_files(start_file, direction)
  local function check(index)
    local file = files[index]
    if not file then
      self.jump = nil
      if opened and start then
        restore(start)
      end
      return warn(("no %s hunk"):format(name))
    end
    local from = direction > 0 and 0 or math.huge
    local ready_buf = self:find_ready_buf(file)
    if ready_buf then
      local line = find_stop(self.provider:hunks(ready_buf) or {}, ready_buf, from, direction)
      if line then
        return land(file.path, line)
      end
      return check(index + 1)
    end
    if not self.opts.open_file(file.path, 1, { keepjumps = true }) then
      self.jump = nil
      return
    end
    opened = true
    local buf = vim.api.nvim_get_current_buf()
    wait_for_hunks(buf, file, function(file_hunks)
      if not file_hunks then
        return land(file.path, 1)
      end
      local line = find_stop(file_hunks, buf, from, direction)
      if line then
        return land(file.path, line)
      end
      check(index + 1)
    end)
  end

  if not start_file then
    start = start_win
      and {
        win = start_win,
        buf = start_buf --[[@as integer]],
        cursor = vim.api.nvim_win_get_cursor(start_win),
      }
    return check(1)
  end
  ---@cast start_win integer
  ---@cast start_buf integer
  wait_for_hunks(start_buf, start_file, function(file_hunks)
    if not file_hunks then
      self.jump = nil
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(start_win)
    local line = find_stop(file_hunks, start_buf, cursor[1], direction)
    if not line then
      start = { win = start_win, buf = start_buf, cursor = cursor }
      return check(1)
    end
    self.jump = nil
    vim.api.nvim_set_current_win(start_win)
    vim.cmd("normal! m'")
    set_cursor(start_win, line)
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
