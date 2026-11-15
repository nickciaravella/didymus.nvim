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
