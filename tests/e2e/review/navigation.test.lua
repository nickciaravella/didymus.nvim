local helpers = dofile("tests/e2e/review/helpers.lua")

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

--- The threads in the order of the provider. The stops of the panel order are a.txt:2, a.txt:6,
--- c.txt:3 and c.txt:5. b.txt has no threads.
---@return didymus.review.Thread[]
local function default_threads()
  return {
    make_thread("c5", "c.txt", { range = { first = 5, last = 5 } }),
    make_thread("a-outdated", "a.txt", { outdated = true }),
    make_thread("a6", "a.txt", { range = { first = 5, last = 6 } }),
    make_thread("c3", "c.txt", { range = { first = 3, last = 3 } }),
    make_thread("c3-range", "c.txt", { range = { first = 1, last = 3 } }),
    make_thread("a2", "a.txt", { range = { first = 2, last = 2 } }),
  }
end

--- The text of a file with `count` lines, such as "a1\na2\n". `changes` replaces some lines.
---@param prefix string
---@param count integer
---@param changes table<integer, string>?
---@return string
local function make_text(prefix, count, changes)
  local lines = {}
  for line = 1, count do
    table.insert(lines, (changes or {})[line] or prefix .. line)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The change modifies a.txt (8 lines), b.txt (3 lines) and c.txt (5 lines).
local thread_files = {
  base = {
    ["a.txt"] = make_text("a", 8),
    ["b.txt"] = make_text("b", 3),
    ["c.txt"] = make_text("c", 5),
  },
  head = {
    ["a.txt"] = make_text("a", 8, { [2] = "A2", [6] = "A6" }),
    ["b.txt"] = make_text("b", 3, { [2] = "B2" }),
    ["c.txt"] = make_text("c", 5, { [3] = "C3", [5] = "C5" }),
  },
}

--- The change modifies a.txt (12 lines) with hunks at lines 2 and 10, and deletes b.txt. It
--- modifies c.txt (5 lines) with a hunk at line 3, and adds d.txt (2 lines).
local hunk_files = {
  base = {
    ["a.txt"] = make_text("a", 12),
    ["b.txt"] = make_text("b", 2),
    ["c.txt"] = make_text("c", 5),
  },
  head = {
    ["a.txt"] = make_text("a", 12, { [2] = "A2", [10] = "A10" }),
    ["b.txt"] = false,
    ["c.txt"] = make_text("c", 5, { [3] = "C3" }),
    ["d.txt"] = make_text("d", 2),
  },
}

--- Make a repo with the files of the change, and make it the directory of the child. Open the
--- review, and wait for its threads.
---@param threads didymus.review.Thread[]? Default `default_threads()`.
---@param files { base: table<string, string>, head: table<string, string|false> }? Default `thread_files`.
---@return didymus.test.Review
local function open_review(threads, files)
  threads = threads or default_threads()
  local repo = helpers.make_repo(files or thread_files)
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads)
  child.cmd("Didymus review open 1")
  local review = helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, #threads)
  return review
end

--- Choose the file in the panel, and put the cursor on `line`.
---@param path string
---@param line integer
local function open_file(path, line)
  for index, item in ipairs(helpers.picker_calls(child, "panel")[1].items) do
    if item.value.kind == "file" and item.value.file.path == path then
      child.lua("require('didymus.ui.picker.test').choose(...)", { index })
      child.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
  error("no file " .. path .. " in the panel")
end

--- The path and the cursor line of the current window.
---@return [string, integer]
local function position()
  return { child.fn.expand("%:."), child.api.nvim_win_get_cursor(0)[1] }
end

---@param text string
local function expect_message(text)
  local messages = child.cmd_capture("messages")
  if not messages:find(text, 1, true) then
    error(("%q is not in the messages:\n%s"):format(text, messages), 2)
  end
end

T["next goes to the next thread in the same file, then to the first thread of the next file"] = function()
  open_review()
  open_file("a.txt", 1)
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 2 })
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 6 })
  -- b.txt has no threads. The two threads at line 3 are one stop.
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 5 })
end

T["prev goes back"] = function()
  open_review()
  open_file("c.txt", 5)
  child.cmd("Didymus review prev thread")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review prev thread")
  eq(position(), { "a.txt", 6 })
  child.cmd("Didymus review prev thread")
  eq(position(), { "a.txt", 2 })
end

T["next and prev skip the outdated threads and the other threads with no line"] = function()
  open_review({
    make_thread("a2", "a.txt", { range = { first = 2, last = 2 } }),
    make_thread("a-outdated", "a.txt", { outdated = true }),
    make_thread("b-base", "b.txt", { side = "base", range = { first = 2, last = 2 } }),
    make_thread("b-file", "b.txt"),
    make_thread("c3", "c.txt", { range = { first = 3, last = 3 } }),
  })
  open_file("a.txt", 2)
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review prev")
  eq(position(), { "a.txt", 2 })
