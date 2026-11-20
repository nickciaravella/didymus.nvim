local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local expect_screenshot = MiniTest.expect.reference_screenshot

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 14, 50
      child.cmd("runtime plugin/didymus.lua")
      child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
    end,
    post_once = child.stop,
  },
})

local make_thread = helpers.make_thread

--- The threads of the review, in the order of the provider. The panel order is different.
local function default_threads()
  return {
    make_thread("outdated", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Old note.", pending = false } },
    }),
    make_thread("resolved", "file.txt", {
      range = { first = 4, last = 5 },
      resolved = true,
      comments = { { author = "hubot", body = "Rename this.", pending = false } },
    }),
    make_thread("open", "file.txt", {
      range = { first = 2, last = 2 },
      comments = {
        { author = "octocat", body = "\nWhy TWO?\nMore text.", pending = false },
        { author = "hubot", body = "Because.", pending = true },
      },
    }),
    make_thread("deleted", "old.txt", {
      side = "base",
      range = { first = 1, last = 1 },
      comments = { { author = "octocat", body = "Why delete?", pending = false } },
    }),
  }
end

--- Make a repo where the change modifies lines 2 and 5 of file.txt, and deletes old.txt. Make it
--- the directory of the child. Open the review, and wait for its threads.
---@param threads didymus.review.Thread[]?
---@return didymus.test.Review
local function open_review(threads)
  threads = threads or default_threads()
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\nfour\nfive\n", ["old.txt"] = "old\n" },
    head = { ["file.txt"] = "one\nTWO\nthree\n    four\n    FIVE\n", ["old.txt"] = false },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads)
  child.cmd("Didymus review open 1")
  local review = helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, #threads)
  return review
end

---@return didymus.test.PickerCall
local function panel()
  return helpers.picker_calls(child, "panel")[1]
end

---@param target integer|string
local function choose(target)
  child.lua("require('didymus.ui.picker.test').choose(...)", { target })
end

---@return string
local function current_path()
  return child.fn.expand("%:.")
end

--- The rows of the marks in the current buffer, 0-based.
---@return integer[]
local function mark_rows()
  return child.lua_get([[
    vim.tbl_map(function(mark)
      return mark[2]
    end, vim.api.nvim_buf_get_extmarks(0, require("didymus.review.threads").namespace, 0, -1, {}))
  ]])
end

--- The rows and the text of the thread marks in the current buffer.
---@return [integer, string[]][]
local function marks()
  return vim.tbl_map(function(mark)
    return { mark.row, mark.lines }
  end, helpers.thread_marks(child))
end

--- The text of an unfolded thread at line 2 of file.txt in `default_threads()`.
local unfolded_open = {
  "┌ 💬 @octocat",
  "│ Why TWO?",
  "│ More text.",
  "├ @hubot [pending]",
  "└ Because.",
}

---@return integer?
local function float_win()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    if child.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

--- The lines of the thread float, and its title.
---@return { lines: string[], title: string }
local function float_content()
  local win = assert(float_win(), "no float")
  local buf = child.api.nvim_win_get_buf(win)
  return {
    lines = child.api.nvim_buf_get_lines(buf, 0, -1, true),
    title = child.api.nvim_win_get_config(win).title[1][1],
  }
end

---@param text string
local function expect_message(text)
  local messages = child.cmd_capture("messages")
  if not messages:find(text, 1, true) then
    error(("%q is not in the messages:\n%s"):format(text, messages), 2)
  end
end

--- The text of the screen rows.
---@return string[]
local function screen_lines()
  return vim.tbl_map(function(row)
    return table.concat(row)
  end, child.get_screenshot().text)
end

---@param lines string[]
---@param text string
---@return boolean
local function has_text(lines, text)
  for _, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

