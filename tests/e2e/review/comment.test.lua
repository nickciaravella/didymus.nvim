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

--- The lines of file.txt: "line 1" to "line 20".
---@return string[]
local function base_lines()
  local lines = {}
  for line = 1, 20 do
    lines[line] = "line " .. line
  end
  return lines
end

---@param lines string[]
---@return string
local function to_text(lines)
  return table.concat(lines, "\n") .. "\n"
end

--- Make a repo where the change modifies lines 2 and 18 of file.txt. The commentable ranges are
--- lines 1-5 and 15-20. Make it the directory of the child. Open the review with one thread on
--- line 19, wait for the thread, and edit file.txt.
---@param opts { no_patch: boolean? }? With `no_patch`, the commentable ranges are unknown.
---@return didymus.test.Repo
local function open_review(opts)
  local head = base_lines()
  head[2], head[18] = "LINE 2", "LINE 18"
  local repo = helpers.make_repo({
    base = { ["file.txt"] = to_text(base_lines()), ["other.txt"] = "other\n" },
    head = { ["file.txt"] = to_text(head), ["other.txt"] = "OTHER\n" },
  })
  if opts and opts.no_patch then
    repo.change.files[1].patch = nil
  end
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", {
    helpers.make_thread("old", "file.txt", { range = { first = 19, last = 19 } }),
  })
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, 1)
  child.cmd("edit file.txt")
  return repo
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

--- Wait for the inline comment box, and give its title and its lines.
---@return { title: string, lines: string[], footer: string? }
local function wait_for_input()
  wait_for(function()
    return inline_win() ~= nil
  end, "the inline comment box")
  local win = assert(inline_win())
  local cfg = child.api.nvim_win_get_config(win)
  return {
    title = cfg.title[2][1],
    footer = cfg.footer and cfg.footer[2][1],
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

--- The threads of the change in the test provider.
---@return didymus.review.Thread[]
local function provider_threads()
  return child.lua_get("require('didymus.review.provider.test').threads['1']")
end

--- The rows of the panel under the three header rows.
---@return string[]
local function panel_rows()
  local items = helpers.picker_calls(child, "panel")[1].items
  return vim.tbl_map(function(item)
    return item.text
  end, vim.list_slice(items, 4))
end

--- The row and the lines of each mark in the current buffer, 0-based.
---@return [integer, string[]][]
local function marks()
  return vim.tbl_map(function(mark)
    return { mark.row, mark.lines }
  end, helpers.thread_marks(child))
end

T["add to review shows the comment as pending in the panel and at the line"] = function()
  open_review()
  local code_win = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  local box = wait_for_input()
  eq(box, {
    title = " New comment (file.txt:3) ",
    footer = " <C-s> comment now  <C-y> add to review  q cancel ",
    lines = { "" },
  })
  eq(child.api.nvim_get_mode().mode, "i")
  eq(
    child.api.nvim_get_option_value(
      "filetype",
      { buf = child.api.nvim_win_get_buf(assert(inline_win())) }
    ),
    "markdown"
  )

  child.type_keys("Looks good.", "<C-y>")
  helpers.wait_for_threads(child, 2)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(inline_win(), nil)
  eq(provider_threads()[2], {
    id = "added-1",
    path = "file.txt",
    side = "head",
    range = { first = 3, last = 3 },
    resolved = false,
    outdated = false,
    can_reply = true,
    can_resolve = false,
    can_unresolve = false,
    comments = { { author = "reviewer", body = "Looks good.", pending = true } },
  })
  eq(panel_rows(), {
    "M file.txt +2 -2 2 threads",
    "💬 @reviewer Looks good. [pending]",
    "💬 @octocat A comment.",
    "M other.txt +1 -1",
  })
  eq(helpers.picker_calls(child, "panel")[1].items[5].segments, {
    { "💬 " },
    { "@reviewer", "DidymusThread" },
    { " Looks good." },
    { " [pending]", "DidymusThreadPending" },
  })
  -- A new thread is active, so it is unfolded in a 4-sided box.
  eq(marks()[1][1], 2)
  eq(marks()[1][2][1]:find("┌─ 💬 @reviewer [pending] ", 1, true) ~= nil, true)
  eq(marks()[1][2][2]:find("│ Looks good.", 1, true) ~= nil, true)
  eq(has_message("didymus: added a pending comment at file.txt:3"), true)
end

T["inline comment pushes code down and grows with new lines"] = function()
  child.o.lines, child.o.columns = 14, 60
  open_review()
  child.o.showtabline, child.o.laststatus, child.o.ruler = 0, 0, false
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  wait_for_input()
  child.type_keys("Line one of comment.", "<CR>", "Line two.")
  child.cmd("stopinsert")
  child.cmd("echo ''")
  -- Line 4 stays visible below the inline comment box.
  local screen = vim.tbl_map(function(row)
    return table.concat(row)
  end, child.get_screenshot().text)
  local has_line_3, has_line_4, has_comment = false, false, false
  for _, row in ipairs(screen) do
    if row:find("line 3", 1, true) then
      has_line_3 = true
    end
    if row:find("line 4", 1, true) then
      has_line_4 = true
    end
    if row:find("Line two.", 1, true) then
      has_comment = true
    end
  end
  eq({ has_line_3, has_line_4, has_comment }, { true, true, true })
  expect_screenshot(child.get_screenshot())
end

T["an open inline comment stays alive when leaving, hides off screen, and blocks a second editor"] = function()
  child.o.lines, child.o.columns = 12, 60
  open_review()
  local code_win = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Didymus review comment")
  wait_for_input()
  child.type_keys("Draft text.", "<Esc>", "<Esc>")

  -- `<Esc>` in normal mode leaves the box back to the code window, keeping the draft open.
  eq(child.api.nvim_get_current_win(), code_win)
  local win = assert(inline_win())
  eq(child.api.nvim_win_get_config(win).hide, false)

  -- Triggering a comment at another line refuses with a warning.
  child.api.nvim_win_set_cursor(0, { 4, 0 })
  child.cmd("Didymus review comment")
  eq(
    has_message(
      "didymus: another comment is already open at file.txt:2. Submit or cancel it first."
    ),
    true
  )

  -- Scrolling line 2 off the top hides the inline box without losing its text.
  child.api.nvim_win_set_cursor(0, { 20, 0 })
  child.cmd("redraw")
  wait_for(function()
    return child.api.nvim_win_get_config(win).hide == true
  end, "the hidden inline box after scroll")

  -- Opening another file keeps it hidden; returning to file.txt at line 2 shows it again.
  child.cmd("edit other.txt")
  eq(child.api.nvim_win_get_config(win).hide, true)
  child.cmd("edit file.txt")
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("redraw")
  wait_for(function()
    return child.api.nvim_win_get_config(win).hide == false
  end, "the restored inline box")

  -- Re-running comment at the same line focuses the open editor with its draft text.
  child.cmd("Didymus review comment")
  eq(child.api.nvim_get_current_win(), win)
  eq(child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, true), { "Draft text." })
  child.type_keys("<Esc>", "q")
  eq(inline_win(), nil)
