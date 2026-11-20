--- One open review: the change, its threads, its tabpage, the files panel and the state of `HEAD`
--- before the review.

local DiffView = require("didymus.diff.view")
local config = require("didymus.config")
local diff_target = require("didymus.review.diff_target")
local panel = require("didymus.review.panel")
local patch = require("didymus.review.patch")
local picker = require("didymus.ui.picker")
local threads = require("didymus.review.threads")
local workspace = require("didymus.review.workspace")

---@class didymus.review.SessionOpts
---@field change didymus.review.Change
---@field open_id string The id that `open` gave to `get_change()`: a PR number or a PR URL.
---@field label string The name of the change in messages, such as "#12".
---@field adapter didymus.picker.Adapter The picker of the files panel.
---@field provider didymus.review.Provider The provider that gave the change. Only it knows its own fields of the change.
---@field cwd string
---@field merge_base string? Nil if git could not find it.
---@field old_branch string? The branch before the review. Nil if `HEAD` was detached.
---@field old_head string? The sha of `HEAD` before the review.
---@field on_close fun(session: didymus.review.Session) Called once, when the tabpage closes.

---@class didymus.review.Session
---@field change didymus.review.Change
---@field open_id string The id for `get_change()`. `change.id` of a PR URL is only the number, and `get_change()` of a number uses the current repo.
---@field label string
---@field threads didymus.review.Thread[] In the order of the panel.
---@field provider didymus.review.Provider
---@field failed_draft didymus.review.CommentDraft? The last comment that the provider did not add. The next comment at its lines starts with its text.
---@field failed_reply didymus.review.ReplyDraft? The last reply that the provider did not add. The next reply to its thread starts with its text.
---@field failed_review_body string? The body of the last review that the provider did not submit. The next submit starts with it.
---@field load_count integer The number of the last get of the threads. Only the result of the newest get applies.
---@field discarded_at integer? The time of the last discard, from `vim.uv.now()`. Nil after a new pending comment or reply.
---@field thread_filter "all"|"active" The threads that the panel shows. Active threads are not resolved.
---@field private folds table<string, boolean> The fold state that the user set, by thread id. True is folded.
---@field private draw_scheduled boolean A draw after a change of the text width waits.
---@field cwd string
---@field merge_base string?
---@field old_branch string?
---@field old_head string?
---@field tabpage integer
---@field adapter didymus.picker.Adapter
---@field private panel didymus.picker.Panel?
---@field private code_win integer The window of the tabpage that shows the files of the change.
---@field private on_close fun(session: didymus.review.Session)
---@field private group integer The autocmds of the review.
---@field private thread_paths table<string, string> The path of each file with threads, by its real path.
---@field diff_view didymus.diff.View The diff of the change in the code window.
---@field private workspace_checked boolean True after the check for local changes in the diff.
local Session = {}
Session.__index = Session

--- Open the review tabpage and the files panel, and make the tabpage current.
---@param opts didymus.review.SessionOpts
---@return didymus.review.Session
function Session.new(opts)
  local self = setmetatable({
    change = opts.change,
    open_id = opts.open_id,
    label = opts.label,
    threads = {},
    load_count = 0,
    adapter = opts.adapter,
    provider = opts.provider,
    cwd = opts.cwd,
    merge_base = opts.merge_base,
    old_branch = opts.old_branch,
    old_head = opts.old_head,
    on_close = opts.on_close,
    thread_paths = {},
    thread_filter = "all",
    folds = {},
    draw_scheduled = false,
    workspace_checked = false,
  }, Session)
  -- An unlisted scratch buffer, so that the close leaves no "[No Name]" buffer.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("tab sbuffer " .. buf)
  self.tabpage = vim.api.nvim_get_current_tabpage()
  self.code_win = vim.api.nvim_get_current_win()

  self.group = vim.api.nvim_create_augroup("didymus.review.session", {})
  -- The user can close the tabpage with `:tabclose`. That also ends the review.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = self.group,
    callback = function()
      if vim.api.nvim_tabpage_is_valid(self.tabpage) then
        return
      end
      vim.api.nvim_del_augroup_by_id(self.group)
      vim.api.nvim_set_decoration_provider(threads.namespace, {})
      self.diff_view:close()
      self:hide_files()
      threads.clear()
      self.on_close(self)
    end,
  })
  -- The review buffers are the normal buffers of the user. So the marks show only in the windows
  -- of the review tabpage.
  vim.api.nvim_create_autocmd("WinNew", {
    group = self.group,
    callback = function()
      self:scope_threads()
    end,
  })
  -- Also after `:checktime` or `:edit!`, which load the file again.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = self.group,
    callback = function(args)
      self:draw_threads(args.buf)
    end,
  })
  -- The unfolded threads wrap at the text width. A resize, a new window or a new sign column
  -- changes it. Only a redraw updates the sign column, so check at the end of each redraw.
  vim.api.nvim_set_decoration_provider(threads.namespace, {
    on_end = function()
      self:check_text_widths()
    end,
  })
  self:scope_threads()
  self:show_files()
  self:make_diff_view()
  return self
