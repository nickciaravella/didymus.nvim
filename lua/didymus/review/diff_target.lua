--- Make the diff target of a review session. The diff part gets only the target, so it does not
--- know about code hosts. See docs/architecture/diff.md#the-diff-target-of-a-review.

local diff_target = require("didymus.diff.target")

local M = {}

---@class didymus.review.DiffTargetSource The fields of a review session that the target uses.
---@field cwd string
---@field merge_base string?
---@field change didymus.review.Change

---@param sha string
---@return string
local function shorten(sha)
  return sha:sub(1, 7)
end

---@param file didymus.review.ChangedFile
---@return didymus.diff.File
local function to_file(file)
  return { path = file.path, base_path = file.old_path, status = file.status }
end

---@param session didymus.review.DiffTargetSource
---@return didymus.diff.Target? target
---@return string? err Why the diff is not available.
function M.make(session)
  local change = session.change
  local base, head
  if change.diff then
    base, head = change.diff.base, change.diff.head
  elseif session.merge_base then
    base, head = { kind = "commit", sha = session.merge_base }, { kind = "worktree" }
  else
    return nil,
      ("the diff is not available: git found no merge-base of %s and %s"):format(
        shorten(change.base_sha),
        shorten(change.head_sha)
      )
  end

  local target = {
    cwd = session.cwd,
    base = vim.deepcopy(base),
    head = vim.deepcopy(head),
    files = vim.tbl_map(to_file, change.files),
  }
  local err = diff_target.check_target(target)
  if err then
    return nil, ("the diff is not available: %s"):format(err)
  end
  return target
end

return M
