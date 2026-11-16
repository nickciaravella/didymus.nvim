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

return T
