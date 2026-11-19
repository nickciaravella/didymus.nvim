local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

---@param diff table? The `diff` options.
local function setup(diff)
  child.lua(
    "require('didymus').setup({ review = { picker = 'test', provider = 'test' }, diff = ... })",
    { vim.tbl_extend("force", { provider = "test" }, diff or {}) }
  )
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      setup()
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
      child.lua([[
        local provider = require("didymus.diff.provider.test")
        provider.hunks_by_path = {
          ["file.txt"] = { { kind = "change", base = { start = 2, count = 1 }, head = { start = 2, count = 1 } } },
          ["new.txt"] = { { kind = "add", base = { start = 0, count = 0 }, head = { start = 1, count = 1 } } },
        }
      ]])
    end,
    post_once = child.stop,
  },
})

---@type didymus.test.Repo
local repo

--- Make a repo where the change modifies file.txt and adds new.txt. other.txt is not in the change.
--- Make it the directory of the child, and give its change to the test provider.
---@param edit fun(change: didymus.review.Change)? Change the change before the review opens.
local function setup_repo(edit)
  repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n", ["other.txt"] = "other\n" },
    head = { ["file.txt"] = "one\n2\nthree\n", ["new.txt"] = "new\n" },
  })
  if edit then
    edit(repo.change)
  end
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", {})
end

---@param edit fun(change: didymus.review.Change)?
local function open_review(edit)
  setup_repo(edit)
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
end

---@return table[]
local function calls()
  return child.lua_get("require('didymus.diff.provider.test').calls")
end

---@param method string
---@return table[]
local function calls_of(method)
  return vim.tbl_filter(function(call)
    return call.method == method
  end, calls())
end

---@param count integer
local function wait_for_renders(count)
  wait_for(function()
    return #calls_of("render") >= count
  end, function()
    return ("render %d: %s"):format(count, vim.inspect(calls()))
  end)
end

--- Open a file of the change with `<CR>` in the panel.
---@param path string
local function choose_file(path)
  local text = path == "file.txt" and "M file.txt +1 -1" or "A new.txt +1 -0"
  child.lua("require('didymus.ui.picker.test').choose(...)", { text })
end

--- The text of the diff marks in the current window.
---@return string[]
local function marks()
  return child.lua_get([[
    (function()
      local ns = vim.api.nvim_get_namespaces()["didymus.diff.test." .. vim.api.nvim_get_current_win()]
      if not ns then
        return {}
      end
      return vim.tbl_map(function(mark)
        return mark[4].virt_text[1][1]
      end, vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true }))
    end)()
  ]])
end

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return child.cmd_capture("messages"):find(text, 1, true) ~= nil
  end, function()
    return ("%q is not in the messages:\n%s"):format(text, child.cmd_capture("messages"))
  end)
end

---@param text string
local function expect_no_message(text)
  local messages = child.cmd_capture("messages")
  if messages:find(text, 1, true) then
    error(("%q is in the messages:\n%s"):format(text, messages), 2)
  end
end

--- Let the scheduled callbacks run.
local function settle()
  child.lua("vim.wait(50, function() return false end)")
end

---@return integer
local function current_buf()
  return child.api.nvim_get_current_buf()
end

T["the diff shows when the review opens, in the code window"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)

  local render = calls_of("render")[1]
  eq(render.path, "file.txt")
  eq(render.layout, "inline")
  eq(render.sides, "both")
  eq(render.head_win, child.api.nvim_get_current_win())
  eq(render.head_buf, current_buf())
  eq(marks(), { "diff inline both" })
end

T["with diff.enabled = false, the diff does not show until toggle"] = function()
  setup({ enabled = false })
  open_review()
  choose_file("file.txt")
  settle()
  eq(calls(), {})

  child.cmd("Didymus diff toggle")
  wait_for_renders(1)
  eq(calls_of("render")[1].path, "file.txt")
  eq(marks(), { "diff inline both" })
end