end

T["comment now posts the comment, with no pending tag"] = function()
  open_review()
  -- A new thread is active, so it also shows when the panel shows only the active threads.
  child.lua("require('didymus.ui.picker.test').press('a')")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  wait_for_input()
  child.type_keys("Looks good.", "<C-s>")
  helpers.wait_for_threads(child, 2)
  eq(
    provider_threads()[2].comments,
    { { author = "reviewer", body = "Looks good.", pending = false } }
  )
  eq(helpers.picker_calls(child, "panel")[1].items[3].text, "Active threads")
  eq(panel_rows()[2], "💬 @reviewer Looks good.")
  eq(marks()[1][1], 2)
  eq(marks()[1][2][1]:find("┌─ 💬 @reviewer ", 1, true) ~= nil, true)
  eq(marks()[1][2][1]:find("[pending]", 1, true), nil)
  eq(has_message("didymus: posted a comment at file.txt:3"), true)
end

T["a comment on the selection in visual mode is a range comment"] = function()
  open_review()
  child.lua("vim.keymap.set({ 'n', 'x' }, 'gC', '<Plug>(didymus-review-comment)')")
  local code_buf = child.api.nvim_get_current_buf()
  child.api.nvim_win_set_cursor(0, { 17, 0 })
  child.type_keys("V", "k", "gC")
  eq(wait_for_input().title, " New comment (file.txt:16-17) ")
  -- The command leaves visual mode, and `gv` selects the lines again.
  eq(
    { child.api.nvim_buf_get_mark(code_buf, "<")[1], child.api.nvim_buf_get_mark(code_buf, ">")[1] },
    { 16, 17 }
  )

  child.type_keys("Two lines.", "<C-y>")
  helpers.wait_for_threads(child, 2)
  local thread = provider_threads()[2]
  eq({ thread.range, thread.comments[1].body }, { { first = 16, last = 17 }, "Two lines." })
  eq(marks()[1][1], 16)
  eq(marks()[1][2][2]:find("│ Two lines.", 1, true) ~= nil, true)
