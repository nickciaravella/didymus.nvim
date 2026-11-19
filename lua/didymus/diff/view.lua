--- The diff view of one review: the state, the attached buffers, and the display in the code window.
--- It calls the diff provider. It does not know about code hosts or threads.
--- See docs/architecture/diff.md#flows.

local config = require("didymus.config")
local hunks = require("didymus.diff.hunks")
local providers = require("didymus.diff.provider")
local revision = require("didymus.diff.revision")
local target_util = require("didymus.diff.target")

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

---@class didymus.diff.view.Revision
---@field buf integer? Nil until `git show` ends.
---@field waiting fun(buf: integer?, err: string?)[]

---@class didymus.diff.view.Shown The buffer of the code window that has the diff, or waits for it.
---@field win integer
---@field buf integer
---@field layout didymus.diff.Layout
---@field base_win integer? The base window that has the diff of the split layout.
---@field number integer Only the callbacks of the newest display apply.

---@class didymus.diff.view.Jump The newest `next` or `prev`. Only its callbacks apply.
---@field buf integer? The buffer whose `attach()` the jump waits for. The jump shows its error.

---@class didymus.diff.view.Start The code window before a jump to a different file.
---@field win integer
---@field buf integer
---@field cursor integer[]

---@class didymus.diff.View
---@field shown boolean
---@field layout didymus.diff.Layout
---@field private opts didymus.diff.ViewOpts
---@field private provider didymus.diff.Provider?
---@field private provider_err string?
---@field private attached table<integer, didymus.diff.view.Attached>
---@field private revisions table<didymus.diff.File, didymus.diff.view.Revision> The base buffers. They are deleted when the diff hides.
---@field private base_win integer? The base window of the split layout, on the left of the code window.
---@field private base_win_buf integer? The base buffer that the base window must show. Any other buffer ends the split layout.
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
    layout = config.options.diff.layout,
    opts = opts,
    provider = provider,
    provider_err = provider_err and ("%s (diff.provider)"):format(provider_err),
    attached = {},
    revisions = {},
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
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(args)
      local win = tonumber(args.match)
      if win == self.base_win then
        self.base_win, self.base_win_buf = nil, nil
        self:end_split("the base window closed")
      elseif self.display and win == self.display.win then
        self:schedule_update()
      end
    end,
  })
  return self
end

---@param message string
local function warn(message)
  vim.notify("didymus: " .. message, vim.log.levels.WARN)
end

--- Change to the inline layout after the user closed the base window, or put a different buffer in
--- it. `:tabclose` also closes the base window, so wait until the close of the review is known.
---@param reason string
function View:end_split(reason)
  vim.schedule(function()
    if not self.shown or not vim.api.nvim_tabpage_is_valid(self.opts.tabpage) then
      return
    end
    self.layout = "inline"
    vim.notify(("didymus: %s, so the diff layout is inline"):format(reason), vim.log.levels.INFO)
    self:update()
  end)
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

--- Get the base buffer of `file`, from `git show`. Call `cb` at once if the buffer is ready.
---@param file didymus.diff.File
---@param cb fun(buf: integer?, err: string?)
function View:get_base_buf(file, cb)
  local state = self.revisions[file]
  if state and state.buf then
    if vim.api.nvim_buf_is_valid(state.buf) then
      return cb(state.buf)
    end
    state = nil
  end
  if state then
    table.insert(state.waiting, cb)
    return
  end
  state = { waiting = { cb } }
  self.revisions[file] = state
  local target = self.opts.target --[[@as didymus.diff.Target]]
  revision.get({
    cwd = target.cwd,
    revision = target.base,
    path = target_util.base_path(file),
    empty = file.status == "added",
  }, function(buf, err)
    -- The diff hid before `git show` ended.
    if self.revisions[file] ~= state then
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      return
    end
    if err then
      self.revisions[file] = nil
    else
      state.buf = buf
    end
    local waiting = state.waiting
    state.waiting = {}
    for _, waiting_cb in ipairs(waiting) do
      waiting_cb(buf, err)
    end
  end)
end

