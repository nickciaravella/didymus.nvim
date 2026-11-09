local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

---@param opts table? More options for `review`.
local function setup(opts)
  child.lua(
    "require('didymus').setup({ review = ... })",
    { vim.tbl_extend("force", { picker = "test", provider = "test" }, opts or {}) }
  )
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      setup()
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
    end,
    post_once = child.stop,
  },
})

local make_thread = helpers.make_thread

---@type didymus.test.Repo
local repo

--- A thread from octocat at `line` of file.txt.
---@param id string
---@param line integer
---@param fields table? The fields to change, such as `comments`.
---@return didymus.review.Thread
local function line_thread(id, line, fields)
  return make_thread(
    id,
    "file.txt",
    vim.tbl_extend("force", { range = { first = line, last = line } }, fields or {})
  )
end

--- Make a repo where the change modifies line 2 of file.txt. Make it the directory of the child.
--- Open the review with `threads`, wait for them, and edit file.txt.
---@param threads didymus.review.Thread[]? Default: one thread on line 3.
---@param id string? The id for `open`. Default "1".
local function open_review(threads, id)
  threads = threads or { line_thread("old", 3) }
  local lines = {}
  for line = 1, 20 do
    lines[line] = "line " .. line
  end
  local base = table.concat(lines, "\n") .. "\n"
  repo = helpers.make_repo({
    base = { ["file.txt"] = base },
    head = { ["file.txt"] = (base:gsub("line 2\n", "LINE 2\n", 1)) },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads)
  child.cmd("Didymus review open " .. (id or "1"))
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, #threads)
  child.cmd("edit file.txt")
end

---@param text string
---@return boolean
local function has_message(text)
  return child.cmd_capture("messages"):find(text, 1, true) ~= nil
end

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return has_message(text)
  end, function()
    return ("%q is not in the messages:\n%s"):format(text, child.cmd_capture("messages"))
  end)
end

--- The texts of the panel rows.
---@return string[]
local function panel_rows()
  return vim.tbl_map(function(item)
    return item.text
  end, helpers.picker_calls(child, "panel")[1].items)
end

--- The ids of the threads of the session.
---@return string[]
local function thread_ids()
  return child.lua_get([[vim.tbl_map(function(thread)
    return thread.id
  end, require("didymus.review").current().threads)]])
end

--- The lines of the thread marks in the current buffer, 1-based.
---@return integer[]
local function mark_lines()
  return child.lua_get(
    [[vim.tbl_map(function(mark)
    return mark[2] + 1
  end, vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("didymus.review"), 0, -1, {}))]]
  )
end

---@return integer?
local function float_win()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    if child.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

--- Run the refresh. Wait for the message at its end.
---@param message string? Default "didymus: refreshed #1".
local function refresh(message)
  message = message or "didymus: refreshed #1"
  child.cmd("messages clear")
  child.cmd("Didymus review refresh")
  wait_for_message(message)
end

T["a refresh shows the new threads and the new data of the change"] = function()
  open_review()
  -- The progress messages do not go into the message history.
  child.lua([[
    _G.progress = {}
    local echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, history, opts)
      if opts.kind == "progress" then
        table.insert(_G.progress, { chunks[1][1], opts.status })
      end
      return echo(chunks, history, opts)
    end
  ]])
  local change = vim.deepcopy(repo.change)
  change.title = "A new title"
  helpers.set_changes(child, { change })
  helpers.set_threads(child, "1", {
    line_thread("old", 3),
    line_thread("new", 2, { comments = { { author = "hubot", body = "New.", pending = false } } }),
  })

  refresh()
  eq(child.lua_get("_G.progress"), { { "refresh #1", "running" }, { "refresh #1", "success" } })
  eq(thread_ids(), { "new", "old" })
  eq(panel_rows(), {
    "#1 A new title",
    "@octocat main ← feature",
    "M file.txt +1 -1 2 threads",
    "@hubot New.",
    "@octocat A comment.",
  })
  eq(mark_lines(), { 2, 3 })
end

T["a refresh gets the change with the id of open"] = function()
  -- The provider gives `id = "1"` for the URL, as the GitHub provider gives the PR number.
  child.lua([[
    local provider = require("didymus.review.provider.test")
    local get_change = provider.get_change
    _G.ids = {}
    provider.get_change = function(self, id, cb)
      table.insert(_G.ids, id)
      get_change(self, id == "https://github.com/o/r/pull/1" and "1" or id, cb)
    end
  ]])
  open_review(nil, "https://github.com/o/r/pull/1")
  refresh()
  eq(child.lua_get("_G.ids"), { "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/1" })
end

T["a new head shows a warning, and HEAD does not change"] = function()
  open_review()
  local old_head = repo.change.head_sha
  local change = vim.deepcopy(repo.change)
  -- As on GitHub, git does not have the commit of the new head before a fetch.
  change.head_sha = ("a"):rep(40)
  helpers.set_changes(child, { change })

  refresh(
    "didymus: refreshed #1. Its head is now aaaaaaa, but HEAD did not change. To check it out, "
      .. "close the review and open it again."
  )
  eq(vim.trim(helpers.git(repo.dir, { "rev-parse", "HEAD" })), old_head)
  eq(child.lua_get("require('didymus.review').current().change.head_sha"), change.head_sha)

  -- The same head on the next refresh gives no warning.
  refresh()
