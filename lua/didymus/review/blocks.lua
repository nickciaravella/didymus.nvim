--- The blocks in the virtual lines of the review: the threads, the open input of a comment or a
--- reply, and the texts that wait for the code host. Neovim cannot put the cursor in virtual lines.
--- So a window with no border covers the block that has the cursor, with the same text. `j` and
--- `k` go in and out of the blocks, as if the blocks were lines of the file. The file buffer keeps
--- its real text. See docs/architecture/review.md#blocks.

local input = require("didymus.ui.input")
local layout = require("didymus.ui.layout")
local overlay = require("didymus.ui.overlay")
local threads = require("didymus.review.threads")

local M = {}

--- The open input of a comment or a reply, in the virtual lines of its line.
---@class didymus.review.blocks.Draft
---@field win integer The window of the input.
---@field buf integer
---@field row integer The 0-based row of the line.
---@field above boolean True above line 1, for a comment on the file.
---@field reply_to string? The id of the thread of a reply.
---@field title string
---@field input didymus.ui.input.Handle?
---@field state didymus.ui.input.InlineState?

--- A text that waits for the code host, in the place of its input.
---@class didymus.review.blocks.Sent
---@field key string `sent:<n>`
---@field buf integer
---@field row integer
---@field above boolean
---@field reply_to string?
---@field title string
---@field lines string[]

--- The window on a block that is not the input: a thread, or a text that waits.
---@class didymus.review.blocks.Cursor
---@field win integer The window of the file.
---@field buf integer The buffer of the file.
---@field key string The key of the block.
---@field overlay integer The window on the block.
---@field overlay_buf integer

local frame_width = vim.fn.strdisplaywidth("│ ")

--- The text width of `win`.
---@param win integer
---@return integer
local function get_text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

--- The indent of a draft: the indent of its line, or 0 above line 1.
---@param buf integer
---@param row integer
---@param above boolean
---@return integer
local function get_draft_indent(buf, row, above)
  if above then
    return 0
  end
  return threads.get_indent(buf, math.min(row + 1, vim.api.nvim_buf_line_count(buf)))
end

--- The body of a text, wrapped at the text width of the frame.
---@param lines string[]
---@param width integer
---@return string[]
local function wrap_body(lines, width)
  local body = {}
  for _, line in ipairs(lines) do
    vim.list_extend(body, threads.wrap(line, width))
  end
  if #body == 0 then
    body = { "" }
  end
  return body
end

--- The drafts of `buf` for `threads.draw()`: the open input, and the texts that wait.
---@param session didymus.review.Session
---@param buf integer
---@param width integer The text width of the windows of the buffer.
---@return didymus.review.threads.Draft[]
function M.get_drafts(session, buf, width)
  local result = {}
  local draft = session.draft
  if draft and draft.buf == buf and draft.state then
    local indent = get_draft_indent(buf, draft.row, draft.above)
    local state = draft.state
    local body = not state.shown and wrap_body(state.lines, width - indent - frame_width) or nil
    table.insert(result, {
      key = "draft",
      row = draft.row,
      above = draft.above,
      reply_to = draft.reply_to,
      indent = indent,
      lines = threads.get_draft_lines({
        indent = indent,
        title = draft.title,
        body = body,
        height = body and #body or state.height,
        keys = state.keys,
        width = width,
      }),
    })
  end
  for _, sent in ipairs(session.sent) do
    if sent.buf == buf then
      local indent = get_draft_indent(buf, sent.row, sent.above)
      local body = wrap_body(sent.lines, width - indent - frame_width)
      table.insert(result, {
        key = sent.key,
        row = sent.row,
        above = sent.above,
        reply_to = sent.reply_to,
        indent = indent,
        lines = threads.get_draft_lines({
          indent = indent,
          title = sent.title,
          body = body,
          height = #body,
          width = width,
        }),
      })
    end
  end
  return result
end