--- The width of a new base window, from `diff.split.width`.
---@param code_win integer
---@return integer
local function get_base_width(code_win)
  local width = config.options.diff.split.width
  if width < 1 then
    width = math.floor(vim.api.nvim_win_get_width(code_win) * width)
  end
  return math.max(1, math.floor(width))
end

--- Show `buf` in the base window. Open the base window on the left of the code window if it is not
--- open. Do not change the jumplist, because a jump to other files opens files on the way.
---@param code_win integer
---@param buf integer
function View:show_base_buf(code_win, buf)
  self.base_win_buf = buf
  local win = self.base_win
  if win and vim.api.nvim_win_is_valid(win) then
    if vim.api.nvim_win_get_buf(win) ~= buf then
      vim.api.nvim_win_call(win, function()
        vim.api.nvim_cmd({
          cmd = "buffer",
          count = buf,
          mods = { keepjumps = true, keepalt = true },
        }, {})
      end)
    end
    return
  end
  self.base_win = vim.api.nvim_open_win(buf, false, {
    split = "left",
    win = code_win,
    width = get_base_width(code_win),
  })
end

--- Close the base window, if the view opened it.
function View:close_base_win()
  local win = self.base_win
  self.base_win, self.base_win_buf = nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    self.provider:clear(win)
    -- It fails for the last window of the tabpage. Then the window stays.
    pcall(vim.api.nvim_win_close, win, false)
  end
end

--- End the split layout if the user put a different buffer in the base window. The window is a
--- window of the user then, so do not close it.
function View:check_base_win()
  local win = self.base_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    self.base_win, self.base_win_buf = nil, nil
    return
  end
  if vim.api.nvim_win_get_buf(win) == self.base_win_buf then
    return
  end
  self.base_win, self.base_win_buf = nil, nil
  self.provider:clear(win)
  self:end_split("the base window shows a different buffer")
end

--- Remove the diff from the code window and the base window. Make the callbacks of the old display
--- old.
function View:clear_display()
  local display = self.display
  self.display = nil
  self.display_count = self.display_count + 1
  if not display then
    return
  end
  for _, win in ipairs({ display.win, display.base_win }) do
    if vim.api.nvim_win_is_valid(win) then
      self.provider:clear(win)
    end
  end
end

