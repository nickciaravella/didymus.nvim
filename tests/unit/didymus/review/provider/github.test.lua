local eq = MiniTest.expect.equality
local github = require("didymus.review.provider.github")
local graphql = require("didymus.review.provider.github.graphql")

local system = vim.system

---@type string[][] The command of each `vim.system()` call.
local commands

--- Replace `vim.system()` with a mock. Like the real one, it calls `on_exit` in a fast event.
---@param reply fun(args: string[]): table The result of `gh` with `args`. `code` 0 is the default.
--- `delay` is the time in milliseconds before `on_exit`. 0 is the default.
local function mock_gh(reply)
  commands = {}
  vim.system = function(cmd, _, on_exit)
    table.insert(commands, cmd)
    local result = vim.tbl_extend("keep", reply(vim.list_slice(cmd, 2)), {
      code = 0,
      signal = 0,
      stdout = "",
      stderr = "",
    })
    vim.uv.new_timer():start(result.delay or 0, 0, function()
      on_exit(result)
    end)
    return {}
  end
end

---@param name string
---@return string
local function read_fixture(name)
  return table.concat(vim.fn.readfile(("tests/fixtures/github/%s.json"):format(name)), "\n")
end

--- Reply to the two calls of `get_change()` with the recorded output of `name`.
---@param name string
local function mock_change(name)
  mock_gh(function(args)
    return { stdout = read_fixture(name .. (args[2] == "graphql" and "_graphql" or "_files")) }
  end)
end

--- Call `method` of the provider, and wait for its `cb`. Check that `cb` runs in the main loop.
---@param method string
---@param ... any The arguments before `cb`.
---@return { err: string?, result: any }
local function call(method, ...)
  local reply
  local args = { ... }
  table.insert(args, function(err, result)
    reply = { err = err, result = result, fast = vim.in_fast_event() }
  end)
  github[method](github, unpack(args))
  assert(
    vim.wait(1000, function()
      return reply ~= nil
    end),
    "no cb from " .. method
  )
  eq(reply.fast, false)
  return { err = reply.err, result = reply.result }
end

---@param id string
---@return table
local function get_change(id)
  local reply = call("get_change", id)
  eq(reply.err, nil)
  return reply.result
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.system = system
    end,
  },
})

T["list_changes()"] = MiniTest.new_set()

