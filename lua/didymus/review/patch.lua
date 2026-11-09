--- The patch parser: the hunks and the commentable ranges of a changed file, from the patch of the
--- code host. See docs/architecture/review.md#patch-parser.

local M = {}

---@class didymus.review.Hunk
---@field head didymus.review.Range? The lines of the hunk in the head file, also the context lines. Nil if the hunk has no head lines.
---@field base didymus.review.Range? The lines of the hunk in the base file. Nil if the hunk has no base lines.
---@field first_change integer The head line of the first added or deleted line.

---@class didymus.review.Patch
---@field hunks didymus.review.Hunk[]
---@field commentable table<didymus.review.Side, didymus.review.Range[]>? The lines that accept comments, one range for each hunk. Nil if they are unknown.

---@class didymus.review.patch.Header
---@field base_start integer
---@field base_count integer
---@field head_start integer
---@field head_count integer

---@param line string
---@return didymus.review.patch.Header?
local function parse_header(line)
  local base_start, base_count, head_start, head_count =
    line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not base_start then
    return nil
  end
  -- A count that the header does not give is 1.
  return {
    base_start = tonumber(base_start),
    base_count = tonumber(base_count) or 1,
    head_start = tonumber(head_start),
    head_count = tonumber(head_count) or 1,
  }
end

---@param start integer
---@param count integer
---@return didymus.review.Range?
local function make_range(start, count)
  if count == 0 then
    return nil
  end
  return { first = start, last = start + count - 1 }
end

---@param header didymus.review.patch.Header
---@param body string[] The lines after the header.
---@return integer
local function get_first_change(header, body)
  -- With a count of 0, the start is the line before the hunk.
  local next_head = header.head_count > 0 and header.head_start or header.head_start + 1
  ---@type integer?
  local deleted_at
  for _, line in ipairs(body) do
    local kind = line:sub(1, 1)
    if kind == "+" then
      return next_head
    elseif kind == "-" then
      deleted_at = deleted_at or next_head
    elseif kind ~= "\\" then
      if deleted_at then
        break
      end
      next_head = next_head + 1
    end
  end
  if deleted_at then
    -- Deleted lines with no added lines after them. A unified diff puts them after the head line
    -- before them.
    return math.max(deleted_at - 1, 1)
  end
  return math.max(header.head_start, 1)
end

--- Parse the patch of a changed file. A nil `text` gives no hunks, and unknown commentable lines.
---@param text string? The hunks of a unified diff, with no file header.
---@return didymus.review.Patch
function M.parse(text)
  ---@type didymus.review.Hunk[]
  local hunks = {}
  ---@type didymus.review.patch.Header?, string[]
  local header, body = nil, {}

  local function add_hunk()
    if header then
      table.insert(hunks, {
        head = make_range(header.head_start, header.head_count),
        base = make_range(header.base_start, header.base_count),
        first_change = get_first_change(header, body),
      })
    end
  end

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local next_header = parse_header(line)
    if next_header then
      add_hunk()
      header, body = next_header, {}
    elseif header then
      table.insert(body, line)
    end
  end
  add_hunk()

  if not text then
    return { hunks = hunks }
  end
  -- GitHub accepts a comment on each line of a hunk, also on a context line.
  local commentable = {}
  for _, side in ipairs({ "head", "base" }) do
    commentable[side] = vim
      .iter(hunks)
      :map(function(hunk)
        return hunk[side]
      end)
      :totable()
  end
  return { hunks = hunks, commentable = commentable }
end

return M
