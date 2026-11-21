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
    make_thread("base", "file.txt", {
      side = "base",
      range = { first = 2, last = 2 },
      comments = { { author = "octocat", body = "Was two.", pending = false } },
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

--- The thread marks on non-zero rows (head-line threads in `default_threads()`).
---@return [integer, string[]][]
local function line_marks()
  return vim.tbl_filter(function(mark)
    return mark[1] > 0
  end, marks())
end

--- The open inline box window, if any.
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

--- The lines and title of the open inline box (or split).
---@return { lines: string[], title: string, footer: string?, split: boolean }
local function inline_content()
  local win = assert(inline_win(), "no inline box")
  local cfg = child.api.nvim_win_get_config(win)
  local buf = child.api.nvim_win_get_buf(win)
  local is_split = cfg.relative == ""
  local title
  if is_split then
    title = child.api.nvim_get_option_value("winbar", { win = win })
  else
    title = cfg.title[2] and cfg.title[2][1] or cfg.title[1][1]
  end
  local footer = not is_split
      and cfg.footer
      and (cfg.footer[2] and cfg.footer[2][1] or cfg.footer[1][1])
    or nil
  return {
    lines = child.api.nvim_buf_get_lines(buf, 0, -1, true),
    title = title,
    footer = footer,
    split = is_split,
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
      { 0, "M file.txt +3 -3 4 threads" },
      { 1, "💬 @octocat Why TWO?" },
      { 1, "✅ @hubot Rename this." },
      { 1, "💬 @octocat Old note. [outdated]" },
      { 1, "💬 @octocat Was two." },
      { 0, "D old.txt +0 -1 1 thread" },
      { 1, "💬 @octocat Why delete?" },
    }
  )
  eq(items[5].segments, { { "💬 " }, { "@octocat", "DidymusThread" }, { " Why TWO?" } })
  eq(items[6].segments, {
    { "✅ ", "DidymusThreadResolved" },
    { "@hubot", "DidymusThreadResolved" },
    { " Rename this.", "DidymusThreadResolved" },
  })
  eq(items[7].segments[4], { " [outdated]", "DiagnosticWarn" })
end

T["a thread row with a line has the location of the thread"] = function()
  local review = open_review()
  local dir = child.fn.getcwd()
  local items = panel().items
  eq(items[5].location, { path = dir .. "/file.txt", line = 2 })
  eq(items[6].location, { path = dir .. "/file.txt", line = 5 })
  -- Outdated, base side and deleted file: no line.
  eq({ items[7].location, items[8].location, items[10].location }, { nil, nil, nil })
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
      "M file.txt +3 -3 3 threads",
      "💬 @octocat Why TWO?",
      "💬 @octocat Old note. [outdated]",
      "💬 @octocat Was two.",
      "D old.txt +0 -1 1 thread",
      "💬 @octocat Why delete?",
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
  eq(inline_win(), nil)
  local resolved_mark = line_marks()[2]
  eq(resolved_mark[1], 4)
  eq(#resolved_mark[2], 3)
  eq(resolved_mark[2][1]:find("    ┌─ ✅ @hubot ", 1, true) ~= nil, true)
  eq(resolved_mark[2][2]:find("    │ Rename this.", 1, true) ~= nil, true)
  eq(resolved_mark[2][3]:find("    └─", 1, true) ~= nil, true)
end

T["an active thread is unfolded with all its comments, and a resolved thread is folded"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  -- The tabline and the status line show the temporary path.
  child.o.showtabline, child.o.laststatus, child.o.ruler = 0, 0, false
  child.cmd("echo ''")
  helpers.wait_for_wrap(child)
  expect_screenshot(child.get_screenshot())
end

T["outdated, base-side and file threads show above line 1, and choose focuses them inline"] = function()
  open_review({
    make_thread("outdated", "file.txt", {
      outdated = true,
      comments = { { author = "octocat", body = "Old note.", pending = false } },
    }),
    make_thread("base", "file.txt", {
      side = "base",
      range = { first = 2, last = 2 },
      comments = { { author = "octocat", body = "Was two.", pending = false } },
    }),
    make_thread("file", "file.txt", {
      comments = { { author = "hubot", body = "File note.", pending = false } },
    }),
    make_thread("deleted", "old.txt", {
      side = "base",
      range = { first = 1, last = 1 },
      comments = { { author = "octocat", body = "Why delete?", pending = false } },
    }),
  })
  choose("M file.txt +3 -3 3 threads")
  -- All three top-of-file threads have marks on row 0, with combined deterministic `virt_lines_above`.
  eq(mark_rows(), { 0, 0, 0 })
  local top_lines = marks()[1][2]
  eq(top_lines[1], "💬 @octocat Old note. [outdated]")
  eq(top_lines[2], "💬 @octocat Was two. [base]")
  -- Active file-level thread starts unfolded in a 4-sided box.
  eq(top_lines[3]:find("┌─ 💬 @hubot [file] ", 1, true) ~= nil, true)
  eq(top_lines[4]:find("│ File note.", 1, true) ~= nil, true)

  -- Choosing an outdated thread from the panel focuses it inline at top of file.
  choose("💬 @octocat Old note. [outdated]")
  eq(child.api.nvim_get_current_win(), inline_win())
  eq(inline_content(), {
    lines = { "Old note." },
    title = " 💬 @octocat [outdated] ",
    footer = " r reply  x resolve  z fold  q close ",
    split = false,
  })
  child.type_keys("q")
  eq(inline_win(), nil)

  -- Choosing a thread on a deleted file opens a bottom split (no float).
  choose("💬 @octocat Why delete?")
  eq(child.api.nvim_get_current_win(), inline_win())
  local split_info = inline_content()
  eq(split_info.split, true)
  eq(split_info.lines, { "**@octocat**", "", "Why delete?" })
  eq(split_info.title:find("old.txt:1 (base)", 1, true) ~= nil, true)
  child.type_keys("q")
  eq(inline_win(), nil)
end

T["unfolded threads highlight markdown with built-in treesitter parsers"] = function()
  open_review({
    make_thread("md", "file.txt", {
      range = { first = 2, last = 2 },
      comments = {
        {
          author = "octocat",
          body = "Use `count` instead of **num**.",
          pending = false,
        },
      },
    }),
  })
  choose("M file.txt +3 -3 1 thread")
  local chunks = child.lua_get(
    [=[vim.api.nvim_buf_get_extmarks(0,
    require("didymus.review.threads").namespace, { 1, 0 }, { 1, -1 }, { details = true })[1][4].virt_lines[2]]=]
  )
  local by_text = {}
  for _, chunk in ipairs(chunks) do
    by_text[chunk[1]] = chunk[2]
  end
  eq(by_text["`count`"], "@markup.raw.markdown_inline")
  eq(by_text["**num**"], "@markup.strong.markdown_inline")
end

T[":Didymus review focus lets the user move cursor, select, yank, fold and return to code"] = function()
  open_review({
    make_thread("open", "file.txt", {
      range = { first = 2, last = 2 },
      comments = {
        { author = "octocat", body = "First line.\nCopy this snippet.", pending = false },
      },
    }),
  })
  choose("M file.txt +3 -3 1 thread")
  local code_win = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review focus")

  local win = assert(inline_win())
  eq(child.api.nvim_get_current_win(), win)
  eq(inline_content(), {
    lines = { "First line.", "Copy this snippet." },
    title = " 💬 @octocat ",
    footer = " r reply  x resolve  z fold  q close ",
    split = false,
  })
  -- Code below line 2 is pushed down by virt_lines, not covered.
  local screen = screen_lines()
  eq(has_text(screen, "three"), true)
  eq(has_text(screen, "First line."), true)

  -- Move cursor inside the thread, visually select the second line, and yank into register a.
  child.type_keys("j", "V", '"ay')
  eq(child.fn.getreg("a"), "Copy this snippet.\n")

  -- q closes focus and returns to the code window.
  child.type_keys("q")
  eq(inline_win(), nil)
  eq(child.api.nvim_get_current_win(), code_win)

  -- Focus via mapping, then z folds the thread and returns to code.
  child.cmd("nmap <F5> <Plug>(didymus-review-focus)")
  child.type_keys("<F5>")
  eq(child.api.nvim_get_current_win(), inline_win())
  child.type_keys("z")
  eq(inline_win(), nil)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(marks()[1], { 1, { "💬 @octocat First line." } })
end

T[":Didymus review fold folds and unfolds the threads at the cursor line"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  eq(line_marks()[1][1], 1)
  eq(#line_marks()[1][2], 6)
  eq(line_marks()[2], { 4, { "    ✅ @hubot Rename this." } })

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review fold")
  eq(line_marks()[1], { 1, { "💬 @octocat Why TWO?" } })
  child.cmd("Didymus review fold")
  eq(#line_marks()[1][2], 6)
  eq(line_marks()[1][2][1]:find("┌─ 💬 @octocat ", 1, true) ~= nil, true)
  eq(line_marks()[1][2][2]:find("│ Why TWO?", 1, true) ~= nil, true)

  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Didymus review fold")
  eq(#line_marks()[2][2], 3)
  -- A resolved thread is dim.
  local chunks = child.lua_get(
    [=[vim.api.nvim_buf_get_extmarks(0,
    require("didymus.review.threads").namespace, { 4, 0 }, { 4, -1 }, { details = true })[1][4].virt_lines[2]]=]
  )
  eq(chunks[2], { "│ ", "DidymusThreadResolved" })
  eq(chunks[3], { "Rename this.", "DidymusThreadResolved" })
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
  eq(marks(), { { 1, { "💬 @octocat A comment.", "✅ @hubot Second." } } })
  child.cmd("Didymus review fold")
  local unfolded = marks()[1][2]
  eq(#unfolded, 6)
  eq(unfolded[1]:find("┌─ 💬 @octocat ", 1, true) ~= nil, true)
  eq(unfolded[2]:find("│ A comment.", 1, true) ~= nil, true)
  eq(unfolded[4]:find("┌─ ✅ @hubot ", 1, true) ~= nil, true)
  eq(unfolded[5]:find("│ Second.", 1, true) ~= nil, true)
  eq(helpers.picker_calls(child, "select"), {})
end

T["fold all folds all threads if one is unfolded, else it unfolds all threads"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  child.cmd("Didymus review fold all")
  eq(
    line_marks(),
    { { 1, { "💬 @octocat Why TWO?" } }, { 4, { "    ✅ @hubot Rename this." } } }
  )
  child.cmd("Didymus review fold all")
  local all_unfolded = line_marks()
  eq(#all_unfolded[1][2], 6)
  eq(#all_unfolded[2][2], 3)

  -- A refresh keeps the folds.
  child.cmd("Didymus review refresh")
  wait_for(function()
    return child.cmd_capture("messages"):find("refreshed #1", 1, true) ~= nil
  end, "the refresh")
  eq(line_marks(), all_unfolded)
end

T["the mappings fold the thread at the cursor, and all threads"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  child.cmd("nmap <F3> <Plug>(didymus-review-fold)")
  child.cmd("nmap <F4> <Plug>(didymus-review-fold-all)")
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys("<F3>")
  eq(line_marks()[1], { 1, { "💬 @octocat Why TWO?" } })
  child.type_keys("<F4>")
  -- The bottom border shows the mapping of fold.
  eq(line_marks()[1][2][6]:find("└─ <F3> fold ", 1, true) ~= nil, true)
  eq(line_marks()[2][2][3]:find("    └─ <F3> fold ", 1, true) ~= nil, true)
end

T["fold with no thread at the cursor, no thread at a line or no review shows a warning"] = function()
  child.cmd("Didymus review fold")
  expect_message("didymus: no review is open")

  open_review()
  choose("M file.txt +3 -3 4 threads")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review fold")
  expect_message("didymus: no thread at line 3")

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
  choose("M file.txt +3 -3 4 threads")
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Didymus review fold")
  eq(line_marks()[1][2][6]:find([[└─ \rr reply  \rx resolve  \rf fold ]], 1, true) ~= nil, true)
  eq(
    line_marks()[2][2][3]:find([[    └─ \rr reply  \rx unresolve  \rf fold ]], 1, true) ~= nil,
    true
  )

  -- In a narrow window, the keys do not fit in the bottom border.
  child.cmd("vsplit")
  child.cmd("vertical resize 30")
  helpers.wait_for_wrap(child)
  eq(line_marks()[1][2][6]:find("reply", 1, true), nil)
  eq(line_marks()[2][2][2]:find("│ Rename", 1, true) ~= nil, true)
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
  choose("M file.txt +3 -3 4 threads")
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
  choose("M file.txt +3 -3 4 threads")
  child.cmd("edit!")
  eq(mark_rows(), { 0, 0, 1, 4 })

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
