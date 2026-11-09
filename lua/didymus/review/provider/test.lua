--- A provider that keeps its changes in memory, for end-to-end tests. Tests give it the data in
--- `changes` and `threads`. It calls each `cb` in `vim.schedule()`, so that its timing is the
--- same as the timing of a real provider.

---@class didymus.review.provider.Test: didymus.review.Provider
---@field changes didymus.review.Change[]
---@field threads table<string, didymus.review.Thread[]> The threads of each change id.
---@field viewer string The author of the new comments.
---@field errors table<string, string> The next call of a method, such as `add_comment`, fails with this error.
local M = { changes = {}, threads = {}, viewer = "reviewer", errors = {} }

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
    comments = { { author = self.viewer, body = draft.body, pending = true } },
  }
  self.threads[change.id] = self.threads[change.id] or {}
  table.insert(self.threads[change.id], thread)
  local copy = vim.deepcopy(thread)
  vim.schedule(function()
    cb(nil, copy)
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