--- The span of the block with `key` in `win`: all of it, or with `body` only the body of the input.
---@param win integer
---@param buf integer
---@param key string
---@param body { height: integer }?
---@return didymus.ui.overlay.Span?
local function get_span(win, buf, key, body)
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local mark_id, group, index = threads.find_block(buf, key)
  if not (mark_id and group and index) then
    return
  end
  local row = threads.get_mark_row(buf, mark_id)
  if not row then
    return
  end
  local block = group.blocks[index]
  -- The marks of other plugins at the line can come before the mark of the review.
  local before =
    layout.count_virt_rows(win, buf, row, group.above, { ns = threads.namespace, id = mark_id })
  if body then
    return {
      row = row,
      above = group.above,
      -- The title row comes before the body.
      offset = before + block.offset + 1,
      height = body.height,
      col = block.indent + frame_width,
    }
  end
  return {
    row = row,
    above = group.above,
    offset = before + block.offset,
    height = #block.lines,
    col = 0,
  }
end

--- The window of the cursor in the blocks, if it is a window on a thread or on a text that waits.
---@param session didymus.review.Session
---@return didymus.review.blocks.Cursor?
local function get_cursor(session)
  local cursor = session.block_cursor
  if cursor and vim.api.nvim_win_is_valid(cursor.overlay) then
    return cursor
  end
end

--- Remember the cursor of `win`, so that the next CursorMoved does not go into a block.
---@param session didymus.review.Session
---@param win integer
local function remember_cursor(session, win)
  local buf = vim.api.nvim_win_get_buf(win)
  session.cursors[win] = {
    buf = buf,
    line = vim.api.nvim_win_get_cursor(win)[1],
    tick = vim.api.nvim_buf_get_changedtick(buf),
  }
end

--- Close the window on the block of the cursor. If it is the current window, go to the window of
--- the file.
---@param session didymus.review.Session
function M.close_cursor(session)
  local cursor = get_cursor(session)
  session.block_cursor = nil
  if not cursor then
    return
  end
  if vim.api.nvim_get_current_win() == cursor.overlay and vim.api.nvim_win_is_valid(cursor.win) then
    vim.api.nvim_set_current_win(cursor.win)
    remember_cursor(session, cursor.win)
  end
  vim.api.nvim_win_close(cursor.overlay, true)
end

local highlight_namespace = vim.api.nvim_create_namespace("didymus.review.blocks")

--- Put the text and the highlights of `block` in `buf`.
---@param buf integer
---@param block didymus.review.threads.Block
local function set_block_text(buf, block)
  local lines, highlights = threads.get_block_text(block)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, highlight_namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, highlight_namespace, highlight.row, highlight.col, {
      end_col = highlight.end_col,
      hl_group = highlight.hl,
    })
  end
end

--- Put the cursor of `win` on the line of the group of the mark: the line above the blocks, or line 1
--- for the blocks above line 1. So the cursor of the file is at the blocks, and the next CursorMoved
--- in `win` does not go into a block.
---@param session didymus.review.Session
---@param win integer
---@param buf integer
---@param mark_id integer
local function set_group_cursor(session, win, buf, mark_id)
  local group = threads.get_group(buf, mark_id)
  local row = threads.get_mark_row(buf, mark_id) or (group and group.row)
  if row and vim.api.nvim_win_get_buf(win) == buf then
    vim.api.nvim_win_set_cursor(win, { row + 1, vim.api.nvim_win_get_cursor(win)[2] })
    remember_cursor(session, win)
  end
end

---@type fun(session: didymus.review.Session, win: integer, buf: integer, key: string, direction: "up"|"down")
local leave

