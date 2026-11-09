local helpers = dofile("tests/e2e/agent/helpers.lua")

local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local lines = { "local a = 1", "local bb = 22", "local c = 3", "return a" }

---@param start_line integer
---@param end_line integer
---@param text string
---@return didymus.agent.backends.test.Entry[]
local function appended(start_line, end_line, text)
  local context =
    { path = "a.lua", start_line = start_line, end_line = end_line, text = text, filetype = "lua" }
  return { { kind = "append", prompt = { context = { context } } } }
end

---@return boolean
local function is_running()
  return child.lua_get([[
    (function()
      local session = require("didymus.agent").current()
      return session ~= nil and session:is_running()
    end)()
  ]])
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
      child.lua([[vim.keymap.set({ "n", "x" }, "<Space>a", "<Plug>(didymus-agent-append)")]])
      helpers.edit_code(child, lines)
    end,
    post_once = child.stop,
  },
})

T["the key in normal mode appends the line, starts the agent and focuses the split"] = function()
  eq(is_running(), false)
  child.type_keys("2G", "<Space>a")

  eq(is_running(), true)
  eq(helpers.prompts(child), appended(2, 2, "local bb = 22"))
  eq(child.api.nvim_get_current_buf(), helpers.agent_buf(child))
  eq(child.lua_get("require('didymus.agent').current():is_visible('split')"), true)
end

T["the key in visual mode"] = MiniTest.new_set({
  parametrize = {
    { "2Gvj", 2, 3, "local bb = 22\nl" },
    { "2GVj", 2, 3, "local bb = 22\nlocal c = 3" },
    { "2G<C-v>jl", 2, 3, "lo\nlo" },
  },
})

T["the key in visual mode"]["appends the selection and leaves visual mode"] = function(
  keys,
  start_line,
  end_line,
  text
)
  child.type_keys(keys, "<Space>a")
  eq(helpers.prompts(child), appended(start_line, end_line, text))
  eq(child.fn.mode(), "n")
end

T["a command range appends those lines"] = function()
  child.cmd("2,3Didymus agent append")
  eq(helpers.prompts(child), appended(2, 3, "local bb = 22\nlocal c = 3"))
end

T["a command with no range appends the current line"] = function()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus agent append")
  eq(helpers.prompts(child), appended(3, 3, "local c = 3"))
end

T["the view option shows that view"] = function()
  child.lua("require('didymus.agent').append({ view = 'float' })")
  eq(child.lua_get("require('didymus.agent').current():is_visible('float')"), true)
  eq(child.api.nvim_get_current_buf(), helpers.agent_buf(child))
end

T["a second append goes to the same agent"] = function()
  child.cmd("1Didymus agent append")
  local buf = helpers.agent_buf(child)
  child.cmd("wincmd p")
  child.cmd("4Didymus agent append")

  eq(helpers.agent_buf(child), buf)
  eq(#helpers.prompts(child), 2)
  eq(#child.api.nvim_list_wins(), 2)
end

T["a buffer with no file shows an error, and starts no agent"] = function()
  child.cmd("enew")
  MiniTest.expect.error(function()
    child.cmd("Didymus agent append")
  end, vim.pesc("didymus: the buffer has no file"))
  eq(child.lua_get("require('didymus.agent').current()"), vim.NIL)
  eq(#child.api.nvim_list_wins(), 1)
end

return T
