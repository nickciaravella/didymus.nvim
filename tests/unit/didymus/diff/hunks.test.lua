local eq = MiniTest.expect.equality
local hunks = require("didymus.diff.hunks")

local T = MiniTest.new_set()

---@param kind "add"|"change"|"delete"
---@param base integer[] The start and the count.
---@param head integer[] The start and the count.
---@return didymus.diff.Hunk
local function hunk(kind, base, head)
  return {
    kind = kind,
    base = { start = base[1], count = base[2] },
    head = { start = head[1], count = head[2] },
  }
end

-- Line 3 changed, lines 8 and 9 added, and the base lines 10 to 12 deleted after head line 14.
local file_hunks = {
  hunk("change", { 3, 1 }, { 3, 1 }),
  hunk("add", { 7, 0 }, { 8, 2 }),
  hunk("delete", { 10, 3 }, { 14, 0 }),
}

---@param line integer
---@param side didymus.diff.Side?
---@return { [1]: integer?, [2]: didymus.diff.Hunk? }
local function next_from(line, side)
  return { hunks.next(file_hunks, { line = line, side = side or "head", line_count = 20 }) }
end

---@param line integer
---@param side didymus.diff.Side?
---@return { [1]: integer?, [2]: didymus.diff.Hunk? }
local function prev_from(line, side)
  return { hunks.prev(file_hunks, { line = line, side = side or "head", line_count = 20 }) }
end

T["stop()"] = MiniTest.new_set()

T["stop()"]["is the first line of a hunk with lines on the side"] = function()
  eq(hunks.stop(file_hunks[1], "head", 20), 3)
  eq(hunks.stop(file_hunks[2], "head", 20), 8)
end

T["stop()"]["is the line after the gap of a hunk with no lines on the side"] = function()
  eq(hunks.stop(file_hunks[3], "head", 20), 15)
  eq(hunks.stop(file_hunks[2], "base", 20), 8)
end

T["stop()"]["is line 1 for a deletion at the start of the file"] = function()
  eq(hunks.stop(hunk("delete", { 1, 2 }, { 0, 0 }), "head", 20), 1)
end

T["stop()"]["is the last line for a deletion at the end of the file"] = function()
  eq(hunks.stop(hunk("delete", { 21, 2 }, { 20, 0 }), "head", 20), 20)
end

T["stop()"]["is line 1 in an empty buffer"] = function()
  eq(hunks.stop(hunk("delete", { 1, 5 }, { 0, 0 }), "head", 0), 1)
end

T["next()"] = MiniTest.new_set()

T["next()"]["gives the first stop after the line"] = function()
  eq(next_from(1), { 3, file_hunks[1] })
  eq(next_from(3), { 8, file_hunks[2] })
  eq(next_from(9), { 15, file_hunks[3] })
end

T["next()"]["does not wrap after the last stop"] = function()
  eq(next_from(15), {})
end

T["next()"]["does not need sorted hunks"] = function()
  local reversed = { file_hunks[3], file_hunks[2], file_hunks[1] }
  eq({ hunks.next(reversed, { line = 1, side = "head", line_count = 20 }) }, { 3, file_hunks[1] })
end

T["next()"]["stops at line 1 for a deletion at the start of the file, from no line"] = function()
  local deletion = hunk("delete", { 1, 2 }, { 0, 0 })
  eq({ hunks.next({ deletion }, { line = 0, side = "head", line_count = 20 }) }, { 1, deletion })
  eq({ hunks.next({ deletion }, { line = 1, side = "head", line_count = 20 }) }, {})
end

T["next()"]["uses the base lines on the base side"] = function()
  eq(next_from(3, "base"), { 8, file_hunks[2] })
  eq(next_from(8, "base"), { 10, file_hunks[3] })
  eq(next_from(10, "base"), {})
end

T["next()"]["gives nothing with no hunks"] = function()
  eq({ hunks.next({}, { line = 1, side = "head", line_count = 20 }) }, {})
end

T["prev()"] = MiniTest.new_set()