--- Make the buffer of the windows on blocks, with the keys that leave the block.
---@param session didymus.review.Session
---@return integer
local function make_cursor_buffer(session)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "didymus_thread"
  ---@param direction "up"|"down"
  local function move(direction)
    local cursor = get_cursor(session)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local edge = direction == "up" and 1 or vim.api.nvim_buf_line_count(buf)
    if cursor and row == edge then
      leave(session, cursor.win, cursor.buf, cursor.key, direction)
    else
      local key = direction == "up" and "k" or "j"
      vim.cmd.normal({ ("%d%s"):format(vim.v.count1, key), bang = true })
    end
  end
  local map_opts = { buffer = buf, nowait = true }
  for _, key in ipairs({ "k", "<Up>" }) do
    vim.keymap.set("n", key, function()
      move("up")
    end, map_opts)
  end
  for _, key in ipairs({ "j", "<Down>" }) do
    vim.keymap.set("n", key, function()
      move("down")
    end, map_opts)
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function()
      -- Close the window outside the autocmd, because an autocmd cannot always change the layout.
      vim.schedule(function()
        local cursor = get_cursor(session)
        if
          cursor
          and cursor.overlay_buf == buf
          and vim.api.nvim_get_current_win() ~= cursor.overlay
        then
          M.close_cursor(session)
        end
      end)
    end,
  })
  return buf
end

