local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua(
        "require('didymus').setup({ review = { picker = 'test', provider = 'test' }, diff = { provider = 'test' } })"
      )
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
      -- The stops are a.txt:2, a.txt:5, c.txt:3 (after a deletion) and c.txt:5. b.txt has no hunks.
      child.lua([[
        require("didymus.diff.provider.test").hunks_by_path = {
          ["a.txt"] = {
            { kind = "add", base = { start = 4, count = 0 }, head = { start = 5, count = 2 } },
            { kind = "change", base = { start = 2, count = 1 }, head = { start = 2, count = 1 } },
          },
          ["c.txt"] = {
            { kind = "delete", base = { start = 3, count = 1 }, head = { start = 2, count = 0 } },
            { kind = "change", base = { start = 6, count = 1 }, head = { start = 5, count = 1 } },
          },
        }
      ]])
    end,
    post_once = child.stop,
  },
})

--- The text of a file with `count` lines, such as "a1\na2\n".
---@param prefix string
---@param count integer
---@return string
local function make_text(prefix, count)
  local lines = {}
  for line = 1, count do
    table.insert(lines, prefix .. line)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Open a review where the change modifies a.txt, b.txt and c.txt, and deletes d.txt. other.txt is
--- not in the change.
local function open_review()
  local repo = helpers.make_repo({
    base = {
      ["a.txt"] = make_text("a", 7),
      ["b.txt"] = make_text("b", 3),
      ["c.txt"] = make_text("c", 7),
      ["d.txt"] = make_text("d", 2),
      ["other.txt"] = make_text("o", 2),
    },
    head = {
      ["a.txt"] = make_text("A", 8),
      ["b.txt"] = make_text("B", 3),
      ["c.txt"] = make_text("C", 6),
      ["d.txt"] = false,
    },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", {})
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
end

--- The path and the cursor line of the current window.
---@return [string, integer]
local function position()
  return { child.fn.expand("%:."), child.api.nvim_win_get_cursor(0)[1] }
end

---@param expected [string, integer]
local function wait_for_position(expected)
  wait_for(function()
    return vim.deep_equal(position(), expected)
  end, function()
    return ("position %s, not %s"):format(vim.inspect(position()), vim.inspect(expected))
  end)
end

--- Choose the file in the panel, and put the cursor on `line`.
---@param path string
---@param line integer
local function open_file(path, line)
  for index, item in ipairs(helpers.picker_calls(child, "panel")[1].items) do
    if item.value.kind == "file" and item.value.file.path == path then
      child.lua("require('didymus.ui.picker.test').choose(...)", { index })
      child.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
  error("no file " .. path .. " in the panel")
end

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return child.cmd_capture("messages"):find(text, 1, true) ~= nil
  end, function()
    return ("%q is not in the messages:\n%s"):format(text, child.cmd_capture("messages"))
  end)
end

--- Let the scheduled callbacks run.
local function settle()
  child.lua("vim.wait(50, function() return false end)")
end

--- The jumplist of the current window, as "path:line".
---@return string[]
local function jumps()
  return child.lua_get([[
    vim.tbl_map(function(jump)
      return vim.fn.fnamemodify(vim.fn.bufname(jump.bufnr), ":.") .. ":" .. jump.lnum
    end, vim.fn.getjumplist()[1])
  ]])
end

--- The paths of the `attach()` calls of the diff provider.
---@return string[]
local function attached_paths()
  return child.lua_get([[
    vim.tbl_map(function(call)
      return call.path
    end, vim.tbl_filter(function(call)
      return call.method == "attach"
    end, require("didymus.diff.provider.test").calls))
  ]])
end

T["next goes to the next hunk in the same file, then to the first hunk of the next file"] = function()
  open_review()
  open_file("a.txt", 1)
  child.cmd("Didymus diff next")
  wait_for_position({ "a.txt", 2 })
  child.cmd("Didymus diff next")
  wait_for_position({ "a.txt", 5 })
  -- b.txt has no hunks.
  child.cmd("Didymus diff next")
  wait_for_position({ "c.txt", 3 })
  child.cmd("Didymus diff next")
  wait_for_position({ "c.txt", 5 })
end

T["prev goes to the last hunk of the previous file"] = function()
  open_review()
  open_file("c.txt", 3)
  child.cmd("Didymus diff prev")
  wait_for_position({ "a.txt", 5 })
  -- In a hunk, prev goes to the stop of the hunk.
  child.api.nvim_win_set_cursor(0, { 6, 0 })
  child.cmd("Didymus diff prev")
  wait_for_position({ "a.txt", 5 })
end

T["a deletion stops at the line after the deleted lines"] = function()
  open_review()
  open_file("c.txt", 1)
  child.cmd("Didymus diff next")
  wait_for_position({ "c.txt", 3 })
end

T["the jumplist gets only the start position, also when the jump checks a file with no hunks"] = function()
  open_review()
  open_file("a.txt", 5)
  child.cmd("clearjumps")
  child.cmd("Didymus diff next")
  wait_for_position({ "c.txt", 3 })
  eq(attached_paths(), { "a.txt", "b.txt", "c.txt" })
  eq(jumps(), { "a.txt:5" })
  eq(child.fn.expand("#:."), "a.txt")

  child.cmd("Didymus diff next")
  wait_for_position({ "c.txt", 5 })
  child.type_keys("<C-o>")
  eq(position(), { "c.txt", 3 })
  child.type_keys("<C-o>")
  eq(position(), { "a.txt", 5 })
end

T["at the last hunk, next shows a message and does not move"] = function()
  open_review()
  open_file("c.txt", 5)
  child.cmd("clearjumps")
  -- d.txt is deleted, so it has no hunks.
  child.cmd("Didymus diff next")
  wait_for_message("didymus: no next hunk")
  eq(position(), { "c.txt", 5 })
  eq(jumps(), {})
end

T["at the first hunk, prev shows a message and does not move"] = function()
  open_review()
  open_file("a.txt", 2)
  child.cmd("Didymus diff prev")
  wait_for_message("didymus: no previous hunk")
  eq(position(), { "a.txt", 2 })
end

T["with no file with hunks after the cursor, next goes back to the start"] = function()
  child.lua("require('didymus.diff.provider.test').hunks_by_path['c.txt'] = nil")
  open_review()
  open_file("a.txt", 5)
  child.cmd("clearjumps")
  child.cmd("Didymus diff next")
  wait_for_message("didymus: no next hunk")
  eq(position(), { "a.txt", 5 })
  eq(attached_paths(), { "a.txt", "b.txt", "c.txt" })
  eq(jumps(), {})
end

T["from a file that is not in the change, next and prev go to the first and the last hunk"] = function()
  open_review()
  open_file("b.txt", 1)
  child.cmd("edit other.txt")
  child.cmd("Didymus diff next")
  wait_for_position({ "a.txt", 2 })
  child.cmd("edit other.txt")
  child.cmd("Didymus diff prev")
  wait_for_position({ "c.txt", 5 })
end

T["next from a split moves the cursor in the code window"] = function()
  open_review()
  open_file("a.txt", 1)
  local code_win = child.api.nvim_get_current_win()
  child.cmd("split")
  child.cmd("Didymus diff next")
  wait_for_position({ "a.txt", 2 })
  eq(child.api.nvim_get_current_win(), code_win)
end

T["next waits for a slow attach"] = function()
  child.lua("require('didymus.diff.provider.test').delays = { ['c.txt'] = 300 }")
  open_review()
  open_file("a.txt", 5)
  child.cmd("Didymus diff next")
  settle()
  eq(position(), { "c.txt", 1 })
  wait_for_position({ "c.txt", 3 })
end

T["a jump stops if the code window shows a different file during the wait"] = function()
  child.lua("require('didymus.diff.provider.test').delays = { ['c.txt'] = 200 }")
  open_review()
  open_file("a.txt", 5)
  child.cmd("Didymus diff next")
  settle()
  child.cmd("edit other.txt")
  child.lua("vim.wait(300, function() return false end)")
  eq(position(), { "other.txt", 1 })
end

T["an attach error stops at the file, and shows each time"] = function()
  child.lua([[
    local provider = require("didymus.diff.provider.test")
    local attach = provider.attach
    provider.attach = function(self, buf, file, target, cb)
      if file.path ~= "b.txt" then
        return attach(self, buf, file, target, cb)
      end
      vim.schedule(function()
        cb("no tool")
      end)
    end
  ]])
  open_review()
  open_file("a.txt", 5)
  child.cmd("clearjumps")
  child.cmd("Didymus diff next")
  wait_for_message("didymus: cannot show the diff of b.txt: no tool")
  eq(position(), { "b.txt", 1 })
  eq(jumps(), { "a.txt:5" })

  child.cmd("messages clear")
  child.cmd("Didymus diff next")
  wait_for_message("didymus: cannot show the diff of b.txt: no tool")
  eq(position(), { "b.txt", 1 })
end

T["a hidden diff shows a message"] = function()
  open_review()
  open_file("a.txt", 1)
  child.cmd("Didymus diff toggle")
  child.cmd("Didymus diff next")
  wait_for_message("didymus: the diff is hidden")
  eq(position(), { "a.txt", 1 })
end

T["next from a different tabpage goes to the review tabpage"] = function()
  open_review()
  open_file("a.txt", 1)
  child.cmd("tabnew")
  child.cmd("Didymus diff next")
  wait_for_position({ "a.txt", 2 })
end

T[":Didymus diff completes its actions"] = function()
  eq(
    child.fn.getcompletion("Didymus diff ", "cmdline"),
    { "layout", "next", "prev", "side", "toggle" }
  )
end

T["next with no review shows a message"] = function()
  child.cmd("Didymus diff next")
  wait_for_message("didymus: no review is open")
end

T["<Plug>(didymus-diff-next) and <Plug>(didymus-diff-prev) go to the hunks"] = function()
  open_review()
  open_file("a.txt", 1)
  child.lua([[
    vim.keymap.set("n", "<F2>", "<Plug>(didymus-diff-next)")
    vim.keymap.set("n", "<F3>", "<Plug>(didymus-diff-prev)")
  ]])
  child.type_keys("<F2>")
  wait_for_position({ "a.txt", 2 })
  child.type_keys("<F2>")
  wait_for_position({ "a.txt", 5 })
  child.type_keys("<F3>")
  wait_for_position({ "a.txt", 2 })
end

return T
