local eq = MiniTest.expect.equality
local target = require("didymus.diff.target")

local T = MiniTest.new_set()

---@param fields table?
---@return didymus.diff.Target
local function make_target(fields)
  return vim.tbl_extend("force", {
    cwd = "/repo",
    base = { kind = "commit", sha = "abc123" },
    head = { kind = "worktree" },
    files = {
      { path = "a.lua", status = "modified" },
      { path = "b.lua", base_path = "old_b.lua", status = "renamed" },
    },
  }, fields or {})
end

T["check_revision()"] = MiniTest.new_set()

T["check_revision()"]["accepts each kind"] = function()
  eq(target.check_revision({ kind = "commit", sha = "abc123" }), nil)
  eq(target.check_revision({ kind = "index" }), nil)
  eq(target.check_revision({ kind = "worktree" }), nil)
end

T["check_revision()"]["refuses an unknown kind"] = function()
  eq(
    target.check_revision({ kind = "branch" }),
    'unknown revision kind "branch". Use "commit", "index" or "worktree".'
  )
  eq(target.check_revision("HEAD"), "the revision is not a table")
end

T["check_revision()"]["needs a sha only for a commit"] = function()
  eq(target.check_revision({ kind = "commit" }), "a commit revision needs a sha")
  eq(target.check_revision({ kind = "commit", sha = "" }), "a commit revision needs a sha")
  eq(
    target.check_revision({ kind = "index", sha = "abc123" }),
    "only a commit revision has a sha, not index"
  )
end

T["check_file()"] = MiniTest.new_set()

T["check_file()"]["accepts a file with and with no base path"] = function()
  eq(target.check_file({ path = "a.lua", status = "added" }), nil)
  eq(target.check_file({ path = "b.lua", base_path = "a.lua", status = "renamed" }), nil)
end

T["check_file()"]["needs a path"] = function()
  eq(target.check_file({ status = "added" }), "the file needs a path")
  eq(target.check_file({ path = "", status = "added" }), "the file needs a path")
end

T["check_file()"]["refuses a base path that is not a path"] = function()
  eq(
    target.check_file({ path = "b.lua", base_path = 1, status = "renamed" }),
    "the base_path of b.lua is not a path"
  )
end

T["check_file()"]["refuses an unknown status"] = function()
  eq(
    target.check_file({ path = "a.lua", status = "copied" }),
    'unknown status "copied" of a.lua. Use "added", "modified", "deleted" or "renamed".'
  )
end

T["check_target()"] = MiniTest.new_set()

T["check_target()"]["accepts a valid target"] = function()
  eq(target.check_target(make_target()), nil)
  eq(target.check_target(make_target({ files = {} })), nil)
end

T["check_target()"]["needs a cwd"] = function()
  eq(target.check_target(make_target({ cwd = "" })), "the target needs a cwd")
end

T["check_target()"]["tells the side of a bad revision"] = function()
  eq(
    target.check_target(make_target({ base = { kind = "commit" } })),
    "base: a commit revision needs a sha"
  )
  eq(target.check_target(make_target({ head = "HEAD" })), "head: the revision is not a table")
end

T["check_target()"]["checks each file"] = function()
  eq(target.check_target(make_target({ files = "a.lua" })), "the target needs a list of files")
  eq(
    target.check_target(make_target({ files = { { path = "a.lua" } } })),
    'unknown status "nil" of a.lua. Use "added", "modified", "deleted" or "renamed".'
  )
end

T["base_path()"] = function()
  eq(target.base_path({ path = "a.lua", status = "modified" }), "a.lua")
  eq(target.base_path({ path = "b.lua", base_path = "a.lua", status = "renamed" }), "a.lua")
end

return T
