--- The inline threads: a sign and a one-line summary at the line of each thread, and the thread
--- float. The marks show only in the windows of the review tabpage. It does not call the provider.
--- See docs/architecture/review.md#inline-threads.

local M = {}

--- The one namespace of the review.
M.namespace = vim.api.nvim_create_namespace("didymus.review")

local function set_highlights()
  vim.api.nvim_set_hl(0, "DidymusThread", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadResolved", { link = "Comment", default = true })
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

---@param thread didymus.review.Thread
---@return string
local function get_title(thread)
  local title = thread.path
  if thread.range then
    title = ("%s:%d"):format(title, thread.range.last)
  end
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

--- Open the thread in a float next to the cursor, as a hover. It closes when the cursor moves. A
--- second call focuses it.
---@param thread didymus.review.Thread
function M.open_float(thread)
  vim.lsp.util.open_floating_preview(M.get_lines(thread), "markdown", {
    focus_id = "didymus.review.thread",
    -- A title needs a border.
    border = (vim.o.winborder == "" or vim.o.winborder == "none") and "rounded" or nil,
    title = get_title(thread),
    max_width = 80,
    max_height = math.max(1, math.floor(vim.o.lines * 0.6)),
  })
end

return M
