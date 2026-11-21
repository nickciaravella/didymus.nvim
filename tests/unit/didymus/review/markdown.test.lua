local eq = MiniTest.expect.equality
local markdown = require("didymus.review.markdown")

local T = MiniTest.new_set()

T["highlight()"] = MiniTest.new_set()

T["highlight()"]["renders inline code, bold and links by concealing markdown delimiters"] = function()
  local lines = markdown.highlight("Use `count` and **num** and [docs](https://example.com).")
  eq(#lines, 1)
  local by_text = {}
  local text = {}
  for _, chunk in ipairs(lines[1]) do
    by_text[chunk[1]] = chunk[2]
    table.insert(text, chunk[1])
  end
  eq(table.concat(text), "Use count and num and docs.")
  eq(by_text["count"], "@markup.raw.markdown_inline")
  eq(by_text["num"], "@markup.strong.markdown_inline")
  eq(by_text["docs"], "@markup.link.label.markdown_inline")
end

T["highlight()"]["renders fenced lua code blocks with language label and hides fences"] = function()
  local lines = markdown.highlight("```lua\nlocal x = 1\n```")
  eq(#lines, 2)
  eq(lines[1], { { "lua", "@label.markdown" } })
  local by_text = {}
  for _, chunk in ipairs(lines[2]) do
    by_text[chunk[1]] = chunk[2]
  end
  eq(by_text["local"], "@keyword.lua")
  eq(by_text["1"], "@number.lua")
end

T["highlight()"]["uses the override highlight when given and still conceals delimiters"] = function()
  eq(markdown.highlight("**bold**\nnext", { hl = "DidymusThreadResolved" }), {
    { { "bold", "DidymusThreadResolved" } },
    { { "next", "DidymusThreadResolved" } },
  })
end

T["highlight()"]["expands tabs and trims trailing spaces"] = function()
  local lines = markdown.highlight("\tx   ", { tabstop = 4, hl = "Comment" })
  eq(lines, { { { "    x", "Comment" } } })
end

T["wrap_chunks()"] = MiniTest.new_set()

T["wrap_chunks()"]["preserves highlight groups across wrapped lines"] = function()
  local wrapped = markdown.wrap_chunks({
    { "Use " },
    { "`long_func`", "@markup.raw.markdown_inline" },
    { " here" },
  }, 11)
  eq(wrapped, {
    { { "Use" } },
    { { "`long_func`", "@markup.raw.markdown_inline" } },
    { { "here" } },
  })
end

T["wrap_chunks()"]["breaks a long styled word and keeps its highlight"] = function()
  local wrapped = markdown.wrap_chunks({
    { "a " },
    { "abcdefgh", "@markup.strong.markdown_inline" },
  }, 4)
  eq(wrapped, {
    { { "a" } },
    { { "abcd", "@markup.strong.markdown_inline" } },
    { { "efgh", "@markup.strong.markdown_inline" } },
  })
end

T["truncate_chunks()"] = MiniTest.new_set()

T["truncate_chunks()"]["cuts chunks at display width"] = function()
  eq(
    markdown.truncate_chunks({ { "💬 ", "Icon" }, { "@octocat", "DidymusThread" } }, 7),
    { { "💬 ", "Icon" }, { "@oct", "DidymusThread" } }
  )
end

return T
