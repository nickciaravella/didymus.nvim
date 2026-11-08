local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
    end,
    post_once = child.stop,
  },
})

---@param cmd string|string[]
---@return string
local function check(cmd)
  child.lua("require('didymus').setup({ agent = { cmd = ... } })", { cmd })
  child.cmd("checkhealth didymus")
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

---@param report string
---@param text string
local function expect_text(report, text)
  if not report:find(text, 1, true) then
    error(("%q is not in the report:\n%s"):format(text, report), 0)
  end
end

T["a program on $PATH gives OK"] = function()
  expect_text(check("git"), "OK `git` is on $PATH (agent.cmd)")
end

T["a missing program gives a warning that names the program"] = function()
  local report = check("didymus-missing-program")
  expect_text(report, "WARNING `didymus-missing-program` is not on $PATH (agent.cmd)")
  expect_text(report, "Install it, or set `agent.cmd`.")
end

T["a string command with arguments checks only the program"] = function()
  expect_text(check("git --missing-flag value"), "OK `git` is on $PATH (agent.cmd)")
end

T["a list command checks its first item"] = function()
  expect_text(check({ "git", "--missing-flag" }), "OK `git` is on $PATH (agent.cmd)")
end

return T
