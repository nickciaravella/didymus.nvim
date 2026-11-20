--- The inline threads: a sign at the line of each thread, and the thread under the line, folded or
--- unfolded. The thread float for the threads with no line. The marks show only in the windows of
--- the review tabpage. It does not call the provider. See docs/architecture/review.md#inline-threads.

local config = require("didymus.config")
local patch = require("didymus.review.patch")

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

--- The head line where the thread shows in the file: the last line of its range, as on GitHub. A
--- thread on the base side shows at its hunk. Nil if the thread shows only in the panel: outdated,
--- on the file, or on base lines out of the patch.
---@param thread didymus.review.Thread
---@param file didymus.review.ChangedFile? The file of the thread. It has the patch.
---@return integer?
function M.get_line(thread, file)
  if thread.outdated or not thread.range then
    return
  end
  if thread.side == "head" then
    return thread.range.last
  end
  -- A deleted file is not in the checkout.
  if file and file.status ~= "deleted" then
    return patch.get_head_line(file.patch, thread.range.last)
  end
end

--- True if the thread shows above line 1 of its file: a thread on the file that is not outdated. A
--- deleted file is not in the checkout.
---@param thread didymus.review.Thread
---@param file didymus.review.ChangedFile? The file of the thread.
---@return boolean
function M.is_at_top(thread, file)
  return not thread.outdated and not thread.range and file ~= nil and file.status ~= "deleted"
end

--- The icon of the state, the author, the first line of the first comment, and the pending and
--- outdated tags.
---@param thread didymus.review.Thread
---@param text_hl string? The highlight of the text. A resolved thread is dim.
---@return [string, string?][]
function M.get_summary(thread, text_hl)
  local comment = thread.comments[1]
  local author = comment and comment.author or "ghost"
  local first_line = comment and vim.trim(vim.trim(comment.body):match("^[^\n]*")) or ""
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local icons = config.options.review.icons
  local icon = thread.resolved and icons.resolved or icons.active
  local segments = {}
  if icon ~= "" then
    table.insert(segments, { icon .. " ", dim })
  end
  vim.list_extend(segments, {
    { "@" .. author, dim or "DidymusThread" },
    { " " .. first_line, dim or text_hl },
  })
  -- The first comment is pending until the user submits the review that started the thread.
  if comment and comment.pending then
    table.insert(segments, { " [pending]", dim or "DidymusThreadPending" })
  end
  if thread.side == "base" then
    table.insert(segments, { " [base]", dim or "Comment" })
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

--- The text width of the unfolded threads in each buffer, at the last `draw()`. Nil if the buffer
--- has no unfolded thread, because a folded thread does not wrap.
---@type table<integer, integer>
local drawn_widths = {}

--- Replace each tab with spaces, up to the next multiple of `tabstop` columns.
---@param line string
---@param tabstop integer
---@return string
local function expand_tabs(line, tabstop)
  local column = 0
  return (
    line:gsub("([^\t]*)\t", function(before)
      column = column + vim.fn.strdisplaywidth(before)
      local spaces = tabstop - column % tabstop
      column = column + spaces
      return before .. (" "):rep(spaces)
    end)
  )
end

--- Split `text` into lines of `width` display cells or fewer, at the spaces. A word that is longer
--- than a line breaks at the width. An empty text gives one empty line.
---@param text string With no tabs and no newlines.
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(width, 1)
  local lines, line, line_width = {}, "", 0
  local function push()
    table.insert(lines, line)
    line, line_width = "", 0
  end
  for spaces, word in text:gmatch("(%s*)(%S*)") do
    local word_width = vim.fn.strdisplaywidth(word)
    if line_width > 0 and line_width + #spaces + word_width > width then
      push()
    else
      -- The spaces at the start of a line can be the indent of code.
      spaces = spaces:sub(1, width - line_width)
      line, line_width = line .. spaces, line_width + #spaces
    end
    if line_width + word_width <= width then
      line, line_width = line .. word, line_width + word_width
    else
      for _, char in ipairs(vim.fn.split(word, [[\zs]])) do
        local char_width = vim.fn.strdisplaywidth(char)
        if line_width > 0 and line_width + char_width > width then
          push()
        end
        line, line_width = line .. char, line_width + char_width
      end
    end
  end
  if line ~= "" or #lines == 0 then
    push()
  end
  return lines
