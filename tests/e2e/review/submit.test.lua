local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
    end,
    post_once = child.stop,
  },
})

local make_thread = helpers.make_thread

--- A submitted thread on line 3 with a pending reply, and a new pending thread on line 19.
---@return didymus.review.Thread[]
local function pending_threads()
  return {
    make_thread("old", "file.txt", {
      range = { first = 3, last = 3 },
      comments = {
        { author = "octocat", body = "A comment.", pending = false },
        { author = "reviewer", body = "A pending reply.", pending = true },
      },
    }),
    make_thread("new", "file.txt", {
      range = { first = 19, last = 19 },
      comments = { { author = "reviewer", body = "A pending comment.\nMore.", pending = true } },
    }),
  }
end

--- Make a repo where the change modifies line 2 of file.txt. Make it the directory of the child.
--- Open the review with `threads`, wait for them, and edit file.txt.
---@param threads didymus.review.Thread[]? Default: `pending_threads()`.
local function open_review(threads)
  threads = threads or pending_threads()
  local lines = {}
  for line = 1, 20 do
    lines[line] = "line " .. line
  end
  local base = table.concat(lines, "\n") .. "\n"
  local repo = helpers.make_repo({
    base = { ["file.txt"] = base },
    head = { ["file.txt"] = (base:gsub("line 2\n", "LINE 2\n", 1)) },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads)
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, #threads)
  child.cmd("edit file.txt")
end

---@param target integer|string
local function choose(target)
  child.lua("require('didymus.ui.picker.test').choose(...)", { target })
end

---@return integer?
local function float_win()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    if child.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

--- Wait for the input float, and give its title, its footer and its lines.
---@return { title: string, footer: string?, lines: string[] }
local function wait_for_input()
  wait_for(function()
    local win = float_win()
    local buf = win and child.api.nvim_win_get_buf(win)
    return buf ~= nil
      and child.api.nvim_get_option_value("filetype", { buf = buf }) == "didymus_input"
  end, "the input float")
  local win = assert(float_win())
  local config = child.api.nvim_win_get_config(win)
  return {
    title = config.title[1][1],
    footer = config.footer and config.footer[1][1],
    lines = child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, true),
  }
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

--- The reviews that the test provider submitted.
---@return { change_id: string, verdict: string, body: string? }[]
local function provider_reviews()
  return child.lua_get("require('didymus.review.provider.test').reviews")
end

--- The id and the comment bodies of each thread, in the test provider and in the session.
---@return { provider: table, session: table }
local function thread_bodies()
  local function bodies(threads)
    return vim.tbl_map(function(thread)
      return {
        thread.id,
        vim.tbl_map(function(comment)
          return comment.body
        end, thread.comments),
      }
    end, threads)
  end
  return {
    provider = bodies(child.lua_get("require('didymus.review.provider.test').threads['1']")),
    session = bodies(child.lua_get("require('didymus.review').current().threads")),
  }
end

--- The texts of the panel rows of the threads.
---@return string[]
local function panel_thread_rows()
  local rows = {}
  for _, item in ipairs(helpers.picker_calls(child, "panel")[1].items) do
    if vim.startswith(item.id, "thread:") then
      table.insert(rows, item.text)
    end
  end
  return rows
end

---@return integer
local function pending_count()
  return child.lua_get("#require('didymus.review').current():get_pending_comments()")
end

T["submit with each verdict sends the verdict and the body"] = MiniTest.new_set({
  parametrize = {
    { "comment", " Comment on #1 ", "didymus: commented on #1" },
    { "approve", " Approve #1 ", "didymus: approved #1" },
    { "request_changes", " Request changes on #1 ", "didymus: requested changes on #1" },
  },
})

T["submit with each verdict sends the verdict and the body"]["with"] = function(
  verdict,
  title,
  message
)
  open_review()
  child.cmd("Didymus review submit " .. verdict)
  eq(wait_for_input(), { title = title, footer = " <C-s> submit  q cancel ", lines = { "" } })
  child.type_keys("Two notes.", "<CR>", "See the threads.", "<C-s>")
  wait_for_message(message)
  eq(
    provider_reviews(),
    { { change_id = "1", verdict = verdict, body = "Two notes.\nSee the threads." } }
  )

  -- The review gets the threads again, and the comments are not pending now.
  wait_for(function()
    return pending_count() == 0
  end, "no pending comments")
  eq(panel_thread_rows(), { "@octocat A comment.", "@reviewer A pending comment." })
end

T["submit with no verdict shows the verdicts in the picker"] = function()
  open_review()
  child.cmd("Didymus review submit")
  local select = helpers.picker_calls(child, "select")[1]
  eq(select.title, "Submit the review of #1")
  eq(
    vim.tbl_map(function(item)
      return item.text
    end, select.items),
    { "Comment", "Approve", "Request changes" }
  )
  choose("Request changes")
  eq(wait_for_input().title, " Request changes on #1 ")
  child.type_keys("Please fix.", "<C-s>")
  wait_for_message("didymus: requested changes on #1")
  eq(provider_reviews()[1].verdict, "request_changes")

  -- A close of the picker with no choice opens no float.
  child.cmd("Didymus review submit")
  child.lua("require('didymus.ui.picker.test').cancel()")
  eq(float_win(), nil)
end

T["an empty body for a verdict that needs one shows a message"] = MiniTest.new_set({
  parametrize = { { "comment", "Comment" }, { "request_changes", "Request changes" } },
})

