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

--- Make a repo where the change modifies a.txt (8 lines), b.txt (3 lines) and c.txt (5 lines).
--- Make it the directory of the child. Open the review, and wait for its threads.
---@param threads didymus.review.Thread[]?
---@return didymus.test.Review
local function open_review(threads)
  threads = threads or default_threads()
  local repo = helpers.make_repo({
    base = {
      ["a.txt"] = "a1\na2\na3\na4\na5\na6\na7\na8\n",
      ["b.txt"] = "b1\nb2\nb3\n",
      ["c.txt"] = "c1\nc2\nc3\nc4\nc5\n",
    },
    head = {
      ["a.txt"] = "a1\nA2\na3\na4\na5\nA6\na7\na8\n",
      ["b.txt"] = "b1\nB2\nb3\n",
      ["c.txt"] = "c1\nc2\nC3\nc4\nC5\n",
    },
  })
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
  child.cmd("Didymus review prev")
  eq(position(), { "c.txt", 3 })
  child.cmd("Didymus review prev")
  eq(position(), { "a.txt", 6 })
  child.cmd("Didymus review prev")
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

T["the mappings go to the next and the previous thread"] = function()
  open_review()
  open_file("a.txt", 1)
  child.cmd("nmap <F3> <Plug>(didymus-review-next)")
  child.cmd("nmap <F4> <Plug>(didymus-review-prev)")
  child.type_keys("<F3>")
  eq(position(), { "a.txt", 2 })
  child.type_keys("<F3>")
  eq(position(), { "a.txt", 6 })
  child.type_keys("<F4>")
  eq(position(), { "a.txt", 2 })
end

T["next with no review shows a warning"] = function()
  child.cmd("Didymus review next")
  expect_message("didymus: no review is open")
end

return T
