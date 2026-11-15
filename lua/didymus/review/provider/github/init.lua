--- The GitHub provider. It runs `gh` with `vim.system`, and changes the output into the review
--- types. See docs/architecture/review.md#gh-commands.

local graphql = require("didymus.review.provider.github.graphql")

--- The PR of a change. `owner` and `repo` are nil for a PR number. Then `gh` uses the current repo.
---@class didymus.review.provider.github.Target
---@field number integer
---@field host string?
---@field owner string?
---@field repo string?
---@field node_id string? The GraphQL id of the PR. `get_change()` sets it.

---@class didymus.review.provider.github.Change: didymus.review.Change
---@field github didymus.review.provider.github.Target

---@class didymus.review.provider.Github: didymus.review.Provider
local M = {}

local auth_timeout = 10000 -- milliseconds

---@type table<string, "added"|"modified"|"deleted"|"renamed">
local statuses = {
  ADDED = "added",
  COPIED = "added",
  MODIFIED = "modified",
  CHANGED = "modified", -- Only the file mode changed.
  DELETED = "deleted",
  RENAMED = "renamed",
}

--- Run `gh` in the current directory. Call `cb` in the main loop.
---@param label string The command for the error message, such as "gh pr list".
---@param args string[] The arguments after `gh`.
---@param cb fun(err: string?, stdout: string?)
local function run(label, args, cb)
  local ok, err = pcall(
    vim.system,
    vim.list_extend({ "gh" }, args),
    { cwd = vim.fn.getcwd(), text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          cb(nil, result.stdout)
        else
          -- Keep all lines. Before the message of git, `gh pr checkout` writes the fetch lines.
          local message = vim.trim(result.stderr or ""):gsub("^gh: ", "")
          if message == "" then
            message = ("exit code %d"):format(result.code)
          end
          cb(("%s: %s"):format(label, message))
        end
      end)
    end
  )
  if not ok then
    -- `vim.system` gives an error at once if it cannot start the program.
    local message = tostring(err):find("ENOENT", 1, true) and "`gh` is not on $PATH" or err
    vim.schedule(function()
      cb(("%s: %s"):format(label, message))
    end)
  end
end

--- Run `gh`, and decode its JSON output. A JSON null in an object becomes nil.
---@param label string
---@param args string[]
---@param cb fun(err: string?, result: any)
local function run_json(label, args, cb)
  run(label, args, function(err, stdout)
    if err then
      return cb(err)
    end
    local ok, result = pcall(vim.json.decode, stdout, { luanil = { object = true } })
    if not ok then
      return cb(("%s: cannot parse the output"):format(label))
    end
    cb(nil, result)
  end)
end

---@param id string A PR number, or a PR URL.
---@return didymus.review.provider.github.Target?
local function parse_id(id)
  id = vim.trim(tostring(id))
  if id:match("^%d+$") then
    return { number = tonumber(id) }
  end
  local host, owner, repo, number, rest =
    id:match("^https?://([^/]+)/([^/]+)/([^/]+)/pull/(%d+)(.*)$")
  if number and (rest == "" or rest:match("^[/?#]")) then
    return { number = tonumber(number), host = host, owner = owner, repo = repo }
  end
end

--- The `gh api` arguments that select the host of `target`.
---@param target didymus.review.provider.github.Target
---@return string[]
local function get_host_args(target)
  return target.host and { "--hostname", target.host } or {}
end

---@param target didymus.review.provider.github.Target
---@return string[]
local function get_change_args(target)
  local args = { "api", "graphql", "--paginate", "--slurp", "-f", "query=" .. graphql.change }
  vim.list_extend(args, { "-F", "number=" .. target.number })
  if target.owner then
    vim.list_extend(args, { "-f", "owner=" .. target.owner, "-f", "repo=" .. target.repo })
  else
    -- Only `-F` puts the current repo into the placeholders.
    vim.list_extend(args, { "-F", "owner={owner}", "-F", "repo={repo}" })
  end
  return vim.list_extend(args, get_host_args(target))
end

---@param target didymus.review.provider.github.Target
---@return string[]
local function get_files_args(target)
  local repo = target.owner and ("%s/%s"):format(target.owner, target.repo) or "{owner}/{repo}"
  local endpoint = ("repos/%s/pulls/%d/files?per_page=100"):format(repo, target.number)
  return vim.list_extend({ "api", "--paginate", "--slurp", endpoint }, get_host_args(target))
end

---@param author { login: string }?
---@return string
local function get_login(author)
  -- GitHub gives no author for a deleted user, and shows "ghost".
  return author and author.login or "ghost"
end

