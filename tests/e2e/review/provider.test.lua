local helpers = dofile("tests/e2e/review/helpers.lua")

local child = MiniTest.new_child_neovim()
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.lua("require('didymus').setup({ review = { provider = 'test' } })")
    end,
    post_once = child.stop,
  },
})

---@param dir string
---@return string
local function head(dir)
  return vim.trim(helpers.git(dir, { "rev-parse", "HEAD" }))
end

T["the test provider returns the changes that the test gave it"] = function()
  local first = helpers.make_repo().change
  local second = vim.tbl_extend("force", first, { id = "2", title = "Draft", is_draft = true })
  helpers.set_changes(child, { first, second })

  expect.equality(helpers.call(child, "list_changes", {}), {
    result = {
      {
        id = "1",
        title = "Change the second line",
        author = "octocat",
        body = "The body of the change.",
        is_draft = false,
      },
      {
        id = "2",
        title = "Draft",
        author = "octocat",
        body = "The body of the change.",
        is_draft = true,
      },
    },
  })
  expect.equality(helpers.call(child, "get_change", "2"), { result = second })
end

T["the change of the repo helper has the files of the diff"] = function()
  local change = helpers.make_repo().change
  expect.equality(change.files, {
    {
      path = "file.txt",
      status = "modified",
      additions = 1,
      deletions = 1,
      patch = "@@ -1,3 +1,3 @@\n one\n-two\n+2\n three",
    },
  })
end

T["get_change gives an error for an unknown id"] = function()
  helpers.set_changes(child, { helpers.make_repo().change })
  expect.equality(helpers.call(child, "get_change", "9"), { err = 'no change "9"' })
end

T["checkout moves HEAD to the head commit of the change"] = function()
  local repo = helpers.make_repo()
  child.fn.chdir(repo.dir)
  expect.equality(head(repo.dir), repo.change.base_sha)

  expect.equality(helpers.call(child, "checkout", repo.change), {})
  expect.equality(head(repo.dir), repo.change.head_sha)
end

T["checkout gives the error of git if git refuses"] = function()
  local repo = helpers.make_repo()
  helpers.write(repo.dir, { ["file.txt"] = "a local change\n" })
  child.fn.chdir(repo.dir)

  -- Git can translate its message, but not the path.
  local reply = helpers.call(child, "checkout", repo.change)
  expect.no_equality(reply.err:find("file.txt", 1, true), nil)
  expect.equality(head(repo.dir), repo.change.base_sha)
end

return T