T["prev()"]["gives the last stop before the line"] = function()
  eq(prev_from(20), { 15, file_hunks[3] })
  eq(prev_from(15), { 8, file_hunks[2] })
  eq(prev_from(8), { 3, file_hunks[1] })
end

T["prev()"]["goes to the stop of the hunk at the cursor"] = function()
  eq(prev_from(9), { 8, file_hunks[2] })
end

T["prev()"]["does not wrap before the first stop"] = function()
  eq(prev_from(3), {})
  eq(prev_from(1), {})
end

T["prev()"]["uses the base lines on the base side"] = function()
  eq(prev_from(20, "base"), { 10, file_hunks[3] })
  eq(prev_from(10, "base"), { 8, file_hunks[2] })
  eq(prev_from(3, "base"), {})
end

T["get_deleted_file_hunks()"] = MiniTest.new_set()

T["get_deleted_file_hunks()"]["gives one deletion of all base lines, with a stop at base line 1"] = function()
  local deleted = hunks.get_deleted_file_hunks(5)
  eq(deleted, { hunk("delete", { 1, 5 }, { 0, 0 }) })
  local opts = { side = "base", line_count = 5 }
  eq({ hunks.next(deleted, vim.tbl_extend("force", opts, { line = 0 })) }, { 1, deleted[1] })
  eq({ hunks.prev(deleted, vim.tbl_extend("force", opts, { line = 3 })) }, { 1, deleted[1] })
  eq({ hunks.next(deleted, vim.tbl_extend("force", opts, { line = 1 })) }, {})
end

T["map_line()"] = MiniTest.new_set()

-- Base line 3 changed, head lines 6 and 7 added after base line 5, and base lines 8 and 9 deleted
-- after head line 9. Each side has 10 lines.
local map_hunks = {
  hunk("change", { 3, 1 }, { 3, 1 }),
  hunk("add", { 5, 0 }, { 6, 2 }),
  hunk("delete", { 8, 2 }, { 9, 0 }),
}

---@param line integer
---@param side didymus.diff.Side
---@return integer
local function map(line, side)
  return hunks.map_line(map_hunks, { line = line, side = side, line_count = 10 })
end

T["map_line()"]["moves a line by the hunks before it"] = function()
  eq({ map(1, "head"), map(4, "head"), map(8, "head"), map(9, "head"), map(10, "head") }, {
    1,
    4,
    6,
    7,
    10,
  })
  eq({ map(1, "base"), map(6, "base"), map(7, "base"), map(10, "base") }, { 1, 8, 9, 10 })
end

T["map_line()"]["keeps the line of a hunk"] = function()
  eq(map(3, "head"), 3)
  eq(map(3, "base"), 3)
end

T["map_line()"]["goes to the last line of a shorter hunk on the other side"] = function()
  local change = { hunk("change", { 3, 1 }, { 3, 3 }) }
  eq(hunks.map_line(change, { line = 5, side = "head", line_count = 10 }), 3)
  eq(hunks.map_line(change, { line = 6, side = "head", line_count = 10 }), 4)
end

T["map_line()"]["goes to the stop of a hunk with no lines on the other side"] = function()
  eq(map(6, "head"), 6)
  eq(map(7, "head"), 6)
  eq(map(8, "base"), 10)
  eq(map(9, "base"), 10)
end

T["map_line()"]["stays in the buffer on the other side"] = function()
  local deletion = { hunk("delete", { 10, 2 }, { 9, 0 }) }
  eq(hunks.map_line(deletion, { line = 11, side = "base", line_count = 9 }), 9)
  eq(hunks.map_line({}, { line = 12, side = "base", line_count = 9 }), 9)
  eq(hunks.map_line({}, { line = 1, side = "base", line_count = 0 }), 1)
end

T["map_line()"]["does not need sorted hunks"] = function()
  local reversed = { map_hunks[3], map_hunks[2], map_hunks[1] }
  eq(hunks.map_line(reversed, { line = 10, side = "base", line_count = 10 }), 10)
  eq(hunks.map_line(reversed, { line = 7, side = "base", line_count = 10 }), 9)
end

return T
