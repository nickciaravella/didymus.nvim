local helpers = dofile("tests/e2e/agent/helpers.lua")

local eq = MiniTest.expect.equality
local no_eq = MiniTest.expect.no_equality

local child = MiniTest.new_child_neovim()

---@return integer?
local function agent_buf()
  return helpers.agent_buf(child)
end

---@param text string
local function expect_message(text)
  no_eq(child.cmd_capture("messages"):find(text, 1, true), nil)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 24, 80
      child.cmd("runtime plugin/didymus.lua")
      child.lua(
        "require('didymus').setup(...)",
        { { agent = { cmd = "agent", backend = "test" } } }
      )
    end,
    post_once = child.stop,
  },
})

T["toggle shows the test buffer in the split"] = function()
  child.cmd("Didymus agent toggle")

  local layout = child.fn.winlayout()
  eq(layout[1], "row")
  local agent_win = layout[2][2][2]
  eq(child.api.nvim_get_current_win(), agent_win)
  eq(child.api.nvim_win_get_buf(agent_win), agent_buf())
  eq(child.api.nvim_get_option_value("buftype", { buf = agent_buf() }), "nofile")
  eq(child.api.nvim_get_option_value("channel", { buf = agent_buf() }), 0)
  eq(child.api.nvim_get_mode().mode, "n")
end

T["append and send record the prompts, and the buffer shows their text"] = function()
  local context =
    { path = "a.lua", start_line = 3, end_line = 3, text = "local a = 1", filetype = "lua" }
  local appended = { context = { context } }
  local sent = { text = "Explain this.", context = { context } }
  child.lua("require('didymus.agent').start()")
  child.lua("require('didymus.agent').current():append(...)", { appended })
  child.lua("require('didymus.agent').current():send(...)", { sent })

  eq(helpers.prompts(child), {
    { kind = "append", prompt = appended },
    { kind = "send", prompt = sent },
  })
  eq(helpers.agent_lines(child), {
    "append:",
    "a.lua:3",
    "```lua",
    "local a = 1",
    "```",
    "send:",
    "a.lua:3",
    "```lua",
    "local a = 1",
    "```",
    "",
    "Explain this.",
  })
end

T["exit shows the exit code, and the next toggle starts a new session"] = function()
  child.cmd("Didymus agent toggle")
  local old_buf = agent_buf()

  helpers.exit(child, 3)
  eq(child.lua_get("require('didymus.agent').current():is_running()"), false)
  expect_message("didymus: `agent` exited with code 3")
  eq(child.api.nvim_buf_is_valid(old_buf), true)

  child.cmd("Didymus agent toggle")
  eq(#child.api.nvim_list_wins(), 1)

  child.cmd("Didymus agent toggle")
  expect_message("didymus: new conversation with `agent`")
  eq(child.api.nvim_buf_is_valid(old_buf), false)
  eq(child.api.nvim_get_current_buf(), agent_buf())
  eq(helpers.prompts(child), {})
end

T["an unknown backend shows an error"] = function()
  child.lua("require('didymus').setup(...)", { { agent = { backend = "other" } } })
  MiniTest.expect.error(function()
    child.cmd("Didymus agent start")
  end, vim.pesc('cannot start `claude`: unknown backend "other"'))
  eq(child.lua_get("require('didymus.agent').current()"), vim.NIL)
end

return T
