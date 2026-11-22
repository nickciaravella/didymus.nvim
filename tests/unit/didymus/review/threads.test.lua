local eq = MiniTest.expect.equality
local threads = require("didymus.review.threads")

local T = MiniTest.new_set()

T["wrap()"] = MiniTest.new_set()

T["wrap()"]["keeps a line that fits"] = function()
  eq(threads.wrap("Why two?", 8), { "Why two?" })
end

T["wrap()"]["breaks at the spaces, and removes the spaces at the break"] = function()
  eq(threads.wrap("one two  three four", 9), { "one two", "three", "four" })
end

T["wrap()"]["breaks a word that is longer than a line"] = function()
  eq(threads.wrap("a abcdefgh b", 4), { "a", "abcd", "efgh", "b" })
end

T["wrap()"]["keeps the indent at the start, also if it is wider than a line"] = function()
  eq(threads.wrap("  local x = 1", 9), { "  local x", "= 1" })
  eq(threads.wrap("      x", 4), { "    ", "x" })
end

T["wrap()"]["uses the display width"] = function()
  eq(threads.wrap("💬 é 💬💬", 5), { "💬 é", "💬💬" })
  -- A character wider than the line gets a line of its own.
  eq(threads.wrap("💬💬", 1), { "💬", "💬" })
end

T["wrap()"]["keeps an empty line"] = function()
  eq(threads.wrap("", 10), { "" })
end

T["format_time()"] = MiniTest.new_set()

T["format_time()"]["formats ISO-8601 timestamps and ignores invalid values"] = function()
  local formatted = threads.format_time("2026-11-21T14:30:00Z")
  eq(type(formatted), "string")
  eq(formatted:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$") ~= nil, true)
  eq(threads.format_time(nil), nil)
  eq(threads.format_time("not-a-date"), nil)
end

return T
