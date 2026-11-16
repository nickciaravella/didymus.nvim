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
      child.o.columns, child.o.lines = 120, 40
      child.cmd("runtime plugin/didymus.lua")
      setup()
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
      -- The stops of a.txt are base 2 and 6, head 4 and 8. The stop of c.txt is base 3, head 1.
      child.lua([[
        require("didymus.diff.provider.test").hunks_by_path = {
          ["a.txt"] = {
            { kind = "change", base = { start = 2, count = 1 }, head = { start = 4, count = 1 } },
            { kind = "change", base = { start = 6, count = 1 }, head = { start = 8, count = 1 } },
          },
          ["b.txt"] = { { kind = "add", base = { start = 0, count = 0 }, head = { start = 1, count = 1 } } },
          ["c.txt"] = { { kind = "change", base = { start = 3, count = 1 }, head = { start = 1, count = 1 } } },
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

--- Open a review where the change modifies a.txt and c.txt, and adds b.txt. other.txt is not in
--- the change.
---@param threads didymus.review.Thread[]?
local function open_review(threads)
  local repo = helpers.make_repo({
    base = {
      ["a.txt"] = make_text("a", 7),
      ["c.txt"] = make_text("c", 5),
      ["other.txt"] = "other\n",
    },
    head = {
      ["a.txt"] = make_text("A", 9),
      ["b.txt"] = "b\n",
      ["c.txt"] = make_text("C", 5),
    },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", threads or {})
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
end

---@return table[]
local function calls_of(method)
  return child.lua(
    [[
    local method = ...
    return vim.tbl_filter(function(call)
      return call.method == method
    end, require("didymus.diff.provider.test").calls)
  ]],
    { method }
  )
end

--- Wait for `count` renders, and give the last one.
---@param count integer
---@return table render
local function wait_for_render(count)
  wait_for(function()
    return #calls_of("render") >= count
  end, function()
    return ("render %d: %s"):format(count, vim.inspect(calls_of("render")))
  end)
  return calls_of("render")[count]
end

--- Open a file of the change with `<CR>` in the panel.
---@param path string
local function choose_file(path)
  for index, item in ipairs(helpers.picker_calls(child, "panel")[1].items) do
    if item.value.kind == "file" and item.value.file.path == path then
      child.lua("require('didymus.ui.picker.test').choose(...)", { index })
      return
    end
  end
  error("no file " .. path .. " in the panel")
end

--- The text of the diff marks in `win`.
---@param win integer
---@return string[]
local function marks(win)
  return child.lua(
    [[
    return (function(win)
      local ns = vim.api.nvim_get_namespaces()["didymus.diff.test." .. win]
      if not ns then
        return {}
      end
      return vim.tbl_map(function(mark)
        return (mark[2] + 1) .. " " .. mark[4].virt_text[1][1]
      end, vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, { details = true }))
    end)(...)
  ]],
    { win }
  )
end

---@return integer[]
local function tab_wins()
  return child.api.nvim_tabpage_list_wins(0)
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

--- The name of the buffer of `win`: "base:<path>" for a base buffer, else the path.
---@param win integer
---@return string
local function shown(win)
  local name = child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(win))
  local base_path = name:match("^didymus://%x+/(.*)$")
  if base_path then
    return "base:" .. base_path
  end
  return child.fn.fnamemodify(name, ":.")
end

--- Wait until `win` shows `name` (see `shown()`) with the cursor at `line`.
---@param win integer
---@param name string
---@param line integer
local function wait_for_position(win, name, line)
  wait_for(function()
    return shown(win) == name and child.api.nvim_win_get_cursor(win)[1] == line
  end, function()
    return ("%s:%d, not %s:%d"):format(
      name,
      line,
      shown(win),
      child.api.nvim_win_get_cursor(win)[1]
    )
  end)
end

--- Open a.txt at `line`, and wait for the render.
---@param line integer?
---@return integer code_win
local function open_a(line)
  open_review()
  choose_file("a.txt")
  local code_win = wait_for_render(1).head_win
  child.api.nvim_win_set_cursor(code_win, { line or 1, 0 })
  return code_win
end

--- The jumplist of the current window, as "name:line", with the names of `shown()`.
---@return string[]
local function jumps()
  return child.lua_get([[
    vim.tbl_map(function(jump)
      local name = vim.fn.bufname(jump.bufnr)
      local base_path = name:match("^didymus://%x+/(.*)$")
      return (base_path and "base:" .. base_path or vim.fn.fnamemodify(name, ":.")) .. ":" .. jump.lnum
    end, vim.fn.getjumplist()[1])
  ]])
end

T["side base shows the base buffer in the code window, with the base marks"] = function()
  local code_win = open_a(4)
  local head_buf = child.api.nvim_win_get_buf(code_win)
  child.cmd("Didymus diff side base")
  local render = wait_for_render(2)
  eq(render.sides, "base")
  eq(render.head_win, nil)
  eq(render.head_buf, head_buf)
  eq(render.base_win, code_win)
  eq(render.base_buf, child.api.nvim_win_get_buf(code_win))
  eq(shown(code_win), "base:a.txt")
  eq(child.api.nvim_buf_get_lines(render.base_buf, 0, -1, true)[1], "a1")
  eq(marks(code_win), { "2 diff inline base", "6 diff inline base" })
  -- Head line 4 is in the hunk of base line 2.
  eq(child.api.nvim_win_get_cursor(code_win)[1], 2)
  -- The head buffer stays loaded, so it keeps its hunks.
  eq(child.api.nvim_buf_is_loaded(head_buf), true)
end

T["a change of the sides puts the cursor at the matching line of the other side"] = function()
  local code_win = open_a(8)
  child.cmd("Didymus diff side base")
  wait_for_position(code_win, "base:a.txt", 6)
  child.api.nvim_win_set_cursor(code_win, { 2, 0 })
  child.cmd("Didymus diff side head")
  wait_for_position(code_win, "a.txt", 4)
  eq(wait_for_render(3).sides, "head")
end

T["each sides value in each layout"] = function()
  local code_win = open_a()
  for _, layout in ipairs({ "inline", "split" }) do
    child.cmd("Didymus diff layout " .. layout)
    settle()
    for _, sides in ipairs({ "head", "base", "both" }) do
      local count = #calls_of("render")
      child.cmd("Didymus diff side " .. sides)
      local render = wait_for_render(count + 1)
      eq({ render.layout, render.sides }, { layout, sides })
      local split = layout == "split" and sides == "both"
      eq(#tab_wins(), split and 2 or 1)
      eq(shown(code_win), sides == "base" and "base:a.txt" or "a.txt")
      local text = ("diff %s %s"):format(layout, sides)
      if sides == "base" then
        eq(marks(code_win), { "2 " .. text, "6 " .. text })
      else
        eq(marks(code_win), { "4 " .. text, "8 " .. text })
      end
      if split then
        eq(marks(render.base_win), { "2 " .. text, "6 " .. text })
      end
    end
  end
end

T["side with no argument goes to the next sides"] = function()
  local code_win = open_a()
  for index, sides in ipairs({ "head", "base", "both" }) do
    child.cmd("Didymus diff side")
    eq(wait_for_render(index + 1).sides, sides)
  end
  eq(shown(code_win), "a.txt")
end

T["next and prev with the base sides use the base lines, also in the next file"] = function()
  local code_win = open_a()
  child.cmd("Didymus diff side base")
  wait_for_position(code_win, "base:a.txt", 1)
  child.cmd("clearjumps")
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:a.txt", 2)
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:a.txt", 6)
  -- The base stop of the added b.txt is line 1 of its empty base buffer.
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:b.txt", 1)
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:c.txt", 3)
  eq(child.api.nvim_get_current_win(), code_win)
  local render = calls_of("render")[#calls_of("render")]
  eq({ render.sides, render.path }, { "base", "c.txt" })
  eq(marks(code_win), { "3 diff inline base" })

  child.cmd("Didymus diff prev")
  wait_for_position(code_win, "base:b.txt", 1)
  child.cmd("Didymus diff prev")
  wait_for_position(code_win, "base:a.txt", 6)
  -- Neovim removes the old entry of a position that it adds again.
  eq(jumps(), { "base:a.txt:1", "base:a.txt:2", "base:a.txt:6", "base:c.txt:3", "base:b.txt:1" })

  -- A base buffer of a file of the change keeps the base sides.
  child.type_keys("<C-o>")
  wait_for_position(code_win, "base:b.txt", 1)
  settle()
  eq(calls_of("render")[#calls_of("render")].sides, "base")
end

T["next with the base sides at the last stop shows a message, and keeps the base sides"] = function()
  local code_win = open_a()
  child.cmd("edit c.txt")
  wait_for_render(2)
  child.cmd("Didymus diff side base")
  -- Head line 1 is in the hunk of base line 3.
  wait_for_position(code_win, "base:c.txt", 3)
  child.api.nvim_win_set_cursor(code_win, { 4, 0 })
  child.cmd("Didymus diff next")
  wait_for_message("didymus: no next hunk")
  settle()
  eq(shown(code_win), "base:c.txt")
  eq(child.api.nvim_win_get_cursor(code_win)[1], 4)
end

T["<CR> in the panel ends the base sides, and the sides go back to the value before"] = function()
  local code_win = open_a()
  child.cmd("Didymus diff side head")
  wait_for_render(2)
  child.cmd("Didymus diff side base")
  wait_for_render(3)
  choose_file("c.txt")
  local render = wait_for_render(4)
  eq({ render.sides, render.path, render.head_win }, { "head", "c.txt", code_win })
  eq(shown(code_win), "c.txt")
end

T["a file that is not in the change ends the base sides"] = function()
  local code_win = open_a()
  child.cmd("Didymus diff side base")
  wait_for_render(2)
  child.cmd("edit other.txt")
  settle()
  child.cmd("edit a.txt")
  eq(wait_for_render(3).sides, "both")
  eq(shown(code_win), "a.txt")
end

T["review comment on a base buffer shows a warning"] = function()
  open_a()
  child.cmd("Didymus diff side base")
  wait_for_render(2)
  child.cmd("Didymus review comment")
  wait_for_message(
    "didymus: the current window shows the base of a.txt. A comment needs the head side."
  )
end

T["the threads do not show on the base buffer"] = function()
  open_review({
    helpers.make_thread("open", "a.txt", { range = { first = 2, last = 2 } }),
  })
  choose_file("a.txt")
  local code_win = wait_for_render(1).head_win
  helpers.wait_for_threads(child, 1)
  eq(#helpers.thread_marks(child), 1)
  child.cmd("Didymus diff side base")
  wait_for_position(code_win, "base:a.txt", 1)
  eq(helpers.thread_marks(child), {})
end

T["toggle with the base sides shows the head buffer, and deletes the base buffer"] = function()
  local code_win = open_a(8)
  child.cmd("Didymus diff side base")
  local base_buf = wait_for_render(2).base_buf
  child.cmd("Didymus diff toggle")
  eq(shown(code_win), "a.txt")
  eq(child.api.nvim_win_get_cursor(code_win)[1], 8)
  eq(child.api.nvim_buf_is_valid(base_buf), false)
  child.cmd("Didymus diff toggle")
  eq(wait_for_render(3).sides, "both")
end

T["the base sides keep the head buffer loaded with 'nohidden'"] = function()
  child.o.hidden = false
  local code_win = open_a()
  local head_buf = child.api.nvim_win_get_buf(code_win)
  child.cmd("Didymus diff side base")
  eq(wait_for_render(2).sides, "base")
  eq(child.api.nvim_buf_is_loaded(head_buf), true)
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:a.txt", 2)
end

T["side of a hidden diff shows the diff"] = function()
  setup({ enabled = false })
  open_review()
  choose_file("a.txt")
  child.cmd("Didymus diff side head")
  eq(wait_for_render(1).sides, "head")
end

T["diff.sides sets the sides when the review opens"] = function()
  setup({ sides = "head" })
  open_review()
  choose_file("a.txt")
  eq(wait_for_render(1).sides, "head")
end

T['diff.sides = "base" shows a warning, and the diff shows both sides'] = function()
  setup({ sides = "base" })
  open_review()
  wait_for_message(
    'didymus: diff.sides is "base". Use "both" or "head". The diff shows both sides.'
  )
  choose_file("a.txt")
  eq(wait_for_render(1).sides, "both")
end

T["side base with no file of the change in the code window shows a warning"] = function()
  open_review()
  child.cmd("edit other.txt")
  child.cmd("Didymus diff side base")
  wait_for_message("didymus: the code window does not show a file of the diff")
  settle()
  eq(#calls_of("render"), 0)
end

T["sides that the provider does not have show a warning"] = function()
  child.lua("require('didymus.diff.provider.test').capabilities.sides.base = false")
  local code_win = open_a()
  child.cmd("Didymus diff side base")
  wait_for_message("didymus: the diff provider does not have the base sides")
  settle()
  eq(#calls_of("render"), 1)
  eq(shown(code_win), "a.txt")
end

T["the <Plug> mappings set the sides"] = function()
  open_a()
  child.lua([[
    vim.keymap.set("n", "<F2>", "<Plug>(didymus-diff-side-head)")
    vim.keymap.set("n", "<F3>", "<Plug>(didymus-diff-side-base)")
    vim.keymap.set("n", "<F4>", "<Plug>(didymus-diff-side-both)")
    vim.keymap.set("n", "<F5>", "<Plug>(didymus-diff-side)")
  ]])
  child.type_keys("<F2>")
  eq(wait_for_render(2).sides, "head")
  child.type_keys("<F3>")
  eq(wait_for_render(3).sides, "base")
  child.type_keys("<F4>")
  eq(wait_for_render(4).sides, "both")
  child.type_keys("<F5>")
  eq(wait_for_render(5).sides, "head")
end

T["an unknown side shows an error"] = function()
  open_review()
  -- An error message in a command is an error of `child.cmd()`.
  child.lua("require('didymus.command').run('diff side left')")
  wait_for_message('didymus: unknown side "left". Use both, base or head.')
end

T[":Didymus diff side completes the sides"] = function()
  eq(child.fn.getcompletion("Didymus diff side ", "cmdline"), { "base", "both", "head" })
end

return T