T["the panel shows the threads under their files, with the resolved and outdated states"] = function()
  open_review()
  local items = panel().items
  eq(items[3].text, "All threads")
  eq(
    vim.tbl_map(function(item)
      return { item.depth or 0, item.text }
    end, vim.list_slice(items, 4)),
    {
      { 0, "M file.txt +3 -3 3 threads" },
      { 1, "💬 @octocat Why TWO?" },
      { 1, "✅ @hubot Rename this." },
      { 1, "💬 @octocat Old note. [outdated]" },
      { 0, "D old.txt +0 -1 1 thread" },
      { 1, "💬 @octocat Why delete? [base]" },
      { 0, "Conversation" },
    }
  )
  eq(items[5].segments, { { "💬 " }, { "@octocat", "DidymusThread" }, { " Why TWO?" } })
  eq(items[6].segments, {
    { "✅ ", "DidymusThreadResolved" },
    { "@hubot", "DidymusThreadResolved" },
    { " Rename this.", "DidymusThreadResolved" },
  })
  eq(items[7].segments[4], { " [outdated]", "DiagnosticWarn" })
  eq(items[9].segments[4], { " [base]", "Comment" })
end

T["a thread row with a line has the location of the thread"] = function()
  local review = open_review()
  local dir = child.fn.getcwd()
  local items = panel().items
  eq(items[5].location, { path = dir .. "/file.txt", line = 2 })
  eq(items[6].location, { path = dir .. "/file.txt", line = 5 })
  -- Outdated, and base side of a deleted file: no line.
  eq({ items[7].location, items[9].location }, { nil, nil })
  eq(review.tabpage, child.api.nvim_get_current_tabpage())
end

T["the icons come from the config"] = function()
  child.lua([[require("didymus").setup({
    review = { picker = "test", provider = "test", icons = { active = "A", resolved = "" } },
  })]])
  open_review()
  local items = panel().items
  eq({ items[5].text, items[6].text }, { "A @octocat Why TWO?", "@hubot Rename this." })
end

T["the panel key shows only the active threads, and then all threads again"] = function()
  open_review()
  child.lua("require('didymus.ui.picker.test').press('a', '💬 @octocat Why TWO?')")
  local items = panel().items
  eq(
    vim.tbl_map(function(item)
      return item.text
    end, vim.list_slice(items, 3)),
    {
      "Active threads",
      "M file.txt +3 -3 2 threads",
      "💬 @octocat Why TWO?",
      "💬 @octocat Old note. [outdated]",
      "D old.txt +0 -1 1 thread",
      "💬 @octocat Why delete? [base]",
      "Conversation",
    }
  )
  eq(panel().cursor, 5)

  -- The panel keeps the filter when it opens again.
  child.cmd("Didymus review files")
  child.cmd("Didymus review files")
  local calls = helpers.picker_calls(child, "panel")
  eq(calls[2].items[3].text, "Active threads")
  child.lua("require('didymus.ui.picker.test').press('a')")
  calls = helpers.picker_calls(child, "panel")
  eq(calls[2].items[3].text, "All threads")
  eq(#calls[2].items, 10)
end

T["the panel key can change, or be off"] = function()
  child.lua([[require("didymus").setup({
    review = { picker = "test", provider = "test", panel = { keys = { toggle_active = "<C-a>" } } },
  })]])
  open_review()
  child.lua("require('didymus.ui.picker.test').press('<C-a>')")
  eq(panel().items[3].text, "Active threads")

  child.cmd("Didymus review close")
  child.lua([[require("didymus").setup({
    review = { picker = "test", provider = "test", panel = { keys = { toggle_active = false } } },
  })]])
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  MiniTest.expect.error(function()
    child.lua("require('didymus.ui.picker.test').press('a')")
  end, 'no action for "a"')
end

T["to choose a thread goes to its line in the code window, and unfolds the thread"] = function()
  local review = open_review()
  local code_win = child.api.nvim_get_current_win()
  child.cmd("leftabove vnew")

  choose("✅ @hubot Rename this.")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(current_path(), "file.txt")
  eq(child.api.nvim_win_get_cursor(0), { 5, 4 })
  eq(float_win(), nil)
  eq(marks()[2], { 4, { "    ┌ ✅ @hubot", "    └ Rename this." } })
end

T["an active thread is unfolded with all its comments, and a resolved thread is folded"] = function()
  open_review()
  choose("M file.txt +3 -3 3 threads")
  -- The tabline and the status line show the temporary path.
  child.o.showtabline, child.o.laststatus, child.o.ruler = 0, 0, false
  child.cmd("echo ''")
  expect_screenshot(child.get_screenshot())
end

T["outdated threads and base lines out of the hunks have no mark"] = function()
  open_review({
    make_thread("outdated", "file.txt", { outdated = true }),
    make_thread("base", "file.txt", { side = "base", range = { first = 9, last = 9 } }),
  })
  choose("M file.txt +3 -3 2 threads")
  eq(mark_rows(), {})
end

T["a thread on the file shows above line 1, with no sign, when the window is at the top"] = function()
  open_review({
    make_thread("file", "file.txt", { comments = { { author = "octocat", body = "About it." } } }),
  })
  choose("M file.txt +3 -3 1 thread")
  local win = child.api.nvim_get_current_win()
  eq(marks(), { { 0, { "┌ 💬 @octocat", "└ About it." } } })
  local namespace = child.lua_get("require('didymus.review.threads').namespace")
  local mark = child.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })[1][4]
  eq({ mark.virt_lines_above, mark.sign_text }, { true, nil })
  -- Neovim shows the lines above line 1 only with `topfill`. The file fits in the window, so the
  -- window shows line 1 at the top.
  eq(child.lua_get("vim.fn.winsaveview().topfill"), 2)
  eq(has_text(screen_lines(), "┌ 💬 @octocat"), true)
  child.cmd("normal! \5")
  eq(child.lua_get("vim.fn.winsaveview().topfill"), 1)

  -- `<CR>` on the thread row goes to line 1 and shows the thread.
  choose("💬 @octocat About it.")
  eq(child.api.nvim_get_current_win(), win)
  eq(child.api.nvim_win_get_cursor(0)[1], 1)
  eq(child.lua_get("vim.fn.winsaveview().topfill"), 2)
  eq(float_win(), nil)