end

T["with the active filter of the panel, next and prev skip the resolved threads"] = function()
  open_review({
    make_thread("a2", "a.txt", { range = { first = 2, last = 2 } }),
    make_thread("a6", "a.txt", { range = { first = 6, last = 6 }, resolved = true }),
    make_thread("c3", "c.txt", { range = { first = 3, last = 3 } }),
  })
  open_file("a.txt", 1)
  child.lua("require('didymus.ui.picker.test').press('a')")
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 2 })
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review prev")
  eq(position(), { "a.txt", 2 })

  -- All threads again.
  child.lua("require('didymus.ui.picker.test').press('a')")
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 6 })
end

T["at the last thread, next shows a message and does not move"] = function()
  open_review()
  open_file("c.txt", 5)
  child.cmd("Didymus review next")
  expect_message("didymus: no next thread")
  eq(position(), { "c.txt", 5 })

  open_file("a.txt", 2)
  child.cmd("Didymus review prev")
  expect_message("didymus: no previous thread")
  eq(position(), { "a.txt", 2 })
end

T["from a file with no threads, next and prev go to the threads of the other files"] = function()
  open_review()
  open_file("b.txt", 1)
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 3 })
  open_file("b.txt", 3)
  child.cmd("Didymus review prev")
  eq(position(), { "a.txt", 6 })
end

T["with no file of the change in the code window, next goes to the first thread and prev to the last thread"] = function()
  open_review()
  child.cmd("Didymus review prev")
  eq(position(), { "c.txt", 5 })
  child.cmd("enew")
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 2 })
end

T["from a window with no file of the change, next starts at the cursor of the code window"] = function()
  open_review()
  open_file("a.txt", 3)
  local code_win = child.api.nvim_get_current_win()
  child.cmd("leftabove vnew")
  child.cmd("Didymus review next")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(position(), { "a.txt", 6 })
  -- The jump in the same file is in the jumplist.
  child.type_keys("<C-o>")
  eq(position(), { "a.txt", 3 })
end

T["from a different tabpage, next goes to the review tabpage"] = function()
  local review = open_review()
  open_file("a.txt", 3)
  local code_win = child.api.nvim_get_current_win()
  child.cmd("tabfirst")
  child.cmd("Didymus review next")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(position(), { "a.txt", 6 })
end

T["in a split that shows the file, the cursor moves in the split"] = function()
  open_review()
  open_file("a.txt", 1)
  local code_win = child.api.nvim_get_current_win()
  child.cmd("split")
  local split_win = child.api.nvim_get_current_win()
  child.cmd("Didymus review next")
  eq(child.api.nvim_get_current_win(), split_win)
  eq(position(), { "a.txt", 2 })
  eq(child.api.nvim_win_get_cursor(code_win), { 1, 0 })
end

T["<C-o> goes back to the position before each jump"] = function()
  open_review()
  open_file("a.txt", 1)
  child.cmd("Didymus review next")
  child.cmd("Didymus review next")
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 3 })
  child.type_keys("<C-o>")
  eq(position(), { "a.txt", 6 })
  child.type_keys("<C-o>")
  eq(position(), { "a.txt", 2 })
  child.type_keys("<C-o>")
  eq(position(), { "a.txt", 1 })
end

T["the threads after the end of the buffer are one stop on the last line"] = function()
  open_review({
    make_thread("a2", "a.txt", { range = { first = 2, last = 2 } }),
    make_thread("a20", "a.txt", { range = { first = 20, last = 20 } }),
    make_thread("a30", "a.txt", { range = { first = 30, last = 30 } }),
    make_thread("c3", "c.txt", { range = { first = 3, last = 3 } }),
  })
  open_file("a.txt", 2)
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 8 })
  child.cmd("Didymus review next")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review prev")
  eq(position(), { "a.txt", 8 })
  child.cmd("Didymus review prev")
  eq(position(), { "a.txt", 2 })
end

T["next file goes to the first change of the next file, and skips the deleted files"] = function()
  open_review({}, hunk_files)
  -- The first change of a.txt is after the cursor, but it is in the same file.
  open_file("a.txt", 1)
  child.cmd("Didymus review next file")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review next file")
  eq(position(), { "d.txt", 1 })
  child.cmd("Didymus review next file")
  expect_message("didymus: no next file")
  eq(position(), { "d.txt", 1 })
end

T["prev file goes to the first change of the previous file"] = function()
  open_review({}, hunk_files)
  -- The first change of c.txt is before the cursor, but it is in the same file.
  open_file("c.txt", 5)
  child.cmd("Didymus review prev file")
  eq(position(), { "a.txt", 2 })
  child.cmd("Didymus review prev file")
  expect_message("didymus: no previous file")
  eq(position(), { "a.txt", 2 })
