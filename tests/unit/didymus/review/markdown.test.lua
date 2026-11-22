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

T["render()"] = MiniTest.new_set()

T["render()"]["applies render-markdown marks for inline code, code blocks and hidden fences"] = function()
  local text = "Why `count = 2` instead of **0**?\n\n```lua\nlocal count = 0\n```"
  local marks = {
    {
      start_row = 0,
      start_col = 4,
      opts = { end_row = 0, end_col = 15, hl_group = "RenderMarkdownCodeInline", priority = 140 },
    },
    { start_row = 2, start_col = 0, opts = { end_row = 2, end_col = 3, conceal = "" } },
    { start_row = 2, start_col = 3, opts = { end_row = 2, end_col = 6, conceal = "" } },
    {
      start_row = 2,
      start_col = 0,
      opts = {
        virt_text = {
          { "lua", { "DevIconLua", "RenderMarkdownCodeBorder" } },
          { ("="):rep(80), "RenderMarkdownCodeBorder" },
        },
        virt_text_pos = "overlay",
      },
    },
    {
      start_row = 3,
      start_col = 0,
      opts = { end_row = 4, hl_eol = true, hl_group = "RenderMarkdownCode", priority = 140 },
    },
    { start_row = 4, start_col = 0, opts = { end_row = 4, end_col = 3, conceal = "" } },
    { start_row = 4, start_col = 0, opts = { end_row = 4, end_col = 3, conceal_lines = "" } },
  }

  local lines = markdown.render(text, { width = 34, marks = marks })
  -- Closing fence is hidden by `conceal_lines = ""`, leaving 4 lines.
  eq(#lines, 4)

  local function join_text(chunks)
    local parts = {}
    for _, chunk in ipairs(chunks) do
      table.insert(parts, chunk[1])
    end
    return table.concat(parts)
  end

  -- Inline code combines treesitter highlight and RenderMarkdownCodeInline.
  eq(join_text(lines[1]), "Why count = 2 instead of 0?")
  local inline_hl
  for _, chunk in ipairs(lines[1]) do
    if chunk[1] == "count = 2" then
      inline_hl = chunk[2]
    end
  end
  eq(inline_hl, { "@markup.raw.markdown_inline", "RenderMarkdownCodeInline" })

  -- Full-width code border overlay is clamped to `width` and does not wrap.
  eq(join_text(lines[3]), "lua" .. ("="):rep(31))
  eq(lines[3][1], { "lua", { "DevIconLua", "RenderMarkdownCodeBorder" } })

  -- Code line stacks Lua syntax highlights with RenderMarkdownCode and pads to `width`.
  eq(markdown.chunks_width(lines[4]), 34)
  eq(lines[4][1], { "local", { "@keyword.lua", "RenderMarkdownCode" } })
  eq(lines[4][#lines[4]], { (" "):rep(19), "RenderMarkdownCode" })
end

T["render()"]["handles heading overlays, bullets, checkboxes and wrapped eol backgrounds"] = function()
  local text = "# Long title here\n- item\n- [x] done"
  local marks = {
    {
      start_row = 0,
      start_col = 0,
      opts = {
        virt_text = { { "H ", { "RenderMarkdownH1", "RenderMarkdownH1Bg" } } },
        virt_text_pos = "overlay",
      },
    },
    {
      start_row = 0,
      start_col = 0,
      opts = { end_row = 1, hl_eol = true, hl_group = "RenderMarkdownH1Bg", priority = 4096 },
    },
    {
      start_row = 1,
      start_col = 0,
      opts = { virt_text = { { "*", "RenderMarkdownBullet" } }, virt_text_pos = "overlay" },
    },
    { start_row = 2, start_col = 0, opts = { end_row = 2, end_col = 2, conceal = "" } },
    {
      start_row = 2,
      start_col = 2,
      opts = {
        virt_text = { { "[X]", "RenderMarkdownChecked" } },
        virt_text_pos = "overlay",
      },
    },
    { start_row = 2, start_col = 5, opts = { end_row = 2, end_col = 6, conceal = "" } },
  }

  local lines = markdown.render(text, { width = 12, marks = marks })
  -- Heading wraps to 2 lines, each padded to width 12 with RenderMarkdownH1Bg.
  eq(#lines, 4)
  eq(markdown.chunks_width(lines[1]), 12)
  eq(markdown.chunks_width(lines[2]), 12)
  eq(lines[1][1], { "H ", { "RenderMarkdownH1", "RenderMarkdownH1Bg" } })
  eq(lines[2][#lines[2]][2], "RenderMarkdownH1Bg")
  eq(lines[3][1], { "*", "RenderMarkdownBullet" })
  eq(lines[4][1], { "[X]", "RenderMarkdownChecked" })
  eq(lines[4][2], { "done" })
end

T["render()"]["applies override highlight for resolved threads across marks"] = function()
  local marks = {
    {
      start_row = 0,
      start_col = 0,
      opts = { virt_text = { { "*", "RenderMarkdownBullet" } }, virt_text_pos = "overlay" },
    },
  }
  eq(
    markdown.render("- done", { width = 20, hl = "DidymusThreadResolved", marks = marks }),
    { { { "* done", "DidymusThreadResolved" } } }
  )
end

return T