end

T["a thread on the base side shows at the head line of its hunk, with the base tag"] = function()
  open_review({
    make_thread("base", "file.txt", {
      side = "base",
      range = { first = 1, last = 2 },
      comments = { { author = "octocat", body = "Was two.", pending = false } },
    }),
  })
  -- The last base line is a deleted line. The first added line after it is head line 2.
  local item = panel().items[5]
  eq(item.text, "💬 @octocat Was two. [base]")
  eq(item.location, { path = child.fn.getcwd() .. "/file.txt", line = 2 })
  choose(5)
  eq({ current_path(), child.api.nvim_win_get_cursor(0)[1] }, { "file.txt", 2 })
  eq(marks(), { { 1, { "┌ 💬 @octocat [base]", "└ Was two." } } })
  child.cmd("Didymus review fold")
  eq(marks(), { { 1, { "💬 @octocat Was two. [base]" } } })
  -- `next` stops at the thread.
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd("Didymus review next")
  eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

T["to choose a thread with no line opens its float"] = function()
  open_review()
  local win = child.api.nvim_get_current_win()
  choose("💬 @octocat Old note. [outdated]")
  eq(child.api.nvim_get_current_win(), win)
  eq(
    float_content(),
    { lines = { "**@octocat**", "", "Old note." }, title = " file.txt (outdated) " }
  )

  -- In a real panel, the move to a different row closes the float.
  child.cmd("doautocmd CursorMoved")
  eq(float_win(), nil)
  choose("💬 @octocat Why delete? [base]")
  eq(float_content().title, " old.txt:1 (base) ")
end

T[":Didymus review fold folds and unfolds the threads at the cursor line"] = function()
  open_review()
  choose("M file.txt +3 -3 3 threads")
  eq(marks(), { { 1, unfolded_open }, { 4, { "    ✅ @hubot Rename this." } } })

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review fold")
  eq(marks()[1], { 1, { "💬 @octocat Why TWO?" } })
  child.cmd("Didymus review fold")
  eq(marks()[1], { 1, unfolded_open })

  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Didymus review fold")
  eq(marks()[2], { 4, { "    ┌ ✅ @hubot", "    └ Rename this." } })
  -- A resolved thread is dim.
  local chunks = child.lua_get(
    [=[vim.api.nvim_buf_get_extmarks(0,
    require("didymus.review.threads").namespace, { 4, 0 }, { 4, -1 }, { details = true })[1][4].virt_lines[2]]=]
  )
  eq(
    chunks,
    { { "    " }, { "└ ", "DidymusThreadResolved" }, { "Rename this.", "DidymusThreadResolved" } }
  )
end

