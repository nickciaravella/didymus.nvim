--- Find the next or the previous hunk from a line, on one side. Pure: it does not use editor state.
--- See docs/architecture/diff.md#navigation.

local M = {}

--- The line where the cursor stops for the hunk: its first line on `side`. A hunk with no lines
--- on `side`, such as a deletion on the head side, stops at the line after the gap. The stop is
--- in the buffer, so a deletion at the end of the file stops at the last line.
---@param hunk didymus.diff.Hunk
---@param side didymus.diff.Side
---@param line_count integer The number of lines of the buffer on `side`.
---@return integer
function M.stop(hunk, side, line_count)
  local range = hunk[side]
  local line = range.count == 0 and range.start + 1 or range.start
  return math.max(1, math.min(line, line_count))
end

---@class didymus.diff.FindOpts
---@field line integer The cursor line.
---@field side didymus.diff.Side
---@field line_count integer The number of lines of the buffer on `side`.

--- The first stop after `opts.line`. Nil at the last stop: the search does not wrap.
---@param hunks didymus.diff.Hunk[]
---@param opts didymus.diff.FindOpts
---@return integer? line
---@return didymus.diff.Hunk? hunk
function M.next(hunks, opts)
  local best_line, best_hunk
  for _, hunk in ipairs(hunks) do
    local line = M.stop(hunk, opts.side, opts.line_count)
    if line > opts.line and (not best_line or line < best_line) then
      best_line, best_hunk = line, hunk
    end
  end
  return best_line, best_hunk
end

--- The last stop before `opts.line`. Nil at the first stop: the search does not wrap.
---@param hunks didymus.diff.Hunk[]
---@param opts didymus.diff.FindOpts
---@return integer? line
---@return didymus.diff.Hunk? hunk
function M.prev(hunks, opts)
  local best_line, best_hunk
  for _, hunk in ipairs(hunks) do
    local line = M.stop(hunk, opts.side, opts.line_count)
    if line < opts.line and (not best_line or line > best_line) then
      best_line, best_hunk = line, hunk
    end
  end
  return best_line, best_hunk
end

return M