--- Put the cursor in the block `index` of the mark `mark_id` of `buf`, in `win`: on its first line,
--- or with `at_end` on its last line. Scroll `win` so that the block shows.
---@param session didymus.review.Session
---@param win integer
---@param buf integer
---@param mark_id integer
---@param index integer
---@param at_end boolean
---@return boolean entered
function M.enter(session, win, buf, mark_id, index, at_end)
  local group = threads.get_group(buf, mark_id)
  local block = group and group.blocks[index]
  if not block then
    return false
  end
  if block.key == "draft" then
    local draft = session.draft
    if not (draft and draft.win == win and draft.input) then
      return false
    end
    set_group_cursor(session, win, buf, mark_id)
    return draft.input.focus(at_end)
  end
  local span = get_span(win, buf, block.key)
  if not span then
    return false
  end
  set_group_cursor(session, win, buf, mark_id)
  if not overlay.is_shown(win, span) then
    overlay.scroll_to(win, span)
  end
  local cursor = get_cursor(session)
  if cursor then
    session.block_cursor = nil
    vim.api.nvim_win_close(cursor.overlay, true)
  end
  local cursor_buf = make_cursor_buffer(session)
  set_block_text(cursor_buf, block)
  local overlay_win = overlay.open(win, cursor_buf, span)
  if not overlay_win then
    vim.api.nvim_buf_delete(cursor_buf, { force = true })
    return false
  end
  vim.wo[overlay_win][0].cursorline = true
  vim.wo[overlay_win][0].wrap = false
  session.block_cursor =
    { win = win, buf = buf, key = block.key, overlay = overlay_win, overlay_buf = cursor_buf }
  local row = at_end and #block.lines or 1
  -- The cursor goes to the text, after the indent and the frame.
  local line = vim.api.nvim_buf_get_lines(cursor_buf, row - 1, row, true)[1]
  local col = #((" "):rep(block.indent)) + #"│ "
  vim.api.nvim_win_set_cursor(overlay_win, { row, math.min(col, math.max(0, #line - 1)) })
  return true
end

--- Leave the block `key` of `buf`: go to the next block of the same line, or to the line of the file
--- under or above the blocks.
---@param session didymus.review.Session
---@param win integer
---@param buf integer
---@param key string
---@param direction "up"|"down"
leave = function(session, win, buf, key, direction)
  local mark_id, group, index = threads.find_block(buf, key)
  if not (mark_id and group and index) or not vim.api.nvim_win_is_valid(win) then
    return M.close_cursor(session)
  end
  local next_index = direction == "down" and index + 1 or index - 1
  if
    group.blocks[next_index] and M.enter(session, win, buf, mark_id, next_index, direction == "up")
  then
    return
  end
  local row = threads.get_mark_row(buf, mark_id) or group.row
  local line
  if group.above then
    -- Above line 1, `k` has no line to go to.
    line = direction == "down" and 1 or nil
  else
    line = direction == "down" and row + 2 or row + 1
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  if not line or line > line_count then
    return
  end
  M.close_cursor(session)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { line, vim.api.nvim_win_get_cursor(win)[2] })
  remember_cursor(session, win)
end
M.leave = leave

--- Draw the window on the block of the cursor again, after a draw of the virtual lines of `buf`.
--- If the block is gone, go to the window of the file.
---@param session didymus.review.Session
---@param buf integer
function M.refresh(session, buf)
  local draft = session.draft
  if draft and draft.buf == buf and draft.input then
    draft.input.update()
  end
  local cursor = get_cursor(session)
  if not cursor or cursor.buf ~= buf then
    return
  end
  local mark_id, group, index = threads.find_block(buf, cursor.key)
  local span = mark_id and get_span(cursor.win, buf, cursor.key)
  if not (group and index and span) then
    return M.close_cursor(session)
  end
  local row = vim.api.nvim_win_get_cursor(cursor.overlay)[1]
  set_block_text(cursor.overlay_buf, group.blocks[index])
  if not overlay.move(cursor.overlay, cursor.win, span) then
    return M.close_cursor(session)
  end
  local last = vim.api.nvim_buf_line_count(cursor.overlay_buf)
  vim.api.nvim_win_set_cursor(cursor.overlay, { math.min(row, last), 0 })
end

--- After a scroll of the window of the file, move the window on the block. If the block does not
--- show, go back to the file.
---@param session didymus.review.Session
function M.on_scroll(session)
  local cursor = get_cursor(session)
  if not cursor then
    return
  end
  local span = get_span(cursor.win, cursor.buf, cursor.key)
  if not (span and overlay.move(cursor.overlay, cursor.win, span)) then
    M.close_cursor(session)
  end
end

--- The key of the block with the cursor: the thread or the text of the window on it. Nil if the
--- cursor is not in a block.
---@param session didymus.review.Session
---@return string?
function M.get_cursor_key(session)
  local cursor = get_cursor(session)
  if cursor and vim.api.nvim_get_current_win() == cursor.overlay then
    return cursor.key
  end
end

--- True if `win` is a window of the review tabpage that shows a buffer, not a float.
---@param session didymus.review.Session
---@param win integer
---@return boolean
local function is_text_window(session, win)
  return vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == session.tabpage
    and vim.api.nvim_win_get_config(win).relative == ""
end

--- The group under the line `row` of `buf`, or above it.
---@param buf integer
---@param row integer
---@param above boolean
---@return integer? mark_id
---@return didymus.review.threads.Group?
local function find_group(buf, row, above)
  for _, item in ipairs(threads.get_groups_at(buf, row)) do
    if item.group.above == above and #item.group.blocks > 0 then
      return item.id, item.group
    end
  end
end

local keys = {
  up = { vim.keycode("k"), vim.keycode("<Up>") },
  down = { vim.keycode("j"), vim.keycode("<Down>") },
}

--- After `j` or `k` moves the cursor by one line in normal mode, go into the blocks between the two
--- lines. A different key, a count, or a change of the text does not go into blocks.
---@param session didymus.review.Session
function M.on_cursor_moved(session)
  local win = vim.api.nvim_get_current_win()
  if not is_text_window(session, win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local last = session.cursors[win]
  remember_cursor(session, win)
  local now = session.cursors[win]
  local key = session.last_key
  session.last_key = nil
  if
    not last
    or last.buf ~= buf
    or last.tick ~= now.tick
    or vim.api.nvim_get_mode().mode ~= "n"
  then
    return
  end
  if now.line == last.line + 1 and vim.list_contains(keys.down, key) then
    local mark_id = find_group(buf, last.line - 1, false)
    if mark_id then
      M.enter(session, win, buf, mark_id, 1, false)
    end
  elseif now.line == last.line - 1 and vim.list_contains(keys.up, key) then
    local mark_id, group = find_group(buf, now.line - 1, false)
    if mark_id and group then
      M.enter(session, win, buf, mark_id, #group.blocks, true)
    end
  end
end

--- Keep the typed key for the next CursorMoved. `k` on line 1 and `j` on the last line do not move the cursor, so no CursorMoved comes. Then go
--- into the blocks above line 1, or under the last line.
---@param session didymus.review.Session
---@param key string The typed key.
function M.on_key(session, key)
  session.last_key = key
  local up, down = vim.list_contains(keys.up, key), vim.list_contains(keys.down, key)
  if not (up or down) or vim.api.nvim_get_mode().mode ~= "n" then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if not is_text_window(session, win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  if up and line == 1 then
    local mark_id, group = find_group(buf, 0, true)
    if mark_id and group then
      vim.schedule(function()
        if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_cursor(win)[1] == 1 then
          M.enter(session, win, buf, mark_id, #group.blocks, true)
        end
      end)
    end
  elseif down and line == vim.api.nvim_buf_line_count(buf) then
    local mark_id = find_group(buf, line - 1, false)
    if mark_id then
      vim.schedule(function()
        if vim.api.nvim_get_current_win() == win then
          M.enter(session, win, buf, mark_id, 1, false)
        end
      end)
    end
  end
end

---@class didymus.review.blocks.DraftOpts
---@field win integer
---@field row integer The 0-based row of the line.
---@field above boolean
---@field reply_to string?
---@field input didymus.ui.input.Opts The options of the input, with no `inline`. `title` is the title of the frame.

--- Open the input of a comment or a reply in the virtual lines of a line of `opts.win`. After a
--- submit, the text waits in the same place, until the callback calls `release`. The `on_submit`
--- of each action gets `release`.
---@param session didymus.review.Session
---@param opts didymus.review.blocks.DraftOpts
---@return boolean opened False if an input with text is open. Then the cursor goes into it.
function M.open_draft(session, opts)
  local open = session.draft
  if open and open.input then
    if #open.input.get_lines() > 0 then
      vim.notify(
        ("didymus: you have an open comment at %s. Submit it, or cancel it with q."):format(
          open.title
        ),
        vim.log.levels.WARN
      )
      local mark_id, group, index = threads.find_block(open.buf, "draft")
      if mark_id and group and index and vim.api.nvim_win_get_buf(open.win) == open.buf then
        M.enter(session, open.win, open.buf, mark_id, index, true)
      end
      return false
    end
    open.input.cancel()
  end
  M.close_cursor(session)
  local buf = vim.api.nvim_win_get_buf(opts.win)
  ---@type didymus.review.blocks.Draft
  local draft = {
    win = opts.win,
    buf = buf,
    row = opts.row,
    above = opts.above,
    reply_to = opts.reply_to,
    title = opts.input.title or "",
  }
  session.draft = draft
  local function remove()
    if session.draft == draft then
      session.draft = nil
    end
    session:draw_threads(buf)
  end
  local input_opts = vim.tbl_extend("force", opts.input, {
    inline = {
      win = opts.win,
      on_change = function(state)
        draft.state = state
        session:draw_threads(buf)
      end,
      get_span = function()
        return get_span(
          draft.win,
          draft.buf,
          "draft",
          { height = draft.state and draft.state.height or 1 }
        )
      end,
      on_leave = function(direction)
        if direction ~= "away" then
          leave(session, draft.win, draft.buf, "draft", direction)
        end
      end,
    },
    on_cancel = function()
      remove()
      if opts.input.on_cancel then
        opts.input.on_cancel()
      end
    end,
    actions = vim.tbl_map(function(action)
      return vim.tbl_extend("force", action, {
        on_submit = function(text)
          session.sent_count = session.sent_count + 1
          ---@type didymus.review.blocks.Sent
          local sent = {
            key = ("sent:%d"):format(session.sent_count),
            buf = buf,
            row = draft.row,
            above = draft.above,
            reply_to = draft.reply_to,
            title = draft.title,
            lines = vim.split(text, "\n"),
          }
          table.insert(session.sent, sent)
          remove()
          action.on_submit(text, function()
            for index, other in ipairs(session.sent) do
              if other == sent then
                table.remove(session.sent, index)
              end
            end
            if vim.api.nvim_buf_is_valid(buf) then
              session:draw_threads(buf)
            end
          end)
        end,
      })
    end, opts.input.actions),
  })
  draft.input = input.open(input_opts)
  return true
end

--- Cancel the open input, and close the window on a block, for the close of the review.
---@param session didymus.review.Session
function M.clear(session)
  if session.draft and session.draft.input then
    session.draft.input.cancel()
  end
  session.draft = nil
  session.sent = {}
  M.close_cursor(session)
end

return M
