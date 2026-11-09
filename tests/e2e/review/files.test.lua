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

---@class didymus.test.OpenOpts
---@field base table<string, string>? The files of the base commit.
---@field head table<string, string|false>? The files of the head commit. False deletes a file.
---@field edit fun(change: didymus.review.Change)? Change the change before the review opens.

--- Make a repo where the change modifies file.txt, adds new.txt and deletes old.txt. Make it the
--- directory of the child, and give its change to the test provider. Then open the review.
---@param opts didymus.test.OpenOpts?
---@return didymus.test.Review
local function open_review(opts)
  opts = opts or {}
  local repo = helpers.make_repo({
    base = opts.base or { ["file.txt"] = "one\ntwo\nthree\n", ["old.txt"] = "old\n" },
    head = opts.head
      or { ["file.txt"] = "one\n2\nthree\n", ["new.txt"] = "new\n", ["old.txt"] = false },
  })
  if opts.edit then
    opts.edit(repo.change)
  end
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  child.cmd("Didymus review open 1")
  return helpers.wait_for_review(child, "1")
end

---@return didymus.test.PickerCall[]
local function panels()
  return helpers.picker_calls(child, "panel")
end

---@param call didymus.test.PickerCall
---@return string[]
local function texts(call)
  return vim.tbl_map(function(item)
    return item.text
  end, call.items)
end

---@param target integer|string
local function choose(target)
  child.lua("require('didymus.ui.picker.test').choose(...)", { target })
end

--- The path of the current buffer, relative to the directory of the child.
---@return string
local function current_path()
  return child.fn.expand("%:.")
end

--- Make a window on the left current. It stands for the window of a real panel.
---@return integer
local function open_left_window()
  child.cmd("leftabove vnew")
  return child.api.nvim_get_current_win()
end

---@param text string
local function expect_message(text)
  local messages = child.cmd_capture("messages")
  if not messages:find(text, 1, true) then
    error(("%q is not in the messages:\n%s"):format(text, messages), 2)
  end
end

local header = { "#1 Change the second line", "@octocat main ← feature" }

