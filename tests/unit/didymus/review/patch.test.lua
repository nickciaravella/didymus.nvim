local eq = MiniTest.expect.equality
local patch = require("didymus.review.patch")

local T = MiniTest.new_set()

---@param lines string[]
---@return didymus.review.Patch
local function parse(lines)
  return patch.parse(table.concat(lines, "\n"))
end

T["parse()"] = MiniTest.new_set()

T["parse()"]["gives the ranges of one hunk on each side, and the first changed line"] = function()
  eq(parse({ "@@ -1,3 +1,3 @@", " one", "-two", "+2", " three" }), {
    hunks = { { head = { first = 1, last = 3 }, base = { first = 1, last = 3 }, first_change = 2 } },
    commentable = { head = { { first = 1, last = 3 } }, base = { { first = 1, last = 3 } } },
  })
end

T["parse()"]["gives one range on each side for each hunk"] = function()
  eq(
    parse({
      "@@ -3,7 +3,7 @@ local M = {}",
      " three",
      " four",
      " five",
      "-six",
      "+6",
      " seven",
      " eight",
      " nine",
      "@@ -15,6 +15,7 @@ function M.run()",
      " fifteen",
      " sixteen",
      " seventeen",
      "+seventeen and a half",
      " eighteen",
      " nineteen",
      " twenty",
    }),
    {
      hunks = {
        { head = { first = 3, last = 9 }, base = { first = 3, last = 9 }, first_change = 6 },
        { head = { first = 15, last = 21 }, base = { first = 15, last = 20 }, first_change = 18 },
      },
      commentable = {
        head = { { first = 3, last = 9 }, { first = 15, last = 21 } },
        base = { { first = 3, last = 9 }, { first = 15, last = 20 } },
      },
    }
  )
end

T["parse()"]["gives no base range for an added file"] = function()
  eq(parse({ "@@ -0,0 +1,2 @@", "+one", "+two" }), {
    hunks = { { head = { first = 1, last = 2 }, first_change = 1 } },
    commentable = { head = { { first = 1, last = 2 } }, base = {} },
  })
end

T["parse()"]["gives no head range for a deleted file, and line 1 as the first change"] = function()
  eq(parse({ "@@ -1,2 +0,0 @@", "-one", "-two" }), {
    hunks = { { base = { first = 1, last = 2 }, first_change = 1 } },
    commentable = { head = {}, base = { { first = 1, last = 2 } } },
  })
end

T["parse()"]["uses a count of 1 if the header does not give the count"] = function()
  eq(parse({ "@@ -1 +1 @@", "-one", "+1" }).hunks, {
    { head = { first = 1, last = 1 }, base = { first = 1, last = 1 }, first_change = 1 },
  })
end

T["parse()"]["gives the first added line after context lines"] = function()
  eq(parse({ "@@ -1,2 +1,4 @@", " one", "+a", "+b", " two" }).hunks[1].first_change, 2)
end

T["parse()"]["gives the line before deleted lines that have no added lines after them"] = function()
  eq(parse({ "@@ -1,4 +1,2 @@", " one", "-two", "-three", " four" }).hunks[1].first_change, 1)
  -- At the end of the file.
  eq(parse({ "@@ -2,3 +2,2 @@", " two", " three", "-four" }).hunks[1].first_change, 3)
  -- At the start of the file, there is no line before.
  eq(parse({ "@@ -1,3 +1,2 @@", "-zero", " one", " two" }).hunks[1].first_change, 1)
end

T["parse()"]["skips a 'No newline at end of file' line"] = function()
  eq(
    parse({
      "@@ -1,2 +1,2 @@",
      " one",
      "-two",
      "\\ No newline at end of file",
      "+2",
      "\\ No newline at end of file",
    }).hunks,
    { { head = { first = 1, last = 2 }, base = { first = 1, last = 2 }, first_change = 2 } }
  )
end

T["parse()"]["reads an empty line in a hunk as a context line"] = function()
  eq(parse({ "@@ -1,3 +1,3 @@", " one", "", "-three", "+3" }).hunks[1].first_change, 3)
end

T["parse()"]["skips the lines before the first hunk"] = function()
  eq(#parse({ "diff --git a/x b/x", "+++ b/x", "@@ -1 +1 @@", "-x", "+y" }).hunks, 1)
end

T["parse()"]["gives no hunks and no commentable lines for an empty patch"] = function()
  eq(patch.parse(""), { hunks = {}, commentable = { head = {}, base = {} } })
end

T["parse()"]["gives no hunks and unknown commentable lines for no patch"] = function()
  eq(patch.parse(nil), { hunks = {} })
end

return T
