--- A provider that keeps its changes in memory, for end-to-end tests. Tests give it the data in
--- `changes` and `threads`. It calls each `cb` in `vim.schedule()`, so that its timing is the
--- same as the timing of a real provider.

---@class didymus.review.provider.Test: didymus.review.Provider
---@field changes didymus.review.Change[]
---@field threads table<string, didymus.review.Thread[]> The threads of each change id.
---@field viewer string The author of the new comments.
---@field errors table<string, string> The next call of a method, such as `add_comment`, fails with this error.
---@field reviews { change_id: string, verdict: didymus.review.Verdict, body: string? }[] The reviews that `submit_review()` submitted.
local M = { changes = {}, threads = {}, viewer = "reviewer", errors = {}, reviews = {} }

--- The number of threads that `add_comment()` made, for their ids.
local added_count = 0

--- Call `cb` with the error of `method`, if a test set one. Use the error only once.
---@param method string
---@param cb fun(err: string?)
---@return boolean failed
local function fail(method, cb)
  local err = M.errors[method]
  if not err then
    return false
  end
  M.errors[method] = nil
  vim.schedule(function()
    cb(err)
  end)
  return true
end

local summary_fields = { "id", "title", "author", "body", "is_draft" }

---@param _ { search: string? }
---@param cb fun(err: string?, changes: didymus.review.ChangeSummary[]?)
function M:list_changes(_, cb)
  local summaries = vim.tbl_map(function(change)
    local summary = {}
    for _, field in ipairs(summary_fields) do
      summary[field] = vim.deepcopy(change[field])
    end
    return summary
  end, self.changes)
  vim.schedule(function()
    cb(nil, summaries)
  end)
end

---@param id string
---@param cb fun(err: string?, change: didymus.review.Change?)
function M:get_change(id, cb)
  for _, change in ipairs(self.changes) do
    if change.id == id then
      local copy = vim.deepcopy(change)
      vim.schedule(function()
        cb(nil, copy)
      end)
      return
    end
  end
  vim.schedule(function()
    cb(("no change %q"):format(id))
  end)
end

---@param change didymus.review.Change
---@param cb fun(err: string?, threads: didymus.review.Thread[]?)
function M:get_threads(change, cb)
  local threads = vim.deepcopy(self.threads[change.id] or {})
  vim.schedule(function()
    cb(nil, threads)
  end)
end

--- Add a thread with one pending comment of `viewer` to the threads of the change.
---@param change didymus.review.Change
---@param draft didymus.review.CommentDraft
---@param cb fun(err: string?, thread: didymus.review.Thread?)
function M:add_comment(change, draft, cb)
  if fail("add_comment", cb) then
    return
  end
  added_count = added_count + 1
  ---@type didymus.review.Thread
  local thread = {
    id = ("added-%d"):format(added_count),
    path = draft.path,
    side = "head",
    range = vim.deepcopy(draft.range),
    resolved = false,
    outdated = false,
    -- GitHub does not let the viewer resolve a thread of a pending review.
    can_reply = true,
    can_resolve = false,
    can_unresolve = false,
    comments = { { author = self.viewer, body = draft.body, pending = true } },
  }
  self.threads[change.id] = self.threads[change.id] or {}
  table.insert(self.threads[change.id], thread)
  local copy = vim.deepcopy(thread)
  vim.schedule(function()
    cb(nil, copy)
  end)
end

--- The thread of the change with `thread_id`. Call `cb` with an error if there is none.
---@param change didymus.review.Change
---@param thread_id string
---@param cb fun(err: string?)
---@return didymus.review.Thread?
local function find_thread(change, thread_id, cb)
  for _, thread in ipairs(M.threads[change.id] or {}) do
    if thread.id == thread_id then
      return thread
    end
  end
  vim.schedule(function()
    cb(("no thread %q"):format(thread_id))
  end)
end

--- Add a pending comment of `viewer` to the thread.
---@param change didymus.review.Change
---@param thread_id string
---@param body string
---@param cb fun(err: string?, comment: didymus.review.Comment?)
function M:reply(change, thread_id, body, cb)
  if fail("reply", cb) then
    return
  end
  local thread = find_thread(change, thread_id, cb)
  if not thread then
    return
  end
  local comment = { author = self.viewer, body = body, pending = true }
  table.insert(thread.comments, comment)
  local copy = vim.deepcopy(comment)
  vim.schedule(function()
    cb(nil, copy)
  end)
end

--- Resolve or unresolve the thread. As on GitHub, the viewer can then do only the other action.
---@param change didymus.review.Change
---@param thread_id string
---@param resolved boolean
---@param cb fun(err: string?, thread: didymus.review.Thread?)
function M:set_resolved(change, thread_id, resolved, cb)
  if fail("set_resolved", cb) then
    return
  end
  local thread = find_thread(change, thread_id, cb)
  if not thread then
    return
  end
  thread.resolved, thread.can_resolve, thread.can_unresolve = resolved, not resolved, resolved
  local copy = vim.deepcopy(thread)
  vim.schedule(function()
    cb(nil, copy)
  end)
end

--- Record the review in `reviews`, and make the pending comments of the change submitted.
---@param change didymus.review.Change
---@param verdict didymus.review.Verdict
---@param body string?
---@param cb fun(err: string?)
function M:submit_review(change, verdict, body, cb)
  if fail("submit_review", cb) then
    return
  end
  table.insert(self.reviews, { change_id = change.id, verdict = verdict, body = body })
  for _, thread in ipairs(self.threads[change.id] or {}) do
    for _, comment in ipairs(thread.comments) do
      comment.pending = false
    end
  end
  vim.schedule(function()
    cb(nil)
  end)
end

--- Remove the pending comments of the change, and the threads with no comments left. Give an error
--- if there are no pending comments.
---@param change didymus.review.Change
---@param cb fun(err: string?)
function M:discard_review(change, cb)
  if fail("discard_review", cb) then
    return
  end
  local kept, found = {}, false
  for _, thread in ipairs(self.threads[change.id] or {}) do
    local comments = vim.tbl_filter(function(comment)
      return not comment.pending
    end, thread.comments)
    found = found or #comments < #thread.comments
    if #comments > 0 then
      thread.comments = comments
      table.insert(kept, thread)
    end
  end
  if found then
    self.threads[change.id] = kept
  end
  vim.schedule(function()
    cb(not found and "you have no pending review" or nil)
  end)
end

--- Run `git checkout <head_sha>` in the current directory.
---@param change didymus.review.Change
---@param cb fun(err: string?)
function M:checkout(change, cb)
  vim.system(
    { "git", "checkout", "--quiet", change.head_sha },
    { cwd = vim.fn.getcwd(), text = true },
    function(result)
      vim.schedule(function()
        cb(result.code ~= 0 and vim.trim(result.stderr) or nil)
      end)
    end
  )
end

function M.health()
  vim.health.ok("the test provider is configured (review.provider)")
end

return M
