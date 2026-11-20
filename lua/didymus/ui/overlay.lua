--- A window with no border over a span of virtual lines in a window, so that the cursor can go into
--- the text of the virtual lines. Neovim cannot put the cursor in virtual lines. The span stays in
--- the virtual lines, so the text scrolls with the file. The window shows only while the span shows.
--- It does not know about reviews.

local layout = require("didymus.ui.layout")

local M = {}

--- A span of virtual lines: some rows of the virtual lines at one line.
---@class didymus.ui.overlay.Span
---@field row integer The 0-based row of the line with the virtual lines.
---@field above boolean True for the virtual lines above the line.
---@field offset integer The rows of the virtual lines of the line that come before the span.
---@field height integer
---@field col integer The columns from the start of the text area. The span goes to the end of the window.

--- The screen row of the first row of `span` in the text area of `win`, 0-based. It can be negative,
--- or after the end of the window, if the span does not show.
---@param win integer
---@param span didymus.ui.overlay.Span
---@return integer? row Nil if the span is above the top line of the window.
function M.get_screen_row(win, span)
  local buf = vim.api.nvim_win_get_buf(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local top, topfill = view.topline, view.topfill
  -- The virtual lines under a line are the filler lines of the next line. The filler lines of a
  -- line come before the line: first the virtual lines under the line before it, then the virtual
  -- lines above it.
  local line = span.above and span.row + 1 or span.row + 2
  local index = span.offset
  if span.above and span.row > 0 then
    local before, after = layout.count_virt_rows(win, buf, span.row - 1, false)
    index = index + before + after
  end
  if line < top then
    return
  end
  if line == top then
    -- `topfill` is the count of the last filler lines of the top line that show.
    local fill = vim.api.nvim_win_text_height(win, { start_row = top - 1, end_row = top - 1 }).fill
    return topfill - fill + index
  end
  -- With `start_vcol`, the filler lines above the top line do not count. The filler lines of `line`
  -- count as a part of `line`, so they are not in the range.
  local rows = vim.api.nvim_win_text_height(
    win,
    { start_row = top - 1, start_vcol = 0, end_row = line - 2 }
  ).all
  return topfill + rows + index
end

--- The rows of the text area of `win`.
---@param win integer
---@return integer
local function get_text_rows(win)
  return vim.api.nvim_win_get_height(win)
end

--- True if all rows of `span` show in `win`.
---@param win integer
---@param span didymus.ui.overlay.Span
---@return boolean
function M.is_shown(win, span)
  local row = M.get_screen_row(win, span)
  return row ~= nil and row >= 0 and row + span.height <= get_text_rows(win)
end

--- The filler rows above `line` in `win`: the virtual lines under the line before it, and above it.
---@param win integer
---@param line integer
---@return integer
local function get_filler_rows(win, line)
  return vim.api.nvim_win_text_height(win, { start_row = line - 1, end_row = line - 1 }).fill
end

--- Scroll `win` by one screen row, as `<C-e>` (`down`) or `<C-y>` does. The filler rows above the top
--- line scroll one at a time.
---@param win integer
---@param down boolean
---@return boolean scrolled
local function scroll_row(win, down)
  return vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local top, topfill = view.topline, view.topfill
    if down then
      if topfill > 0 then
        topfill = topfill - 1
      elseif top < vim.api.nvim_buf_line_count(0) then
        top = top + 1
        topfill = get_filler_rows(win, top)
      else
        return false
      end
    else
      if topfill < get_filler_rows(win, top) then
        topfill = topfill + 1
      elseif top > 1 then
        top, topfill = top - 1, 0
      else
        return false
      end
    end
    -- Keep the cursor in the window, else Neovim scrolls back to it.
    local lnum = view.lnum
    local bottom = vim.fn.line("w$")
    if lnum < top then
      lnum = top
    elseif not down and lnum > bottom - 1 and bottom > top then
      lnum = bottom - 1
    end
    vim.fn.winrestview({ topline = top, topfill = topfill, lnum = lnum })
    return true
  end)
end

--- Scroll `win` one row at a time, so that all rows of `span` show. If the span is higher than the
--- window, its first row goes to the top. The scroll can move the cursor of `win`.
---@param win integer
---@param span didymus.ui.overlay.Span
function M.scroll_to(win, span)
  local rows = get_text_rows(win)
  -- The limit stops a loop, for example if a mark moves.
  for _ = 1, 500 do
    local row = M.get_screen_row(win, span)
    local down
    if row == nil or row < 0 then
      down = false
    elseif row > 0 and row + span.height > rows then
      down = true
    else
      return
    end
    if not scroll_row(win, down) then
      return
    end
  end
end

--- The window config that puts a window on `span`. The part of the span after the end of the
--- window does not show. Nil if the first row of the span does not show.
---@param win integer
---@param span didymus.ui.overlay.Span
---@return vim.api.keyset.win_config?
function M.get_config(win, span)
  local row = M.get_screen_row(win, span)
  local rows = get_text_rows(win)
  if not row or row < 0 or row >= rows then
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  return {
    relative = "win",
    win = win,
    -- With `relative = "win"`, row 0 is the winbar, and col 0 is the sign column.
    row = row + info.winbar,
    col = info.textoff + span.col,
    width = math.max(1, info.width - info.textoff - span.col),
    height = math.max(1, math.min(span.height, rows - row)),
  }
end

--- Open a window for `buf` on `span` of `win`, and focus it. Nil if the span does not show.
---@param win integer
---@param buf integer
---@param span didymus.ui.overlay.Span
---@return integer?
function M.open(win, buf, span)
  local config = M.get_config(win, span)
  if not config then
    return
  end
  local overlay = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("force", config, {
      style = "minimal",
      border = "none",
      -- Under the floats of other plugins, such as a picker.
      zindex = 10,
    })
  )
  -- The window has the background of the text.
  vim.wo[overlay][0].winhighlight = "NormalFloat:Normal"
  return overlay
end

--- Put `overlay` on `span` again, for example after a scroll of `win`.
---@param overlay integer
---@param win integer
---@param span didymus.ui.overlay.Span
---@return boolean shown False if the first row of the span does not show. Then the window does not move.
function M.move(overlay, win, span)
  local config = M.get_config(win, span)
  if not config then
    return false
  end
  local current = vim.api.nvim_win_get_config(overlay)
  local changed = false
  for key, value in pairs(config) do
    if not vim.deep_equal(current[key], value) then
      changed = true
    end
  end
  if changed then
    vim.api.nvim_win_set_config(overlay, config)
  end
  return true
end

return M
