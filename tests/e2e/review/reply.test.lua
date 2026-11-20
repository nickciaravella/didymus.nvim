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

--- Make a repo where the change modifies line 2 of file.txt. Make it the directory of the child.
--- Open the review with `threads`, wait for them, and edit file.txt with the cursor on line 19.
---@param threads didymus.review.Thread[]? Default: one thread on line 19.
local function open_review(threads)
  threads = threads or { make_thread("old", "file.txt", { range = { first = 19, last = 19 } }) }
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
  child.api.nvim_win_set_cursor(0, { 19, 0 })
end

--- Put the cursor in the thread under `line`.
---@param line integer? Default 19.
local function enter(line)
  helpers.enter_thread(child, line or 19)
end

---@param target integer|string
local function choose(target)
  child.lua("require('didymus.ui.picker.test').choose(...)", { target })
end

--- The thread float or the input float. A window on a thread in the file does not count.
---@return integer?
local function float_win()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    local buf = child.api.nvim_win_get_buf(win)
    if
      child.api.nvim_win_get_config(win).relative ~= ""
      and child.api.nvim_get_option_value("filetype", { buf = buf }) ~= "didymus_thread"
    then
      return win
    end
  end
end

--- The title, the footer and the lines of the float. The footer is nil if it does not show.
---@return { title: string, footer: string?, lines: string[] }
local function float_content()
  local win = assert(float_win(), "no float")
  local config = child.api.nvim_win_get_config(win)
  return {
    title = config.title[1][1],
    footer = config.footer and config.footer[1][1],
    lines = child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, true),
  }
end

--- Wait for the input, and give its content. In the code window, the input is inline. From the
--- panel, it is a float.
---@return { title: string, footer: string?, lines: string[] }
local function wait_for_input()
  local input = helpers.wait_for_input(child)
  return { title = input.title, footer = input.footer, lines = input.lines }
end

--- Open the thread float of the panel row `text`, and focus it. The test picker has no window, so a
--- second choice focuses the float, as a second `<CR>` in a real panel.
---@param text string
local function focus_thread_float(text)
  choose(text)
  choose(text)
  eq(child.api.nvim_get_current_win(), float_win())
end

--- The text of the thread mark on line 19.
---@return string[]
local function mark_lines()
  for _, mark in ipairs(helpers.thread_marks(child)) do
    if mark.row == 18 then
      return mark.lines
    end
  end
  error("no mark on line 19")
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

--- The thread of the open review with `id`.
---@param id string
---@return didymus.review.Thread
local function session_thread(id)
  return child.lua_get("require('didymus.review').current():get_thread(...)", { id })
end

--- The threads of the change in the test provider.
---@return didymus.review.Thread[]
local function provider_threads()
  return child.lua_get("require('didymus.review.provider.test').threads['1']")
end

--- The panel row of the thread with `id`.
---@param id string
---@return didymus.picker.Item
local function panel_item(id)
  for _, item in ipairs(helpers.picker_calls(child, "panel")[1].items) do
    if item.id == "thread:" .. id then
      return item
    end
  end
  error("no panel row of " .. id)
end

--- The sign and its highlight of the mark on line 19 of the code window.
---@return [string, string]
local function sign()
  return child.lua_get([[
    (function()
      local namespace = require("didymus.review.threads").namespace
      local buf = vim.api.nvim_win_get_buf(require("didymus.review").current().code_win)
      local mark = vim.api.nvim_buf_get_extmarks(buf, namespace, { 18, 0 }, { 18, -1 }, {
        details = true,
      })[1]
      return { vim.trim(mark[4].sign_text), mark[4].sign_hl_group }
    end)()
  ]])
end

