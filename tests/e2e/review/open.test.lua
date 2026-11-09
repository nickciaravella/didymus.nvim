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

--- Make a repo with `other.txt`, which the change does not change. Make it the directory of the
--- child, and give its change to the test provider.
---@param changes (fun(change: didymus.review.Change): didymus.review.Change[])? More changes.
---@return didymus.test.Repo
local function setup_repo(changes)
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n", ["other.txt"] = "other\n" },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, changes and changes(repo.change) or { repo.change })
  return repo
end

---@param repo didymus.test.Repo
---@return string
local function head(repo)
  return vim.trim(helpers.git(repo.dir, { "rev-parse", "HEAD" }))
end

---@return didymus.test.Review?
local function review()
  return helpers.review(child)
end

---@param id string?
local function wait_for_review(id)
  helpers.wait_for_review(child, id)
end

--- The calls of the select role. Each review also opens a panel. `files.test.lua` tests it.
---@return didymus.test.PickerCall[]
local function picker_calls()
  return helpers.picker_calls(child, "select")
end

---@param count integer
local function wait_for_picker(count)
  wait_for(function()
    return #picker_calls() >= count
  end, ("picker call %d"):format(count))
end

---@param target (integer|string)?
local function choose(target)
  child.lua("require('didymus.ui.picker.test').choose(...)", { target })
end

---@param call { items: didymus.picker.Item[] }
---@return string[]
local function texts(call)
  return vim.tbl_map(function(item)
    return item.text
  end, call.items)
end

---@return string
local function messages()
  return child.cmd_capture("messages")
end

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return messages():find(text, 1, true) ~= nil
  end, function()
    return ("message %q in:\n%s"):format(text, messages())
  end)
end

---@param text string
local function expect_message(text)
  if not messages():find(text, 1, true) then
    error(("%q is not in the messages:\n%s"):format(text, messages()), 2)
  end
end

---@return integer
local function tab_count()
  return #child.api.nvim_list_tabpages()
end

T["open shows the changes in the picker. The choice opens the review tabpage"] = function()
  local repo = setup_repo(function(change)
    local draft = vim.tbl_extend("force", change, { id = "2", title = "Draft", is_draft = true })
    return { change, draft }
  end)

  child.cmd("Didymus review open")
  wait_for_picker(1)
  local call = picker_calls()[1]
  eq(call.kind, "select")
  eq(call.title, "Pull requests")
  eq(texts(call), { "#1 Change the second line @octocat", "#2 Draft @octocat [draft]" })
  eq(call.items[2].segments[4], { " [draft]", "DiagnosticWarn" })
  eq(call.items[1].preview, {
    lines = { "# Change the second line", "", "The body of the change." },
    filetype = "markdown",
  })

  choose(1)
  wait_for_review("1")
  eq(tab_count(), 2)
  eq(child.api.nvim_get_current_tabpage(), review().tabpage)
  eq(head(repo), repo.change.head_sha)
  eq(review().merge_base, repo.change.base_sha)
  expect_message("didymus: opened the review of #1: Change the second line")
end

