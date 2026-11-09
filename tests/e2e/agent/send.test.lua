local helpers = dofile("tests/e2e/agent/helpers.lua")

local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local lines = { "local a = 1", "local bb = 22", "local c = 3", "return a" }

---@param start_line integer
---@param end_line integer
---@param text string The code.
---@param prompt_text string
---@return didymus.agent.backends.test.Entry[]
local function sent(start_line, end_line, text, prompt_text)
  local context =
    { path = "a.lua", start_line = start_line, end_line = end_line, text = text, filetype = "lua" }
  return { { kind = "send", prompt = { text = prompt_text, context = { context } } } }
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

---@return string?
local function input_title()
  local config = child.api.nvim_win_get_config(0)
  if child.bo.filetype ~= "didymus_input" or not config.title then
    return nil
  end
  return config.title[1][1]
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
      child.lua([[vim.keymap.set({ "n", "x" }, "<Space>s", "<Plug>(didymus-agent-send)")]])
      helpers.edit_code(child, lines)
    end,
    post_once = child.stop,
  },
})

T["the key opens the input float with the location as the title"] = function()
  child.type_keys("2G", "<Space>s")
  eq(input_title(), " a.lua:2 ")
  eq(child.api.nvim_get_mode().mode, "i")
  eq(is_running(), false)
end

T["submit sends one prompt and starts a hidden agent"] = function()
  child.type_keys("2G", "<Space>s", "Explain this.", "<C-y>")

  eq(is_running(), true)
  eq(helpers.prompts(child), sent(2, 2, "local bb = 22", "Explain this."))
  eq(child.lua_get("require('didymus.agent').current():is_visible()"), false)
  eq(#child.api.nvim_list_wins(), 1)
  helpers.expect_message(child, "didymus: sent to `agent`")
end

T["the key in visual mode"] = MiniTest.new_set({
  parametrize = {
    { "2Gvj", 2, 3, "local bb = 22\nl" },
    { "2GVj", 2, 3, "local bb = 22\nlocal c = 3" },
    { "2G<C-v>jl", 2, 3, "lo\nlo" },
  },
})

T["the key in visual mode"]["sends the selection"] = function(keys, start_line, end_line, text)
  child.type_keys(keys, "<Space>s")
  eq(input_title(), (" a.lua:%d-%d "):format(start_line, end_line))
  child.type_keys("Why?", "<C-y>")
  eq(helpers.prompts(child), sent(start_line, end_line, text, "Why?"))
end

T["the input float opens above the selection, or under it"] = function()
  local many = {}
  for i = 1, 20 do
    many[i] = ("local v%d = %d"):format(i, i)
  end
  helpers.edit_code(child, many)

  child.type_keys("15GVj", "<Space>s")
  local above = child.api.nvim_win_get_config(0)
  eq({ above.anchor, above.row }, { "SW", 14 })

  child.type_keys("<Esc>", "q", "1GVj", "<Space>s")
  local under = child.api.nvim_win_get_config(0)
  eq({ under.anchor, under.row }, { "NW", 2 })
end

T["a command range opens the input float for those lines"] = function()
  child.cmd("2,3Didymus agent send")
  eq(input_title(), " a.lua:2-3 ")
end

T["a command with text sends at once"] = function()
  child.cmd("2Didymus agent send Why?")
  eq(helpers.prompts(child), sent(2, 2, "local bb = 22", "Why?"))
  eq(#child.api.nvim_list_wins(), 1)
end

T["send({ text }) sends at once"] = function()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.lua("require('didymus.agent').send({ text = 'Explain this.' })")
  eq(helpers.prompts(child), sent(3, 3, "local c = 3", "Explain this."))
  eq(#child.api.nvim_list_wins(), 1)
end

T["cancel sends nothing and starts no agent"] = function()
  child.type_keys("<Space>s", "text", "<Esc>", "q")
  eq(#child.api.nvim_list_wins(), 1)
  eq(child.lua_get("require('didymus.agent').current()"), vim.NIL)
end

T["agent.input sets the width and the keys of the input float"] = function()
  child.lua("require('didymus').setup(...)", {
    {
      agent = {
        cmd = "agent",
        backend = "test",
        input = { width = 30, keys = { submit = "<C-s>" } },
      },
    },
  })
  child.type_keys("<Space>s")
  eq(child.api.nvim_win_get_width(0), 30)
  child.type_keys("Why?", "<C-s>")
  eq(helpers.prompts(child), sent(1, 1, "local a = 1", "Why?"))
end

T["a buffer with no file shows an error, and opens no input float"] = function()
  child.cmd("enew")
  MiniTest.expect.error(function()
    child.cmd("Didymus agent send")
  end, vim.pesc("didymus: the buffer has no file"))
  eq(#child.api.nvim_list_wins(), 1)
  eq(child.lua_get("require('didymus.agent').current()"), vim.NIL)
end

return T
