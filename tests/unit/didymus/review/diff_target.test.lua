local eq = MiniTest.expect.equality
local diff_target = require("didymus.review.diff_target")

local T = MiniTest.new_set()

---@return didymus.review.DiffTargetSource
local function make_session()
  return {
    cwd = "/repo",
    merge_base = "1111111aaaa",
    change = {
      base_sha = "2222222bbbb",
      head_sha = "3333333cccc",
      files = {
        {
          path = "new.lua",
          status = "added",
          additions = 3,
          deletions = 0,
          patch = "@@ -0,0 +1,3 @@",
        },
        { path = "edit.lua", status = "modified", additions = 1, deletions = 1 },
        { path = "gone.lua", status = "deleted", additions = 0, deletions = 2 },
        {
          path = "lua/moved.lua",
          old_path = "moved.lua",
          status = "renamed",
          additions = 0,
          deletions = 0,
        },
      },
    },
  }
end

T["make()"] = MiniTest.new_set()

T["make()"]["gives the merge-base, the working tree and the files of a PR"] = function()
  local target, err = diff_target.make(make_session())
  eq(err, nil)
  eq(target, {
    cwd = "/repo",
    base = { kind = "commit", sha = "1111111aaaa" },
    head = { kind = "worktree" },
    files = {
      { path = "new.lua", status = "added" },
      { path = "edit.lua", status = "modified" },
      { path = "gone.lua", status = "deleted" },
      { path = "lua/moved.lua", base_path = "moved.lua", status = "renamed" },
    },
  })
end

T["make()"]["gives an error with no merge-base"] = function()
  local session = make_session()
  session.merge_base = nil
  local target, err = diff_target.make(session)
  eq(target, nil)
  eq(err, "the diff is not available: git found no merge-base of 2222222 and 3333333")
end

T["make()"]["uses the diff of the change, also with no merge-base"] = function()
  local session = make_session()
  session.merge_base = nil
  session.change.diff = { base = { kind = "index" }, head = { kind = "worktree" } }
  local target, err = diff_target.make(session)
  eq(err, nil)
  eq({ target.base, target.head }, { { kind = "index" }, { kind = "worktree" } })
  eq(#target.files, 4)

  -- The target has its own tables, so a change of the target does not change the session.
  target.base.kind = "commit"
  eq(session.change.diff.base, { kind = "index" })
end

T["make()"]["gives the error of a wrong diff of the change"] = function()
  local session = make_session()
  session.change.diff = { base = { kind = "commit" }, head = { kind = "worktree" } }
  local target, err = diff_target.make(session)
  eq(target, nil)
  eq(err, "the diff is not available: base: a commit revision needs a sha")
end

return T
