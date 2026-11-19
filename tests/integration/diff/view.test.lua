-- The diff view of a review with the real gitsigns: the flow from the open of a file to the close.

local review_helpers = dofile("tests/e2e/review/helpers.lua")
local helpers = dofile("tests/integration/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.restart(child, { "gitsigns.nvim" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua("require('gitsigns').setup()")
      child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
    end,
    post_once = child.stop,
  },
})

---@return didymus.test.Repo
local function open_review()
  local repo = review_helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n" },
    head = { ["file.txt"] = "one\n2\nthree\n" },
  })
  child.fn.chdir(repo.dir)
  review_helpers.set_changes(child, { repo.change })
  review_helpers.set_threads(child, "1", {})
  child.cmd("Didymus review open 1")
  review_helpers.wait_for_review(child, "1")
  child.lua("require('didymus.ui.picker.test').choose('M file.txt +1 -1')")
  return repo
end

---@return boolean
local function has_view()
  return child.lua_get(
    "require('gitsigns.unified').get_view(vim.api.nvim_get_current_win()) ~= nil"
  )
end

--- The base of the gitsigns hunks of the current buffer. Nil is the index.
---@return string?
local function base()
  local revision = child.lua_get([[
    (function()
      local entry = require("gitsigns.cache").cache[vim.api.nvim_get_current_buf()]
      return entry and entry.git_obj.revision
    end)()
  ]])
  return revision ~= vim.NIL and revision or nil
end

T["the code window shows the unified view against the merge-base, and toggle hides it"] = function()
  local repo = open_review()
  wait_for(has_view, "the unified view")
  eq(base(), repo.change.base_sha)
  eq(child.lua_get("#require('gitsigns').get_hunks(0)"), 1)

  child.cmd("Didymus diff toggle")
  eq(has_view(), false)
  wait_for(function()
    return base() == nil
  end, "the base of the gitsigns config")

  child.cmd("Didymus diff toggle")
  wait_for(has_view, "the unified view after toggle")
end

T["the close of the review puts back the base of the gitsigns config"] = function()
  open_review()
  wait_for(has_view, "the unified view")
  local buf = child.api.nvim_get_current_buf()

  child.cmd("Didymus review close")
  child.cmd("buffer " .. buf)
  wait_for(function()
    return base() == nil
  end, "the base of the gitsigns config")
  eq(has_view(), false)
end

T["with no gitsigns, a warning shows and the review works"] = function()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.cmd("runtime plugin/didymus.lua")
  child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
  child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
  open_review()
  wait_for(function()
    return child.cmd_capture("messages"):find(
      "didymus: cannot show the diff of file.txt: gitsigns.nvim is not available",
      1,
      true
    ) ~= nil
  end, "the warning")
  eq(child.fn.expand("%:t"), "file.txt")
end

return T
