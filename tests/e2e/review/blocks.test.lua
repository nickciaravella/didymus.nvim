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

--- Make a repo where the change modifies line 2 and line 19 of file.txt, which has 20 lines. Open
--- the review with `threads`, and edit file.txt.
---@param threads didymus.review.Thread[]
---@return string[] lines The lines of file.txt.
local function open_review(threads)
  local base, head = {}, {}
  for line = 1, 20 do
    base[line] = "line " .. line
    head[line] = base[line]
  end
  head[2], head[19] = "LINE 2", "LINE 19"
  local repo = helpers.make_repo({
    base = { ["file.txt"] = table.concat(base, "\n") .. "\n" },
    head = { ["file.txt"] = table.concat(head, "\n") .. "\n" },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads)
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, #threads)
  child.cmd("edit file.txt")
  return head
end

--- A thread on `line` with one comment.
---@param id string
---@param line integer
---@param body string
---@return didymus.review.Thread
local function make_thread(id, line, body)
  return helpers.make_thread(id, "file.txt", {
    range = line > 0 and { first = line, last = line } or nil,
    comments = { { author = "octocat", body = body, pending = false } },
  })
end

--- Where the cursor is: the line of the file, or the line of the window on a block.
---@return { kind: string, line: string|integer }
local function cursor()
  local filetype = child.bo.filetype
  if filetype == "didymus_thread" or filetype == "didymus_input" then
    return { kind = filetype, line = child.fn.getline(".") }
  end
  return { kind = "file", line = child.fn.line(".") }
end

---@param keys string
local function press(keys)
  child.type_keys(keys)
  -- The keys at the first and the last line go into a block in `vim.schedule()`.
  child.lua("vim.wait(20)")
end

T["j and k go into a thread and out of it, as if its lines were lines of the file"] = function()
  local lines = open_review({ make_thread("t", 3, "Why?") })
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  press("j")
  eq(cursor(), { kind = "didymus_thread", line = "┌ 💬 @octocat" })
  -- The cursor is on the text, after the frame.
  eq(child.api.nvim_win_get_cursor(0), { 1, #"┌ " })
  -- The window has no border, and it is on the virtual lines under line 3, after the sign column.
  local config = child.api.nvim_win_get_config(0)
  eq({ config.border, config.row, config.col }, { "none", 3, 2 })
  press("j")
  eq(cursor(), { kind = "didymus_thread", line = "└ Why?" })
  press("j")
  eq(cursor(), { kind = "file", line = 4 })
  press("k")
  eq(cursor(), { kind = "didymus_thread", line = "└ Why?" })
  press("k")
  press("k")
  eq(cursor(), { kind = "file", line = 3 })

  -- The file buffer keeps its text.
  eq(child.api.nvim_buf_get_lines(0, 0, -1, true), lines)
  eq(child.bo.modified, false)
end

T["a count, a jump, visual mode or a change of the text does not go into a thread"] = function()
  open_review({ make_thread("t", 3, "Why?") })
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  press("2j")
  eq(cursor(), { kind = "file", line = 4 })
  press("3G")
  eq(cursor(), { kind = "file", line = 3 })
  press("Vj")
  eq(cursor(), { kind = "file", line = 4 })
  press("<Esc>")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  -- `p` of a line moves the cursor to the next line.
  press("yyp")
  eq(cursor(), { kind = "file", line = 4 })
end

T["k on line 1 goes into a thread on the file, and j on the last line into its threads"] = function()
  open_review({ make_thread("file", 0, "About the file."), make_thread("end", 20, "At the end.") })
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  press("k")
  eq(cursor(), { kind = "didymus_thread", line = "└ About the file." })
  press("j")
  eq(cursor(), { kind = "file", line = 1 })
  press("G")
  press("j")
  eq(cursor(), { kind = "didymus_thread", line = "┌ 💬 @octocat" })
end

T["the input stays open when the cursor leaves it, and j goes back into it"] = function()
  open_review({})
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Didymus review comment")
  eq(helpers.wait_for_input(child).inline, true)
  press("Draft.<Esc>")
  press("k")
  eq(cursor(), { kind = "file", line = 5 })
  -- The text shows in the virtual lines under line 5.
  local marks = helpers.thread_marks(child)
  eq(marks[1].row, 4)
  eq(marks[1].lines[2], "│ Draft.")
  press("j")
  eq(cursor(), { kind = "didymus_input", line = "Draft." })

  -- A new comment does not replace an input with text.
  press("k")
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Didymus review comment")
  wait_for(function()
    return child.cmd_capture("messages"):find("you have an open comment at file.txt:5", 1, true)
      ~= nil
  end, "the warning")
  eq(cursor(), { kind = "didymus_input", line = "Draft." })

  press("q")
  eq(cursor(), { kind = "file", line = 5 })
  eq(helpers.thread_marks(child), {})
end

T["a scroll that hides the thread puts the cursor back in the file"] = function()
  open_review({ make_thread("t", 3, "Why?") })
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  press("j")
  eq(cursor().kind, "didymus_thread")
  local code_win = child.lua_get("require('didymus.review').current().code_win")
  child.lua("vim.api.nvim_win_call(..., function() vim.cmd('normal! 5\\5') end)", { code_win })
  wait_for(function()
    return cursor().kind == "file"
  end, "the cursor in the file")
  eq(child.api.nvim_get_current_win(), code_win)
end

return T
