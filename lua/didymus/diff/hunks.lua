--- Find the next or the previous hunk from a line, on one side, and map a line to the other side.
--- Pure: it does not use editor state.
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

--- The hunks of a deleted file: one deletion of all base lines. A deleted file has no head buffer,
--- so the provider cannot give them.
---@param line_count integer The number of lines of the base buffer.
---@return didymus.diff.Hunk[]
function M.get_deleted_file_hunks(line_count)
  return {
    { kind = "delete", base = { start = 1, count = line_count }, head = { start = 0, count = 0 } },
  }
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

---@class didymus.diff.MapOpts
---@field line integer A line on `side`.
---@field side didymus.diff.Side The side of `line`.
---@field line_count integer The number of lines of the buffer on the other side.

--- The line on the other side that matches `opts.line`. A line in a hunk goes to the same line of
--- the hunk on the other side, or to its last line. A line in a hunk with no lines on the other
--- side goes to the stop of the hunk on the other side.
---@param hunks didymus.diff.Hunk[]
---@param opts didymus.diff.MapOpts
---@return integer
function M.map_line(hunks, opts)
  local other = opts.side == "head" and "base" or "head"
  local line = opts.line
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local from, to = hunk[opts.side], hunk[other]
    local last = from.count == 0 and from.start or from.start + from.count - 1
    if from.count > 0 and line >= from.start and line <= last then
      if to.count == 0 then
        return M.stop(hunk, other, opts.line_count)
      end
      line, offset = to.start + math.min(line - from.start, to.count - 1), 0
      break
    elseif last < line then
      offset = offset + to.count - from.count
    end
  end
  return math.max(1, math.min(line + offset, opts.line_count))
end

return M
