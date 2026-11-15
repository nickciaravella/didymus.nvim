--- One open review: the change, its threads, its tabpage, the files panel and the state of `HEAD`
--- before the review.

local panel = require("didymus.review.panel")
local patch = require("didymus.review.patch")
local picker = require("didymus.ui.picker")
local threads = require("didymus.review.threads")

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
---@field threads didymus.review.Thread[] In the order of the panel.
---@field thread_filter "all"|"active" The threads that the panel shows. Active threads are not resolved.
---@field cwd string
---@field merge_base string?
---@field old_branch string?
---@field old_head string?
---@field tabpage integer
---@field private adapter didymus.picker.Adapter
---@field private panel didymus.picker.Panel?
---@field private code_win integer The window of the tabpage that shows the files of the change.
---@field private on_close fun(session: didymus.review.Session)
---@field private group integer The autocmds of the review.
---@field private thread_paths table<string, string> The path of each file with threads, by its real path.
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
    thread_paths = {},
    thread_filter = "all",
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
  self:scope_threads()
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

function Session:scope_threads()
  if self:is_open() then
    threads.scope(vim.api.nvim_tabpage_list_wins(self.tabpage))
  end
end

--- Draw the threads in `buf`, if it shows a file with threads.
---@param buf integer
function Session:draw_threads(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local real_path = name ~= "" and vim.uv.fs_realpath(name)
  local path = real_path and self.thread_paths[real_path]
  if path then
    threads.draw(buf, path, self.threads)
  end
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
    local real_path = vim.uv.fs_realpath(vim.fs.joinpath(self.cwd, thread.path))
    if real_path then
      self.thread_paths[real_path] = thread.path
    end
  end
  threads.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      self:draw_threads(buf)
    end
  end
  if self:is_panel_open() then
    self.panel:update()
  end
end

--- Show all threads in the panel, or only the active threads.
function Session:toggle_thread_filter()
  self.thread_filter = self.thread_filter == "all" and "active" or "all"
  if self:is_panel_open() then
    self.panel:update()
  end
end

--- Open the thread at the cursor in a float. If more than one thread is at the line, ask which one.
function Session:show_thread_at_cursor()
  local found = threads.at_cursor(self.threads)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if #found == 0 then
    vim.notify(("didymus: no thread at line %d"):format(line), vim.log.levels.WARN)
  elseif #found == 1 then
    threads.open_float(found[1])
  else
    local ok, err = pcall(self.adapter.select, {
      title = ("Threads at line %d"):format(line),
      items = vim.tbl_map(function(thread)
        local segments = threads.get_summary(thread)
        return { text = picker.join_segments(segments), segments = segments, value = thread }
      end, found),
      on_choose = function(item)
        threads.open_float(item.value)
      end,
    })
    if not ok then
      -- The snacks adapter gives an error if snacks.nvim is not available.
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
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
      -- `:edit` of a different file adds the old position to the jumplist. A move in the same file
      -- does not.
      vim.cmd("normal! m'")
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
    if vim.uv.fs_realpath(vim.fs.joinpath(self.cwd, file.path)) == real_path then
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
--- change, go to the first or the last stop.
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
  else
    self:open_file(stop.path, stop.line)
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
