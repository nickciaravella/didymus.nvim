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

return M