end

--- Make the diff view of the change. Show the diff if `diff.enabled` is true.
function Session:make_diff_view()
  local target, target_err = diff_target.make(self)
  self.diff_view = DiffView.new({
    tabpage = self.tabpage,
    target = target,
    target_err = target_err,
    get_code_win = function()
      if
        vim.api.nvim_win_is_valid(self.code_win)
        and vim.api.nvim_win_get_tabpage(self.code_win) == self.tabpage
      then
        return self.code_win
      end
    end,
    open_file = function(path, line, opts)
      return self:open_file(path, line, opts)
    end,
    on_show = function()
      self:check_workspace()
    end,
  })
  if config.options.diff.enabled then
    self.diff_view:show()
  end
end

--- Show the diff in the preview window of the files panel. Nil removes it.
---@param win integer?
---@param ready fun()? Called when the diff shows, or will not show.
---@return boolean wait True if the call of `ready` comes later.
function Session:preview_diff(win, ready)
  -- The panel opens before the diff view.
  return self.diff_view ~= nil and self.diff_view:set_preview(win, ready)
end

--- The reason that the diff is not the diff of the code host, or nil.
---@param status didymus.review.workspace.Status
---@return string?
function Session:get_local_changes(status)
  if status.head ~= self.change.head_sha then
    return ("HEAD is not the head of %s"):format(self.label)
  end
  local paths = {}
  for _, file in ipairs(self.change.files) do
    paths[file.path] = true
    if file.old_path then
      paths[file.old_path] = true
    end
  end
  local changed = vim.tbl_filter(function(path)
    return paths[path]
  end, status.changed_files)
  if #changed == 1 then
    return ("%s has uncommitted changes"):format(changed[1])
  elseif #changed > 1 then
    return ("%d files of %s have uncommitted changes"):format(#changed, self.label)
  end
end

--- Once for each review, when the diff shows: if `HEAD` is not the change head, or a file of the
--- change has uncommitted changes, show a warning. The diff then shows these changes too.
function Session:check_workspace()
  if self.workspace_checked then
    return
  end
  self.workspace_checked = true
  workspace.get_status(self.cwd, function(err, status)
    if not self:is_open() then
      return
    end
    if err then
      vim.notify("didymus: cannot check the local changes: " .. err, vim.log.levels.WARN)
      return
    end
    local reason = self:get_local_changes(status --[[@as didymus.review.workspace.Status]])
    if reason then
      vim.notify(
        ("didymus: the diff also shows local changes, because %s"):format(reason),
        vim.log.levels.WARN
      )
    end
  end)
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

--- The full path of a file of the change. It stays correct if the current directory changes.
---@param path string Relative to `cwd`, as the provider gives it.
---@return string
function Session:get_full_path(path)
  return vim.fs.joinpath(self.cwd, path)
end

function Session:scope_threads()
  if self:is_open() then
    threads.scope(vim.api.nvim_tabpage_list_wins(self.tabpage))
  end
end

---@param win integer
---@return integer
local function get_win_text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

--- The text width of the narrowest window of the review tabpage that shows `buf`. With no such
--- window, the text width of the code window, because the buffer shows there when it opens.
---@param buf integer
---@return integer
function Session:get_text_width(buf)
  local width
  if self:is_open() then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(self.tabpage)) do
      -- A float, such as the preview of a picker, is not a window of the code.
      if
        vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_get_config(win).relative == ""
      then
        width = math.min(width or math.huge, get_win_text_width(win))
      end
    end
  end
  if width then
    return width
  end
  if vim.api.nvim_win_is_valid(self.code_win) then
    return get_win_text_width(self.code_win)
  end
  return vim.o.columns
