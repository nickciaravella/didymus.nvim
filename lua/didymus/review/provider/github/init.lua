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

---@param comment table A comment from GraphQL.
---@return didymus.review.Comment
local function to_comment(comment)
  return {
    author = get_login(comment.author),
    body = ((comment.body or ""):gsub("\r\n", "\n")),
    pending = comment.state == "PENDING",
  }
end

---@param thread table A thread from GraphQL.
---@param comments table[] All comments of the thread.
---@return didymus.review.Thread
local function to_thread(thread, comments)
  local range
  -- GitHub gives no line for an outdated thread or a thread on the file.
  if thread.line and not thread.isOutdated then
    local first = thread.startLine or thread.line
    -- A range can start on the other side. Only the last line is on the side of the thread.
    if thread.startDiffSide and thread.startDiffSide ~= thread.diffSide then
      first = thread.line
    end
    range = { first = first, last = thread.line }
  end
  return {
    id = thread.id,
    path = thread.path,
    side = thread.diffSide == "LEFT" and "base" or "head",
    range = range,
    resolved = thread.isResolved,
    outdated = thread.isOutdated,
    can_reply = thread.viewerCanReply,
    can_resolve = thread.viewerCanResolve,
    can_unresolve = thread.viewerCanUnresolve,
    comments = vim.tbl_map(to_comment, comments),
  }
end

---@param target didymus.review.provider.github.Target
---@param query string
---@param id string The GraphQL id of the node.
---@return string[]
local function get_node_args(target, query, id)
  local args = { "api", "graphql", "--paginate", "--slurp", "-f", "query=" .. query }
  vim.list_extend(args, { "-f", "id=" .. id })
  return vim.list_extend(args, get_host_args(target))
end

--- The arguments of one `gh api graphql` call, with no pagination.
---@param target didymus.review.provider.github.Target
---@param query string
---@param fields string[] The `-f` and `-F` arguments of the variables.
---@return string[]
local function get_graphql_args(target, query, fields)
  local args = vim.list_extend({ "api", "graphql", "-f", "query=" .. query }, fields)
  return vim.list_extend(args, get_host_args(target))
end

--- Get all comments of each thread that has more comments than the first page, at the same time.
--- Then change the threads into review threads.
---@param target didymus.review.provider.github.Target
---@param nodes table[] Threads from GraphQL.
---@param cb fun(err: string?, threads: didymus.review.Thread[]?)
local function complete_threads(target, nodes, cb)
  local comments, waiting, failed = {}, 0, false
  local function finish()
    cb(
      nil,
      vim.tbl_map(function(thread)
        return to_thread(thread, comments[thread.id] or thread.comments.nodes)
      end, nodes)
    )
  end
  for _, thread in ipairs(nodes) do
    if thread.comments.pageInfo.hasNextPage then
      waiting = waiting + 1
      local args = get_node_args(target, graphql.thread_comments, thread.id)
      run_json("gh api graphql", args, function(err, comment_pages)
        if failed then
          return
        end
        if err then
          failed = true
          return cb(err)
        end
        comments[thread.id] = {}
        for _, page in ipairs(comment_pages) do
          vim.list_extend(comments[thread.id], page.data.node.comments.nodes)
        end
        waiting = waiting - 1
        if waiting == 0 then
          finish()
        end
      end)
    end
  end
  if waiting == 0 then
    finish()
  end
end

--- Get the threads, then all comments of each thread that has more comments, at the same time.
---@param change didymus.review.provider.github.Change
---@param cb fun(err: string?, threads: didymus.review.Thread[]?)
function M:get_threads(change, cb)
  local target = change.github
  local args = get_node_args(target, graphql.threads, target.node_id)
  run_json("gh api graphql", args, function(err, pages)
    if err then
      return cb(err)
    end
    local threads = {}
    for _, page in ipairs(pages) do
      vim.list_extend(threads, page.data.node.reviewThreads.nodes)
    end
    complete_threads(target, threads, cb)
  end)
end

--- Get the pending review of the viewer. Nil if there is none. Do not use
--- `change.pending_review_id`, because the user can start, submit or discard a review on github.com.
---@param change didymus.review.provider.github.Change
---@param cb fun(err: string?, review_id: string?)
local function find_pending_review(change, cb)
  local target = change.github
  local args = get_graphql_args(target, graphql.pending_reviews, { "-f", "id=" .. target.node_id })
  run_json("gh api graphql", args, function(err, result)
    if err then
      return cb(err)
    end
    for _, review in ipairs(result.data.node.reviews.nodes) do
      if review.viewerDidAuthor then
        return cb(nil, review.id)
      end
    end
    cb(nil, nil)
  end)
end

--- Get the pending review of the viewer, or start one at the change head.
---@param change didymus.review.provider.github.Change
---@param cb fun(err: string?, review_id: string?)
local function get_pending_review(change, cb)
  local target = change.github
  local label = "gh api graphql"
  find_pending_review(change, function(err, review_id)
    if err or review_id then
      return cb(err, review_id)
    end
    local args = get_graphql_args(target, graphql.start_review, {
      "-f",
      "pullRequestId=" .. target.node_id,
      "-f",
      "commitOID=" .. change.head_sha,
    })
    run_json(label, args, function(start_err, started)
      if start_err then
        return cb(start_err)
      end
      cb(nil, started.data.addPullRequestReview.pullRequestReview.id)
    end)
  end)
end

