local helpers = dofile("tests/e2e/agent/helpers.lua")
local prompt = require("didymus.agent.prompt")

local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

---@param path string
---@param text string
---@return didymus.agent.Context
local function make_context(path, text)
  local _, newlines = text:gsub("\n", "")
  return { path = path, start_line = 1, end_line = 1 + newlines, text = text, filetype = "lua" }
end

--- The rows of the fake agent events: paste, key and submitted.
---@return string[]
local function get_events()
  return vim.tbl_filter(function(line)
    return line:match("^%a+: ") ~= nil
  end, helpers.agent_lines(child))
end

local function wait_for_submit()
  helpers.wait_for_text(child, "submitted: ")
end

--- The text of a prompt, as the fake agent shows it.
---@param p didymus.agent.Prompt
---@return string
local function quote(p)
  return vim.inspect(prompt.to_text(p))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      -- Make the hidden terminal wide, so that each event of the fake agent fits on one row.
      child.o.lines, child.o.columns = 24, 250
      child.cmd("runtime plugin/didymus.lua")
      child.lua("require('didymus').setup(...)", {
        { agent = { cmd = helpers.fake_cmd("--name", "input"), terminal = { ready_delay = 10 } } },
      })
    end,
    post_once = child.stop,
  },
})

T["send submits multi-line text as one message"] = function()
  local sent =
    { text = "Explain this.", context = { make_context("a.lua", "local a = 1\nreturn a") } }
  child.lua("require('didymus.agent').start()")
  helpers.wait_for_text(child, "fake agent input")

  child.lua("require('didymus.agent').current():send(...)", { sent })
  wait_for_submit()
  eq(get_events(), { "paste: " .. quote(sent), "submitted: " .. quote(sent) })
end

T["append puts the text in the agent input and does not submit"] = function()
  local appended = { context = { make_context("a.lua", "x") } }
  local sent = { text = "Why?", context = { make_context("b.lua", "y") } }
  child.lua("require('didymus.agent').start()")
  helpers.wait_for_text(child, "fake agent input")

  -- A submit after the append would show the appended text alone, before the send.
  child.lua("require('didymus.agent').current():append(...)", { appended })
  child.lua("require('didymus.agent').current():send(...)", { sent })
  wait_for_submit()
  eq(get_events(), {
    "paste: " .. quote(appended),
    "paste: " .. quote(sent),
    "submitted: " .. vim.inspect(prompt.to_text(appended) .. prompt.to_text(sent)),
  })
end

T["input before the agent is ready arrives one time, after the agent is ready"] = function()
  local sent = { text = "Explain this.", context = { make_context("a.lua", "x") } }
  -- The agent cannot write output before this call returns, so the input waits in the queue.
  child.lua(
    [[
      local agent = require('didymus.agent')
      agent.start()
      agent.current():send(...)
    ]],
    { sent }
  )
  wait_for_submit()
  -- Input before the agent sets raw mode shows as an echo of the pty, above the banner.
  eq(helpers.agent_lines(child)[1], "fake agent input")
  eq(get_events(), { "paste: " .. quote(sent), "submitted: " .. quote(sent) })
end

T["append puts the context in the agent input, and the user submits it"] = function()
  helpers.edit_code(child, { "local a = 1" })
  child.lua("require('didymus.agent').append()")
  helpers.wait_for_text(child, "paste: ")
  -- The split has focus in terminal mode, so the next key goes to the agent.
  helpers.wait_for_mode(child, "t")
  child.type_keys("<CR>")
  wait_for_submit()

  local appended = {
    context = {
      { path = "a.lua", start_line = 1, end_line = 1, text = "local a = 1", filetype = "lua" },
    },
  }
  -- A submit by append would show a second "submitted" row.
  eq(get_events(), { "paste: " .. quote(appended), "submitted: " .. quote(appended) })
end

return T
