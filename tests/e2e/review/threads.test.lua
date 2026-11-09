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
  eq(
    vim.tbl_map(function(item)
      return { item.depth or 0, item.text }
    end, vim.list_slice(items, 3)),
    {
      { 0, "M file.txt +3 -3 4 threads" },
      { 1, "@octocat Why TWO?" },
      { 1, "@hubot Rename this. [resolved]" },
      { 1, "@octocat Old note. [outdated]" },
      { 1, "@octocat Was two." },
      { 0, "D old.txt +0 -1 1 thread" },
      { 1, "@octocat Why delete?" },
    }
  )
  eq(items[4].segments, { { "@octocat", "DidymusThread" }, { " Why TWO?" } })
  eq(items[5].segments, {
    { "@hubot", "DidymusThreadResolved" },
    { " Rename this.", "DidymusThreadResolved" },
    { " [resolved]", "DidymusThreadResolved" },
  })
  eq(items[6].segments[3], { " [outdated]", "DiagnosticWarn" })
end

T["to choose a thread goes to its line in the code window"] = function()
  local review = open_review()
  local code_win = child.api.nvim_get_current_win()
  child.cmd("leftabove vnew")

  choose("@hubot Rename this. [resolved]")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(current_path(), "file.txt")
  eq(child.api.nvim_win_get_cursor(0), { 5, 4 })
  eq(float_win(), nil)
end

T["the sign and the summary show at the line of each thread"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  -- The tabline and the status line show the temporary path.
  child.o.showtabline, child.o.laststatus, child.o.ruler = 0, 0, false
  child.cmd("echo ''")
  expect_screenshot(child.get_screenshot())
end

T["outdated threads and threads on the base side have no mark"] = function()
  open_review({
    make_thread("outdated", "file.txt", { outdated = true }),
    make_thread("base", "file.txt", { side = "base", range = { first = 2, last = 2 } }),
    make_thread("file", "file.txt"),
  })
  choose("M file.txt +3 -3 3 threads")
  eq(mark_rows(), {})
end

T["to choose a thread with no line opens its float"] = function()
  open_review()
  local win = child.api.nvim_get_current_win()
  choose("@octocat Old note. [outdated]")
  eq(child.api.nvim_get_current_win(), win)
  eq(
    float_content(),
    { lines = { "**@octocat**", "", "Old note." }, title = " file.txt (outdated) " }
  )

  -- In a real panel, the move to a different row closes the float.
  child.cmd("doautocmd CursorMoved")
  eq(float_win(), nil)
  choose("@octocat Why delete?")
  eq(float_content().title, " old.txt:1 (base) ")
end

T[":Didymus review thread opens the float with all comments"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  local code_win = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review thread")
  eq(float_content(), {
    -- The markdown float of Neovim joins empty lines, and draws `---` as a line.
    lines = {
      "**@octocat**",
      "",
      "Why TWO?",
      "More text.",
      ("─"):rep(20),
      "**@hubot** *pending*",
      "",
      "Because.",
    },
    title = " file.txt:2 ",
  })
  eq(child.api.nvim_get_current_win(), code_win)
  local float_buf = child.api.nvim_win_get_buf(assert(float_win()))
  eq(child.api.nvim_get_option_value("filetype", { buf = float_buf }), "markdown")

  -- A second call focuses the float, and a third call goes back. A move of the cursor in the code
  -- window closes it.
  child.cmd("Didymus review thread")
  eq(child.api.nvim_get_current_win(), float_win())
  child.cmd("Didymus review thread")
  eq(child.api.nvim_get_current_win(), code_win)
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("doautocmd CursorMoved")
  eq(float_win(), nil)
  child.cmd("Didymus review thread")
  eq(float_content().title, " file.txt:5 (resolved) ")
end

T[":Didymus review thread with no thread at the cursor shows a warning"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd("Didymus review thread")
  expect_message("didymus: no thread at line 1")
  eq(float_win(), nil)
end

T["with two threads at the line, the picker asks which one to open"] = function()
  open_review({
    make_thread("first", "file.txt", { range = { first = 2, last = 2 } }),
    make_thread("second", "file.txt", {
      range = { first = 1, last = 2 },
      comments = { { author = "hubot", body = "Second.", pending = false } },
    }),
  })
  choose("M file.txt +3 -3 2 threads")
  child.cmd("Didymus review thread")
  local select = helpers.picker_calls(child, "select")[1]
  eq(select.title, "Threads at line 2")
  eq(
    vim.tbl_map(function(item)
      return item.text
    end, select.items),
    { "@octocat A comment.", "@hubot Second." }
  )
  choose("@hubot Second.")
  eq(float_content().lines, { "**@hubot**", "", "Second." })
end

T["the mapping opens the thread at the cursor"] = function()
  open_review()
  choose("M file.txt +3 -3 4 threads")
  child.cmd("nmap <F3> <Plug>(didymus-review-thread)")
  child.type_keys("<F3>")
  eq(float_content().title, " file.txt:2 ")
end

T["thread with no review shows a warning"] = function()
  child.cmd("Didymus review thread")
  expect_message("didymus: no review is open")
end

T["the marks show only in the windows of the review tabpage"] = function()
  local review = open_review()
  choose("M file.txt +3 -3 4 threads")
  local review_lines = screen_lines()
  eq(has_text(review_lines, "2 TWO"), true)
  eq(has_text(review_lines, "@octocat Why TWO?"), true)

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
    local _, matches = line:gsub("@octocat Why TWO%?", "")
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
