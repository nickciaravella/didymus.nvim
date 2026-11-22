local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local expect_screenshot = MiniTest.expect.reference_screenshot

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

--- Make a repo where the change modifies line 2 of file.txt and deletes old.txt. Make it the
--- directory of the child. Open the review with `threads`, wait for them, and edit file.txt with
--- the cursor on line 19.
---@param threads didymus.review.Thread[]? Default: one thread on line 19.
local function open_review(threads)
  threads = threads or { make_thread("old", "file.txt", { range = { first = 19, last = 19 } }) }
  local lines = {}
  for line = 1, 20 do
    lines[line] = "line " .. line
  end
  local base = table.concat(lines, "\n") .. "\n"
  local repo = helpers.make_repo({
    base = { ["file.txt"] = base, ["old.txt"] = "old\n" },
    head = { ["file.txt"] = (base:gsub("line 2\n", "LINE 2\n", 1)), ["old.txt"] = false },
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

---@param target integer|string
local function choose(target)
  child.lua("require('didymus.ui.picker.test').choose(...)", { target })
end

---@return integer?
local function inline_win()
  local win = child.lua_get([[
    (function()
      local session = require("didymus.review").current()
      return session and session.inline_box and session.inline_box:is_open() and session.inline_box.win or vim.NIL
    end)()
  ]])
  return win ~= vim.NIL and win or nil
end

--- The mode, title, footer and lines of the open inline box or split.
---@return { mode: string, title: string?, footer: string?, lines: string[], split: boolean }
local function inline_content()
  local win = assert(inline_win(), "no inline box")
  local cfg = child.api.nvim_win_get_config(win)
  local buf = child.api.nvim_win_get_buf(win)
  local mode = child.lua_get("require('didymus.review').current().inline_box.mode")
  local is_split = cfg.relative == ""
  local title
  if is_split then
    title = child.api.nvim_get_option_value("winbar", { win = win })
  elseif cfg.title then
    title = cfg.title[2] and cfg.title[2][1] or cfg.title[1][1]
  end
  local footer = not is_split
      and cfg.footer
      and (cfg.footer[2] and cfg.footer[2][1] or cfg.footer[1][1])
    or nil
  return {
    mode = mode,
    title = title,
    footer = footer,
    lines = child.api.nvim_buf_get_lines(buf, 0, -1, true),
    split = is_split,
  }
end

--- Wait for the inline reply edit box, and give its content.
---@return { mode: string, title: string, footer: string?, lines: string[], split: boolean }
local function wait_for_reply_box()
  wait_for(function()
    local win = inline_win()
    return win ~= nil
      and child.lua_get("require('didymus.review').current().inline_box.mode") == "edit"
  end, "the inline reply box")
  return inline_content()
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

--- The sign and its highlight of the mark on line 19 of the current buffer.
---@return [string, string]
local function sign()
  return child.lua_get([[
    (function()
      local namespace = require("didymus.review.threads").namespace
      local mark = vim.api.nvim_buf_get_extmarks(0, namespace, { 18, 0 }, { 18, -1 }, {
        details = true,
      })[1]
      return { vim.trim(mark[4].sign_text), mark[4].sign_hl_group }
    end)()
  ]])
end

T["a reply adds a pending comment to the thread"] = function()
  open_review()
  local code_win = child.api.nvim_get_current_win()
  child.cmd("Didymus review reply")
  eq(wait_for_reply_box(), {
    mode = "edit",
    title = " Reply ",
    footer = " <C-s> reply now  <C-y> add to review  q cancel ",
    lines = { "" },
    split = false,
  })

  child.type_keys("Thanks.", "<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(inline_win(), nil)
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

T["inline reply attaches seamlessly to the bottom of the thread box"] = function()
  child.o.lines, child.o.columns = 14, 60
  open_review({
    make_thread("t1", "file.txt", {
      range = { first = 3, last = 3 },
      comments = {
        { author = "octocat", body = "Why three?", pending = false },
        { author = "hubot", body = "Because.", pending = true },
      },
    }),
  })
  child.o.showtabline, child.o.laststatus, child.o.ruler = 0, 0, false
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review reply")
  wait_for_reply_box()
  child.type_keys("Makes sense.")
  child.cmd("stopinsert")
  child.cmd("echo ''")
  expect_screenshot(child.get_screenshot())
end

T["a second reply at another thread refuses while an inline reply is open"] = function()
  open_review({
    make_thread("first", "file.txt", { range = { first = 3, last = 3 } }),
    make_thread("second", "file.txt", { range = { first = 19, last = 19 } }),
  })
  local code_win = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review reply")
  wait_for_reply_box()
  child.type_keys("In progress.", "<Esc>", "<Esc>")

  eq(child.api.nvim_get_current_win(), code_win)
  local win = assert(inline_win())
  eq(child.api.nvim_get_option_value("conceallevel", { win = win }), 3)
  child.api.nvim_win_set_cursor(0, { 19, 0 })
  child.cmd("Didymus review reply")
  eq(
    has_message(
      "didymus: another comment is already open at file.txt:3. Submit or cancel it first."
    ),
    true
  )

  -- Re-entering the draft reply restores raw markdown editing.
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review reply")
  eq(child.api.nvim_get_current_win(), win)
  eq(child.api.nvim_get_option_value("conceallevel", { win = win }), 0)
end

T["reply now posts the reply at once, with no pending tag"] = function()
  open_review()
  child.cmd("Didymus review reply")
  wait_for_reply_box()
  child.type_keys("Posted.", "<C-s>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  local comment = { author = "reviewer", body = "Posted.", pending = false }
  eq(provider_threads()[1].comments[2], comment)
  eq(session_thread("old").comments[2], comment)
  eq(has_message("didymus: posted a reply at file.txt:19"), true)
  local lines = mark_lines()
  eq(#lines, 7)
  eq(lines[1]:find("┌───", 1, true), 1)
  eq(lines[2]:find("│ 💬 @octocat", 1, true), 1)
  eq(lines[3]:find("│ A comment.", 1, true), 1)
  eq(lines[4]:find("├───", 1, true), 1)
  eq(lines[5]:find("│ @reviewer", 1, true), 1)
  eq(lines[6]:find("│ Posted.", 1, true), 1)
  eq(lines[7]:find("└───", 1, true), 1)
end

T["if the code host refuses a reply now, the message shows, and the text stays"] = function()
  open_review()
  -- The GitHub provider gives this error if the viewer has a pending review.
  child.lua("require('didymus.review.provider.test').errors.reply = 'you have a pending review'")
  child.cmd("Didymus review reply")
  wait_for_reply_box()
  child.type_keys("Not yet.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-s>")
  wait_for_message(
    "didymus: cannot post the reply at file.txt:19: you have a pending review. "
      .. "The next reply to this thread starts with its text."
  )
  eq(#session_thread("old").comments, 1)

  child.cmd("Didymus review reply")
  eq(wait_for_reply_box().lines, { "Not yet." })
  child.type_keys("<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(session_thread("old").comments[2].pending, true)
end

T["reply and resolve work on an unfolded thread. A resolve folds it, and an unresolve unfolds it"] = function()
  open_review()
  eq(#mark_lines(), 4)
  child.cmd("Didymus review reply")
  eq(wait_for_reply_box().title, " Reply ")
  child.type_keys("Thanks.", "<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(#mark_lines(), 7)
  eq(mark_lines()[5]:find("│ @reviewer [pending]", 1, true), 1)

  child.cmd("Didymus review resolve")
  wait_for(function()
    return session_thread("old").resolved
  end, "the resolved thread")
  eq(mark_lines(), { "✅ @octocat A comment." })
  child.cmd("Didymus review resolve")
  wait_for(function()
    return not session_thread("old").resolved
  end, "the unresolved thread")
  eq(mark_lines()[1]:find("┌───", 1, true), 1)
  eq(mark_lines()[2]:find("│ 💬 @octocat", 1, true), 1)
end

T["resolve resolves the thread, and the panel shows it dim. resolve again unresolves it"] = function()
  open_review()
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
  child.cmd("Didymus review reply")
  eq(has_message("didymus: you cannot reply to the thread at file.txt:19"), true)
  child.cmd("Didymus review resolve")
  eq(has_message("didymus: you cannot resolve the thread at file.txt:19"), true)
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review resolve")
  eq(has_message("didymus: you cannot unresolve the thread at file.txt:3"), true)

  -- The provider calls `cb` in `vim.schedule()`. Give it a chance to run.
  child.lua("vim.wait(50)")
  eq(inline_win(), nil)
  eq(
    vim.tbl_map(function(thread)
      return { thread.resolved, #thread.comments }
    end, provider_threads()),
    { { false, 1 }, { true, 1 } }
  )
end

T["the keys of a focused inline thread reply and resolve"] = function()
  open_review({
    make_thread("old", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Please rename this variable.", pending = false } },
    }),
  })
  local code_win = child.api.nvim_get_current_win()
  choose("💬 @octocat Please rename this variable. [outdated]")
  eq(child.api.nvim_get_current_win(), inline_win())
  eq(inline_content().footer, nil)

  child.type_keys("r")
  eq(wait_for_reply_box().title, " Reply ")
  child.type_keys("<Esc>", "q")
  eq(child.api.nvim_get_current_win(), code_win)

  choose("💬 @octocat Please rename this variable. [outdated]")
  child.type_keys("x")
  eq(inline_win(), nil)
  eq(child.api.nvim_get_current_win(), code_win)
  wait_for(function()
    return session_thread("old").resolved
  end, "the resolved thread")

  choose("✅ @octocat Please rename this variable. [outdated]")
  child.type_keys("?")
  local help_text =
    table.concat(child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(0), 0, -1, true), "\n")
  eq(help_text:find("unresolve thread", 1, true) ~= nil, true)
  child.type_keys("q")
end

T["a key set to false is off, and the commands also work in a focused inline thread"] = function()
  child.lua("require('didymus').setup(...)", {
    { review = { picker = "test", provider = "test", thread = { keys = { reply = false } } } },
  })
  open_review({
    make_thread("old", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Please rename this variable.", pending = false } },
    }),
  })
  choose("💬 @octocat Please rename this variable. [outdated]")
  child.type_keys("?")
  local help_text =
    table.concat(child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(0), 0, -1, true), "\n")
  eq(help_text:find("reply to thread", 1, true), nil)
  eq(help_text:find("resolve thread", 1, true) ~= nil, true)
  child.type_keys("q")
  eq(child.fn.maparg("r", "n"), "")

  child.cmd("Didymus review reply")
  eq(wait_for_reply_box().title, " Reply ")
end

T["a top-of-file thread and a deleted-file thread get replies inline or in a bottom split"] = function()
  open_review({
    make_thread("outdated", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Old note.", pending = false } },
    }),
    make_thread("deleted", "old.txt", {
      side = "base",
      range = { first = 1, last = 1 },
      comments = { { author = "octocat", body = "Why delete?", pending = false } },
    }),
  })
  choose("💬 @octocat Old note. [outdated]")
  eq(child.api.nvim_get_current_win(), inline_win())
  child.type_keys("r")
  eq(wait_for_reply_box().title, " Reply ")
  child.type_keys("Still true.", "<C-y>")
  wait_for_message("didymus: added a pending reply at file.txt")
  eq(#provider_threads()[1].comments, 2)

  -- Deleted file uses a non-floating bottom split.
  choose("💬 @octocat Why delete?")
  eq(inline_content().split, true)
  child.type_keys("r")
  local split_reply = wait_for_reply_box()
  eq(split_reply.split, true)
  eq(split_reply.title:find("Reply to old.txt:1", 1, true) ~= nil, true)
  child.type_keys("Not needed.", "<C-y>")
  wait_for_message("didymus: added a pending reply at old.txt:1")
  eq(#provider_threads()[2].comments, 2)
end

T["with two threads at the line, the picker asks which one"] = function()
  open_review({
    make_thread("first", "file.txt", { range = { first = 19, last = 19 } }),
    make_thread("second", "file.txt", {
      range = { first = 18, last = 19 },
      comments = { { author = "hubot", body = "Second.", pending = false } },
    }),
  })
  child.cmd("Didymus review resolve")
  local select = helpers.picker_calls(child, "select")[1]
  eq(select.title, "Threads at line 19")
  choose("💬 @hubot Second.")
  wait_for(function()
    return session_thread("second").resolved
  end, "the resolved thread")
  eq(session_thread("first").resolved, false)

  child.cmd("Didymus review reply")
  choose("💬 @octocat A comment.")
  eq(wait_for_reply_box().title, " Reply ")
  child.type_keys("To the first.", "<C-y>")
  wait_for(function()
    return #session_thread("first").comments == 2
  end, "the reply in the session")
  eq(#session_thread("second").comments, 1)
end

T["with a focused inline thread, commands use its thread, not another thread on the line"] = function()
  open_review({
    make_thread("outdated", "file.txt", {
      outdated = true,
      comments = { { author = "hubot", body = "Old note.", pending = false } },
    }),
    make_thread("line", "file.txt", { range = { first = 1, last = 1 } }),
  })
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
  child.cmd("Didymus review reply")
  wait_for_reply_box()
  child.type_keys("First try.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-y>")
  wait_for_message(
    "didymus: cannot add the reply at file.txt:19: no network. "
      .. "The next reply to this thread starts with its text."
  )
  eq(#session_thread("old").comments, 1)

  child.cmd("Didymus review reply")
  eq(wait_for_reply_box().lines, { "First try." })
  child.type_keys(" Again.", "<C-y>")
  wait_for(function()
    return #session_thread("old").comments == 2
  end, "the reply in the session")
  eq(provider_threads()[1].comments[2].body, "First try. Again.")

  child.lua("require('didymus.review.provider.test').errors.set_resolved = 'no network'")
  child.cmd("Didymus review resolve")
  wait_for_message("didymus: cannot resolve the thread at file.txt:19: no network")
  eq(session_thread("old").resolved, false)
end

T["with no thread at the cursor, or no open review, a warning shows"] = function()
  child.cmd("Didymus review reply")
  child.cmd("Didymus review resolve")
  eq(select(2, child.cmd_capture("messages"):gsub("didymus: no review is open", "")), 2)

  open_review()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("messages clear")
  child.cmd("Didymus review reply")
  child.cmd("Didymus review resolve")
  eq(select(2, child.cmd_capture("messages"):gsub("didymus: no thread at line 3", "")), 2)
end

T["the mappings reply and resolve"] = function()
  open_review()
  child.lua("vim.keymap.set('n', 'gR', '<Plug>(didymus-review-reply)')")
  child.lua("vim.keymap.set('n', 'gX', '<Plug>(didymus-review-resolve)')")
  child.type_keys("gR")
  eq(wait_for_reply_box().title, " Reply ")
  child.type_keys("<Esc>", "q")
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