T["list_changes()"]["gives the PRs of gh pr list as summaries"] = function()
  mock_gh(function()
    return { stdout = read_fixture("list") }
  end)
  local changes = call("list_changes", {}).result

  eq(commands, {
    { "gh", "pr", "list", "--json", "number,title,author,body,isDraft", "--limit", "100" },
  })
  eq(#changes, 2)
  eq({ changes[1].id, changes[1].author, changes[1].is_draft }, { "42760", "helmipradita", false })
  eq(changes[2], {
    id = "42739",
    title = "fix(window): CTRL-W commands enter non-focusable split",
    author = "glepnir",
    body = "Problem:\nCTRL-W commands can enter a split with focusable=false. Only floats are skipped.\n\n"
      .. "Solution:\nSkip non-focusable windows, regardless of whether they are floating.\n\n"
      .. "Fixes #29365",
    is_draft = true,
  })
end

T["list_changes()"]["gives the search to --search"] = function()
  mock_gh(function()
    return { stdout = "[]" }
  end)
  eq(call("list_changes", { search = "review-requested:@me" }), { result = {} })
  eq(vim.list_slice(commands[1], 8), { "--search", "review-requested:@me" })
end

T["get_change()"] = MiniTest.new_set()

T["get_change()"]["a PR with a fork head, by URL"] = function()
  mock_change("fork")
  local change = get_change("https://github.com/neovim/neovim/pull/38540")

  eq(commands, {
    {
      "gh",
      "api",
      "graphql",
      "--paginate",
      "--slurp",
      "-f",
      "query=" .. graphql.change,
      "-F",
      "number=38540",
      "-f",
      "owner=neovim",
      "-f",
      "repo=neovim",
      "--hostname",
      "github.com",
    },
    {
      "gh",
      "api",
      "--paginate",
      "--slurp",
      "repos/neovim/neovim/pulls/38540/files?per_page=100",
      "--hostname",
      "github.com",
    },
  })
  change.files = nil
  eq(change, {
    id = "38540",
    title = "refactor: move ugrid.c => tui/ugrid.c",
    author = "justinmk",
    body = "This module is only used by the tui code.\n",
    is_draft = false,
    base_branch = "master",
    head_branch = "justinmk:refactorugrid",
    base_sha = "d5516daf121aa718e79bcd423ee24c24492893c0",
    head_sha = "4854b4b08dc660f7f9380e4756b82a5a1957a1ea",
    github = {
      number = 38540,
      host = "github.com",
      owner = "neovim",
      repo = "neovim",
      node_id = "PR_kwDOAPphoM7OUZMP",
    },
  })
end

T["get_change()"]["a renamed file has its new path, and the files of all pages"] = function()
  mock_change("fork")
  local files = get_change("38540").files

  eq(
    vim.tbl_map(function(file)
      return { file.path, file.status, file.additions, file.deletions }
    end, files),
    {
      { "src/nvim/tui/tui.c", "modified", 1, 1 },
      { "src/nvim/tui/ugrid.c", "renamed", 2, 2 },
      { "src/nvim/tui/ugrid.h", "renamed", 1, 1 },
    }
  )
  eq(
    files[3].patch,
    '@@ -23,4 +23,4 @@ typedef struct {\n     } \\\n   } while (0)\n \n-#include "ugrid.h.generated.h"\n+#include "tui/ugrid.h.generated.h"'
  )
end

T["get_change()"]["a file with no patch, by number in the current repo"] = function()
  mock_change("no_patch")
  local files = get_change("27317").files

  eq(
    vim.list_slice(commands[1], 8),
    { "-F", "number=27317", "-F", "owner={owner}", "-F", "repo={repo}" }
  )
  eq(commands[2], {
    "gh",
    "api",
    "--paginate",
    "--slurp",
    "repos/{owner}/{repo}/pulls/27317/files?per_page=100",
  })
  eq({ files[1].path, files[1].patch }, { "src/unicode/EastAsianWidth.txt", nil })
  eq(files[2].path, "src/unicode/emoji-data.txt")
  eq(files[2].patch:sub(1, 16), "@@ -1,11 +1,11 @")
end

T["get_change()"]["a PR with a pending review of the viewer"] = function()
  mock_change("pending")
  local change = get_change("57")
  eq(change.pending_review_id, "PRR_kwDOVmiVUM7viewer")
  eq(change.head_branch, "feat/review-provider")

  mock_change("fork")
  eq(get_change("38540").pending_review_id, nil)
end

T["get_change()"]["accepts a PR URL with a path after the number"] = function()
  mock_change("fork")
  eq(get_change("https://github.example.com/neovim/neovim/pull/38540/files#diff").github, {
    number = 38540,
    host = "github.example.com",
    owner = "neovim",
    repo = "neovim",
    node_id = "PR_kwDOAPphoM7OUZMP",
  })
end

T["get_change()"]["gives an error for an id that is not a PR number or URL"] = function()
  mock_change("fork")
  for _, id in ipairs({ "main", "https://github.com/neovim/neovim/issues/1", "12a" }) do
    eq(call("get_change", id), { err = ("not a PR number or URL: %q"):format(id) })
  end
  eq(commands, {})
end

T["get_change()"]["gives a short error with the message of gh, from GraphQL first"] = function()
  -- The recorded errors for a PR that does not exist. The REST error comes first.
  mock_gh(function(args)
    if args[2] == "graphql" then
      return {
        code = 1,
        delay = 20,
        stderr = "gh: Could not resolve to a PullRequest with the number of 99999.\n",
      }
    end
    return { code = 1, stderr = "gh: Not Found (HTTP 404)\n" }
  end)
  eq(call("get_change", "99999"), {
    err = "gh api graphql: Could not resolve to a PullRequest with the number of 99999.",
  })

  mock_gh(function(args)
    return args[2] == "graphql" and { stdout = read_fixture("fork_graphql") }
      or { code = 1, stderr = "gh: Not Found (HTTP 404)\n" }
  end)
  eq(call("get_change", "38540"), { err = "gh api: Not Found (HTTP 404)" })
end

T["the methods give an error if gh is not on $PATH"] = function()
  vim.system = function(cmd)
    -- The error of the real `vim.system()`.
    error(("ENOENT: no such file or directory (cmd): '%s'"):format(cmd[1]))
  end
  eq(call("list_changes", {}), { err = "gh pr list: `gh` is not on $PATH" })
  eq(call("get_change", "1"), { err = "gh api graphql: `gh` is not on $PATH" })
end

T["get_threads()"] = MiniTest.new_set()

-- The change of neovim/neovim#42726, by number. `get_threads()` uses only `github`.
local threads_change =
  { id = "42726", github = { number = 42726, node_id = "PR_kwDOAPphoM8AAAABNUMiSA" } }

--- Reply to the threads query with the recorded output of `name`, after `edit` changes it, and to
--- the comments query with `thread_comments`.
---@param name string
---@param edit fun(pages: table[])?
local function mock_threads(name, edit)
  local pages = vim.json.decode(read_fixture(name))
  if edit then
    edit(pages)
  end
  mock_gh(function(args)
    if args[6] == "query=" .. graphql.thread_comments then
      return { stdout = read_fixture("thread_comments_graphql") }
    end
    return { stdout = vim.json.encode(pages) }
  end)
end

---@param change table
---@return didymus.review.Thread[]
local function get_threads(change)
  local reply = call("get_threads", change)
  eq(reply.err, nil)
  return reply.result
end

T["get_threads()"]["gives the threads of all pages, and all comments of a long thread"] = function()
  mock_threads("threads_graphql")
  local threads = get_threads(threads_change)

  eq(commands, {
    {
      "gh",
      "api",
      "graphql",
      "--paginate",
      "--slurp",
      "-f",
      "query=" .. graphql.threads,
      "-f",
      "id=PR_kwDOAPphoM8AAAABNUMiSA",
    },
    {
      "gh",
      "api",
      "graphql",
      "--paginate",
      "--slurp",
      "-f",
      "query=" .. graphql.thread_comments,
      "-f",
      "id=PRRT_kwDOAPphoM60iFrl",
    },
  })
  eq(#threads, 3)
  eq(threads[1], {
    id = "PRRT_kwDOAPphoM60iDI1",
    path = "runtime/lua/vim/async.lua",
    side = "head",
    range = { first = 323, last = 323 },
    resolved = false,
    outdated = false,
    comments = { { author = "lewis6991", body = ":+1:", pending = false } },
  })
  eq(
    { threads[2].range, threads[2].resolved, threads[2].outdated, #threads[2].comments },
    { nil, true, true, 14 }
  )
  eq(threads[2].comments[14].author, "justinmk")
  -- The recorded body has `\r\n`.
  eq(
    threads[2].comments[10].body:sub(1, 60),
    "> But we certainly have made many changes to luaref.txt.\n\nht"
  )
  eq(
    { threads[3].path, threads[3].range },
    { "runtime/doc/lua-async.txt", { first = 579, last = 580 } }
  )
end

T["get_threads()"]["a thread on the base side, by URL"] = function()
  mock_threads("base_threads_graphql")
  local change = {
    id = "https://github.com/neovim/neovim/pull/42735",
    github = {
      number = 42735,
      host = "github.com",
      owner = "neovim",
      repo = "neovim",
      node_id = "PR_x",
    },
  }
  local threads = get_threads(change)

  eq(vim.list_slice(commands[1], 8), { "-f", "id=PR_x", "--hostname", "github.com" })
  eq(#commands, 1)
  eq(
    { threads[1].side, threads[1].range, threads[1].resolved },
    { "base", { first = 433, last = 433 }, true }
  )
  eq({ threads[2].side, threads[2].range, threads[2].outdated }, { "head", nil, true })
end

T["get_threads()"]["a deleted author, a pending comment, a thread on the file and a range on two sides"] = function()
  mock_threads("base_threads_graphql", function(pages)
    local nodes = pages[1].data.node.reviewThreads.nodes
    nodes[1].comments.nodes[1].author = vim.NIL
    nodes[1].comments.nodes[2].state = "PENDING"
    nodes[2].isOutdated, nodes[2].subjectType = false, "FILE"
    nodes[3].isOutdated, nodes[3].line, nodes[3].startLine = false, 12, 10
    nodes[3].diffSide, nodes[3].startDiffSide = "RIGHT", "LEFT"
    nodes[4].isOutdated, nodes[4].line, nodes[4].startLine = false, 12, 10
    nodes[4].diffSide, nodes[4].startDiffSide = "RIGHT", "RIGHT"
  end)
  local threads = get_threads(threads_change)

  eq(
    vim.tbl_map(function(comment)
      return { comment.author, comment.pending }
    end, threads[1].comments),
    { { "ghost", false }, { "b84330808", true } }
  )
  eq({ threads[2].range, threads[2].outdated }, { nil, false })
  eq(threads[3].range, { first = 12, last = 12 })
  eq(threads[4].range, { first = 10, last = 12 })
end

T["get_threads()"]["gives the error of gh, also for the comments of a long thread"] = function()
  mock_gh(function()
    return { code = 1, stderr = "gh: Could not resolve to a node with the global id of 'PR_x'.\n" }
  end)
  eq(call("get_threads", threads_change), {
    err = "gh api graphql: Could not resolve to a node with the global id of 'PR_x'.",
  })

  mock_gh(function(args)
    if args[6] == "query=" .. graphql.thread_comments then
      return { code = 1, stderr = "gh: HTTP 502\n" }
    end
    return { stdout = read_fixture("threads_graphql") }
  end)
  eq(call("get_threads", threads_change), { err = "gh api graphql: HTTP 502" })
end

T["add_comment()"] = MiniTest.new_set()

-- The node id of nickciaravella/didymus.nvim#64.
local comment_node_id = "PR_kwDOVmiVUM8AAAABNzd55g"

--- The change of nickciaravella/didymus.nvim#64. `add_comment()` uses `github` and `head_sha`.
---@param github table? The `github` field. Default: the PR by number.
---@return table
local function make_comment_change(github)
  return {
    id = "64",
    head_sha = "e7923fbc3f3e4806ed079d00eb44b0fa1894809b",
    github = github or { number = 64, node_id = comment_node_id },
  }
end

--- Reply to each query of `add_comment()` with a recorded result.
---@param replies table<string, table> The result of each GraphQL document, by its name in `graphql`.
local function mock_comment(replies)
  mock_gh(function(args)
    for name, reply in pairs(replies) do
      if args[4] == "query=" .. graphql[name] then
        return reply
      end
    end
    error("no reply for " .. args[4])
  end)
end

---@param name string
---@return table
local function fixture_reply(name)
  return { stdout = read_fixture(name) }
end

---@param first integer
---@param last integer
---@return didymus.review.CommentDraft
local function make_draft(first, last)
  return {
    path = "lua/didymus/init.lua",
    range = { first = first, last = last },
    body = ("Recorded for the unit tests of didymus: lines %d-%d."):format(first, last),
  }
end

T["add_comment()"]["starts a pending review if there is none, and adds a thread on one line"] = function()
  mock_comment({
    pending_reviews = fixture_reply("comment_no_review_graphql"),
    start_review = fixture_reply("comment_start_review_graphql"),
    add_thread = fixture_reply("comment_thread_graphql"),
  })
  local change = make_comment_change()
  local reply = call("add_comment", change, make_draft(25, 25))

  local review_id = "PRR_kwDOVmiVUM8AAAABWx95Dg"
  eq(commands, {
    {
      "gh",
      "api",
      "graphql",
      "-f",
      "query=" .. graphql.pending_reviews,
      "-f",
      "id=" .. comment_node_id,
    },
    {
      "gh",
      "api",
      "graphql",
      "-f",
      "query=" .. graphql.start_review,
      "-f",
      "pullRequestId=" .. comment_node_id,
      "-f",
      "commitOID=e7923fbc3f3e4806ed079d00eb44b0fa1894809b",
    },
    {
      "gh",
      "api",
      "graphql",
      "-f",
      "query=" .. graphql.add_thread,
      "-f",
      "reviewId=" .. review_id,
      "-f",
      "path=lua/didymus/init.lua",
      "-f",
      "body=Recorded for the unit tests of didymus: lines 25-25.",
      "-F",
      "line=25",
    },
  })
  eq(reply, {
    result = {
      id = "PRRT_kwDOVmiVUM61MQcu",
      path = "lua/didymus/init.lua",
      side = "head",
      range = { first = 25, last = 25 },
      resolved = false,
      outdated = false,
      comments = {
        {
          author = "nickciaravella",
          body = "Recorded for the unit tests of didymus: lines 25-25.",
          pending = true,
        },
      },
    },
  })
  eq(change.pending_review_id, review_id)
end

T["add_comment()"]["adds a range to the pending review of the viewer, on the host of a URL"] = function()
  mock_comment({
    pending_reviews = fixture_reply("comment_pending_review_graphql"),
    add_thread = fixture_reply("comment_range_thread_graphql"),
  })
  local change = make_comment_change({
    number = 64,
    host = "github.com",
    owner = "nickciaravella",
    repo = "didymus.nvim",
    node_id = comment_node_id,
  })
  local reply = call("add_comment", change, make_draft(2, 4))

  eq(#commands, 2)
  eq(vim.list_slice(commands[1], 8), { "--hostname", "github.com" })
  eq(vim.list_slice(commands[2], 6), {
    "-f",
    "reviewId=PRR_kwDOVmiVUM8AAAABWx95Dg",
    "-f",
    "path=lua/didymus/init.lua",
    "-f",
    "body=Recorded for the unit tests of didymus: lines 2-4.",
    "-F",
    "line=4",
    "-F",
    "startLine=2",
    "-f",
    "startSide=RIGHT",
    "--hostname",
    "github.com",
  })
  eq(reply.result.range, { first = 2, last = 4 })
end

T["add_comment()"]["gives an error if GitHub adds no thread"] = function()
  -- GitHub gives no error for a line out of the diff.
  mock_comment({
    pending_reviews = fixture_reply("comment_pending_review_graphql"),
    add_thread = fixture_reply("comment_no_thread_graphql"),
  })
  eq(call("add_comment", make_comment_change(), make_draft(12, 12)), {
    err = "gh api graphql: GitHub did not add the thread. Are the lines in the diff?",
  })
end

T["add_comment()"]["gives the error of gh, and stops"] = function()
  mock_comment({ pending_reviews = { code = 1, stderr = "gh: HTTP 502\n" } })
  eq(call("add_comment", make_comment_change(), make_draft(25, 25)), {
    err = "gh api graphql: HTTP 502",
  })
  eq(#commands, 1)

  mock_comment({
    pending_reviews = fixture_reply("comment_no_review_graphql"),
    start_review = {
      code = 1,
      stderr = "gh: User can only have one pending review per pull request\n",
    },
  })
  eq(call("add_comment", make_comment_change(), make_draft(25, 25)), {
    err = "gh api graphql: User can only have one pending review per pull request",
  })
  eq(#commands, 2)
end

T["checkout()"] = MiniTest.new_set()

T["checkout()"]["runs gh pr checkout with the number, and the repo of a URL"] = function()
  mock_change("fork")
  local by_number = get_change("38540")
  local by_url = get_change("https://github.com/neovim/neovim/pull/38540")

  mock_gh(function()
    return {}
  end)
  eq(call("checkout", by_number), {})
  eq(call("checkout", by_url), {})
  eq(commands, {
    { "gh", "pr", "checkout", "38540" },
    { "gh", "pr", "checkout", "38540", "--repo", "github.com/neovim/neovim" },
  })
end

T["checkout()"]["gives all lines of the error if git refuses"] = function()
  mock_change("pending")
  local change = get_change("57")
  -- The recorded output. The message of git comes after the fetch lines.
  local stderr = table.concat({
    "From github.com:nickciaravella/didymus.nvim",
    " * [new branch]      feat/review-provider -> origin/feat/review-provider",
    "error: Your local changes to the following files would be overwritten by checkout:",
    "\tlua/didymus/config.lua",
    "Please commit your changes or stash them before you switch branches.",
    "Aborting",
    "failed to run git: exit status 1",
    "",
  }, "\n")
  mock_gh(function()
    return { code = 1, stderr = stderr }
  end)
  eq(call("checkout", change), { err = "gh pr checkout: " .. vim.trim(stderr) })
end

return T