T["fold on a line with two threads folds or unfolds both, with no question"] = function()
  open_review({
    make_thread("first", "file.txt", { range = { first = 2, last = 2 } }),
    make_thread("second", "file.txt", {
      range = { first = 1, last = 2 },
      resolved = true,
      comments = { { author = "hubot", body = "Second.", pending = false } },
    }),
  })
  choose("M file.txt +3 -3 2 threads")
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  -- One of the two threads is unfolded, so fold folds both.
  child.cmd("Didymus review fold")
  eq(marks(), { { 1, { "💬 @octocat A comment." } }, { 1, { "✅ @hubot Second." } } })
  child.cmd("Didymus review fold")
  eq(marks(), {
    { 1, { "┌ 💬 @octocat", "└ A comment." } },
    { 1, { "┌ ✅ @hubot", "└ Second." } },
  })
  eq(helpers.picker_calls(child, "select"), {})
end

T["fold all folds all threads if one is unfolded, else it unfolds all threads"] = function()
  open_review()
  choose("M file.txt +3 -3 3 threads")
  child.cmd("Didymus review fold all")
  eq(marks(), { { 1, { "💬 @octocat Why TWO?" } }, { 4, { "    ✅ @hubot Rename this." } } })
  child.cmd("Didymus review fold all")
  local all_unfolded =
    { { 1, unfolded_open }, { 4, { "    ┌ ✅ @hubot", "    └ Rename this." } } }
  eq(marks(), all_unfolded)

  -- A refresh keeps the folds.
  child.cmd("Didymus review refresh")
  wait_for(function()
    return child.cmd_capture("messages"):find("refreshed #1", 1, true) ~= nil
  end, "the refresh")
  eq(marks(), all_unfolded)
end

T["the mappings fold the thread at the cursor, and all threads"] = function()
  open_review()
  choose("M file.txt +3 -3 3 threads")
  child.cmd("nmap <F3> <Plug>(didymus-review-fold)")
  child.cmd("nmap <F4> <Plug>(didymus-review-fold-all)")
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys("<F3>")
  eq(marks()[1], { 1, { "💬 @octocat Why TWO?" } })
  child.type_keys("<F4>")
  -- The keys line shows the mapping of fold.
  eq(marks(), {
    {
      1,
      vim.list_extend(vim.list_slice(unfolded_open, 1, 4), { "│ Because.", "└ <F3> fold" }),
    },
    { 4, { "    ┌ ✅ @hubot", "    │ Rename this.", "    └ <F3> fold" } },
  })
end

T["fold with no thread at the cursor, no thread at a line or no review shows a warning"] = function()
  child.cmd("Didymus review fold")
  expect_message("didymus: no review is open")

  open_review()
  choose("M file.txt +3 -3 3 threads")
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd("Didymus review fold")
  expect_message("didymus: no thread at line 1")

  child.cmd("Didymus review close")
  open_review({ make_thread("outdated", "file.txt", { outdated = true }) })
  child.cmd("Didymus review fold all")
  expect_message("didymus: #1 has no threads at a line")
end

T["fold with an unknown argument shows an error"] = function()
  open_review()
  -- An error message in a command is an error of `child.cmd()`.
  child.lua("require('didymus.command').run('review fold some')")
  expect_message(
    'didymus: cannot fold "some". Use :Didymus review fold or :Didymus review fold all.'
  )
end

T["an unfolded thread shows the keys of the user, if they fit"] = function()
  child.lua([[
    vim.keymap.set("n", "<Leader>rr", "<Plug>(didymus-review-reply)")
    vim.keymap.set("n", "<Leader>rx", "<Plug>(didymus-review-resolve)")
    vim.keymap.set("n", "<Leader>rf", "<Plug>(didymus-review-fold)")
  ]])
  open_review()
  choose("M file.txt +3 -3 3 threads")
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Didymus review fold")
  eq(marks(), {
    {
      1,
      {
        "┌ 💬 @octocat",
        "│ Why TWO?",
        "│ More text.",
        "├ @hubot [pending]",
        "│ Because.",
        [[└ \rr reply  \rx resolve  \rf fold]],
      },
    },
    {
      4,
      {
        "    ┌ ✅ @hubot",
        "    │ Rename this.",
        [[    └ \rr reply  \rx unresolve  \rf fold]],
      },
    },
  })

  -- In a narrow window, the keys do not fit.
  child.cmd("vsplit")
  child.cmd("vertical resize 30")
  helpers.wait_for_wrap(child)
  eq(marks()[1][2][5], "└ Because.")
  eq(marks()[2][2], { "    ┌ ✅ @hubot", "    │ Rename", "    └ this." })
