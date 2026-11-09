--- The inline threads: a sign and a one-line summary at the line of each thread, and the thread
--- float. The marks show only in the windows of the review tabpage. It does not call the provider.
--- See docs/architecture/review.md#inline-threads.

local config = require("didymus.config")

local M = {}

---@class didymus.review.threads.Float
---@field win integer
---@field origin_win integer The window that was current when the float opened.
---@field thread_id string

--- The last thread float.
---@type didymus.review.threads.Float?
local float

--- The one namespace of the review.
M.namespace = vim.api.nvim_create_namespace("didymus.review")

local function set_highlights()
  vim.api.nvim_set_hl(0, "DidymusThread", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadResolved", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadPending", { link = "DiagnosticHint", default = true })
end
set_highlights()
-- A color scheme clears the highlight groups.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("didymus.review.threads", {}),
  callback = set_highlights,
})

--- Show the marks only in `wins`. `nvim__ns_set()` is experimental. If a later Neovim does not
--- have it, the marks show in all windows.
---@param wins integer[] Not empty, because an empty list shows the marks in all windows.
function M.scope(wins)
  local set_namespace = vim.api.nvim__ns_set
  if set_namespace then
    set_namespace(M.namespace, { wins = wins })
  end
end

--- The head line where the thread shows in the file: the last line of its range, as on GitHub.
--- Nil if the thread shows only in the panel: outdated, on the base side, or on the file.
---@param thread didymus.review.Thread
---@return integer?
function M.get_line(thread)
  if thread.side == "head" and not thread.outdated and thread.range then
    return thread.range.last
  end
end

--- The author, the first line of the first comment, and the tags of the state.
---@param thread didymus.review.Thread
---@param text_hl string? The highlight of the text. A resolved thread is dim.
---@return [string, string?][]
function M.get_summary(thread, text_hl)
  local comment = thread.comments[1]
  local author = comment and comment.author or "ghost"
  local first_line = comment and vim.trim(vim.trim(comment.body):match("^[^\n]*")) or ""
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local segments = {
    { "@" .. author, dim or "DidymusThread" },
    { " " .. first_line, dim or text_hl },
  }
  -- The first comment is pending until the user submits the review that started the thread.
  if comment and comment.pending then
    table.insert(segments, { " [pending]", dim or "DidymusThreadPending" })
  end
  if thread.resolved then
    table.insert(segments, { " [resolved]", dim })
  end
  if thread.outdated then
    table.insert(segments, { " [outdated]", dim or "DiagnosticWarn" })
  end
  return segments
end

---@param count integer
---@return string
local function get_sign_text(count)
  return count <= 9 and tostring(count) or "9+"
end