T["open 1 opens the review with no picker"] = function()
  local repo = setup_repo()
  child.cmd("Didymus review open 1")
  wait_for_review("1")
  eq(#picker_calls(), 0)
  eq(head(repo), repo.change.head_sha)
end

T["the review tabpage leaves no buffer after the close"] = function()
  setup_repo()
  local buffers = child.api.nvim_list_bufs()
  child.cmd("Didymus review open 1")
  wait_for_review()
  child.cmd("Didymus review close")
  eq(child.api.nvim_list_bufs(), buffers)
end

T["if HEAD is the change head, there is no checkout and no question"] = function()
  local repo = setup_repo()
  helpers.git(repo.dir, { "switch", "--quiet", "feature" })
  helpers.write(repo.dir, { ["other.txt"] = "a local change\n" })

  child.cmd("Didymus review open 1")
  wait_for_review()
  eq(#picker_calls(), 0)
  -- The test provider checks out a detached HEAD.
  eq(vim.trim(helpers.git(repo.dir, { "branch", "--show-current" })), "feature")
  child.cmd("Didymus review close")
  expect_message("didymus: closed the review of #1. The branch before the review was feature.")
end

T["with uncommitted changes, a warning shows the files, and a question asks first"] = function()
  local repo = setup_repo()
  helpers.write(repo.dir, { ["other.txt"] = "a local change\n" })

  child.cmd("Didymus review open 1")
  wait_for_picker(1)
  local call = picker_calls()[1]
  eq(call.title, "Uncommitted changes. Check out #1?")
  eq(texts(call), { "Check out", "Cancel" })
  eq(call.items[1].preview, { lines = { "other.txt" } })
  expect_message("didymus: these files have uncommitted changes:\n  other.txt")
  eq(review(), nil)
  eq(head(repo), repo.change.base_sha)
end

T["the question shows staged changes, renames and paths with spaces"] = function()
  local repo = setup_repo()
  helpers.write(repo.dir, { ["a b.txt"] = "base\n" })
  helpers.git(repo.dir, { "add", "--all" })
  helpers.git(repo.dir, { "commit", "--quiet", "--message", "a file with a space" })
  helpers.write(repo.dir, { ["a b.txt"] = "a staged change\n", ["untracked.txt"] = "new\n" })
  helpers.git(repo.dir, { "add", "a b.txt" })
  helpers.git(repo.dir, { "mv", "other.txt", "moved.txt" })

  child.cmd("Didymus review open 1")
  wait_for_picker(1)
  local lines = picker_calls()[1].items[1].preview.lines
  table.sort(lines)
  eq(lines, { "a b.txt", "moved.txt" })
end

T["the warning shows 10 files, and the number of the other files"] = function()
  local repo = setup_repo()
  local base, local_changes = {}, {}
  for index = 1, 12 do
    local path = ("dir/%02d.txt"):format(index)
    base[path], local_changes[path] = "base\n", "a local change\n"
  end
  helpers.write(repo.dir, base)
  helpers.git(repo.dir, { "add", "--all" })
  helpers.git(repo.dir, { "commit", "--quiet", "--message", "more files" })
  helpers.write(repo.dir, local_changes)

  child.cmd("Didymus review open 1")
  wait_for_picker(1)
  eq(#picker_calls()[1].items[1].preview.lines, 12)
  expect_message("  dir/10.txt\n  and 2 more")
  eq(messages():find("dir/11.txt", 1, true), nil)
end

T["Cancel does not check out and opens no tabpage"] = function()
  local repo = setup_repo()
  helpers.write(repo.dir, { ["other.txt"] = "a local change\n" })
  child.cmd("Didymus review open 1")
  wait_for_picker(1)

  choose("Cancel")
  eq(review(), nil)
  eq(tab_count(), 1)
  eq(head(repo), repo.change.base_sha)
end

T["a close of the question with no choice is a cancel"] = function()
  local repo = setup_repo()
  helpers.write(repo.dir, { ["other.txt"] = "a local change\n" })
  child.cmd("Didymus review open 1")
  wait_for_picker(1)

  child.lua("require('didymus.ui.picker.test').cancel()")
  eq(review(), nil)
  eq(tab_count(), 1)
  eq(head(repo), repo.change.base_sha)
end

T["Check out checks out the head and keeps the uncommitted changes"] = function()
  local repo = setup_repo()
  helpers.write(repo.dir, { ["other.txt"] = "a local change\n" })
  child.cmd("Didymus review open 1")
  wait_for_picker(1)

  choose("Check out")
  wait_for_review()
  eq(head(repo), repo.change.head_sha)
  eq(vim.fn.readfile(vim.fs.joinpath(repo.dir, "other.txt")), { "a local change" })
end

T["if the checkout fails, the error shows and no tabpage opens"] = function()
  local repo = setup_repo()
  -- The change also changes file.txt, so git refuses.
  helpers.write(repo.dir, { ["file.txt"] = "a local change\n" })
  child.cmd("Didymus review open 1")
  wait_for_picker(1)

  choose("Check out")
  wait_for_message("didymus: cannot check out #1: ")
  expect_message("file.txt")
  eq(review(), nil)
  eq(tab_count(), 1)
  eq(head(repo), repo.change.base_sha)
end

T["a buffer of a file that the checkout changed shows the new text"] = function()
  setup_repo()
  child.cmd("edit file.txt")
  local buf = child.api.nvim_get_current_buf()

  child.cmd("Didymus review open 1")
  wait_for_review()
  eq(child.api.nvim_buf_get_lines(buf, 0, -1, true), { "one", "2", "three" })
end

T["if git cannot find the merge-base, a warning shows and the review opens"] = function()
  setup_repo(function(change)
    return { vim.tbl_extend("force", change, { base_sha = ("0"):rep(40) }) }
  end)
  child.cmd("Didymus review open 1")
  wait_for_review()
  eq(review().merge_base, nil)
  expect_message("didymus: no merge-base for #1: git merge-base: ")
end

T["close closes the tabpage, and the message names the old branch"] = function()
  local repo = setup_repo()
  child.cmd("Didymus review open 1")
  wait_for_review()

  child.cmd("Didymus review close")
  eq(review(), nil)
  eq(tab_count(), 1)
  expect_message("didymus: closed the review of #1. The branch before the review was main.")
  -- The close does not check out the old branch.
  eq(head(repo), repo.change.head_sha)
end

T["with a detached HEAD, the close message names the old commit"] = function()
  local repo = setup_repo()
  helpers.git(repo.dir, { "switch", "--quiet", "--detach", "main" })
  child.cmd("Didymus review open 1")
  wait_for_review()

  child.cmd("Didymus review close")
  expect_message(
    ("didymus: closed the review of #1. Before the review, HEAD was at the commit %s."):format(
      repo.change.base_sha:sub(1, 7)
    )
  )
end

T[":tabclose of the review tabpage ends the review"] = function()
  setup_repo()
  child.cmd("Didymus review open 1")
  wait_for_review()

  child.cmd("tabclose")
  eq(review(), nil)
  expect_message("didymus: closed the review of #1.")
end

T["close works when the review tabpage is the last tabpage"] = function()
  setup_repo()
  child.cmd("Didymus review open 1")
  wait_for_review()
  child.cmd("tabonly")

  child.cmd("Didymus review close")
  eq(review(), nil)
  eq(tab_count(), 1)
end

T["close with no review shows a warning"] = function()
  child.cmd("Didymus review close")
  expect_message("didymus: no review is open")
end

T["open of the same change goes to its tabpage"] = function()
  setup_repo()
  child.cmd("Didymus review open 1")
  wait_for_review()
  local tabpage = review().tabpage
  child.cmd("tabfirst")

  child.cmd("Didymus review open 1")
  eq(child.api.nvim_get_current_tabpage(), tabpage)
  eq(tab_count(), 2)
  eq(#picker_calls(), 0)
end

---@param change didymus.review.Change
---@return didymus.review.Change[]
local function with_second_change(change)
  return { change, vim.tbl_extend("force", change, { id = "2", title = "Second" }) }
end

T["open of a different change asks to close the review first"] = function()
  setup_repo(with_second_change)
  child.cmd("Didymus review open 1")
  wait_for_review("1")

  child.cmd("Didymus review open 2")
  wait_for_picker(1)
  local call = picker_calls()[1]
  eq(call.title, "Close the review of #1 and open #2?")
  eq(texts(call), { "Open #2", "Cancel" })
  eq(call.items[1].preview.lines[1], "# Second")

  choose("Open #2")
  wait_for_review("2")
  expect_message("didymus: closed the review of #1.")
  eq(tab_count(), 2)
end

T["Cancel keeps the open review"] = function()
  setup_repo(with_second_change)
  child.cmd("Didymus review open 1")
  wait_for_review("1")
  child.cmd("Didymus review open 2")
  wait_for_picker(1)

  choose("Cancel")
  eq(review().id, "1")
  eq(tab_count(), 2)
end

T["a newer open wins over an older open"] = function()
  setup_repo(with_second_change)
  child.cmd("Didymus review open")
  wait_for_picker(1)
  child.cmd("Didymus review open 1")
  wait_for_review("1")
  -- Hide the panel, so that `choose()` acts on the picker of the older open. It is still open.
  child.cmd("Didymus review files")

  choose(2)
  eq(review().id, "1")
  eq(#picker_calls(), 1)
end

T["open shows a message if there are no open changes"] = function()
  child.cmd("Didymus review open")
  wait_for_message("didymus: there are no open pull requests")
  eq(#picker_calls(), 0)
end

T["open shows the error of the provider"] = function()
  setup_repo()
  child.cmd("Didymus review open 9")
  wait_for_message('didymus: no change "9"')
  eq(review(), nil)
  eq(tab_count(), 1)
end

T["the mappings run the commands"] = function()
  setup_repo()
  child.cmd("nmap <F2> <Plug>(didymus-review-open)")
  child.cmd("nmap <F3> <Plug>(didymus-review-close)")

  child.type_keys("<F2>")
  wait_for_picker(1)
  choose(1)
  wait_for_review()
  child.type_keys("<F3>")
  eq(review(), nil)
end

T["the command completes the review actions"] = function()
  eq(child.fn.getcompletion("Didymus review ", "cmdline"), {
    "close",
    "comment",
    "discard",
    "files",
    "next",
    "open",
    "prev",
    "refresh",
    "reply",
    "resolve",
    "submit",
    "thread",
  })
  eq(
    child.fn.getcompletion("Didymus review submit ", "cmdline"),
    { "approve", "comment", "request_changes" }
  )
  eq(child.fn.getcompletion("Didymus ", "cmdline"), { "agent", "review" })
end

T["an unknown review action shows the usage"] = function()
  -- An error message in a command is an error of `child.cmd()`.
  child.lua("require('didymus.command').run('review foo')")
  expect_message(
    "didymus: unknown command. Use :Didymus review open, close, files, thread, next, prev, comment, "
      .. "reply, resolve, submit, discard or refresh."
  )
end

return T