end

T["a long comment wraps at the text width, and again after a resize"] = function()
  open_review({
    make_thread("long", "file.txt", {
      range = { first = 4, last = 4 },
      comments = {
        {
          author = "octocat",
          body = "This comment is long, so it wraps at the width of the window.\n\n"
            .. "\tA tab, and a word that is longer than a line: "
            .. ("x"):rep(50),
          pending = false,
        },
      },
    }),
  })
  choose("M file.txt +3 -3 1 thread")
  child.o.showtabline, child.o.laststatus, child.o.ruler = 0, 0, false
  child.cmd("echo ''")
  -- The sign column shows after the first draw, so the second draw wraps at a smaller width.
  helpers.wait_for_wrap(child)
  expect_screenshot(child.get_screenshot())

  child.cmd("vsplit")
  helpers.wait_for_wrap(child)
  expect_screenshot(child.get_screenshot())
end

T["the marks show only in the windows of the review tabpage"] = function()
  local review = open_review()
  choose("M file.txt +3 -3 3 threads")
  local review_lines = screen_lines()
  eq(has_text(review_lines, "2 TWO"), true)
  eq(has_text(review_lines, "│ Why TWO?"), true)

  -- The same buffer in a different tabpage.
  local buf = child.api.nvim_get_current_buf()
  child.cmd("tabfirst")
  child.api.nvim_set_current_buf(buf)
  local other_lines = screen_lines()
  eq(has_text(other_lines, "TWO"), true)
  eq(has_text(other_lines, "2 TWO"), false)
  eq(has_text(other_lines, "@"), false)

  -- A new window in the review tabpage shows them.
  child.api.nvim_set_current_tabpage(review.tabpage)
  child.cmd("vsplit")
  child.cmd("tabfirst")
  child.cmd("vsplit")
  child.api.nvim_set_current_tabpage(review.tabpage)
  local count = 0
  for _, line in ipairs(screen_lines()) do
    local _, matches = line:gsub("│ Why TWO%?", "")
    count = count + matches
  end
  eq(count, 2)
end

T["a buffer that was open before the review gets the marks"] = function()
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n" },
    head = { ["file.txt"] = "one\nTWO\nthree\n" },
  })
  child.fn.chdir(repo.dir)
  child.cmd("edit file.txt")
  local buf = child.api.nvim_get_current_buf()
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(
    child,
    "1",
    { make_thread("1", "file.txt", { range = { first = 2, last = 2 } }) }
  )
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, 1)

  choose("M file.txt +1 -1 1 thread")
  eq(child.api.nvim_get_current_buf(), buf)
  eq(mark_rows(), { 1 })
end

T[":edit! keeps the marks, and the close of the review removes them"] = function()
  open_review()
  choose("M file.txt +3 -3 3 threads")
  child.cmd("edit!")
  eq(mark_rows(), { 1, 4 })

  local buf = child.api.nvim_get_current_buf()
  child.cmd("Didymus review close")
  child.api.nvim_set_current_buf(buf)
  eq(mark_rows(), {})
end

T["if the threads cannot load, the error shows and the review stays open"] = function()
  child.lua([[
    local test_provider = require("didymus.review.provider.test")
    local provider = setmetatable({
      get_threads = function(_, _, cb)
        vim.schedule(function()
          cb("gh api graphql: HTTP 502")
        end)
      end,
    }, { __index = test_provider })
    require("didymus").setup({ review = { picker = "test", provider = provider } })
  ]])
  local repo = helpers.make_repo()
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  child.cmd("Didymus review open 1")
  local review = helpers.wait_for_review(child, "1")
  wait_for(function()
    return child.cmd_capture("messages"):find("cannot get the threads", 1, true) ~= nil
  end, "the error")
  expect_message("didymus: cannot get the threads of #1: gh api graphql: HTTP 502")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(helpers.review(child) ~= nil, true)
end

return T