--- Draw the threads of `path` in `buf`. The id of each mark is the index of its thread in
--- `threads`, so that `at_cursor()` finds the thread.
---@param buf integer
---@param path string
---@param threads didymus.review.Thread[]
function M.draw(buf, path, threads)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for index, thread in ipairs(threads) do
    local line = thread.path == path and M.get_line(thread)
    if line then
      -- The file in the checkout can be shorter than the change head.
      line = math.min(line, line_count)
      local indent = vim.api.nvim_buf_call(buf, function()
        return vim.fn.indent(line)
      end)
      local summary = M.get_summary(thread, "DidymusThread")
      table.insert(summary, 1, { (" "):rep(indent) })
      vim.api.nvim_buf_set_extmark(buf, M.namespace, line - 1, 0, {
        id = index,
        sign_text = get_sign_text(#thread.comments),
        sign_hl_group = thread.resolved and "DidymusThreadResolved" or "DidymusThread",
        virt_lines = { summary },
      })
    end
  end
end

--- Remove the marks from all buffers.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
    end
  end
end

--- The threads with a mark on the cursor line. The marks move with the text.
---@param threads didymus.review.Thread[] The list that `draw()` used.
---@return didymus.review.Thread[]
function M.at_cursor(threads)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local marks = vim.api.nvim_buf_get_extmarks(0, M.namespace, { row, 0 }, { row, -1 }, {})
  local result = {}
  for _, mark in ipairs(marks) do
    table.insert(result, threads[mark[1]])
  end
  return result
end

--- The path and the line of the thread in messages, such as `file.txt:19`. Only the path if the
--- thread has no line.
---@param thread didymus.review.Thread
---@return string
function M.get_location(thread)
  if thread.range then
    return ("%s:%d"):format(thread.path, thread.range.last)
  end
  return thread.path
end

---@param thread didymus.review.Thread
---@return string
local function get_title(thread)
  local title = M.get_location(thread)
  local tags = {}
  if thread.side == "base" then
    table.insert(tags, "base")
  end
  if thread.resolved then
    table.insert(tags, "resolved")
  end
  if thread.outdated then
    table.insert(tags, "outdated")
  end
  if #tags > 0 then
    title = ("%s (%s)"):format(title, table.concat(tags, ", "))
  end
  return (" %s "):format(title)
end

--- The comments of a thread as markdown.
---@param thread didymus.review.Thread
---@return string[]
function M.get_lines(thread)
  local lines = {}
  for index, comment in ipairs(thread.comments) do
    if index > 1 then
      vim.list_extend(lines, { "", "---", "" })
    end
    local author = ("**@%s**"):format(comment.author)
    table.insert(lines, comment.pending and author .. " *pending*" or author)
    table.insert(lines, "")
    vim.list_extend(lines, vim.split(comment.body, "\n"))
  end
  return lines
end

--- Set the keys of `review.thread.keys` in the float. Show them in the footer if it fits.
---@param buf integer
---@param win integer
---@param thread didymus.review.Thread
local function set_keys(buf, win, thread)
  local keys = config.options.review.thread.keys
  -- The review API loads this module, so load the review API only when a key runs.
  local actions = {
    {
      key = keys.reply,
      name = "reply",
      fn = function()
        require("didymus.review").reply()
      end,
    },
    {
      key = keys.resolve,
      name = thread.resolved and "unresolve" or "resolve",
      fn = function()
        require("didymus.review").resolve()
      end,
    },
  }
  local footer_parts = {}
  for _, action in ipairs(actions) do
    if action.key then
      vim.keymap.set(
        "n",
        action.key,
        action.fn,
        { buffer = buf, nowait = true, desc = "didymus: review " .. action.name }
      )
      table.insert(footer_parts, ("%s %s"):format(action.key, action.name))
    end
  end
  local footer = (" %s "):format(table.concat(footer_parts, "  "))
  -- Neovim cuts a long footer from the start.
  if #footer_parts > 0 and vim.api.nvim_strwidth(footer) <= vim.api.nvim_win_get_width(win) then
    vim.api.nvim_win_set_config(win, { footer = footer, footer_pos = "right" })
  end
end

--- Open the thread in a float next to the cursor, as a hover. It closes when the cursor moves. A
--- second call focuses it.
---@param thread didymus.review.Thread
function M.open_float(thread)
  local origin_win = vim.api.nvim_get_current_win()
  local buf, win = vim.lsp.util.open_floating_preview(M.get_lines(thread), "markdown", {
    focus_id = "didymus.review.thread",
    -- A title needs a border.
    border = (vim.o.winborder == "" or vim.o.winborder == "none") and "rounded" or nil,
    title = get_title(thread),
    max_width = 80,
    max_height = math.max(1, math.floor(vim.o.lines * 0.6)),
  })
  if float and float.win == win then
    -- The call focused the open float, or went back from it.
    return
  end
  float = { win = win, origin_win = origin_win, thread_id = thread.id }
  set_keys(buf, win, thread)
end

--- The id of the thread of the thread float, if the float is the current window.
---@return string?
function M.get_float_thread_id()
  if float and vim.api.nvim_get_current_win() == float.win then
    return float.thread_id
  end
end

--- Close the thread float. If it is the current window, go back to the window where it opened.
function M.close_float()
  if not (float and vim.api.nvim_win_is_valid(float.win)) then
    return
  end
  if
    vim.api.nvim_get_current_win() == float.win and vim.api.nvim_win_is_valid(float.origin_win)
  then
    vim.api.nvim_set_current_win(float.origin_win)
  end
  vim.api.nvim_win_close(float.win, true)
end

return M
