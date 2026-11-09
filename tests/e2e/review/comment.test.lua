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
    base = { ["file.txt"] = to_text(base_lines()) },
    head = { ["file.txt"] = to_text(head) },
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
local function float_win()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    if child.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

--- Wait for the input float, and give its title and its lines.
---@return { title: string, lines: string[] }
local function wait_for_input()
  wait_for(function()
    return float_win() ~= nil
  end, "the input float")
  local win = assert(float_win())
  return {
    title = child.api.nvim_win_get_config(win).title[1][1],
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

--- The rows of the panel under the file.
---@return string[]
local function panel_rows()
  local items = helpers.picker_calls(child, "panel")[1].items
  return vim.tbl_map(function(item)
    return item.text
  end, vim.list_slice(items, 3))
end

--- The row and the summary of each mark in the current buffer, 0-based.
---@return { [1]: integer, [2]: string }[]
local function marks()
  return child.lua_get([[
    vim.tbl_map(function(mark)
      local texts = vim.tbl_map(function(segment)
        return segment[1]
      end, mark[4].virt_lines[1])
      return { mark[2], vim.trim(table.concat(texts)) }
    end, vim.api.nvim_buf_get_extmarks(
      0,
      require("didymus.review.threads").namespace,
      0,
      -1,
      { details = true }
    ))
  ]])
end

T["a comment on one line shows as pending in the panel and at the line"] = function()
  open_review()
  local code_win = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  eq(wait_for_input(), { title = " file.txt:3 ", lines = { "" } })
  eq(child.api.nvim_get_mode().mode, "i")

  child.type_keys("Looks good.", "<C-s>")
  helpers.wait_for_threads(child, 2)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(float_win(), nil)
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
    "@reviewer Looks good. [pending]",
    "@octocat A comment.",
  })
  eq(helpers.picker_calls(child, "panel")[1].items[4].segments, {
    { "@reviewer", "DidymusThread" },
    { " Looks good." },
    { " [pending]", "DidymusThreadPending" },
  })
  eq(marks(), { { 2, "@reviewer Looks good. [pending]" }, { 18, "@octocat A comment." } })
  eq(has_message("didymus: added a pending comment at file.txt:3"), true)
end

T["a comment on the selection in visual mode is a range comment"] = function()
  open_review()
  child.lua("vim.keymap.set({ 'n', 'x' }, 'gC', '<Plug>(didymus-review-comment)')")
  local code_buf = child.api.nvim_get_current_buf()
  child.api.nvim_win_set_cursor(0, { 17, 0 })
  child.type_keys("V", "k", "gC")
  eq(wait_for_input().title, " file.txt:16-17 ")
  -- The command leaves visual mode, and `gv` selects the lines again.
  eq(
    { child.api.nvim_buf_get_mark(code_buf, "<")[1], child.api.nvim_buf_get_mark(code_buf, ">")[1] },
    { 16, 17 }
  )

  child.type_keys("Two lines.", "<C-s>")
  helpers.wait_for_threads(child, 2)
  local thread = provider_threads()[2]
  eq({ thread.range, thread.comments[1].body }, { { first = 16, last = 17 }, "Two lines." })
  eq(marks()[1], { 16, "@reviewer Two lines. [pending]" })
end

T["a comment on a command range, and a cancel, add no comment"] = function()
  open_review()
  child.cmd("2,4Didymus review comment")
  eq(wait_for_input().title, " file.txt:2-4 ")
  child.type_keys("Not sent.", "<Esc>", "q")
  eq(float_win(), nil)
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
  eq(float_win(), nil)
end

T["with unknown commentable ranges, the code host decides"] = function()
  open_review({ no_patch = true })
  child.api.nvim_win_set_cursor(0, { 10, 0 })
  child.cmd("Didymus review comment")
  eq(wait_for_input().title, " file.txt:10 ")
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
  eq(float_win(), nil)
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
  eq(float_win(), nil)

  -- A local commit also changes the line numbers.
  helpers.git(repo.dir, { "commit", "--quiet", "--all", "--message", "local" })
  child.cmd("messages clear")
  child.cmd("Didymus review comment")
  wait_for_message(message)
  eq(float_win(), nil)
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
    "didymus: cannot add the comment at file.txt:3: no network. "
      .. "The next comment at these lines starts with its text."
  )
  eq(child.lua_get("#require('didymus.review').current().threads"), 1)

  -- A comment at different lines starts empty.
  child.api.nvim_win_set_cursor(0, { 4, 0 })
  child.cmd("Didymus review comment")
  eq(wait_for_input(), { title = " file.txt:4 ", lines = { "" } })
  child.type_keys("<Esc>", "q")

  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  eq(wait_for_input(), { title = " file.txt:3 ", lines = { "First try." } })
  child.type_keys(" Again.", "<C-s>")
  helpers.wait_for_threads(child, 2)
  eq(provider_threads()[2].comments[1].body, "First try. Again.")
end

return T
