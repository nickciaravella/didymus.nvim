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

---@param opts table
---@return string
local function report(opts)
  child.lua("require('didymus').setup(...)", { opts })
  child.cmd("checkhealth didymus")
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

---@param cmd string|string[]
---@return string
local function check(cmd)
  return report({ agent = { cmd = cmd } })
end

--- The lines of the section `name`, from its heading to the next heading.
---@param opts table
---@param name string
---@return string
local function section(opts, name)
  local lines, found = {}, false
  for line in vim.gsplit(report(opts), "\n") do
    local heading = line:match("^(%S.*) ~$")
    if heading then
      found = heading == name
    elseif found then
      table.insert(lines, line)
    end
  end
  return table.concat(lines, "\n")
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

T["didymus review"] = MiniTest.new_set()

T["didymus review"]["shows an error if snacks.nvim is not available"] = function()
  local text = section({}, "didymus review")
  expect_text(text, "ERROR snacks.nvim is not available (review.picker)")
  expect_text(text, "Install snacks.nvim, or set `review.picker`.")
end

T["didymus review"]["shows no error with the test picker"] = function()
  local text = section({ review = { picker = "test" } }, "didymus review")
  expect_text(text, "OK the test picker is configured (review.picker)")
  MiniTest.expect.equality(text:find("ERROR", 1, true), nil)
end

T["didymus review"]["shows an error for an unknown picker"] = function()
  local text = section({ review = { picker = "unknown" } }, "didymus review")
  expect_text(text, 'ERROR unknown picker "unknown". Use "snacks", "test" or an adapter table.')
end

return T