end

--- The keys that the user mapped to each `<Plug>` mapping of didymus, in `buf` or global. A key is
--- in the notation of `keytrans()`, such as `<Space>rr`.
---@param buf integer
---@return table<string, string>
local function get_mapped_keys(buf)
  local keys = {}
  local maps = vim.list_extend(vim.api.nvim_buf_get_keymap(buf, "n"), vim.api.nvim_get_keymap("n"))
  for _, map in ipairs(maps) do
    if map.rhs and vim.startswith(map.rhs, "<Plug>(didymus-") and not keys[map.rhs] then
      keys[map.rhs] = map.lhsraw and vim.fn.keytrans(map.lhsraw) or map.lhs
    end
  end
  return keys
end

---@param chunks [string, string?][]
---@return integer
local function get_chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

--- The keys of the user for the actions on `thread`. Nil if the user mapped no key, or if the line
--- is wider than `width`.
---@param thread didymus.review.Thread
---@param keys table<string, string> From `get_mapped_keys()`.
---@param width integer
---@param dim string? The highlight of a resolved thread.
---@return [string, string?][]?
local function get_keys_chunks(thread, keys, width, dim)
  local actions = {
    { plug = "<Plug>(didymus-review-reply)", name = "reply" },
    {
      plug = "<Plug>(didymus-review-resolve)",
      name = thread.resolved and "unresolve" or "resolve",
    },
    { plug = "<Plug>(didymus-review-fold)", name = "fold" },
  }
  local chunks = {}
  for _, action in ipairs(actions) do
    local key = keys[action.plug]
    if key then
      table.insert(chunks, { (#chunks > 0 and "  " or "") .. key, dim or "DidymusThread" })
      table.insert(chunks, { " " .. action.name, dim or "Comment" })
    end
  end
  if #chunks > 0 and get_chunks_width(chunks) <= width then
    return chunks
  end
end

---@class didymus.review.threads.UnfoldOpts
---@field indent integer The indent of the line of the thread.
---@field width integer The width of the text area.
---@field tabstop integer
---@field keys table<string, string> From `get_mapped_keys()`.

--- The `virt_lines` of an unfolded thread: all comments in a frame, and the keys of the user.
---@param thread didymus.review.Thread
---@param opts didymus.review.threads.UnfoldOpts
---@return [string, string?][][]
local function get_unfolded_lines(thread, opts)
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local icons = config.options.review.icons
  local icon = thread.resolved and icons.resolved or icons.active
  -- The frame is a character and a space in front of each line.
  local text_width = opts.width - opts.indent - vim.fn.strdisplaywidth("│ ")
  ---@type { header: boolean, chunks: [string, string?][] }[]
  local rows = {}
  for index, comment in ipairs(thread.comments) do
    local header = {}
    if index == 1 and icon ~= "" then
      table.insert(header, { icon .. " ", dim })
    end
    table.insert(header, { "@" .. comment.author, dim or "DidymusThread" })
    if comment.pending then
      table.insert(header, { " [pending]", dim or "DidymusThreadPending" })
    end
    -- The thread is on deleted lines, so it needs a tag at its head line.
    if index == 1 and thread.side == "base" then
      table.insert(header, { " [base]", dim or "Comment" })
    end
    table.insert(rows, { header = true, chunks = header })
    -- Keep the indent of the first line, because it can be code.
    local body = comment.body:gsub("^%s*\n", ""):gsub("%s+$", "")
    if body ~= "" then
      for _, body_line in ipairs(vim.split(body, "\n")) do
        body_line = expand_tabs((body_line:gsub("%s+$", "")), opts.tabstop)
        for _, part in ipairs(M.wrap(body_line, text_width)) do
          table.insert(rows, { header = false, chunks = { { part, dim } } })
        end
      end
    end
  end
  local keys = get_keys_chunks(thread, opts.keys, text_width, dim)
  if keys then
    table.insert(rows, { header = false, chunks = keys })
  end

  local indent = (" "):rep(opts.indent)
  local lines = {}
  for index, row in ipairs(rows) do
    local frame = "│"
    if index == 1 then
      frame = #rows == 1 and "─" or "┌"
    elseif index == #rows then
      frame = "└"
    elseif row.header then
      frame = "├"
    end
    local line = { { indent }, { frame .. " ", dim or "DidymusThread" } }
    table.insert(lines, vim.list_extend(line, row.chunks))
  end
  return lines
end

--- A draft of a comment or a reply: the input, or a text that waits for the code host. It shows in
--- the virtual lines of its line, as a thread.
---@class didymus.review.threads.Draft
---@field row integer The 0-based row of its line.
---@field above boolean True above line 1, for a comment on the file.
---@field reply_to string? The id of the thread of a reply. The draft shows after the thread.
---@field key string `draft` for the open input, or `sent:<n>` for a text that waits.
---@field indent integer
---@field lines [string, string?][][] Its virtual lines.

--- One thread or one draft in the virtual lines of a line.
---@class didymus.review.threads.Block
---@field key string `thread:<id>`, or `draft` for the open input, or `sent:<n>` for a text that waits.
---@field thread_index integer? The index of the thread in the list of `draw()`.
---@field offset integer The rows of the blocks before it in the mark.
---@field lines [string, string?][][]
---@field indent integer The indent of the frame.

--- The blocks of one mark. A mark has all virtual lines under a line, or above it.
---@class didymus.review.threads.Group
---@field row integer
---@field above boolean
---@field blocks didymus.review.threads.Block[]

--- The groups of each buffer at the last `draw()`, by mark id.
---@type table<integer, table<integer, didymus.review.threads.Group>>
local groups = {}

---@class didymus.review.threads.DrawOpts
---@field width integer The width of the text area. The comments of an unfolded thread wrap at it.
---@field is_folded fun(thread: didymus.review.Thread): boolean
---@field get_line fun(thread: didymus.review.Thread): integer? The line of the thread in the file. Nil shows no mark.
---@field is_at_top fun(thread: didymus.review.Thread): boolean True shows the thread above line 1, with no sign.
---@field drafts didymus.review.threads.Draft[]? The drafts in the buffer.

--- The indent of `line` in `buf`.
---@param buf integer
---@param line integer
---@return integer
function M.get_indent(buf, line)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.indent(line)
  end)
end

--- Draw the threads of `path` and the drafts in `buf`. One mark has all threads and drafts under a
--- line, in the order of `threads`, so that the place of each block is known. A draft of a reply
--- comes after its thread. A folded thread is one line: its summary. An unfolded thread shows all
--- its comments. A thread on the file shows above line 1, so its mark is on line 1.
---@param buf integer
---@param path string? Nil if the buffer has no file with threads.
---@param threads didymus.review.Thread[]
---@param opts didymus.review.threads.DrawOpts
function M.draw(buf, path, threads, opts)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  drawn_widths[buf] = nil
  groups[buf] = {}
  local line_count = vim.api.nvim_buf_line_count(buf)
  ---@type table<string, string>?
  local keys
  ---@type table<string, { row: integer, above: boolean, blocks: didymus.review.threads.Block[], comments: integer, resolved: boolean }>
  local by_place = {}
  local order = {}
  local function get_place(row, above)
    local key = ("%d:%s"):format(row, above)
    if not by_place[key] then
      by_place[key] = { row = row, above = above, blocks = {}, comments = 0, resolved = true }
      table.insert(order, key)
    end
    return by_place[key]
  end
  for index, thread in ipairs(threads) do
    local at_top = path ~= nil and thread.path == path and opts.is_at_top(thread)
    local line = path ~= nil and thread.path == path and (opts.get_line(thread) or at_top and 1)
    if line then
      -- The file in the checkout can be shorter than the change head.
      line = math.min(line, line_count)
      local indent = at_top and 0 or M.get_indent(buf, line)
      local virt_lines
      if opts.is_folded(thread) or #thread.comments == 0 then
        local summary = M.get_summary(thread, "DidymusThread")
        table.insert(summary, 1, { (" "):rep(indent) })
        virt_lines = { summary }
      else
        keys = keys or get_mapped_keys(buf)
        virt_lines = get_unfolded_lines(thread, {
          indent = indent,
          width = opts.width,
          tabstop = vim.bo[buf].tabstop,
          keys = keys,
        })
        drawn_widths[buf] = opts.width
      end
      local place = get_place(line - 1, at_top)
      place.comments = place.comments + #thread.comments
      place.resolved = place.resolved and thread.resolved
      table.insert(place.blocks, {
        key = "thread:" .. thread.id,
        thread_index = index,
        lines = virt_lines,
        indent = indent,
      })
    end
  end
  for _, draft in ipairs(opts.drafts or {}) do
    local place = get_place(math.min(draft.row, line_count - 1), draft.above)
    local block = {
      key = draft.key,
      lines = draft.lines,
      indent = draft.indent,
    }
    local position = #place.blocks + 1
    for index, other in ipairs(place.blocks) do
      if draft.reply_to and other.key == "thread:" .. draft.reply_to then
        position = index + 1
      end
    end
    table.insert(place.blocks, position, block)
  end
  for _, key in ipairs(order) do
    local place = by_place[key]
    local virt_lines, offset = {}, 0
    for _, block in ipairs(place.blocks) do
      block.offset = offset
      offset = offset + #block.lines
      vim.list_extend(virt_lines, block.lines)
    end
    -- A sign on line 1 is for a thread on line 1. A place with only drafts has no sign.
    local has_sign = not place.above and place.comments > 0
    local id = vim.api.nvim_buf_set_extmark(buf, M.namespace, place.row, 0, {
      sign_text = has_sign and get_sign_text(place.comments) or nil,
      sign_hl_group = has_sign and (place.resolved and "DidymusThreadResolved" or "DidymusThread")
        or nil,
      virt_lines = virt_lines,
      virt_lines_above = place.above,
    })
    groups[buf][id] = { row = place.row, above = place.above, blocks = place.blocks }
  end
end

--- The groups of the marks of `buf` at `row`, with their mark ids: the group above the line first.
---@param buf integer
---@param row integer 0-based.
---@return { id: integer, group: didymus.review.threads.Group }[]
function M.get_groups_at(buf, row)
  local result = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.namespace, { row, 0 }, { row, -1 }, {})
  for _, mark in ipairs(marks) do
    local group = (groups[buf] or {})[mark[1]]
    if group then
      table.insert(result, { id = mark[1], group = group })
    end
  end
  table.sort(result, function(a, b)
    return a.group.above and not b.group.above
  end)
  return result
end

--- The group of the mark `mark_id` of `buf`, at the last `draw()`.
---@param buf integer
---@param mark_id integer
---@return didymus.review.threads.Group?
function M.get_group(buf, mark_id)
  return (groups[buf] or {})[mark_id]
end

--- The group and the index of the block with `key` in `buf`.
---@param buf integer
---@param key string
---@return integer? mark_id
---@return didymus.review.threads.Group?
---@return integer? index
function M.find_block(buf, key)
  for id, group in pairs(groups[buf] or {}) do
    for index, block in ipairs(group.blocks) do
      if block.key == key then
        return id, group, index
      end
    end
  end
end

--- The current row of the mark of a group. The marks move with the text.
---@param buf integer
---@param mark_id integer
---@return integer?
function M.get_mark_row(buf, mark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.namespace, mark_id, {})
  return mark[1]
end

--- The text and the highlights of the virtual lines of a block, for a window on the block.
---@param block didymus.review.threads.Block
---@return string[] lines
---@return { row: integer, col: integer, end_col: integer, hl: string }[] highlights 0-based, in bytes.
function M.get_block_text(block)
  local lines, highlights = {}, {}
  for row, chunks in ipairs(block.lines) do
    local line = ""
    for _, chunk in ipairs(chunks) do
      if chunk[2] then
        table.insert(highlights, {
          row = row - 1,
          col = #line,
          end_col = #line + #chunk[1],
          hl = chunk[2],
        })
      end
      line = line .. chunk[1]
    end
    table.insert(lines, line)
  end
  return lines, highlights
end

---@class didymus.review.threads.DraftLinesOpts
---@field indent integer
---@field title string
---@field body string[]? The text lines, wrapped at the width. Nil for an input with a window on it.
---@field height integer The rows of the body.
---@field keys { key: string, name: string }[]? The keys of the input. Nil for a text that waits.
---@field width integer The width of the text area.

--- The virtual lines of a draft, in the frame of a thread: the title, the body and the keys. A text
--- that waits for the code host has no keys, and its body is dim.
---@param opts didymus.review.threads.DraftLinesOpts
---@return [string, string?][][]
function M.get_draft_lines(opts)
  local indent = (" "):rep(opts.indent)
  local hl = "DidymusThread"
  local function make_line(frame, chunks)
    return vim.list_extend({ { indent }, { frame .. " ", hl } }, chunks or {})
  end
  local lines = { make_line("┌", { { opts.title, hl } }) }
  local text_width = opts.width - opts.indent - vim.fn.strdisplaywidth("│ ")
  for row = 1, opts.height do
    local text = opts.body and opts.body[row]
    local last = row == opts.height and not opts.keys
    table.insert(
      lines,
      make_line(
        last and "└" or "│",
        text and { { text, not opts.keys and "Comment" or nil } } or nil
      )
    )
  end
  if opts.keys then
    -- Remove the last keys until they fit.
    local chunks = {}
    for count = #opts.keys, 1, -1 do
      chunks = {}
      local width = 0
      for index = 1, count do
        local key = (index > 1 and "  " or "") .. opts.keys[index].key
        local name = " " .. opts.keys[index].name
        vim.list_extend(chunks, { { key, hl }, { name, "Comment" } })
        width = width + vim.fn.strdisplaywidth(key .. name)
      end
      if width <= text_width then
        break
      end
      chunks = {}
    end
    table.insert(lines, make_line("└", chunks))
  end
  return lines
end

--- The text width of the last `draw()` in `buf`. Nil if `buf` has no unfolded thread.
---@param buf integer
---@return integer?
function M.get_drawn_width(buf)
  return drawn_widths[buf]
end

--- Remove the marks from all buffers.
function M.clear()
  drawn_widths = {}
  groups = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
    end
  end
end

--- The threads at the cursor line: under it, and above line 1. The marks move with the text.
---@param threads didymus.review.Thread[] The list that `draw()` used.
---@return didymus.review.Thread[]
function M.at_cursor(threads)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local result = {}
  for _, item in ipairs(M.get_groups_at(vim.api.nvim_get_current_buf(), row)) do
    for _, block in ipairs(item.group.blocks) do
      if block.thread_index then
        table.insert(result, threads[block.thread_index])
      end
    end
  end
  return result
end

--- The path and the line of the thread in messages, such as `file.txt:19`. A line on the base side
--- gets `(base)`. Only the path if the thread has no line.
---@param thread didymus.review.Thread
---@return string
function M.get_location(thread)
  if not thread.range then
    return thread.path
  end
  local location = ("%s:%d"):format(thread.path, thread.range.last)
  return thread.side == "base" and location .. " (base)" or location
end

---@param thread didymus.review.Thread
---@return string
local function get_title(thread)
  local title = thread.path
  local tags = {}
  if thread.range then
    title = ("%s:%d"):format(thread.path, thread.range.last)
  end
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
  return M.format_comments(thread.comments)
end

--- Comments as markdown: the author of each comment, then its body. A line separates them.
---@param comments didymus.review.Comment[]
---@return string[]
function M.format_comments(comments)
  local lines = {}
  for index, comment in ipairs(comments) do
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

--- Open the general comments of a change in a float next to the cursor, as the thread float.
---@param title string
---@param comments didymus.review.Comment[]
function M.open_comments_float(title, comments)
  local lines = #comments > 0 and M.format_comments(comments) or { "No comments." }
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    focus_id = "didymus.review.comments",
    -- A title needs a border.
    border = (vim.o.winborder == "" or vim.o.winborder == "none") and "rounded" or nil,
    title = (" %s "):format(title),
    max_width = 80,
    max_height = math.max(1, math.floor(vim.o.lines * 0.6)),
  })
end

--- The id of the thread of the open thread float, if the float or the window where it opened is
--- the current window. A move of the cursor closes the float, so the cursor is at the thread.
---@return string?
function M.get_float_thread_id()
  if not (float and vim.api.nvim_win_is_valid(float.win)) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if win == float.win or win == float.origin_win then
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