T["the panel shows the header and one row for each file, in the order of the provider"] = function()
  open_review({
    edit = function(change)
      -- git gives the files in the order of the paths. A code host can use a different order.
      change.files = { change.files[3], change.files[1], change.files[2] }
    end,
  })

  local calls = panels()
  eq(#calls, 1)
  eq(calls[1].open, true)
  eq(calls[1].title, "Review #1")
  eq(
    texts(calls[1]),
    vim.list_extend(
      vim.deepcopy(header),
      { "D old.txt +0 -1", "M file.txt +1 -1", "A new.txt +1 -0" }
    )
  )
  eq(calls[1].items[1].segments, { { "#1", "Number" }, { " Change the second line", "Title" } })
  eq(calls[1].items[2].segments, { { "@octocat", "Comment" }, { " main ← feature" } })
  eq(
    calls[1].items[4].segments,
    { { "M", "Changed" }, { " file.txt" }, { " +1", "Added" }, { " -1", "Removed" } }
  )
  eq(calls[1].items[3].segments[1], { "D", "Removed" })
  eq(calls[1].items[5].segments[1], { "A", "Added" })
end

T["to choose a file opens the real file in the code window. The panel stays open"] = function()
  local review = open_review()
  local code_win = child.api.nvim_get_current_win()
  open_left_window()

  choose("M file.txt +1 -1")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(current_path(), "file.txt")
  eq(child.api.nvim_buf_get_lines(0, 0, -1, true), { "one", "2", "three" })
  eq(panels()[1].open, true)

  open_left_window()
  choose("A new.txt +1 -0")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(current_path(), "new.txt")
  eq(#panels(), 1)
end

T["to choose a header row does nothing"] = function()
  open_review()
  local buf = child.api.nvim_get_current_buf()
  choose(1)
  choose(2)
  eq(child.api.nvim_get_current_buf(), buf)
end

T["to choose a deleted file shows a message and opens nothing"] = function()
  open_review()
  local buf = child.api.nvim_get_current_buf()
  choose("D old.txt +0 -1")
  eq(child.api.nvim_get_current_buf(), buf)
  expect_message("didymus: old.txt is deleted in #1")
end

T["if the code window is closed, the file opens in a new window on the right"] = function()
  open_review()
  local code_win = child.api.nvim_get_current_win()
  local left_win = open_left_window()
  child.api.nvim_win_close(code_win, true)

  choose("M file.txt +1 -1")
  local wins = child.api.nvim_tabpage_list_wins(0)
  eq(#wins, 2)
  eq(wins[1], left_win)
  eq(child.api.nvim_get_current_win(), wins[2])
  eq(current_path(), "file.txt")

  -- The new window is now the code window.
  child.api.nvim_set_current_win(left_win)
  choose("A new.txt +1 -0")
  eq(child.api.nvim_tabpage_list_wins(0), wins)
  eq(child.api.nvim_get_current_win(), wins[2])
  eq(current_path(), "new.txt")
end

--- Open a review where the change modifies line 6 and line 18 of long.txt. Line 6 has an indent.
--- The patch has a hunk for each change.
local function open_long_review()
  local base, head = {}, {}
  for line = 1, 20 do
    base[line] = "line " .. line
    head[line] = base[line]
  end
  head[6], head[18] = "  six", "eighteen"
  open_review({
    base = { ["long.txt"] = table.concat(base, "\n") .. "\n" },
    head = { ["long.txt"] = table.concat(head, "\n") .. "\n" },
  })
end

T["to choose a file puts the cursor on the first change of its first hunk"] = function()
  open_long_review()
  open_left_window()
  choose("M long.txt +2 -2")
  eq(current_path(), "long.txt")
  eq(child.api.nvim_win_get_cursor(0), { 6, 2 })
end

T["to choose the file of the code window again moves the cursor, also in a modified buffer"] = function()
  open_long_review()
  local code_win = child.api.nvim_get_current_win()
  choose("M long.txt +2 -2")
  child.api.nvim_buf_set_lines(0, 0, 1, true, { "edited" })
  child.api.nvim_win_set_cursor(0, { 20, 0 })

  open_left_window()
  choose("M long.txt +2 -2")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(child.api.nvim_win_get_cursor(0), { 6, 2 })
  eq(child.bo.modified, true)
  eq(child.api.nvim_buf_get_lines(0, 0, 1, true), { "edited" })
  eq(child.cmd_capture("messages"):find("cannot open"), nil)
end

T["a file with no patch opens at line 1"] = function()
  open_review({
    edit = function(change)
      change.files[1].patch = nil
    end,
  })
  choose("M file.txt +1 -1")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  choose("M file.txt +1 -1")
  eq(child.api.nvim_win_get_cursor(0), { 1, 0 })
end

T["if the file is shorter than the patch, the cursor goes to the last line"] = function()
  open_review({
    edit = function(change)
      change.files[1].patch = "@@ -8,3 +8,4 @@\n eight\n+new\n nine\n ten"
    end,
  })
  choose("M file.txt +1 -1")
  eq(child.api.nvim_win_get_cursor(0), { 3, 0 })
end

T["if Neovim cannot open the file, the error shows and the focus goes back"] = function()
  open_review()
  local code_win = child.api.nvim_get_current_win()
  choose("M file.txt +1 -1")
  child.api.nvim_buf_set_lines(0, 0, 1, true, { "edited" })
  child.o.hidden = false
  local left_win = open_left_window()

  choose("A new.txt +1 -0")
  expect_message(
    "didymus: cannot open new.txt: E37: No write since last change (add ! to override)"
  )
  eq(child.api.nvim_get_current_win(), left_win)
  child.api.nvim_set_current_win(code_win)
  eq(current_path(), "file.txt")
  eq(#panels(), 1)
  eq(panels()[1].open, true)

  -- After a write, the file opens in the same code window.
  child.cmd("write")
  child.api.nvim_set_current_win(left_win)
  choose("A new.txt +1 -0")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(current_path(), "new.txt")
end

T["a file row shows the thread count only if it is above 0"] = function()
  open_review()
  -- The providers do not give threads yet.
  child.lua([[
    require("didymus.review").current().threads =
      { { path = "file.txt" }, { path = "file.txt" }, { path = "new.txt" } }
  ]])
  child.cmd("Didymus review files")
  child.cmd("Didymus review files")
  eq(
    texts(panels()[2]),
    vim.list_extend(vim.deepcopy(header), {
      "M file.txt +1 -1 2 threads",
      "A new.txt +1 -0 1 thread",
      "D old.txt +0 -1",
    })
  )
  eq(panels()[2].items[3].segments[5], { " 2 threads", "Comment" })
end

T[":Didymus review files hides the panel, and shows it again"] = function()
  open_review()
  child.cmd("Didymus review files")
  eq(panels()[1].open, false)

  child.cmd("Didymus review files")
  local calls = panels()
  eq(#calls, 2)
  eq(calls[2].open, true)
  eq(texts(calls[2]), texts(calls[1]))
end

T["files in a different tabpage goes to the review tabpage and shows the panel"] = function()
  local review = open_review()
  child.cmd("tabfirst")
  child.cmd("Didymus review files")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(#panels(), 1)
  eq(panels()[1].open, true)
  eq(panels()[1].focus_count, 1)

  -- In the review tabpage, files hides the panel.
  child.cmd("Didymus review files")
  child.cmd("tabfirst")
  child.cmd("Didymus review files")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(#panels(), 2)
  eq(panels()[2].open, true)
end

T["files with no review shows a warning"] = function()
  child.cmd("Didymus review files")
  expect_message("didymus: no review is open")
  eq(#panels(), 0)
end

T["close and :tabclose also close the panel"] = function()
  open_review()
  child.cmd("Didymus review close")
  eq(panels()[1].open, false)

  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  child.cmd("tabclose")
  eq(panels()[2].open, false)
end

T["if the panel cannot open, the review opens and the error shows"] = function()
  child.lua([[
    local test_picker = require("didymus.ui.picker.test")
    local adapter = setmetatable({
      panel = function()
        error("didymus: no panel", 0)
      end,
    }, { __index = test_picker })
    require("didymus").setup({ review = { picker = adapter, provider = "test" } })
  ]])
  local review = open_review()
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  expect_message("didymus: no panel")
end

T["the mapping hides the panel, and shows it again"] = function()
  open_review()
  child.cmd("nmap <F2> <Plug>(didymus-review-files)")
  child.type_keys("<F2>")
  eq(panels()[1].open, false)
  child.type_keys("<F2>")
  eq(#panels(), 2)
  eq(panels()[2].open, true)
end

return T
