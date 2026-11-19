--- The diff types and their checks. The review gives the diff view a target. The diff part does
--- not know about code hosts. See docs/architecture/diff.md#interfaces.

---@alias didymus.diff.Layout "inline"|"split"
---@alias didymus.diff.Sides "both"|"base"|"head"
---@alias didymus.diff.Side "base"|"head"
---@alias didymus.diff.RevisionKind "commit"|"index"|"worktree"

---@class didymus.diff.Revision
---@field kind didymus.diff.RevisionKind
---@field sha string? Only for "commit".

---@class didymus.diff.File
---@field path string        The head path, relative to `Target.cwd`.
---@field base_path string?  The base path of a renamed file. Default `path`.
---@field status "added"|"modified"|"deleted"|"renamed"

---@class didymus.diff.Target
---@field cwd string
---@field base didymus.diff.Revision
---@field head didymus.diff.Revision
---@field files didymus.diff.File[] In the order of the panel.

--- 1-based lines. For a deletion, `head.count` is 0 and `head.start` is the line before the deleted
--- lines, as in a unified diff. It is 0 at the start of the file. The same applies to `base`.
---@class didymus.diff.Hunk
---@field kind "add"|"change"|"delete"
---@field base { start: integer, count: integer }
---@field head { start: integer, count: integer }

--- The windows and buffers that the provider decorates. The diff view makes them.
---@class didymus.diff.Display
---@field layout didymus.diff.Layout
---@field sides didymus.diff.Sides
---@field file didymus.diff.File
---@field target didymus.diff.Target
---@field head_win integer?  The code window with the head buffer. Nil if the sides are "base".
---@field head_buf integer?  The attached head buffer, which has the hunks. Also for "base", when it is hidden.
---@field base_win integer?  The window with the base revision buffer. The code window if the sides are "base".
---@field base_buf integer?  Nil for inline "both" and for "head".

local M = {}

local revision_kinds = { commit = true, index = true, worktree = true }
local statuses = { added = true, modified = true, deleted = true, renamed = true }

---@param value any
---@return boolean
local function is_text(value)
  return type(value) == "string" and value ~= ""
end

---@param revision any
---@return string? err
function M.check_revision(revision)
  if type(revision) ~= "table" then
    return "the revision is not a table"
  end
  if not revision_kinds[revision.kind] then
    return ('unknown revision kind %q. Use "commit", "index" or "worktree".'):format(
      tostring(revision.kind)
    )
  end
  if revision.kind == "commit" and not is_text(revision.sha) then
    return "a commit revision needs a sha"
  end
  if revision.kind ~= "commit" and revision.sha ~= nil then
    return ("only a commit revision has a sha, not %s"):format(revision.kind)
  end
end

---@param file any
---@return string? err
function M.check_file(file)
  if type(file) ~= "table" then
    return "the file is not a table"
  end
  if not is_text(file.path) then
    return "the file needs a path"
  end
  if file.base_path ~= nil and not is_text(file.base_path) then
    return ("the base_path of %s is not a path"):format(file.path)
  end
  if not statuses[file.status] then
    return ('unknown status %q of %s. Use "added", "modified", "deleted" or "renamed".'):format(
      tostring(file.status),
      file.path
    )
  end
end

---@param target any
---@return string? err
function M.check_target(target)
  if type(target) ~= "table" then
    return "the target is not a table"
  end
  if not is_text(target.cwd) then
    return "the target needs a cwd"
  end
  for _, side in ipairs({ "base", "head" }) do
    local err = M.check_revision(target[side])
    if err then
      return ("%s: %s"):format(side, err)
    end
  end
  if type(target.files) ~= "table" then
    return "the target needs a list of files"
  end
  for _, file in ipairs(target.files) do
    local err = M.check_file(file)
    if err then
      return err
    end
  end
end

--- The path of the file on the base side.
---@param file didymus.diff.File
---@return string
function M.base_path(file)
  return file.base_path or file.path
end

return M
