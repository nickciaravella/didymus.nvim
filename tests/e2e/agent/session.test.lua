local helpers = dofile("tests/e2e/agent/helpers.lua")

local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local fake_cmd, wait_for = helpers.fake_cmd, helpers.wait_for

---@return integer?
local function agent_buf()
  return helpers.agent_buf(child)
end

---@param text string
local function wait_for_text(text)
  helpers.wait_for_text(child, text)
end

---@param mode string
local function wait_for_mode(mode)
  helpers.wait_for_mode(child, mode)
end

---@param text string
local function expect_message(text)
  helpers.expect_message(child, text)
end

--- Wait until the last screen line shows `text`. A redraw can clear a message that is in :messages.
---@param text string
local function wait_for_screen_message(text)
  wait_for(function()
    local screen = child.get_screenshot().text
    return table.concat(screen[#screen]):find(text, 1, true) ~= nil
  end, "screen message " .. text)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 24, 80
      child.cmd("runtime plugin/didymus.lua")
      child.lua(
        "require('didymus').setup(...)",
        { { agent = { cmd = fake_cmd("--name", "config") } } }
      )
    end,
    post_once = child.stop,
  },
})

T["toggle shows the agent in a split on the right, in terminal mode"] = function()
  child.cmd("Didymus agent toggle")
  wait_for_text("fake agent config")

  local layout = child.fn.winlayout()
  eq(layout[1], "row")
  eq(#layout[2], 2)
  local agent_win = layout[2][2][2]
  eq(child.api.nvim_get_current_win(), agent_win)
  eq(child.api.nvim_win_get_buf(agent_win), agent_buf())
  eq(child.api.nvim_win_get_width(agent_win), 32)
  eq(child.api.nvim_get_option_value("number", { win = agent_win }), false)
  wait_for_mode("t")
end

T["toggle hides the split, the agent continues, and toggle shows the same buffer"] = function()
  child.api.nvim_set_keymap("t", "<C-q>", "<Plug>(didymus-agent-toggle)", {})
  child.cmd("Didymus agent toggle")
  wait_for_text("fake agent config")
  local buf = agent_buf()
  wait_for_mode("t")

  child.type_keys("<C-q>")
  eq(#child.api.nvim_list_wins(), 1)
  eq(child.lua_get("require('didymus.agent').current():is_running()"), true)

  child.cmd("Didymus agent toggle")
  eq(#child.api.nvim_list_wins(), 2)
  eq(child.api.nvim_get_current_buf(), buf)
end

T["start runs the agent with no window"] = function()
  child.cmd("Didymus agent start")
  wait_for_text("fake agent config")
  eq(#child.api.nvim_list_wins(), 1)
  expect_message("didymus: started `")

  child.cmd("Didymus agent toggle")
  eq(child.api.nvim_get_current_buf(), agent_buf())
end

T["stop ends the agent, closes the split and deletes the buffer"] = function()
  child.cmd("Didymus agent toggle")
  wait_for_text("fake agent config")
  local buf = agent_buf()
  local pid = child.lua_get("vim.fn.jobpid(vim.bo[...].channel)", { buf })

  child.cmd("Didymus agent stop")
  eq(#child.api.nvim_list_wins(), 1)
  eq(child.api.nvim_buf_is_valid(buf), false)
  wait_for(function()
    return vim.uv.kill(pid, 0) == nil
  end, "the agent process ends")
end

T["the cmd of the command overrides agent.cmd"] = function()
  local cmd = table.concat(vim.tbl_map(vim.fn.shellescape, fake_cmd("--name", "command")), " ")
  child.cmd("Didymus agent toggle split " .. cmd)
  wait_for_text("fake agent command")
end

T["the cmd of the Lua API overrides agent.cmd"] = function()
  child.lua("require('didymus.agent').start({ cmd = ... })", { fake_cmd("--name", "lua") })
  wait_for_text("fake agent lua")
end

T["a different cmd does not replace a running agent"] = function()
  child.cmd("Didymus agent start")
  wait_for_text("fake agent config")
  local buf = agent_buf()

  child.lua("require('didymus.agent').toggle({ cmd = ... })", { fake_cmd("--name", "other") })
  eq(child.api.nvim_get_current_buf(), buf)
  expect_message("To start `")
end

T["after an exit, the buffer stays, and the next toggle starts a new conversation"] = function()
  -- The command of the fake agent is long. The exit message must fit on one line.
  child.o.columns = 250
  child.lua("require('didymus.agent').toggle({ cmd = ... })", { fake_cmd("--exit", "3") })
  wait_for_text("fake agent")
  local old_buf = agent_buf()
  wait_for_mode("t")
  child.type_keys("<CR>")
  wait_for(function()
    return child.lua_get("require('didymus.agent').current():is_running()") == false
  end, "the agent exits")
  wait_for_screen_message("exited with code 3")

  -- A key in terminal mode after the exit deletes the buffer. didymus leaves terminal mode first.
  wait_for_mode("nt")
  child.type_keys("k")
  eq(child.api.nvim_buf_is_valid(old_buf), true)
  eq(child.api.nvim_get_current_buf(), old_buf)

  child.cmd("Didymus agent toggle")
  eq(#child.api.nvim_list_wins(), 1)

  child.cmd("Didymus agent toggle")
  wait_for_text("fake agent config")
  expect_message("didymus: new conversation with `")
  eq(child.api.nvim_buf_is_valid(old_buf), false)
  eq(child.api.nvim_get_current_buf(), agent_buf())
end

T[":Didymus completes the agent commands"] = function()
  eq(child.fn.getcompletion("Didymus ", "cmdline"), { "agent" })
  eq(
    child.fn.getcompletion("Didymus agent ", "cmdline"),
    { "append", "focus", "send", "start", "stop", "toggle" }
  )
  eq(child.fn.getcompletion("Didymus agent t", "cmdline"), { "toggle" })
  eq(child.fn.getcompletion("Didymus agent toggle ", "cmdline"), { "float", "split" })
end

return T