T["an empty body for a verdict that needs one shows a message"]["with"] = function(verdict, text)
  open_review({ make_thread("old", "file.txt", { range = { first = 3, last = 3 } }) })
  child.cmd("Didymus review submit " .. verdict)
  wait_for_input()
  child.type_keys("<C-s>")
  eq(has_message(('didymus: a "%s" review needs a body or a pending comment'):format(text)), true)
  -- The float stays open for the body.
  eq(child.api.nvim_get_current_win(), float_win())
  child.type_keys("A body.", "<C-s>")
  wait_for(function()
    return #provider_reviews() == 1
  end, "the review")
  eq(provider_reviews()[1].body, "A body.")
end

T["an empty body is permitted for an approval, and for a review with pending comments"] = function()
  open_review({ make_thread("old", "file.txt", { range = { first = 3, last = 3 } }) })
  child.cmd("Didymus review submit approve")
  wait_for_input()
  child.type_keys("<C-s>")
  wait_for_message("didymus: approved #1")
  eq(provider_reviews(), { { change_id = "1", verdict = "approve" } })

  child.cmd("Didymus review close")
  open_review()
  child.cmd("Didymus review submit comment")
  wait_for_input()
  child.type_keys("<C-s>")
  wait_for_message("didymus: commented on #1")
  eq(provider_reviews()[2], { change_id = "1", verdict = "comment" })
end

T["after an error, the message shows, and the next submit starts with the body"] = function()
  open_review()
  child.lua("require('didymus.review.provider.test').errors.submit_review = 'no network'")
  child.cmd("Didymus review submit comment")
  wait_for_input()
  child.type_keys("First try.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-s>")
  wait_for_message(
    "didymus: cannot submit the review of #1: no network. The next submit starts with its text."
  )
  eq(provider_reviews(), {})
  eq(pending_count(), 2)

  child.cmd("Didymus review submit approve")
  eq(wait_for_input().lines, { "First try." })
  child.type_keys(" Again.", "<C-s>")
  wait_for_message("didymus: approved #1")
  eq(provider_reviews(), { { change_id = "1", verdict = "approve", body = "First try. Again." } })
end

T["discard asks first, then removes the pending comments"] = function()
  open_review()
  child.cmd("Didymus review discard")
  local select = helpers.picker_calls(child, "select")[1]
  eq(select.title, "Discard your pending review of #1?")
  eq(
    vim.tbl_map(function(item)
      return item.text
    end, select.items),
    { "Discard", "Cancel" }
  )
  eq(select.items[1].preview, {
    lines = { "file.txt:3: A pending reply.", "file.txt:19: A pending comment." },
  })

  choose("Discard")
  wait_for_message("didymus: discarded the pending review of #1")
  wait_for(function()
    return child.lua_get("#require('didymus.review').current().threads") == 1
  end, "one thread")
  eq(thread_bodies(), {
    provider = { { "old", { "A comment." } } },
    session = { { "old", { "A comment." } } },
  })
  eq(panel_thread_rows(), { "@octocat A comment." })
end

T["cancel of the confirm keeps the pending review"] = function()
  open_review()
  child.cmd("Didymus review discard")
  choose("Cancel")
  child.cmd("Didymus review discard")
  child.lua("require('didymus.ui.picker.test').cancel()")

  -- The provider calls `cb` in `vim.schedule()`. Give it a chance to run.
  child.lua("vim.wait(50)")
  local bodies = {
    { "old", { "A comment.", "A pending reply." } },
    { "new", { "A pending comment.\nMore." } },
  }
  eq(thread_bodies(), { provider = bodies, session = bodies })
end

T["after a discard, the threads that the provider still gives have no pending comments"] = function()
  open_review()
  -- As on GitHub, the threads of the discarded review stay for a few seconds.
  child.lua([[
    require("didymus.review.provider.test").discard_review = function(_, _, cb)
      vim.schedule(cb)
    end
  ]])
  child.cmd("Didymus review discard")
  choose("Discard")
  wait_for(function()
    return child.lua_get("#require('didymus.review').current().threads") == 1
  end, "one thread")
  eq(thread_bodies().session, { { "old", { "A comment." } } })
end

T["a discard with no pending review, or an error, shows the message"] = function()
  open_review({ make_thread("old", "file.txt", { range = { first = 3, last = 3 } }) })
  child.cmd("Didymus review discard")
  eq(helpers.picker_calls(child, "select")[1].items[1].preview, {
    lines = { "#1 has no pending comments." },
  })
  choose("Discard")
  wait_for_message("didymus: cannot discard the pending review of #1: you have no pending review")

  child.lua("require('didymus.review.provider.test').errors.discard_review = 'no network'")
  child.cmd("Didymus review discard")
  choose("Discard")
  wait_for_message("didymus: cannot discard the pending review of #1: no network")
end

T["with no open review or an unknown verdict, a message shows"] = function()
  child.cmd("Didymus review submit")
  child.cmd("Didymus review discard")
  eq(select(2, child.cmd_capture("messages"):gsub("didymus: no review is open", "")), 2)

  open_review()
  -- An error message in a command is an error of `child.cmd()`.
  child.lua("require('didymus.command').run('review submit maybe')")
  eq(
    has_message('didymus: unknown verdict "maybe". Use approve, comment or request_changes.'),
    true
  )
  eq(float_win(), nil)
end

T["the mappings submit and discard"] = function()
  open_review()
  child.lua("vim.keymap.set('n', 'gS', '<Plug>(didymus-review-submit)')")
  child.lua("vim.keymap.set('n', 'gD', '<Plug>(didymus-review-discard)')")
  child.type_keys("gS")
  eq(helpers.picker_calls(child, "select")[1].title, "Submit the review of #1")
  child.lua("require('didymus.ui.picker.test').cancel()")
  child.type_keys("gD")
  eq(helpers.picker_calls(child, "select")[2].title, "Discard your pending review of #1?")
end

return T