T["toggle hides the diff and detaches the buffers, then shows it again"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)
  local win, buf = child.api.nvim_get_current_win(), current_buf()

  child.cmd("Didymus diff toggle")
  eq(marks(), {})
  eq(#calls_of("clear"), 1)
  eq(calls_of("clear")[1].win, win)
  eq(calls_of("detach"), { { method = "detach", buf = buf } })

  child.cmd("Didymus diff toggle")
  wait_for_renders(2)
  eq(#calls_of("attach"), 2)
  eq(marks(), { "diff inline both" })
end

T["the diff follows the code window to a different file of the change"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)
  local file_buf = current_buf()

  child.cmd("edit new.txt")
  wait_for_renders(2)
  eq(calls_of("render")[2].path, "new.txt")
  eq(marks(), { "diff inline both" })

  -- The buffer stays attached, so the provider does not attach it again.
  choose_file("file.txt")
  wait_for_renders(3)
  eq(current_buf(), file_buf)
  eq(calls_of("render")[3].path, "file.txt")
  eq(
    vim.tbl_map(function(call)
      return call.path
    end, calls_of("attach")),
    { "file.txt", "new.txt" }
  )
end

T["a file that is not in the change has no diff"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)
  local win = child.api.nvim_get_current_win()

  child.cmd("edit other.txt")
  settle()
  eq(calls_of("clear")[1].win, win)
  eq(#calls_of("attach"), 1)
  eq(#calls_of("render"), 1)
  eq(marks(), {})
end

T["only the code window has the diff"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)

  child.cmd("split new.txt")
  settle()
  eq(#calls_of("attach"), 1)
  eq(marks(), {})
end

for _, close in ipairs({ "Didymus review close", "tabclose" }) do
  T[(":%s detaches all buffers"):format(close)] = function()
    open_review()
    choose_file("file.txt")
    wait_for_renders(1)
    local file_buf = current_buf()
    child.cmd("edit new.txt")
    wait_for_renders(2)
    local new_buf = current_buf()

    child.cmd(close)
    local detached = vim.tbl_map(function(call)
      return call.buf
    end, calls_of("detach"))
    table.sort(detached)
    eq(detached, { file_buf, new_buf })
  end
end

T["an unloaded buffer is detached"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)
  local buf = current_buf()

  child.cmd("bwipeout")
  settle()
  eq(calls_of("detach"), { { method = "detach", buf = buf } })
end

T["a progress message shows if attach takes more than 500 ms"] = function()
  -- The progress messages do not go into the message history.
  child.lua([[
    _G.progress = {}
    local echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, history, opts)
      if opts.kind == "progress" and opts.id == "didymus.diff.progress" then
        table.insert(_G.progress, { chunks[1][1], opts.status })
      end
      return echo(chunks, history, opts)
    end
    require("didymus.diff.provider.test").delays = { ["file.txt"] = 700, ["new.txt"] = 100 }
  ]])
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)
  child.cmd("edit new.txt")
  wait_for_renders(2)
  settle()

  eq(child.lua_get("_G.progress"), {
    { "get the diff of file.txt", "running" },
    { "get the diff of file.txt", "success" },
  })
end

T["an attach error shows a warning once"] = function()
  child.lua("require('didymus.diff.provider.test').errors.attach = 'no tool'")
  open_review()
  choose_file("file.txt")
  wait_for_message("didymus: cannot show the diff of file.txt: no tool")
  eq(#calls_of("render"), 0)

  child.lua("require('didymus.diff.provider.test').errors.attach = 'no tool'")
  child.cmd("edit new.txt")
  wait_for(function()
    return #calls_of("attach") == 2
  end, "the second attach")
  settle()
  expect_no_message("the diff of new.txt")
end

T["a render error shows a warning"] = function()
  child.lua("require('didymus.diff.provider.test').errors.render = 'no window'")
  open_review()
  choose_file("file.txt")
  wait_for_message("didymus: cannot show the diff of file.txt: no window")
end

T["an old attach does not render after the code window shows a different file"] = function()
  child.lua("require('didymus.diff.provider.test').delays = { ['file.txt'] = 200 }")
  open_review()
  choose_file("file.txt")
  settle()
  child.cmd("edit new.txt")
  wait_for_renders(1)
  child.lua("vim.wait(300, function() return false end)")

  eq(
    vim.tbl_map(function(call)
      return call.path
    end, calls_of("render")),
    { "new.txt" }
  )
end

T["toggle from a different tabpage goes to the review tabpage"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)
  local review = helpers.review(child) --[[@as didymus.test.Review]]
  child.cmd("tabnew")

  child.cmd("Didymus diff toggle")
  eq(child.api.nvim_get_current_tabpage(), review.tabpage)
  eq(#calls_of("detach"), 1)
end

T["<Plug>(didymus-diff-toggle) toggles the diff"] = function()
  open_review()
  choose_file("file.txt")
  wait_for_renders(1)

  child.lua("vim.keymap.set('n', '<F2>', '<Plug>(didymus-diff-toggle)')")
  child.type_keys("<F2>")
  eq(marks(), {})
end

T["toggle with no review shows a warning"] = function()
  child.cmd("Didymus diff toggle")
  wait_for_message("didymus: no review is open")
end

T["an unknown provider shows a warning, and the review opens with no diff"] = function()
  setup({ provider = "nope" })
  open_review()
  wait_for_message('didymus: unknown provider "nope". Use "gitsigns", "test" or a provider table.')
  wait_for_message("(diff.provider)")
  choose_file("file.txt")
  eq(child.fn.expand("%:."), "file.txt")
end

T["with no merge-base, a warning tells that the diff is not available"] = function()
  open_review(function(change)
    change.base_sha = string.rep("1", 40)
  end)
  wait_for_message("didymus: the diff is not available: git found no merge-base of 1111111 and")
  choose_file("file.txt")
  settle()
  eq(calls(), {})
end

T["a warning shows once if HEAD is not the head of the change"] = function()
  setup({ enabled = false })
  open_review()
  helpers.git(repo.dir, { "commit", "--quiet", "--allow-empty", "--message", "local" })

  child.cmd("Didymus diff toggle")
  wait_for_message("didymus: the diff also shows local changes, because HEAD is not the head of #1")
  child.cmd("Didymus diff toggle")
  child.cmd("messages clear")
  child.cmd("Didymus diff toggle")
  settle()
  expect_no_message("local changes")
end

T["a warning shows if a file of the change has uncommitted changes"] = function()
  setup({ enabled = false })
  open_review()
  helpers.write(repo.dir, { ["file.txt"] = "local\n", ["other.txt"] = "local\n" })

  child.cmd("Didymus diff toggle")
  wait_for_message(
    "didymus: the diff also shows local changes, because file.txt has uncommitted changes"
  )
end

T["no local changes warning shows for a clean checkout"] = function()
  open_review()
  helpers.write(repo.dir, { ["other.txt"] = "local\n" })
  choose_file("file.txt")
  wait_for_renders(1)
  settle()
  expect_no_message("local changes")
end

return T
