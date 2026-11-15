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
  -- The default `github` provider runs `gh auth status`, which uses the network.
  opts = vim.tbl_deep_extend("keep", opts, { review = { provider = "test" } })
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

--- Make the $PATH of the child a new directory. If `script` is given, put a fake `gh` in it.
---@param script string? The shell code of the fake `gh`.
local function set_path(script)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  if script then
    local path = vim.fs.joinpath(dir, "gh")
    vim.fn.writefile({ "#!/bin/sh", script }, path)
    vim.uv.fs_chmod(path, tonumber("755", 8))
  end
  child.lua("vim.env.PATH = ...", { dir })
end

local github = { review = { picker = "test", provider = "github" } }

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

T["didymus review"]["shows OK with the test provider"] = function()
  local text = section({ review = { picker = "test" } }, "didymus review")
  expect_text(text, "OK the test provider is configured (review.provider)")
end

T["didymus review"]["shows an error for an unknown provider"] = function()
  local text = section({ review = { provider = "unknown" } }, "didymus review")
  expect_text(text, 'ERROR unknown provider "unknown". Use "github", "test" or a provider table.')
  expect_text(text, "Set `review.provider`.")
end

T["didymus review"]["shows an error if gh is not on $PATH"] = function()
  set_path()
  local text = section(github, "didymus review")
  expect_text(text, "ERROR `gh` is not on $PATH (review.provider)")
  expect_text(text, "Install the GitHub CLI, or set `review.provider`.")
end

T["didymus review"]["shows the message of gh if gh auth status fails"] = function()
  set_path([[echo "fake gh: $*" >&2; exit 1]])
  local text = section(github, "didymus review")
  expect_text(text, "ERROR `gh auth status` failed (review.provider)")
  expect_text(text, "fake gh: auth status --active")
  expect_text(text, "Run `gh auth login`, or set `review.provider`.")
end

T["didymus review"]["shows OK if gh is authenticated"] = function()
  set_path("exit 0")
  local text = section(github, "didymus review")
  expect_text(text, "OK `gh` is authenticated (review.provider)")
  MiniTest.expect.equality(text:find("ERROR", 1, true), nil)
end

return T