--- Add a thread on the head side to the pending review of the viewer. Start the review if there
--- is none.
---@param change didymus.review.provider.github.Change
---@param draft didymus.review.CommentDraft
---@param cb fun(err: string?, thread: didymus.review.Thread?)
function M:add_comment(change, draft, cb)
  local label = "gh api graphql"
  get_pending_review(change, function(err, review_id)
    if err then
      return cb(err)
    end
    change.pending_review_id = review_id
    local fields = { "-f", "reviewId=" .. review_id, "-f", "path=" .. draft.path }
    vim.list_extend(fields, { "-f", "body=" .. draft.body, "-F", "line=" .. draft.range.last })
    if draft.range.first ~= draft.range.last then
      vim.list_extend(fields, { "-F", "startLine=" .. draft.range.first, "-f", "startSide=RIGHT" })
    end
    local args = get_graphql_args(change.github, graphql.add_thread, fields)
    run_json(label, args, function(add_err, result)
      if add_err then
        return cb(add_err)
      end
      local thread = result.data.addPullRequestReviewThread.thread
      if not thread then
        -- GitHub gives no error for a line out of the diff.
        return cb(("%s: GitHub did not add the thread. Are the lines in the diff?"):format(label))
      end
      cb(nil, to_thread(thread, thread.comments.nodes))
    end)
  end)
end

--- Add a reply to the pending review of the viewer. Start the review if there is none.
---@param change didymus.review.provider.github.Change
---@param thread_id string
---@param body string
---@param cb fun(err: string?, comment: didymus.review.Comment?)
function M:reply(change, thread_id, body, cb)
  local label = "gh api graphql"
  get_pending_review(change, function(err, review_id)
    if err then
      return cb(err)
    end
    change.pending_review_id = review_id
    local args = get_graphql_args(change.github, graphql.reply, {
      "-f",
      "reviewId=" .. review_id,
      "-f",
      "threadId=" .. thread_id,
      "-f",
      "body=" .. body,
    })
    run_json(label, args, function(reply_err, result)
      if reply_err then
        return cb(reply_err)
      end
      local comment = result.data.addPullRequestReviewThreadReply.comment
      if not comment then
        return cb(("%s: GitHub did not add the reply"):format(label))
      end
      cb(nil, to_comment(comment))
    end)
  end)
end

--- Resolve or unresolve a thread. Give the thread with its new state.
---@param change didymus.review.provider.github.Change
---@param thread_id string
---@param resolved boolean
---@param cb fun(err: string?, thread: didymus.review.Thread?)
function M:set_resolved(change, thread_id, resolved, cb)
  local label = "gh api graphql"
  local query = resolved and graphql.resolve or graphql.unresolve
  local args = get_graphql_args(change.github, query, { "-f", "threadId=" .. thread_id })
  run_json(label, args, function(err, result)
    if err then
      return cb(err)
    end
    local payload = result.data[resolved and "resolveReviewThread" or "unresolveReviewThread"]
    if not (payload and payload.thread) then
      return cb(("%s: GitHub did not change the thread"):format(label))
    end
    complete_threads(change.github, { payload.thread }, function(threads_err, threads)
      cb(threads_err, threads and threads[1])
    end)
  end)
end

---@type table<didymus.review.Verdict, string>
local events = { approve = "APPROVE", comment = "COMMENT", request_changes = "REQUEST_CHANGES" }

--- Submit the pending review of the viewer with the verdict. With no pending review, add a review
--- at the change head.
---@param change didymus.review.provider.github.Change
---@param verdict didymus.review.Verdict
---@param body string? Nil or empty for no body.
---@param cb fun(err: string?)
function M:submit_review(change, verdict, body, cb)
  local target = change.github
  local label = "gh api graphql"
  find_pending_review(change, function(err, review_id)
    if err then
      return cb(err)
    end
    local fields = { "-f", "event=" .. events[verdict], "-f", "body=" .. (body or "") }
    local query, mutation = graphql.submit_review, "submitPullRequestReview"
    if review_id then
      vim.list_extend(fields, { "-f", "reviewId=" .. review_id })
    else
      query, mutation = graphql.add_review, "addPullRequestReview"
      vim.list_extend(fields, { "-f", "pullRequestId=" .. target.node_id })
      vim.list_extend(fields, { "-f", "commitOID=" .. change.head_sha })
    end
    run_json(label, get_graphql_args(target, query, fields), function(submit_err, result)
      if submit_err then
        return cb(submit_err)
      end
      -- GitHub can give an error with no message. Then `gh` exits with 0.
      if not (result.data and result.data[mutation]) then
        return cb(("%s: GitHub did not submit the review"):format(label))
      end
      change.pending_review_id = nil
      cb(nil)
    end)
  end)
end

--- Delete the pending review of the viewer and its comments. Give an error if there is none.
---@param change didymus.review.provider.github.Change
---@param cb fun(err: string?)
function M:discard_review(change, cb)
  local label = "gh api graphql"
  find_pending_review(change, function(err, review_id)
    if err then
      return cb(err)
    end
    if not review_id then
      change.pending_review_id = nil
      return cb("you have no pending review")
    end
    local args = get_graphql_args(change.github, graphql.delete_review, {
      "-f",
      "reviewId=" .. review_id,
    })
    run_json(label, args, function(delete_err, result)
      if delete_err then
        return cb(delete_err)
      end
      if not (result.data and result.data.deletePullRequestReview) then
        return cb(("%s: GitHub did not delete the review"):format(label))
      end
      change.pending_review_id = nil
      cb(nil)
    end)
  end)
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
