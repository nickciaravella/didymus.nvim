-- Helpers for the end-to-end tests of the review. Load them with `dofile()`.

local wait_for = dofile("tests/helpers.lua").wait_for

local M = {}

-- The tests do not use the git config of the user, because it can sign commits or run hooks.
local git_env = {
  GIT_CONFIG_GLOBAL = "/dev/null",
  GIT_CONFIG_NOSYSTEM = "1",
  GIT_AUTHOR_NAME = "didymus",
  GIT_AUTHOR_EMAIL = "didymus@example.com",
  GIT_COMMITTER_NAME = "didymus",
  GIT_COMMITTER_EMAIL = "didymus@example.com",
}

--- Run git in `dir`, in the test process.
---@param dir string
---@param args string[]
---@return string stdout
function M.git(dir, args)
  local result =
    vim.system(vim.list_extend({ "git" }, args), { cwd = dir, env = git_env, text = true }):wait()
  if result.code ~= 0 then
    error(("git %s: %s"):format(table.concat(args, " "), result.stderr), 2)
  end
  return result.stdout
end

--- Write files in `dir`.
---@param dir string
---@param files table<string, string|false> The text of each path. False deletes the file.
function M.write(dir, files)
  for path, text in pairs(files) do
    local full = vim.fs.joinpath(dir, path)
    if text == false then
      assert(os.remove(full))
    else
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      local file = assert(io.open(full, "w"))
      file:write(text)
      file:close()
    end
  end
end

---@type table<string, "added"|"modified"|"deleted">
local statuses = { A = "added", M = "modified", D = "deleted" }

--- The changed files from `base` to `head`, as a code host gives them.
---@param dir string
---@param base string
---@param head string
---@return didymus.review.ChangedFile[]
local function changed_files(dir, base, head)
  local counts = {}
  for line in vim.gsplit(vim.trim(M.git(dir, { "diff", "--numstat", base, head })), "\n") do
    local additions, deletions, path = line:match("^(%S+)\t(%S+)\t(.+)$")
    counts[path] = { tonumber(additions) or 0, tonumber(deletions) or 0 }
  end

  local files = {}
  for line in vim.gsplit(vim.trim(M.git(dir, { "diff", "--name-status", base, head })), "\n") do
    local status, path = line:match("^(%a)\t(.+)$")
    local diff = M.git(dir, { "diff", base, head, "--", path })
    table.insert(files, {
      path = path,
      status = statuses[status],
      additions = counts[path][1],
      deletions = counts[path][2],
      -- A code host gives only the hunks. A binary file has no hunks.
      patch = diff:match("\n(@@.*)\n$"),
    })
  end
  return files
end

---@class didymus.test.Repo
---@field dir string
---@field change didymus.review.Change

--- Make a git repo with a base commit on `main` and a head commit on `feature`. `HEAD` is on
--- `main`. Make a change for the test provider that points to the two commits.
---@param opts { base: table<string, string>?, head: table<string, string|false>? }? The files of each commit. False deletes a file.
---@return didymus.test.Repo
function M.make_repo(opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  M.git(dir, { "init", "--quiet", "--initial-branch", "main" })

  ---@param files table<string, string|false>
  ---@param message string
  ---@return string sha
  local function commit(files, message)
    M.write(dir, files)
    M.git(dir, { "add", "--all" })
    M.git(dir, { "commit", "--quiet", "--message", message })
    return vim.trim(M.git(dir, { "rev-parse", "HEAD" }))
  end

  local base_sha = commit(opts.base or { ["file.txt"] = "one\ntwo\nthree\n" }, "base")
  M.git(dir, { "switch", "--quiet", "--create", "feature" })
  local head_sha = commit(opts.head or { ["file.txt"] = "one\n2\nthree\n" }, "head")
  M.git(dir, { "switch", "--quiet", "main" })

  return {
    dir = dir,
    change = {
      id = "1",
      title = "Change the second line",
      author = "octocat",
      body = "The body of the change.",
      is_draft = false,
      base_branch = "main",
      head_branch = "feature",
      base_sha = base_sha,
      head_sha = head_sha,
      files = changed_files(dir, base_sha, head_sha),
    },
  }
end

--- Give `changes` to the test provider in the child.
---@param child MiniTest.child
---@param changes didymus.review.Change[]
function M.set_changes(child, changes)
  child.lua("require('didymus.review.provider.test').changes = ...", { changes })
end

---@class didymus.test.Review
---@field id string
---@field tabpage integer
---@field merge_base string?

--- The open review in the child, else nil.
---@param child MiniTest.child
---@return didymus.test.Review?
function M.review(child)
  local session = child.lua_get([[
    (function()
      local session = require("didymus.review").current()
      return session and {
        id = session.change.id,
        tabpage = session.tabpage,
        merge_base = session.merge_base,
      }
    end)()
  ]])
  return session ~= vim.NIL and session or nil
end

--- Wait until the review of `id` is open. Nil is any change.
---@param child MiniTest.child
---@param id string?
---@return didymus.test.Review
function M.wait_for_review(child, id)
  wait_for(function()
    local session = M.review(child)
    return session ~= nil and (id == nil or session.id == id)
  end, "the review of " .. (id or "a change"))
  return assert(M.review(child))
end

---@class didymus.test.PickerCall
---@field kind "select"|"panel"
---@field title string
---@field items didymus.picker.Item[]
---@field cursor integer
---@field open boolean
---@field focus_count integer

--- The calls of the test picker in the child, with no functions, so that they go through RPC.
---@param child MiniTest.child
---@param kind ("select"|"panel")? Nil is all calls.
---@return didymus.test.PickerCall[]
function M.picker_calls(child, kind)
  local calls = child.lua_get([[
    vim.tbl_map(function(call)
      return {
        kind = call.kind,
        title = call.opts.title,
        items = call.items,
        cursor = call.cursor,
        open = call.open,
        focus_count = call.focus_count,
      }
    end, require("didymus.ui.picker.test").calls)
  ]])
  return vim.tbl_filter(function(call)
    return kind == nil or call.kind == kind
  end, calls)
end

--- Call `method` of the configured provider in the child, and wait for its `cb`.
---@param child MiniTest.child
---@param method string
---@param ... any The arguments before `cb`.
---@return { err: string?, result: any }
function M.call(child, method, ...)
  return child.lua(
    [[
    local method, args = ...
    local config = require("didymus.config")
    local provider = assert(require("didymus.review.provider").get(config.options.review.provider))
    local reply
    table.insert(args, function(err, result)
      reply = { err = err, result = result }
    end)
    provider[method](provider, unpack(args))
    if not vim.wait(5000, function() return reply ~= nil end) then
      error("timeout: no cb from " .. method)
    end
    return reply
  ]],
    { method, { ... } }
  )
end

return M
