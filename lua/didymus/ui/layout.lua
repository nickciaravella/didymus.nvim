--- Sizes and positions of windows. It does not know about agents, diffs or reviews.
local M = {}

---@class didymus.ui.layout.Area
---@field row integer 0-based, relative to the editor.
---@field col integer
---@field width integer
---@field height integer

--- A size below 1 is a fraction of `total`. The result is from 1 to `total`.
---@param size number
---@param total integer
---@return integer
function M.resolve_size(size, total)
  local resolved = size < 1 and math.floor(total * size) or size
  return math.max(1, math.min(resolved, total))
end

--- The editor rows above the command line.
---@return didymus.ui.layout.Area
function M.editor_area()
  return { row = 0, col = 0, width = vim.o.columns, height = vim.o.lines - vim.o.cmdheight }
end

---@param part string|string[]
---@return boolean
local function has_char(part)
  local char = type(part) == "table" and part[1] or part
  return char ~= ""
end

--- The columns and the rows that a border adds to a window.
---@param border string|table The `border` of `nvim_win_get_config()`.
---@return integer width
---@return integer height
function M.border_size(border)
  if type(border) ~= "table" then
    return 0, 0
  end
  -- The parts start at the top-left corner and go clockwise.
  local top, right, bottom, left = border[2], border[4], border[6], border[8]
  local width = (has_char(left) and 1 or 0) + (has_char(right) and 1 or 0)
  local height = (has_char(top) and 1 or 0) + (has_char(bottom) and 1 or 0)
  return width, height
end

--- The offset that puts `size` in the center of `total`.
---@param size integer
---@param total integer
---@return integer
function M.center_offset(size, total)
  return math.floor((total - size) / 2)
end

--- The position and size of a float in the center of `area`. If the float and its border do not
--- fit, the float becomes smaller.
---@param area didymus.ui.layout.Area
---@param width integer Without the border.
---@param height integer
---@param border string|table The `border` of `nvim_win_get_config()`.
---@return { row: integer, col: integer, width: integer, height: integer }
function M.center(area, width, height, border)
  local border_width, border_height = M.border_size(border)
  width = math.max(1, math.min(width, area.width - border_width))
  height = math.max(1, math.min(height, area.height - border_height))
  return {
    row = area.row + M.center_offset(height + border_height, area.height),
    col = area.col + M.center_offset(width + border_width, area.width),
    width = width,
    height = height,
  }
end

--- The screen rows of the virtual lines at `row` of `buf` that show in `win`: below the line, or
--- above it. Neovim draws them in the order of `nvim_buf_get_extmarks()`. A namespace with a scope
--- shows only in the windows of its scope.
---@param win integer
---@param buf integer
---@param row integer 0-based.
---@param above boolean
---@param mark { ns: integer, id: integer }? This mark does not count. The rows of the marks after it go into `after`.
---@return integer before
---@return integer after
function M.count_virt_rows(win, buf, row, above, mark)
  local before, after, found = 0, 0, false
  local get_namespace = vim.api.nvim__ns_get
  local shown = {}
  local items = vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })
  for _, item in ipairs(items) do
    local details = item[4] or {}
    local ns = details.ns_id
    if mark and ns == mark.ns and item[1] == mark.id then
      found = true
    elseif details.virt_lines and (details.virt_lines_above or false) == above then
      if shown[ns] == nil then
        local wins = get_namespace and get_namespace(ns).wins or {}
        shown[ns] = #wins == 0 or vim.list_contains(wins, win)
      end
      if shown[ns] and found then
        after = after + #details.virt_lines
      elseif shown[ns] then
        before = before + #details.virt_lines
      end
    end
  end
  return before, after
end

--- Scroll `win` so that the virtual lines under `line` show, if they fit. `line` stays in the
--- window.
---@param win integer
---@param line integer
function M.show_lines_under(win, line)
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local height = vim.api.nvim_win_get_height(win)
  ---@param top integer
  ---@return integer rows The screen rows from `top` to the last virtual line under `line`.
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

--- Scroll `win` to the top, and show the virtual lines above line 1. Neovim shows them only with
--- `topfill`. The cursor line stays in the window.
---@param win integer
function M.show_lines_above_first(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local rows = M.count_virt_rows(win, buf, 0, true)
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local height = vim.api.nvim_win_get_height(win)
    local cursor_rows = vim.api.nvim_win_text_height(win, {
      start_row = 0,
      start_vcol = 0,
      end_row = vim.fn.line(".") - 1,
    }).all
    local topfill = math.max(0, math.min(rows, height - cursor_rows))
    if view.topline ~= 1 or view.topfill ~= topfill then
      vim.fn.winrestview({ topline = 1, topfill = topfill })
    end
  end)
end

return M