---@param pr table A PR from `gh pr list` or from GraphQL. They have the same field names.
---@return didymus.review.ChangeSummary
local function to_summary(pr)
  return {
    id = tostring(pr.number),
    title = pr.title,
    author = get_login(pr.author),
    body = ((pr.body or ""):gsub("\r\n", "\n")),
    is_draft = pr.isDraft,
  }
end

---@param pages table[] The GraphQL pages of the PR.
---@param file_pages table[][] The REST pages of the files.
---@param target didymus.review.provider.github.Target
---@return didymus.review.provider.github.Change
local function to_change(pages, file_pages, target)
  local patches = {}
  for _, page in ipairs(file_pages) do
    for _, file in ipairs(page) do
      patches[file.filename] = file.patch
    end
  end

  local pr = pages[1].data.repository.pullRequest
  local change = to_summary(pr) --[[@as didymus.review.provider.github.Change]]
  change.base_branch = pr.baseRefName
  change.head_branch = pr.headRefName
  if pr.isCrossRepository and pr.headRepositoryOwner then
    change.head_branch = ("%s:%s"):format(pr.headRepositoryOwner.login, pr.headRefName)
  end
  change.base_sha = pr.baseRefOid
  change.head_sha = pr.headRefOid
  change.files = {}
  for _, page in ipairs(pages) do
    for _, file in ipairs(page.data.repository.pullRequest.files.nodes) do
      table.insert(change.files, {
        path = file.path,
        status = statuses[file.changeType] or "modified",
        additions = file.additions,
        deletions = file.deletions,
        patch = patches[file.path],
      })
    end
  end
  for _, review in ipairs(pr.reviews.nodes) do
    if review.viewerDidAuthor then
      change.pending_review_id = review.id
      break
    end
  end
  change.github = vim.tbl_extend("force", target, { node_id = pr.id })
  return change
end

---@param opts { search: string? }
---@param cb fun(err: string?, changes: didymus.review.ChangeSummary[]?)
function M:list_changes(opts, cb)
  local args = { "pr", "list", "--json", "number,title,author,body,isDraft", "--limit", "100" }
  if opts.search and opts.search ~= "" then
    vim.list_extend(args, { "--search", opts.search })
  end
  run_json("gh pr list", args, function(err, prs)
    if err then
      return cb(err)
    end
    cb(nil, vim.tbl_map(to_summary, prs))
  end)
end

--- Get the PR data and the files with GraphQL, and the patches with REST, at the same time.
---@param id string A PR number, or a PR URL.
---@param cb fun(err: string?, change: didymus.review.provider.github.Change?)
function M:get_change(id, cb)
  local target = parse_id(id)
  if not target then
    vim.schedule(function()
      cb(("not a PR number or URL: %q"):format(tostring(id)))
    end)
    return
  end

  local results, errors, count = {}, {}, 0
  ---@param name "pages"|"files"
  local function on_result(name)
    return function(err, result)
      results[name], errors[name], count = result, err, count + 1
      if count < 2 then
        return
      end
      -- The GraphQL error is clearer, for example for a PR that does not exist.
      local first_err = errors.pages or errors.files
      if first_err then
        cb(first_err)
      else
        cb(nil, to_change(results.pages, results.files, target))
      end
    end
  end
  run_json("gh api graphql", get_change_args(target), on_result("pages"))
  run_json("gh api", get_files_args(target), on_result("files"))
end

---@param change didymus.review.provider.github.Change
---@param cb fun(err: string?)
function M:checkout(change, cb)
  local target = change.github
  local args = { "pr", "checkout", tostring(target.number) }
  if target.owner then
    vim.list_extend(args, { "--repo", ("%s/%s/%s"):format(target.host, target.owner, target.repo) })
  end
  run("gh pr checkout", args, function(err)
    cb(err)
  end)
end

--- `:checkhealth` is synchronous, so this check waits for `gh auth status`.
function M.health()
  if vim.fn.executable("gh") ~= 1 then
    vim.health.error(
      "`gh` is not on $PATH (review.provider)",
      "Install the GitHub CLI, or set `review.provider`."
    )
    return
  end
  local result = vim
    .system({ "gh", "auth", "status", "--active" }, { text = true })
    :wait(auth_timeout)
  if result.code == 0 then
    vim.health.ok("`gh` is authenticated (review.provider)")
  elseif result.code == 124 then
    vim.health.error(
      ("`gh auth status` gave no reply in %d seconds (review.provider)"):format(auth_timeout / 1000)
    )
  else
    local advice = {}
    for line in vim.gsplit(vim.trim(result.stderr), "\n") do
      -- `gh` starts some lines with "- ", and the report adds one more.
      line = vim.trim(line):gsub("^%- ", "")
      if line ~= "" then
        table.insert(advice, line)
      end
    end
    table.insert(advice, "Run `gh auth login`, or set `review.provider`.")
    vim.health.error("`gh auth status` failed (review.provider)", advice)
  end
end

return M
