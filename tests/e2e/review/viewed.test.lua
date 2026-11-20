local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

---@param opts table? More options for `review`.
local function setup(opts)
  child.lua(
    "require('didymus').setup({ review = ... })",
    { vim.tbl_extend("force", { picker = "test", provider = "test" }, opts or {}) }
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
    end,
    post_once = child.stop,
  },
})

-- The rows of the files, after the three header rows. git gives the files in the order of the
-- paths.
local file_row, new_row, old_row = 4, 5, 6

--- Make a repo where the change modifies file.txt, adds new.txt and deletes old.txt. Make it the
--- directory of the child. Open the review.
---@param viewed table<string, didymus.review.ViewedState>? The viewed state of each path.
---@param threads didymus.review.Thread[]?
local function open_review(viewed, threads)
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n", ["old.txt"] = "old\n" },
    head = { ["file.txt"] = "one\n2\nthree\n", ["new.txt"] = "new\n", ["old.txt"] = false },
  })
  for _, file in ipairs(repo.change.files) do
    file.viewed = (viewed or {})[file.path] or "unviewed"
  end
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads or {})
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, #(threads or {}))
end

---@return didymus.picker.Item[]
local function panel_items()
  return helpers.picker_calls(child, "panel")[1].items
end

---@param row integer
---@return string
local function row_text(row)
  return panel_items()[row].text
end

--- The viewed state of each file in the test provider.
---@return table<string, string>
local function provider_states()
  return child.lua_get([[(function()
    local states = {}
    for _, file in ipairs(require("didymus.review.provider.test").changes[1].files) do
      states[file.path] = file.viewed
    end
    return states
  end)()]])
end

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return child.cmd_capture("messages"):find(text, 1, true) ~= nil
  end, function()
    return ("%q is not in the messages:\n%s"):format(text, child.cmd_capture("messages"))
  end)
end

---@param key string
---@param row integer
local function press(key, row)
  child.lua("require('didymus.ui.picker.test').press(...)", { key, row })
end

T["a viewed file is dim with the viewed tag, and a changed file has the changed tag"] = function()
  open_review(
    { ["file.txt"] = "viewed", ["new.txt"] = "changed" },
    { helpers.make_thread("t1", "file.txt", { range = { first = 2, last = 2 } }) }
  )
  local items = panel_items()
  eq(items[file_row].segments, {
    { "M", "DidymusFileViewed" },
    { " file.txt", "DidymusFileViewed" },
    { " +1", "DidymusFileViewed" },
    { " -1", "DidymusFileViewed" },
    { " 1 thread", "DidymusFileViewed" },
    { " [viewed]", "DidymusFileViewed" },
  })
  -- The thread of file.txt is in the row under it, so the other files are one row lower.
  eq(items[new_row + 1].segments, {
    { "A", "Added" },
    { " new.txt" },
    { " +1", "Added" },
    { " -0", "Removed" },
    { " [changed]", "DiagnosticWarn" },
  })
  eq(items[old_row + 1].text, "D old.txt +0 -1")
  eq(child.fn.hlexists("DidymusFileViewed"), 1)
end

T["v in the panel marks the file as viewed, and unmarks it"] = function()
  open_review()
  press("v", file_row)
  wait_for_message("didymus: marked file.txt as viewed")
  eq(row_text(file_row), "M file.txt +1 -1 [viewed]")
  eq(provider_states()["file.txt"], "viewed")

  press("v", file_row)
  wait_for_message("didymus: unmarked file.txt as viewed")
  eq(row_text(file_row), "M file.txt +1 -1")
  eq(provider_states()["file.txt"], "unviewed")
end

T["v marks a changed file as viewed"] = function()
  open_review({ ["new.txt"] = "changed" })
  press("v", new_row)
  wait_for_message("didymus: marked new.txt as viewed")
  eq(row_text(new_row), "A new.txt +1 -0 [viewed]")
end

T["v marks a deleted file"] = function()
  open_review()
  press("v", old_row)
  wait_for_message("didymus: marked old.txt as viewed")
  eq(row_text(old_row), "D old.txt +0 -1 [viewed]")
end

T["v on a thread row marks the file of the thread, and v on a header row does nothing"] = function()
  open_review(nil, { helpers.make_thread("t1", "new.txt", { range = { first = 1, last = 1 } }) })
  -- The thread of new.txt is under its row.
  press("v", new_row + 1)
  wait_for_message("didymus: marked new.txt as viewed")
  eq(row_text(new_row), "A new.txt +1 -0 1 thread [viewed]")

  child.cmd("messages clear")
  press("v", 1)
  vim.uv.sleep(50)
  eq(child.cmd_capture("messages"), "")
  eq(provider_states()["file.txt"], "unviewed")
end

T[":Didymus review viewed uses the file of the current window, else of the code window"] = function()
  open_review()
  child.cmd("edit file.txt")
  child.cmd("Didymus review viewed")
  wait_for_message("didymus: marked file.txt as viewed")
  eq(row_text(file_row), "M file.txt +1 -1 [viewed]")

  -- A window with no file of the change, such as the panel.
  child.cmd("leftabove vnew")
  child.cmd("Didymus review viewed")
  wait_for_message("didymus: unmarked file.txt as viewed")
end

T[":Didymus review viewed with no file of the change shows a warning"] = function()
  open_review()
  child.cmd("Didymus review viewed")
  wait_for_message("didymus: no window shows a file of #1")
  eq(provider_states()["file.txt"], "unviewed")
end

T["the mapping marks the file of the current window"] = function()
  open_review()
  child.cmd("edit new.txt")
  child.lua("vim.keymap.set('n', '<F2>', '<Plug>(didymus-review-viewed)')")
  child.type_keys("<F2>")
  wait_for_message("didymus: marked new.txt as viewed")
end

T["if the provider fails, the error shows and the state does not change"] = function()
  open_review()
  child.lua("require('didymus.review.provider.test').errors.set_viewed = 'no access'")
  press("v", file_row)
  wait_for_message("didymus: cannot mark file.txt as viewed: no access")
  eq(row_text(file_row), "M file.txt +1 -1")
end

T["a refresh gets the viewed state again"] = function()
  open_review()
  child.lua("require('didymus.review.provider.test').changes[1].files[2].viewed = 'viewed'")
  child.cmd("Didymus review refresh")
  wait_for_message("didymus: refreshed #1")
  eq(row_text(new_row), "A new.txt +1 -0 [viewed]")
end

T["a provider with no set_viewed shows a warning"] = function()
  child.lua([[
    local test = require("didymus.review.provider.test")
    require("didymus").setup({
      review = {
        picker = "test",
        provider = setmetatable({ set_viewed = false }, { __index = test }),
      },
    })
  ]])
  open_review()
  press("v", file_row)
  wait_for_message("didymus: the review provider cannot mark a file as viewed")
end

T["review.panel.keys.viewed sets the key, and false turns it off"] = function()
  setup({ panel = { keys = { viewed = "V" } } })
  open_review()
  press("V", file_row)
  wait_for_message("didymus: marked file.txt as viewed")

  child.cmd("Didymus review close")
  setup({ panel = { keys = { viewed = false } } })
  open_review()
  eq(
    child.lua_get(
      [[vim.tbl_map(function(action)
      return action.key
    end, require("didymus.ui.picker.test").calls[#require("didymus.ui.picker.test").calls].opts.actions)]]
    ),
    { "a", "R" }
  )
end

return T