end

T["next hunk goes to the next hunk, also in the next file"] = function()
  open_review({}, hunk_files)
  open_file("a.txt", 1)
  child.cmd("Didymus review next hunk")
  eq(position(), { "a.txt", 2 })
  child.cmd("Didymus review next hunk")
  eq(position(), { "a.txt", 10 })
  child.cmd("Didymus review next hunk")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review next hunk")
  eq(position(), { "d.txt", 1 })
  child.cmd("Didymus review next hunk")
  expect_message("didymus: no next hunk")
  eq(position(), { "d.txt", 1 })
end

T["prev hunk goes back"] = function()
  open_review({}, hunk_files)
  open_file("d.txt", 2)
  child.cmd("Didymus review prev hunk")
  eq(position(), { "d.txt", 1 })
  child.cmd("Didymus review prev hunk")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review prev hunk")
  eq(position(), { "a.txt", 10 })
  child.cmd("Didymus review prev hunk")
  eq(position(), { "a.txt", 2 })
  child.cmd("Didymus review prev hunk")
  expect_message("didymus: no previous hunk")
  eq(position(), { "a.txt", 2 })
end

T["next file from a different tabpage goes to the review tabpage, and <C-o> goes back"] = function()
  local review = open_review({}, hunk_files)
  open_file("a.txt", 4)
  child.cmd("tabfirst")
  child.cmd("Didymus review next file")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(position(), { "c.txt", 3 })
  child.type_keys("<C-o>")
  eq(position(), { "a.txt", 4 })
end

T["with no file of the change in the code window, next file goes to the first file and prev hunk to the last hunk"] = function()
  open_review({}, hunk_files)
  child.cmd("Didymus review next file")
  eq(position(), { "a.txt", 2 })
  child.cmd("enew")
  child.cmd("Didymus review prev hunk")
  eq(position(), { "d.txt", 1 })
end

T["the mappings go to the next and the previous thread, file and hunk"] = function()
  open_review({ make_thread("a5", "a.txt", { range = { first = 5, last = 5 } }) }, hunk_files)
  for index, name in ipairs({
    "next-thread",
    "next-file",
    "next-hunk",
    "prev-thread",
    "prev-file",
    "prev-hunk",
  }) do
    child.cmd(("nmap <F%d> <Plug>(didymus-review-%s)"):format(index, name))
  end
  open_file("a.txt", 12)
  child.type_keys("<F4>")
  eq(position(), { "a.txt", 5 })
  child.type_keys("<F6>")
  eq(position(), { "a.txt", 2 })
  child.type_keys("<F3>")
  eq(position(), { "a.txt", 10 })
  child.type_keys("<F2>")
  eq(position(), { "c.txt", 3 })
  child.type_keys("<F5>")
  eq(position(), { "a.txt", 2 })
  child.type_keys("<F1>")
  eq(position(), { "a.txt", 5 })
end

T["next thread unfolds the threads at the stop, and scrolls so that they show"] = function()
  local comments = {}
  for index = 1, 8 do
    table.insert(
      comments,
      { author = "octocat", body = "Comment " .. index .. ".", pending = false }
    )
  end
  open_review({
    make_thread("a2", "a.txt", { range = { first = 2, last = 2 }, resolved = true }),
    make_thread("a30", "a.txt", { range = { first = 30, last = 30 }, comments = comments }),
  }, {
    base = { ["a.txt"] = make_text("a", 40) },
    head = { ["a.txt"] = make_text("a", 40, { [2] = "A2", [30] = "A30" }) },
  })
  open_file("a.txt", 1)
  child.cmd("Didymus review fold all")
  -- A move to a hunk does not unfold.
  child.cmd("Didymus review next hunk")
  eq(helpers.thread_marks(child)[1].lines, { "✅ @octocat A comment." })

  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 2 })
  eq(helpers.thread_marks(child)[1].lines, { "┌ ✅ @octocat", "└ A comment." })

  child.cmd("Didymus review next")
  eq(position(), { "a.txt", 30 })
  eq(#helpers.thread_marks(child)[2].lines, 16)
  local screen = vim.tbl_map(function(row)
    return vim.trim(table.concat(row))
  end, child.get_screenshot().text)
  -- The sign is the comment count.
  eq(vim.tbl_contains(screen, "8 A30"), true)
  eq(vim.tbl_contains(screen, "└ Comment 8."), true)
end

T["next with an unknown kind shows an error"] = function()
  open_review()
  -- An error message in a command is an error of `child.cmd()`.
  child.lua("require('didymus.command').run('review next line')")
  expect_message("didymus: cannot go to the next line. Use thread, file or hunk.")
end

T["next with no review shows a warning"] = function()
  child.cmd("Didymus review next")
  expect_message("didymus: no review is open")
end

return T
