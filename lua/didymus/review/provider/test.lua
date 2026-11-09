--- A provider that keeps its changes in memory, for end-to-end tests. Tests give it the data in
--- `changes`. It calls each `cb` in `vim.schedule()`, so that its timing is the same as the
--- timing of a real provider.

---@class didymus.review.provider.Test: didymus.review.Provider
---@field changes didymus.review.Change[]
local M = { changes = {} }

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

return M