end

--- Draw the threads in `buf` again if its text width changed. A decoration provider calls it at the
--- end of each redraw, so it must be fast.
function Session:check_text_widths()
  if self.draw_scheduled or vim.api.nvim_get_current_tabpage() ~= self.tabpage then
    return
  end
  local bufs = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(self.tabpage)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local width = threads.get_drawn_width(buf)
    if width and width ~= self:get_text_width(buf) then
      bufs[buf] = true
    end
  end
  if next(bufs) then
    -- A decoration provider must not change the extmarks.
    self.draw_scheduled = true
    vim.schedule(function()
      self.draw_scheduled = false
      for buf in pairs(bufs) do
        if vim.api.nvim_buf_is_loaded(buf) then
          self:draw_threads(buf)
        end
      end
    end)
  end
end

--- Draw the threads in `buf`, if it shows a file with threads.
---@param buf integer
function Session:draw_threads(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local real_path = name ~= "" and vim.uv.fs_realpath(name)
  local path = real_path and self.thread_paths[real_path]
  if path then
    threads.draw(buf, path, self.threads, {
      width = self:get_text_width(buf),
      is_folded = function(thread)
        return self:is_folded(thread)
      end,
    })
  end
end

--- Draw the threads in all loaded buffers of files with threads.
function Session:draw_all_threads()
  threads.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      self:draw_threads(buf)
    end
  end
end

--- As on github.com, a resolved thread starts folded, and an active thread starts unfolded.
---@param thread didymus.review.Thread
---@return boolean
function Session:is_folded(thread)
  local folded = self.folds[thread.id]
  if folded == nil then
    return thread.resolved
  end
  return folded
end

--- Fold or unfold the threads, and draw them again.
---@param list didymus.review.Thread[]
---@param folded boolean
function Session:set_folded(list, folded)
  for _, thread in ipairs(list) do
    self.folds[thread.id] = folded
  end
  self:draw_all_threads()
end

--- Remove the fold state that the user set. The thread then gets the start state of its new
--- resolved state at the next draw.
---@param thread_id string
function Session:reset_fold(thread_id)
  self.folds[thread_id] = nil
end

---@param list didymus.review.Thread[]
---@return boolean
function Session:has_unfolded(list)
  for _, thread in ipairs(list) do
    if not self:is_folded(thread) then
      return true
    end
  end
  return false
end

--- The index of each file in the order of the provider, by its path.
---@param files didymus.review.ChangedFile[]
---@return table<string, integer>
local function get_file_indexes(files)
  local file_indexes = {}
  for index, file in ipairs(files) do
    file_indexes[file.path] = index
  end
  return file_indexes
end

--- The order of the panel: the files in the order of the provider. In each file, the threads with a
--- line come first, by line. The other threads stay in the order of the provider.
---@param list didymus.review.Thread[]
---@param files didymus.review.ChangedFile[]
---@return didymus.review.Thread[]
local function sort_threads(list, files)
  local file_indexes = get_file_indexes(files)
  local keys = {}
  for index, thread in ipairs(list) do
    local line = threads.get_line(thread)
    keys[thread] = { file_indexes[thread.path] or math.huge, line or math.huge, index }
  end
  local sorted = vim.list_slice(list)
  table.sort(sorted, function(a, b)
    local a_key, b_key = keys[a], keys[b]
    for part = 1, 3 do
      if a_key[part] ~= b_key[part] then
        return a_key[part] < b_key[part]
      end
    end
    return false
  end)
  return sorted
end

--- Keep the threads of the change. Show them in the panel and in the loaded files.
---@param list didymus.review.Thread[]
function Session:set_threads(list)
  self.threads = sort_threads(list, self.change.files)
  self.thread_paths = {}
  for _, thread in ipairs(self.threads) do
    local real_path = vim.uv.fs_realpath(self:get_full_path(thread.path))
    if real_path then
      self.thread_paths[real_path] = thread.path
    end
  end
  self:draw_all_threads()
  if self:is_panel_open() then
    self.panel:update()
  end
end

--- Replace the change and its threads, for example after a refresh. Show them in the panel and in
--- the loaded files.
---@param change didymus.review.Change
---@param list didymus.review.Thread[]
function Session:set_change(change, list)
  self.change = change
  self:set_threads(list)
end

--- The file of the change at `path`.
---@param path string
---@return didymus.review.ChangedFile?
function Session:get_file(path)
  for _, file in ipairs(self.change.files) do
    if file.path == path then
      return file
    end
  end
end

--- Set the viewed state of the file at `path`. Show it in the panel.
---@param path string
---@param state didymus.review.ViewedState
function Session:set_viewed(path, state)
  local file = self:get_file(path)
  if file then
    file.viewed = state
  end
  if self:is_panel_open() then
    self.panel:update()
  end
end

--- Add a new thread. Show it in the panel and in the loaded files.
---@param thread didymus.review.Thread
function Session:add_thread(thread)
  self:set_threads(vim.list_extend(vim.list_slice(self.threads), { thread }))
end

--- Show all threads in the panel, or only the active threads.
function Session:toggle_thread_filter()
  self.thread_filter = self.thread_filter == "all" and "active" or "all"
  if self:is_panel_open() then
    self.panel:update()
  end
end

---@param id string
---@return didymus.review.Thread?
function Session:get_thread(id)
  for _, thread in ipairs(self.threads) do
    if thread.id == id then
      return thread
    end
  end
end

--- Replace the thread with the same id. Show it in the panel and in the loaded files.
---@param thread didymus.review.Thread
function Session:update_thread(thread)
  self:set_threads(vim.tbl_map(function(old)
    return old.id == thread.id and thread or old
  end, self.threads))
end

--- Add a reply to the thread with `thread_id`. Show it in the panel and in the loaded files.
---@param thread_id string
---@param comment didymus.review.Comment
function Session:add_reply(thread_id, comment)
  local thread = self:get_thread(thread_id)
  if thread then
    table.insert(thread.comments, comment)
    self:update_thread(thread)
  end
end

--- The pending comments of the review, with their threads, in the order of the panel.
---@return { thread: didymus.review.Thread, comment: didymus.review.Comment }[]
function Session:get_pending_comments()
  local result = {}
  for _, thread in ipairs(self.threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.pending then
        table.insert(result, { thread = thread, comment = comment })
      end
    end
  end
  return result
end

--- Call `cb` with the thread at the cursor: the thread of the open thread float, else the thread
--- with a mark on the cursor line. If more than one thread is at the line, ask which one.
---@param cb fun(thread: didymus.review.Thread)
function Session:pick_thread_at_cursor(cb)
  local float_thread_id = threads.get_float_thread_id()
  local float_thread = float_thread_id and self:get_thread(float_thread_id)
  -- The select closes the float. So with the float open, a second `thread` must focus the float,
  -- and not ask again.
  local found = float_thread and { float_thread } or threads.at_cursor(self.threads)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if #found == 0 then
    vim.notify(("didymus: no thread at line %d"):format(line), vim.log.levels.WARN)
  elseif #found == 1 then
    cb(found[1])
  else
    local ok, err = pcall(self.adapter.select, {
      title = ("Threads at line %d"):format(line),
      kind = "choice",
      items = vim.tbl_map(function(thread)
        local segments = threads.get_summary(thread)
        return { text = picker.join_segments(segments), segments = segments, value = thread }
      end, found),
      on_choose = function(item)
        cb(item.value)
      end,
    })
    if not ok then
      -- The snacks adapter gives an error if snacks.nvim is not available.
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- Scroll `win` so that the threads under `line` show, if they fit. `line` stays in the window.
---@param win integer
---@param line integer
local function show_threads_under(win, line)
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local height = vim.api.nvim_win_get_height(win)
  ---@param top integer
  ---@return integer rows The screen rows from `top` to the last line of the threads.
  local function get_rows(top)
    -- With `start_vcol`, the virtual lines above `top` do not count. They do not show.
    local opts = { start_row = top - 1, start_vcol = 0 }
    if line == line_count then
      -- With no `end_row`, the virtual lines under the last line count.
      return vim.api.nvim_win_text_height(win, opts).all
    end
    -- The virtual lines under `line` count as a part of the next line.
    opts.end_row = line
    local next_line =
      vim.api.nvim_win_text_height(win, { start_row = line, start_vcol = 0, end_row = line })
    return vim.api.nvim_win_text_height(win, opts).all - next_line.all
  end
  vim.api.nvim_win_call(win, function()
    local top = vim.fn.line("w0")
    -- A top line after this line moves the cursor, because of 'scrolloff'.
    local last_top = math.max(top, line - vim.o.scrolloff)
    local new_top = top
    while new_top < last_top and get_rows(new_top) > height do
      new_top = new_top + 1
    end
    if new_top ~= top then
      vim.fn.winrestview({ topline = new_top, topfill = 0 })
    end
  end)
end

--- Fold or unfold the threads at the cursor line, with no question. If one of them is unfolded,
--- fold all of them.
function Session:toggle_fold()
  local found = threads.at_cursor(self.threads)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if #found == 0 then
    vim.notify(("didymus: no thread at line %d"):format(line), vim.log.levels.WARN)
    return
  end
  local folded = self:has_unfolded(found)
  self:set_folded(found, folded)
  if not folded then
    show_threads_under(vim.api.nvim_get_current_win(), line)
  end
end

--- Fold all threads if one of the threads at a line is unfolded. Else, unfold all threads.
function Session:toggle_all_folds()
  local shown = vim.tbl_filter(function(thread)
    return threads.get_line(thread) ~= nil
  end, self.threads)
  if #shown == 0 then
    vim.notify(("didymus: %s has no threads at a line"):format(self.label), vim.log.levels.WARN)
    return
  end
  self:set_folded(self.threads, self:has_unfolded(shown))
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

---@class didymus.review.OpenFileOpts
---@field keepjumps boolean? Do not change the jumplist and the alternate file.
---@field buf integer? Show this buffer in place of the file, such as the base buffer of a deleted file.

--- Open a file of the change in the code window at `line`, and focus that window. If the user
--- closed the code window, open a new one on the right.
---@param path string Relative to `cwd`.
---@param line integer
---@param opts didymus.review.OpenFileOpts?
---@return boolean opened False if the file did not open. Then the error shows.
function Session:open_file(path, line, opts)
  local keepjumps = opts and opts.keepjumps or false
  if not self:is_open() then
    return false
  end
  local previous_win = vim.api.nvim_get_current_win()
  self:focus()
  local full_path = self:get_full_path(path)
  local buf = opts and opts.buf
  ---@type vim.api.keyset.cmd?
  local command = buf and { cmd = "buffer", count = buf }
    or { cmd = "edit", args = { full_path }, magic = { file = false } }
  command.mods = { keepjumps = keepjumps, keepalt = keepjumps }
  if
    vim.api.nvim_win_is_valid(self.code_win)
    and vim.api.nvim_win_get_tabpage(self.code_win) == self.tabpage
  then
    vim.api.nvim_set_current_win(self.code_win)
    -- `:edit` of the file in the window gives E37 if the buffer is modified.
    if
      buf and vim.api.nvim_win_get_buf(self.code_win) == buf
      or not buf and shows_file(self.code_win, full_path)
    then
      command = nil
      -- `:edit` of a different file adds the old position to the jumplist. A move in the same file
      -- does not.
      if not keepjumps then
        vim.cmd("normal! m'")
      end
    end
  else
    command.mods.split = "botright"
    command.mods.vertical = buf ~= nil
    command.cmd = buf and "sbuffer" or "vsplit"
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
      return false
    end
  end
  self.code_win = vim.api.nvim_get_current_win()
  set_cursor(self.code_win, line)
  return true
end

--- Open the file of `thread` at the line of the thread, unfold the thread, and show it.
---@param thread didymus.review.Thread
function Session:open_thread(thread)
  local line = threads.get_line(thread)
  if line and self:open_file(thread.path, line) then
    self:set_folded({ thread }, false)
    show_threads_under(self.code_win, vim.api.nvim_win_get_cursor(self.code_win)[1])
  end
end

---@class didymus.review.CursorPosition
---@field win integer
---@field file_index integer The index of the file of the window in the files of the change.
---@field line integer
---@field line_count integer The lines of the buffer of the window.

--- The index of the file of the change that `buf` shows. Nil if `buf` shows no file of the change.
---@param buf integer
---@return integer?
function Session:find_file_index(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local real_path = name ~= "" and vim.uv.fs_realpath(name)
  if not real_path then
    return
  end
  for index, file in ipairs(self.change.files) do
    if vim.uv.fs_realpath(self:get_full_path(file.path)) == real_path then
      return index
    end
  end
end

--- The cursor in the current window if it shows a file of the change, else in the code window. For
--- example, the panel or the thread float is the current window. Nil if no window shows a file.
---@return didymus.review.CursorPosition?
function Session:get_cursor_position()
  for _, win in ipairs({ vim.api.nvim_get_current_win(), self.code_win }) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == self.tabpage then
      local buf = vim.api.nvim_win_get_buf(win)
      local file_index = self:find_file_index(buf)
      if file_index then
        return {
          win = win,
          file_index = file_index,
          line = vim.api.nvim_win_get_cursor(win)[1],
          line_count = vim.api.nvim_buf_line_count(buf),
        }
      end
    end
  end
end

---@alias didymus.review.StopKind "thread"|"file"|"hunk"

---@class didymus.review.Stop A place where `next` and `prev` put the cursor.
---@field path string
---@field file_index integer
---@field line integer A head line.

--- The stops of `kind`, in the order of the panel. A deleted file is not in the checkout, so it
--- has no stops.
---@param kind didymus.review.StopKind
---@return didymus.review.Stop[]
function Session:get_stops(kind)
  local stops = {}
  if kind == "thread" then
    -- The panel shows only the threads of the files of the change, and with the active filter, only
    -- the threads that are not resolved.
    local file_indexes = get_file_indexes(self.change.files)
    for _, thread in ipairs(self.threads) do
      local line = threads.get_line(thread)
      local file_index = file_indexes[thread.path]
      local shown = self.thread_filter == "all" or not thread.resolved
      if line and file_index and shown then
        table.insert(stops, { path = thread.path, file_index = file_index, line = line })
      end
    end
    return stops
  end
  for file_index, file in ipairs(self.change.files) do
    if file.status ~= "deleted" then
      local hunks = patch.parse(file.patch).hunks
      if kind == "file" then
        -- The first change, as `<CR>` of the panel.
        local line = hunks[1] and hunks[1].first_change or 1
        table.insert(stops, { path = file.path, file_index = file_index, line = line })
      else
        for _, hunk in ipairs(hunks) do
          table.insert(
            stops,
            { path = file.path, file_index = file_index, line = hunk.first_change }
          )
        end
      end
    end
  end
  return stops
end

--- The first stop after `position` in `direction`. With no position, the first or the last stop.
---@param stops didymus.review.Stop[]
---@param position didymus.review.CursorPosition?
---@param direction 1|-1
---@param by_file boolean Compare only the files, so that a stop in the file of the cursor is not next.
---@return didymus.review.Stop?
local function find_stop(stops, position, direction, by_file)
  local first, last = 1, #stops
  if direction < 0 then
    first, last = last, first
  end
  for index = first, last, direction do
    local stop = stops[index]
    local order = direction
    if position then
      order = stop.file_index - position.file_index
      if order == 0 and not by_file then
        -- A line after the end of the buffer counts as the last line, where the mark of a thread
        -- is. Else `next` goes to the last line again and again.
        order = math.min(stop.line, position.line_count) - position.line
      end
    end
    if order * direction > 0 then
      return stop
    end
  end
end

--- Go to the next or the previous thread, file or hunk in the order of the panel, also in a
--- different file. Stops at the same line are one stop. Do not wrap. With no cursor in a file of the
--- change, go to the first or the last stop. Unfold the threads of a thread stop, and show them.
---@param kind didymus.review.StopKind
---@param direction 1|-1 1 for the next stop, -1 for the previous stop.
function Session:go_to(kind, direction)
  if not self:is_open() then
    return
  end
  -- The jump shows only in the review tabpage.
  self:focus()
  local position = self:get_cursor_position()
  local stop = find_stop(self:get_stops(kind), position, direction, kind == "file")
  if not stop then
    local name = direction > 0 and "next" or "previous"
    vim.notify(("didymus: no %s %s"):format(name, kind), vim.log.levels.WARN)
    return
  end
  local current_win = vim.api.nvim_get_current_win()
  if position and position.win == current_win and position.file_index == stop.file_index then
    -- A split of the review tabpage can show the file. Then the cursor moves in that split.
    vim.cmd("normal! m'")
    set_cursor(current_win, stop.line)
  elseif not self:open_file(stop.path, stop.line) then
    return
  end
  if kind == "thread" then
    -- The threads at the line are one stop. With the active filter, a resolved thread is no stop.
    local found = vim.tbl_filter(function(thread)
      return self.thread_filter == "all" or not thread.resolved
    end, threads.at_cursor(self.threads))
    self:set_folded(found, false)
    show_threads_under(vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)[1])
  end
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