end

T["a comment on a command range, and a cancel, add no comment"] = function()
  open_review()
  child.cmd("2,4Didymus review comment")
  eq(wait_for_input().title, " New comment (file.txt:2-4) ")
  child.type_keys("Not sent.", "<Esc>", "q")
  eq(inline_win(), nil)
  -- The provider calls `cb` in `vim.schedule()`. Give it a chance to run.
  child.lua("vim.wait(50)")
  eq(#provider_threads(), 1)
  eq(child.lua_get("#require('didymus.review').current().threads"), 1)
end

T["a line or a range out of the commentable ranges shows the reason"] = function()
  open_review()
  child.api.nvim_win_set_cursor(0, { 10, 0 })
  child.cmd("Didymus review comment")
  eq(has_message("didymus: line 10 of file.txt is not in a hunk of #1"), true)

  -- GitHub does not show a range across two hunks well.
  child.cmd("4,16Didymus review comment")
  eq(has_message("didymus: lines 4-16 of file.txt are not in one hunk of #1"), true)
  child.lua("vim.wait(50)")
  eq(inline_win(), nil)
end

T["with unknown commentable ranges, the code host decides"] = function()
  open_review({ no_patch = true })
  child.api.nvim_win_set_cursor(0, { 10, 0 })
  child.cmd("Didymus review comment")
  eq(wait_for_input().title, " New comment (file.txt:10) ")
end

T["a modified buffer shows the reason"] = function()
  open_review()
  child.api.nvim_buf_set_lines(0, 0, 1, true, { "changed" })
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  eq(
    has_message("didymus: file.txt is modified. A comment needs the lines of the head of #1."),
    true
  )
  child.lua("vim.wait(50)")
  eq(inline_win(), nil)
end

T["a file that is different from the change head shows the reason"] = function()
  local repo = open_review()
  local message =
    "didymus: file.txt is different from the head of #1. A comment needs the lines of the head."
  local lines = base_lines()
  lines[1] = "new line 1"
  helpers.write(repo.dir, { ["file.txt"] = to_text(lines) })
  child.cmd("edit!")
  child.cmd("Didymus review comment")
  wait_for_message(message)
  eq(inline_win(), nil)

  -- A local commit also changes the line numbers. It moves HEAD from the change head.
  helpers.git(repo.dir, { "commit", "--quiet", "--all", "--message", "local" })
  child.cmd("messages clear")
  child.cmd("Didymus review comment")
  wait_for_message(
    "didymus: HEAD is not the head of #1. To check it out, close the review and open it again."
  )
  eq(inline_win(), nil)
end

T["a window with no file of the change shows the reason"] = function()
  open_review()
  child.cmd("enew")
  child.cmd("Didymus review comment")
  eq(has_message("didymus: the current window does not show a file of #1"), true)
end

T["with no open review, a warning shows"] = function()
  child.cmd("Didymus review comment")
  eq(has_message("didymus: no review is open"), true)
end

T["after an error, the next comment at the same lines starts with the text"] = function()
  open_review()
  child.lua("require('didymus.review.provider.test').errors.add_comment = 'no network'")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  wait_for_input()
  child.type_keys("First try.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-s>")
  wait_for_message(
    "didymus: cannot post the comment at file.txt:3: no network. "
      .. "The next comment at these lines starts with its text."
  )
  eq(child.lua_get("#require('didymus.review').current().threads"), 1)

  -- A comment at different lines starts empty.
  child.api.nvim_win_set_cursor(0, { 4, 0 })
  child.cmd("Didymus review comment")
  local other_box = wait_for_input()
  eq({ other_box.title, other_box.lines }, { " New comment (file.txt:4) ", { "" } })
  child.type_keys("<Esc>", "q")

  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  local retry_box = wait_for_input()
  eq({ retry_box.title, retry_box.lines }, { " New comment (file.txt:3) ", { "First try." } })
  -- The text stays also for the other action.
  child.type_keys(" Again.", "<C-y>")
  helpers.wait_for_threads(child, 2)
  local comment = provider_threads()[2].comments[1]
  eq({ comment.body, comment.pending }, { "First try. Again.", true })
end

return T