end

T["a comment after a new head shows the reason, but a reply works"] = function()
  open_review()
  local change = vim.deepcopy(repo.change)
  change.head_sha = ("a"):rep(40)
  helpers.set_changes(child, { change })
  refresh("didymus: refreshed #1. Its head is now aaaaaaa")

  child.cmd("messages clear")
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review comment")
  wait_for_message(
    "didymus: HEAD is not the head of #1. To check it out, close the review and open it again."
  )
  eq(has_message("git diff"), false)
  eq(float_win(), nil)

  -- A reply has no line numbers, so it does not need the head.
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review reply")
  wait_for(function()
    return float_win() ~= nil
  end, "the input float")
  eq(child.api.nvim_win_get_config(float_win()).title[1][1], " Reply to file.txt:3 ")
end

T["R in the panel refreshes"] = function()
  open_review()
  helpers.set_threads(child, "1", { line_thread("old", 3), line_thread("new", 4) })
  child.lua("require('didymus.ui.picker.test').press('R')")
  wait_for_message("didymus: refreshed #1")
  eq(thread_ids(), { "old", "new" })
end

T["review.panel.keys.refresh = false turns off the key"] = function()
  setup({ panel = { keys = { refresh = false } } })
  open_review()
  eq(child.lua_get("require('didymus.ui.picker.test').calls[1].opts.actions"), {})
end

T["an error shows the message, and the review keeps its data"] = MiniTest.new_set({
  parametrize = { { "get_change" }, { "get_threads" } },
})

T["an error shows the message, and the review keeps its data"]["of"] = function(method)
  open_review()
  local change = vim.deepcopy(repo.change)
  change.title = "A new title"
  helpers.set_changes(child, { change })
  helpers.set_threads(child, "1", { line_thread("old", 3), line_thread("new", 4) })
  child.lua("require('didymus.review.provider.test').errors[...] = 'no network'", { method })

  refresh("didymus: cannot refresh #1: no network")
  eq(thread_ids(), { "old" })
  eq(panel_rows()[1], "#1 Change the second line")
end

T["only the newest refresh applies"] = function()
  open_review()
  -- The first get of the threads replies after the second one.
  child.lua([[
    local provider = require("didymus.review.provider.test")
    local count = 0
    provider.get_threads = function(_, _, cb)
      count = count + 1
      local id, delay = "first", 200
      if count == 2 then
        id, delay = "second", 0
      end
      vim.defer_fn(function()
        cb(nil, { { id = id, path = "file.txt", side = "head", range = { first = 3, last = 3 },
          resolved = false, outdated = false, can_reply = true, can_resolve = true,
          can_unresolve = false, comments = { { author = "octocat", body = id, pending = false } } } })
      end, delay)
    end
  ]])
  child.cmd("Didymus review refresh")
  child.cmd("Didymus review refresh")
  wait_for(function()
    return vim.deep_equal(thread_ids(), { "second" })
  end, "the threads of the second refresh")
  child.lua("vim.wait(300)")
  eq(thread_ids(), { "second" })
end

T["just after a discard, a refresh has no pending comments"] = function()
  open_review({
    line_thread("old", 3),
    line_thread("new", 4, { comments = { { author = "reviewer", body = "P.", pending = true } } }),
  })
  -- As on GitHub, the threads of the discarded review stay for a few seconds.
  child.lua([[
    require("didymus.review.provider.test").discard_review = function(_, _, cb)
      vim.schedule(cb)
    end
  ]])
  child.cmd("Didymus review discard")
  child.lua("require('didymus.ui.picker.test').choose('Discard')")
  helpers.wait_for_threads(child, 1)
  refresh()
  eq(thread_ids(), { "old" })

  -- Some seconds later, a pending comment from the provider is real.
  child.lua("require('didymus.review').current().discarded_at = vim.uv.now() - 20000")
  refresh()
  eq(thread_ids(), { "old", "new" })
end

T["after a discard, a new comment shows the pending comments on a refresh"] = function()
  open_review({
    line_thread("old", 3),
    line_thread("new", 4, { comments = { { author = "reviewer", body = "P.", pending = true } } }),
  })
  child.lua([[
    require("didymus.review.provider.test").discard_review = function(_, _, cb)
      vim.schedule(cb)
    end
  ]])
  child.cmd("Didymus review discard")
  child.lua("require('didymus.ui.picker.test').choose('Discard')")
  helpers.wait_for_threads(child, 1)

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review comment")
  wait_for(function()
    return float_win() ~= nil
  end, "the input float")
  child.type_keys("Added.", "<C-s>")
  wait_for_message("didymus: added a pending comment at file.txt:2")
  refresh()
  eq(thread_ids(), { "added-1", "old", "new" })
end

T["with no open review, a warning shows"] = function()
  child.cmd("Didymus review refresh")
  eq(has_message("didymus: no review is open"), true)
end

T["the mapping refreshes"] = function()
  open_review()
  helpers.set_threads(child, "1", { line_thread("old", 3), line_thread("new", 4) })
  child.lua("vim.keymap.set('n', 'gR', '<Plug>(didymus-review-refresh)')")
  child.type_keys("gR")
  wait_for_message("didymus: refreshed #1")
  eq(thread_ids(), { "old", "new" })
end

return T