--- Show the diff of the buffer of the code window, if it is a file of the target. Clear the old
--- display first. The split layout also shows the base buffer in the base window.
function View:update()
  if not self.shown or vim.api.nvim_get_current_tabpage() ~= self.opts.tabpage then
    return
  end
  self:check_base_win()
  local win = self.opts.get_code_win()
  local buf = win and vim.api.nvim_win_get_buf(win)
  local layout = self.layout
  local display = self.display
  if display and display.win == win and display.buf == buf and display.layout == layout then
    return
  end
  self:clear_display()
  local file = buf and self:find_file(buf)
  if not (win and buf and file) or layout ~= "split" then
    self:close_base_win()
  end
  if not (win and buf and file) then
    return
  end
  local number = self.display_count
  local new_display = { win = win, buf = buf, layout = layout, number = number }
  self.display = new_display
  local function is_current()
    return self.shown and self.display ~= nil and self.display.number == number
  end
  local attached, base_buf = false, nil
  local function render()
    if not attached or (layout == "split" and not base_buf) then
      return
    end
    self.provider:render({
      layout = layout,
      sides = "both",
      file = file,
      target = self.opts.target --[[@as didymus.diff.Target]],
      head_win = win,
      head_buf = buf,
      base_win = new_display.base_win,
      base_buf = base_buf,
    }, function(render_err)
      if render_err and is_current() then
        self:warn_once(file.path, render_err)
      end
    end)
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
    attached = true
    render()
  end)
  if layout ~= "split" then
    return
  end
  self:get_base_buf(file, function(result, err)
    if not is_current() then
      return
    end
    if err then
      self:close_base_win()
      return self:warn_once(file.path, err)
    end
    ---@cast result integer
    self:show_base_buf(win, result)
    new_display.base_win, base_buf = self.base_win, result
    render()
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
  for file, state in pairs(self.revisions) do
    if state.buf == buf then
      self.revisions[file] = nil
    end
  end
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

--- The stop of the hunks after `line` on `side`, in `direction`, and its hunk. Nil if there is no
--- stop. `buf` is the buffer of `side`.
---@param file_hunks didymus.diff.Hunk[]
---@param buf integer
---@param side didymus.diff.Side
---@param line integer
---@param direction 1|-1
---@return integer? line
---@return didymus.diff.Hunk? hunk
local function find_stop(file_hunks, buf, side, line, direction)
  local opts = { line = line, side = side, line_count = vim.api.nvim_buf_line_count(buf) }
  local find = direction > 0 and hunks.next or hunks.prev
  return find(file_hunks, opts)
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

--- Focus the base window, and put its cursor on `line`, if the base window shows `buf`.
---@param buf integer
---@param line integer
---@param add_jump boolean Add the old position to the jumplist of the base window.
function View:move_in_base(buf, line, add_jump)
  local win = self.base_win
  if not (win and vim.api.nvim_win_is_valid(win) and self.base_win_buf == buf) then
    return
  end
  vim.api.nvim_set_current_win(win)
  if add_jump then
    vim.cmd("normal! m'")
  end
  set_cursor(win, line)
end

---@class didymus.diff.view.Stop
---@field line integer The head line.
---@field base_buf integer? Only for a jump in the base window.
---@field base_line integer? Only for a jump in the base window.

--- Go to the next or the previous hunk of the provider in the code window, also in the next files of
--- the target. Do not wrap. In the base window, use the base lines, and move the cursor of the base
--- window. See docs/architecture/diff.md#navigation.
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
  local from_base = self.base_win ~= nil and vim.api.nvim_get_current_win() == self.base_win
  ---@type didymus.diff.view.Start?
  local start
  -- A file that the jump opened only to get its hunks.
  local opened = false

  local function is_current()
    return self.shown
      and self.jump == jump
      and vim.api.nvim_get_current_tabpage() == self.opts.tabpage
  end

  --- False, and stop the jump, if the code window does not show `buf` now.
  ---@param buf integer
  ---@return boolean
  local function is_shown(buf)
    local win = self.opts.get_code_win()
    if is_current() and win and vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
    if self.jump == jump then
      self.jump = nil
    end
    return false
  end

  --- Wait for the hunks of `buf`, and for the base buffer in the base window. Stop the jump if the
  --- code window shows a different buffer. An error shows each time, because the user gave the
  --- command.
  ---@param buf integer
  ---@param file didymus.diff.File
  ---@param cb fun(file_hunks: didymus.diff.Hunk[]?, base_buf: integer?) No hunks after an error.
  local function wait_for_hunks(buf, file, cb)
    jump.buf = buf
    self:attach(buf, file, function(err)
      if not is_shown(buf) then
        return
      end
      jump.buf = nil
      if err then
        self:warn_error(file.path, err)
        return cb(nil)
      end
      local file_hunks = self.provider:hunks(buf) or {}
      if not from_base then
        return cb(file_hunks)
      end
      self:get_base_buf(file, function(base_buf, base_err)
        if not is_shown(buf) then
          return
        end
        if base_err then
          self:warn_error(file.path, base_err)
          return cb(nil)
        end
        cb(file_hunks, base_buf)
      end)
    end)
  end

  --- The stop after `line` in the head buffer `buf`, or in `base_buf` in the base window.
  ---@param file_hunks didymus.diff.Hunk[]
  ---@param buf integer
  ---@param base_buf integer?
  ---@param line integer
  ---@return didymus.diff.view.Stop?
  local function get_stop(file_hunks, buf, base_buf, line)
    if not from_base then
      local head_line = find_stop(file_hunks, buf, "head", line, direction)
      return head_line and { line = head_line }
    end
    ---@cast base_buf integer
    local base_line, hunk = find_stop(file_hunks, base_buf, "base", line, direction)
    if base_line and hunk then
      local head_line = hunks.stop(hunk, "head", vim.api.nvim_buf_line_count(buf))
      return { line = head_line, base_buf = base_buf, base_line = base_line }
    end
  end

  --- Open `path` at the stop. Only the start position goes into the jumplist of the code window.
  ---@param path string
  ---@param stop didymus.diff.view.Stop
  local function land(path, stop)
    self.jump = nil
    local restored = opened and start ~= nil and restore(start)
    if not self.opts.open_file(path, stop.line, { keepjumps = opened and not restored }) then
      return
    end
    if stop.base_buf then
      -- Show the base buffer now, not after the scheduled update. It is ready, so this is at once.
      self:update()
      self:move_in_base(stop.base_buf, stop.base_line --[[@as integer]], false)
    end
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
      if from_base and self.base_win and vim.api.nvim_win_is_valid(self.base_win) then
        vim.api.nvim_set_current_win(self.base_win)
      end
      return warn(("no %s hunk"):format(name))
    end
    local from = direction > 0 and 0 or math.huge
    local ready_buf = self:find_ready_buf(file)
    if ready_buf then
      local function check_ready(base_buf)
        local stop = get_stop(self.provider:hunks(ready_buf) or {}, ready_buf, base_buf, from)
        if stop then
          return land(file.path, stop)
        end
        check(index + 1)
      end
      if not from_base then
        return check_ready(nil)
      end
      return self:get_base_buf(file, function(base_buf, err)
        if not is_current() then
          return
        end
        if err then
          self:warn_error(file.path, err)
          return land(file.path, { line = 1 })
        end
        check_ready(base_buf)
      end)
    end
    if not self.opts.open_file(file.path, 1, { keepjumps = true }) then
      self.jump = nil
      return
    end
    opened = true
    local buf = vim.api.nvim_get_current_buf()
    wait_for_hunks(buf, file, function(file_hunks, base_buf)
      if not file_hunks then
        return land(file.path, { line = 1 })
      end
      local stop = get_stop(file_hunks, buf, base_buf, from)
      if stop then
        return land(file.path, stop)
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
  wait_for_hunks(start_buf, start_file, function(file_hunks, base_buf)
    if not file_hunks then
      self.jump = nil
      return
    end
    local line = vim.api.nvim_win_get_cursor(start_win)[1]
    if from_base then
      local base_win = self.base_win
      local shows_base = base_win
        and vim.api.nvim_win_is_valid(base_win)
        and self.base_win_buf == base_buf
      line = shows_base and vim.api.nvim_win_get_cursor(base_win)[1] or 1
    end
    local stop = get_stop(file_hunks, start_buf, base_buf, line)
    if not stop then
      start = { win = start_win, buf = start_buf, cursor = vim.api.nvim_win_get_cursor(start_win) }
      return check(1)
    end
    self.jump = nil
    if from_base then
      return self:move_in_base(base_buf --[[@as integer]], stop.base_line --[[@as integer]], true)
    end
    vim.api.nvim_set_current_win(start_win)
    vim.cmd("normal! m'")
    set_cursor(start_win, stop.line)
  end)
end

---@param layout string
---@return string
local function get_layout_err(layout)
  return ("the diff provider does not have the %s layout"):format(layout)
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
  -- For example `diff.layout = "split"` with a provider that has only the inline layout.
  if not self.provider.capabilities.layouts[self.layout] then
    local err = get_layout_err(self.layout)
    if not self.warned[err] then
      self.warned[err] = true
      warn(err)
    end
    self.layout = "inline"
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
  self:close_base_win()
  local attached = self.attached
  self.attached = {}
  for buf in pairs(attached) do
    self.provider:detach(buf)
  end
  local revisions = self.revisions
  self.revisions = {}
  for _, state in pairs(revisions) do
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_delete(state.buf, { force = true })
    end
  end
end

--- Set the layout, and show the diff if it is hidden. With no layout, change to the other layout.
---@param layout didymus.diff.Layout?
function View:set_layout(layout)
  layout = layout or (self.layout == "inline" and "split" or "inline")
  if self.provider and not self.provider.capabilities.layouts[layout] then
    return warn(get_layout_err(layout))
  end
  self.layout = layout
  if self.shown then
    self:update()
  else
    self:show()
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