T["a reply adds a pending comment to the thread"] = function()
  open_review()
  local code_win = child.api.nvim_get_current_win()
  enter()
  child.cmd("Didymus review reply")
  eq(wait_for_input(), {
    title = "Reply to file.txt:19",
    footer = "<C-s> reply now  <C-y> add to review  q cancel",
    lines = { "" },
  })
  -- The input shows under the thread.
  eq(helpers.get_input(child).inline, true)

  child.type_keys("Thanks.", "<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(float_win(), nil)
  local comments = {
    { author = "octocat", body = "A comment.", pending = false },
    { author = "reviewer", body = "Thanks.", pending = true },
  }
  eq(provider_threads()[1].comments, comments)
  eq(session_thread("old").comments, comments)
  eq(sign(), { "2", "DidymusThread" })
  eq(panel_item("old").text, "💬 @octocat A comment.")
  eq(has_message("didymus: added a pending reply at file.txt:19"), true)
end

T["reply now posts the reply at once, with no pending tag"] = function()
  open_review()
  enter()
  child.cmd("Didymus review reply")
  wait_for_input()
  child.type_keys("Posted.", "<C-s>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  local comment = { author = "reviewer", body = "Posted.", pending = false }
  eq(provider_threads()[1].comments[2], comment)
  eq(session_thread("old").comments[2], comment)
  eq(has_message("didymus: posted a reply at file.txt:19"), true)
  eq(mark_lines(), { "┌ 💬 @octocat", "│ A comment.", "├ @reviewer", "└ Posted." })
end

T["if the code host refuses a reply now, the message shows, and the text stays"] = function()
  open_review()
  -- The GitHub provider gives this error if the viewer has a pending review.
  child.lua("require('didymus.review.provider.test').errors.reply = 'you have a pending review'")
  enter()
  child.cmd("Didymus review reply")
  wait_for_input()
  child.type_keys("Not yet.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-s>")
  wait_for_message(
    "didymus: cannot post the reply at file.txt:19: you have a pending review. "
      .. "The next reply to this thread starts with its text."
  )
  eq(#session_thread("old").comments, 1)

  enter()
  child.cmd("Didymus review reply")
  eq(wait_for_input().lines, { "Not yet." })
  child.type_keys("<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(session_thread("old").comments[2].pending, true)
end

T["reply and resolve work on an unfolded thread. A resolve folds it, and an unresolve unfolds it"] = function()
  open_review()
  eq(mark_lines(), { "┌ 💬 @octocat", "└ A comment." })
  enter()
  child.cmd("Didymus review reply")
  eq(wait_for_input().title, "Reply to file.txt:19")
  child.type_keys("Thanks.", "<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(
    mark_lines(),
    { "┌ 💬 @octocat", "│ A comment.", "├ @reviewer [pending]", "└ Thanks." }
  )

  -- The cursor stays in the thread after a resolve.
  enter()
  child.cmd("Didymus review resolve")
  wait_for(function()
    return session_thread("old").resolved
  end, "the resolved thread")
  eq(mark_lines(), { "✅ @octocat A comment." })
  child.cmd("Didymus review resolve")
  wait_for(function()
    return not session_thread("old").resolved
  end, "the unresolved thread")
  eq(mark_lines()[1], "┌ 💬 @octocat")
end

T["resolve resolves the thread, and the panel shows it dim. resolve again unresolves it"] = function()
  open_review()
  enter()
  child.cmd("Didymus review resolve")
  wait_for(function()
    return session_thread("old").resolved
  end, "the resolved thread")
  eq(provider_threads()[1].resolved, true)
  eq(panel_item("old").segments, {
    { "✅ ", "DidymusThreadResolved" },
    { "@octocat", "DidymusThreadResolved" },
    { " A comment.", "DidymusThreadResolved" },
  })
  eq(sign(), { "1", "DidymusThreadResolved" })
  eq(has_message("didymus: resolved the thread at file.txt:19"), true)

  child.cmd("Didymus review resolve")
  wait_for(function()
    return not session_thread("old").resolved
  end, "the unresolved thread")
  eq(provider_threads()[1].resolved, false)
  eq(
    panel_item("old").segments,
    { { "💬 " }, { "@octocat", "DidymusThread" }, { " A comment." } }
  )
  eq(sign(), { "1", "DidymusThread" })
  eq(has_message("didymus: unresolved the thread at file.txt:19"), true)
end

T["with no permission, the message shows"] = function()
  open_review({
    make_thread("locked", "file.txt", {
      range = { first = 19, last = 19 },
      can_reply = false,
      can_resolve = false,
    }),
    make_thread("resolved", "file.txt", {
      range = { first = 3, last = 3 },
      resolved = true,
      can_unresolve = false,
    }),
  })
  enter()
  child.cmd("Didymus review reply")
  eq(has_message("didymus: you cannot reply to the thread at file.txt:19"), true)
  child.cmd("Didymus review resolve")
  eq(has_message("didymus: you cannot resolve the thread at file.txt:19"), true)
  enter(3)
  child.cmd("Didymus review resolve")
  eq(has_message("didymus: you cannot unresolve the thread at file.txt:3"), true)

  -- The provider calls `cb` in `vim.schedule()`. Give it a chance to run.
  child.lua("vim.wait(50)")
  eq(float_win(), nil)
  eq(
    vim.tbl_map(function(thread)
      return { thread.resolved, #thread.comments }
    end, provider_threads()),
    { { false, 1 }, { true, 1 } }
  )
end

T["the keys of the thread float reply and resolve"] = function()
  open_review({
    make_thread("old", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Please rename this variable.", pending = false } },
    }),
  })
  local code_win = child.api.nvim_get_current_win()
  focus_thread_float("💬 @octocat Please rename this variable. [outdated]")
  eq(float_content().footer, " r reply  x resolve ")

  child.type_keys("r")
  eq(wait_for_input().title, " Reply to file.txt ")
  -- A thread with no place in the file gets the input float.
  eq(helpers.get_input(child).inline, false)
  child.type_keys("<Esc>", "q")
  eq(child.api.nvim_get_current_win(), code_win)

  focus_thread_float("💬 @octocat Please rename this variable. [outdated]")
  child.type_keys("x")
  eq(float_win(), nil)
  eq(child.api.nvim_get_current_win(), code_win)
  wait_for(function()
    return session_thread("old").resolved
  end, "the resolved thread")

  focus_thread_float("✅ @octocat Please rename this variable. [outdated]")
  eq(float_content().footer, " r reply  x unresolve ")
end

T["a key set to false is off, and the commands also work in the thread float"] = function()
  child.lua("require('didymus').setup(...)", {
    { review = { picker = "test", provider = "test", thread = { keys = { reply = false } } } },
  })
  open_review({
    make_thread("old", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Please rename this variable.", pending = false } },
    }),
  })
  focus_thread_float("💬 @octocat Please rename this variable. [outdated]")
  eq(float_content().footer, " x resolve ")
  eq(child.fn.maparg("r", "n"), "")

  child.cmd("Didymus review reply")
  eq(wait_for_input().title, " Reply to file.txt ")
end

T["a thread with no line gets a reply from its float"] = function()
  open_review({
    make_thread("outdated", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Old note.", pending = false } },
    }),
  })
  -- The test picker has no window. A second choice focuses the float, as in a real panel.
  choose("💬 @octocat Old note. [outdated]")
  choose("💬 @octocat Old note. [outdated]")
  eq(child.api.nvim_get_current_win(), float_win())
  child.type_keys("r")
  eq(wait_for_input().title, " Reply to file.txt ")
  child.type_keys("Still true.", "<C-y>")
  wait_for_message("didymus: added a pending reply at file.txt")
  eq(#provider_threads()[1].comments, 2)
end

T["with two threads at the line, the commands use the thread with the cursor"] = function()
  open_review({
    make_thread("first", "file.txt", { range = { first = 19, last = 19 } }),
    make_thread("second", "file.txt", {
      range = { first = 18, last = 19 },
      comments = { { author = "hubot", body = "Second.", pending = false } },
    }),
  })
  enter()
  -- `j` goes down in the first thread, then into the second thread.
  child.type_keys("j", "j")
  eq(child.fn.getline(1), "┌ 💬 @hubot")
  child.cmd("Didymus review resolve")
  wait_for(function()
    return session_thread("second").resolved
  end, "the resolved thread")
  eq(session_thread("first").resolved, false)
  eq(helpers.picker_calls(child, "select"), {})

  -- `k` goes back into the first thread, on its last line.
  child.type_keys("k")
  eq(child.fn.getline("."), "└ A comment.")
  child.cmd("Didymus review reply")
  eq(wait_for_input().title, "Reply to file.txt:19")
  -- The input shows under the first thread, before the second thread.
  local lines = mark_lines()
  eq(
    { lines[1], lines[3], lines[#lines] },
    { "┌ 💬 @octocat", "┌ Reply to file.txt:19", "✅ @hubot Second." }
  )
  child.type_keys("To the first.", "<C-y>")
  wait_for(function()
    return #session_thread("first").comments == 2
  end, "the reply in the session")
  eq(#session_thread("second").comments, 1)
end

T["with the thread float open, the commands use its thread, not the thread at the cursor line"] = function()
  open_review({
    make_thread("outdated", "file.txt", {
      outdated = true,
      comments = { { author = "hubot", body = "Old note.", pending = false } },
    }),
    make_thread("line", "file.txt", { range = { first = 19, last = 19 } }),
  })
  -- The float opens over the code window, so that window is under the float.
  choose("💬 @hubot Old note. [outdated]")
  child.cmd("Didymus review resolve")
  wait_for(function()
    return session_thread("outdated").resolved
  end, "the resolved thread")
  eq(session_thread("line").resolved, false)
  eq(helpers.picker_calls(child, "select"), {})
  eq(has_message("didymus: resolved the thread at file.txt"), true)
end

T["after an error, the message shows, and the next reply to the thread starts with the text"] = function()
  open_review()
  child.lua("require('didymus.review.provider.test').errors.reply = 'no network'")
  enter()
  child.cmd("Didymus review reply")
  wait_for_input()
  child.type_keys("First try.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-y>")
  wait_for_message(
    "didymus: cannot add the reply at file.txt:19: no network. "
      .. "The next reply to this thread starts with its text."
  )
  eq(#session_thread("old").comments, 1)

  enter()
  child.cmd("Didymus review reply")
  eq(wait_for_input().lines, { "First try." })
  child.type_keys(" Again.", "<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(provider_threads()[1].comments[2].body, "First try. Again.")

  child.lua("require('didymus.review.provider.test').errors.set_resolved = 'no network'")
  enter()
  child.cmd("Didymus review resolve")
  wait_for_message("didymus: cannot resolve the thread at file.txt:19: no network")
  eq(session_thread("old").resolved, false)
end

T["with no thread at the cursor, or no open review, a warning shows"] = function()
  child.cmd("Didymus review reply")
  child.cmd("Didymus review resolve")
  eq(select(2, child.cmd_capture("messages"):gsub("didymus: no review is open", "")), 2)

  -- A line with a thread is not in the thread, so the command has no thread.
  open_review()
  child.cmd("messages clear")
  child.cmd("Didymus review reply")
  child.cmd("Didymus review resolve")
  local messages = child.cmd_capture("messages")
  eq(
    messages:find("the cursor is not in a thread. To reply, put the cursor in the thread", 1, true)
      ~= nil,
    true
  )
  eq(
    messages:find(
      "the cursor is not in a thread. To resolve, put the cursor in the thread",
      1,
      true
    ) ~= nil,
    true
  )
end

T["the mappings reply and resolve"] = function()
  open_review()
  child.lua("vim.keymap.set('n', 'gR', '<Plug>(didymus-review-reply)')")
  child.lua("vim.keymap.set('n', 'gX', '<Plug>(didymus-review-resolve)')")
  enter()
  child.type_keys("gR")
  eq(wait_for_input().title, "Reply to file.txt:19")
  child.type_keys("<Esc>", "q")
  enter()
  child.type_keys("gX")
  wait_for(function()
    return session_thread("old").resolved
  end, "the resolved thread")
  -- The mapping also unresolves.
  eq(
    child.lua_get("vim.fn.maparg('<Plug>(didymus-review-resolve)', 'n', false, true).desc"),
    "didymus: review resolve or unresolve"
  )
end

return T
