local eq = MiniTest.expect.equality
local prompt = require("didymus.agent.prompt")

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({ hooks = { post_once = child.stop } })

---@param overrides table?
---@return didymus.agent.Context
local function make_context(overrides)
  return vim.tbl_extend("force", {
    path = "lua/didymus/init.lua",
    start_line = 10,
    end_line = 10,
    text = "local M = {}",
    filetype = "lua",
  }, overrides or {})
end

T["to_text()"] = MiniTest.new_set()

T["to_text()"]["writes one line, then the prompt text after a blank line"] = function()
  eq(
    prompt.to_text({ text = "Explain this.", context = { make_context() } }),
    "lua/didymus/init.lua:10\n```lua\nlocal M = {}\n```\n\nExplain this."
  )
end

T["to_text()"]["writes a range"] = function()
  eq(
    prompt.to_text({
      text = "Explain this.",
      context = { make_context({ end_line = 12, text = "local M = {}\n\nreturn M" }) },
    }),
    "lua/didymus/init.lua:10-12\n```lua\nlocal M = {}\n\nreturn M\n```\n\nExplain this."
  )
end

T["to_text()"]["makes the fence longer than the longest backtick run"] = function()
  eq(
    prompt.to_text({ text = "Fix it.", context = { make_context({ text = "a ```` b `` c" }) } }),
    "lua/didymus/init.lua:10\n`````lua\na ```` b `` c\n`````\n\nFix it."
  )
end

T["to_text()"]["writes a fence with no filetype"] = function()
  local context = make_context()
  context.filetype = nil
  eq(
    prompt.to_text({ text = "Fix it.", context = { context } }),
    "lua/didymus/init.lua:10\n```\nlocal M = {}\n```\n\nFix it."
  )
end

T["to_text()"]["ends with a newline when there is no prompt text"] = function()
  eq(
    prompt.to_text({ context = { make_context() } }),
    "lua/didymus/init.lua:10\n```lua\nlocal M = {}\n```\n"
  )
end

T["to_text()"]["puts a blank line between contexts"] = function()
  eq(
    prompt.to_text({
      context = { make_context(), make_context({ start_line = 20, end_line = 20 }) },
    }),
    "lua/didymus/init.lua:10\n```lua\nlocal M = {}\n```\n\nlua/didymus/init.lua:20\n```lua\nlocal M = {}\n```\n"
  )
end

T["context()"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.api.nvim_buf_set_name(0, "src/main.lua")
      child.bo.filetype = "lua"
      child.api.nvim_buf_set_lines(
        0,
        0,
        -1,
        true,
        { "local a = 1", "local bb = 22", "local c = 3" }
      )
    end,
  },
})

---@param opts table?
---@return didymus.agent.Context
local function get_context(opts)
  return child.lua_get("require('didymus.agent.prompt').context(...)", { opts or { buf = 0 } })
end

---@param start_line integer
---@param end_line integer
---@param text string
local function expect_context(start_line, end_line, text)
  eq(get_context(), {
    path = "src/main.lua",
    start_line = start_line,
    end_line = end_line,
    text = text,
    filetype = "lua",
  })
end

T["context()"]["uses the current line"] = function()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  expect_context(2, 2, "local bb = 22")
end

T["context()"]["uses a range"] = function()
  local context = get_context({ buf = 0, range = { 2, 3 } })
  eq({ context.start_line, context.end_line, context.text }, { 2, 3, "local bb = 22\nlocal c = 3" })
end

T["context()"]["uses a charwise selection"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 6 })
  child.type_keys("vj")
  expect_context(1, 2, "a = 1\nlocal b")
end

T["context()"]["uses a linewise selection"] = function()
  child.api.nvim_win_set_cursor(0, { 3, 4 })
  child.type_keys("Vk")
  expect_context(2, 3, "local bb = 22\nlocal c = 3")
end

T["context()"]["uses a blockwise selection"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 6 })
  child.type_keys("<C-v>2jll")
  expect_context(1, 3, "a =\nbb \nc =")
end

T["context()"]["uses a blockwise selection to the end of each line"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 6 })
  child.type_keys("<C-v>2j$")
  expect_context(1, 3, "a = 1\nbb = 22\nc = 3")
end

T["context()"]["uses an absolute path for a file outside the current directory"] = function()
  child.api.nvim_buf_set_name(0, "/outside/main.lua")
  eq(get_context().path, "/outside/main.lua")
end

T["context()"]["throws an error for a buffer with no file"] = function()
  child.cmd("enew")
  MiniTest.expect.error(get_context, "didymus: the buffer has no file")
end

return T
