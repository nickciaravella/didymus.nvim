local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

---@param diff table? The `diff` options. The preload is off, because the tests count the calls of the
--- provider. tests/e2e/diff/preview.test.lua tests it.
local function setup(diff)
  child.lua(
    "require('didymus').setup({ review = { picker = 'test', provider = 'test' }, diff = ... })",
    { vim.tbl_extend("force", { provider = "test", preload = 0 }, diff or {}) }
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
      -- The stop of a.txt is base 2, head 2. The stop of c.txt is base 3, head 3. b.txt is deleted,
      -- so the diff view gives its hunks.
      child.lua([[
        require("didymus.diff.provider.test").hunks_by_path = {
          ["a.txt"] = { { kind = "change", base = { start = 2, count = 1 }, head = { start = 2, count = 1 } } },
          ["c.txt"] = { { kind = "change", base = { start = 3, count = 1 }, head = { start = 3, count = 1 } } },
        }
      ]])
    end,
    post_once = child.stop,
  },
})

--- Open a review where the change modifies a.txt and c.txt, and deletes b.txt.
local function open_review()
  local repo = helpers.make_repo({
    base = {
      ["a.txt"] = "a1\na2\na3\n",
      ["b.txt"] = "b1\nb2\nb3\n",
      ["c.txt"] = "c1\nc2\nc3\n",
    },
    head = {
      ["a.txt"] = "a1\nA2\na3\n",
      ["b.txt"] = false,
      ["c.txt"] = "c1\nc2\nC3\n",
    },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", {})
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

--- The index of the row of `path` in the panel.
---@param path string
---@return integer
local function find_row(path)
  for index, item in ipairs(helpers.picker_calls(child, "panel")[1].items) do
    if item.value.kind == "file" and item.value.file.path == path then
      return index
    end
  end
  error("no file " .. path .. " in the panel")
end

--- `<CR>` on a file in the panel.
---@param path string
local function choose_file(path)
  child.lua("require('didymus.ui.picker.test').choose(...)", { find_row(path) })
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

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return child.cmd_capture("messages"):find(text, 1, true) ~= nil
  end, function()
    return ("%q is not in the messages:\n%s"):format(text, child.cmd_capture("messages"))
  end)
end

--- The name of the buffer of `win`: "base:<path>" for a base buffer, "empty:<path>" for the empty
--- head buffer of a deleted file, else the path.
---@param win integer
---@return string
local function shown(win)
  local name = child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(win))
  local empty_path = name:match("^didymus://deleted/(.*)$")
  if empty_path then
    return "empty:" .. empty_path
  end
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

--- Open the review, and open a.txt with `<CR>`. Give the code window.
---@return integer code_win
local function open_a()
  open_review()
  choose_file("a.txt")
  return wait_for_render(1).head_win
end

T["<CR> on a deleted file shows its base buffer in the code window, with all lines deleted"] = function()
  local code_win = open_a()
  wait_for_position(code_win, "a.txt", 2)
  choose_file("b.txt")
  local render = wait_for_render(2)
  eq(render.path, "b.txt")
  eq(render.sides, "base")
  eq(render.head_win, nil)
  eq(render.head_buf, nil)
  eq(render.base_win, code_win)
  eq(render.base_buf, child.api.nvim_win_get_buf(code_win))
  eq(shown(code_win), "base:b.txt")
  eq(child.api.nvim_buf_get_lines(render.base_buf, 0, -1, true), { "b1", "b2", "b3" })
  eq(child.api.nvim_win_get_cursor(code_win)[1], 1)
  eq(child.api.nvim_get_current_win(), code_win)
  eq(marks(code_win), { "1 diff inline base" })
  -- The provider does not attach, because there is no head buffer.
  eq(
    vim.tbl_map(function(call)
      return call.path
    end, calls_of("attach")),
    { "a.txt" }
  )
  -- As for a head file, the old position goes into the jumplist.
  child.type_keys("<C-o>")
  wait_for_position(code_win, "a.txt", 2)
end

T["a newer <CR> wins over the open of a deleted file"] = function()
  local code_win = open_a()
  child.lua(
    [[
    local picker = require("didymus.ui.picker.test")
    local deleted, other = ...
    picker.choose(deleted)
    picker.choose(other)
  ]],
    { find_row("b.txt"), find_row("c.txt") }
  )
  wait_for_position(code_win, "c.txt", 3)
  child.lua("vim.wait(100, function() return false end)")
  eq(shown(code_win), "c.txt")
end

T["if the code window is closed, the base buffer opens in a new window on the right"] = function()
  local code_win = open_a()
  child.cmd("leftabove vnew")
  local left_win = child.api.nvim_get_current_win()
  child.api.nvim_win_close(code_win, true)
  choose_file("b.txt")
  local render = wait_for_render(2)
  eq(render.path, "b.txt")
  local new_win = render.base_win
  eq(child.api.nvim_tabpage_list_wins(0), { left_win, new_win })
  eq(child.api.nvim_get_current_win(), new_win)
  eq(shown(new_win), "base:b.txt")
end

--- The window on the left of `win` in the current tabpage, or nil.
---@param win integer
---@return integer?
local function find_left_win(win)
  local wins = child.api.nvim_tabpage_list_wins(0)
  for index, other in ipairs(wins) do
    if other == win then
      return wins[index - 1]
    end
  end
end

T["split"] = MiniTest.new_set()

T["split"]["a deleted file shows its base buffer on the left, and an empty head buffer on the right"] = function()
  setup({ layout = "split" })
  local code_win = open_a()
  choose_file("b.txt")
  local render = wait_for_render(2)
  local base_win = find_left_win(code_win)
  eq({ render.path, render.layout, render.sides }, { "b.txt", "split", "base" })
  eq({ render.head_win, render.head_buf, render.base_win }, { nil, nil, base_win })
  eq(child.api.nvim_tabpage_list_wins(0), { base_win, code_win })
  eq({ shown(base_win), shown(code_win) }, { "base:b.txt", "empty:b.txt" })
  eq(marks(base_win), { "1 diff split base" })
  eq(marks(code_win), {})
  local empty_buf = child.api.nvim_win_get_buf(code_win)
  eq(child.api.nvim_buf_get_lines(empty_buf, 0, -1, true), { "" })
  eq({
    child.api.nvim_get_option_value("modifiable", { buf = empty_buf }),
    child.api.nvim_get_option_value("buftype", { buf = empty_buf }),
  }, { false, "nofile" })
  -- The text is in the base window, so the focus goes there.
  eq(child.api.nvim_get_current_win(), base_win)
  eq(child.api.nvim_win_get_cursor(base_win)[1], 1)

  choose_file("c.txt")
  render = wait_for_render(3)
  eq({ render.path, render.layout, render.sides }, { "c.txt", "split", "both" })
  eq({ shown(base_win), shown(code_win) }, { "base:c.txt", "c.txt" })
  eq(child.api.nvim_get_current_win(), code_win)
end

T["split"]["next and prev stop in a deleted file at base line 1 of the base window"] = function()
  setup({ layout = "split" })
  local code_win = open_a()
  wait_for_position(code_win, "a.txt", 2)
  child.cmd("Didymus diff next")
  local base_win = find_left_win(code_win) --[[@as integer]]
  wait_for_position(base_win, "base:b.txt", 1)
  eq(shown(code_win), "empty:b.txt")
  eq(child.api.nvim_get_current_win(), base_win)
  child.api.nvim_win_set_cursor(base_win, { 3, 0 })
  child.cmd("Didymus diff prev")
  wait_for_position(base_win, "base:b.txt", 1)
  -- From the base window, the next stop is in the base window, as for a modified file.
  child.cmd("Didymus diff next")
  wait_for_position(base_win, "base:c.txt", 3)
  eq(shown(code_win), "c.txt")
  child.cmd("Didymus diff prev")
  wait_for_position(base_win, "base:b.txt", 1)
  eq(shown(code_win), "empty:b.txt")
end

T["split"]["a change of the layout or the sides moves the base buffer, and keeps the cursor line"] = function()
  setup({ layout = "split" })
  local code_win = open_a()
  choose_file("b.txt")
  wait_for_render(2)
  local base_win = find_left_win(code_win) --[[@as integer]]
  child.api.nvim_win_set_cursor(base_win, { 2, 0 })

  child.cmd("Didymus diff layout inline")
  local render = wait_for_render(3)
  eq({ render.layout, render.sides, render.base_win }, { "inline", "base", code_win })
  eq(child.api.nvim_tabpage_list_wins(0), { code_win })
  eq(shown(code_win), "base:b.txt")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(child.api.nvim_win_get_cursor(code_win)[1], 2)

  child.cmd("Didymus diff layout split")
  render = wait_for_render(4)
  base_win = find_left_win(code_win) --[[@as integer]]
  eq({ render.layout, render.base_win }, { "split", base_win })
  eq({ shown(base_win), shown(code_win) }, { "base:b.txt", "empty:b.txt" })
  eq(child.api.nvim_get_current_win(), base_win)
  eq(child.api.nvim_win_get_cursor(base_win)[1], 2)

  -- The head sides show one window, as for a modified file.
  child.cmd("Didymus diff side head")
  wait_for_message("didymus: b.txt is deleted, so only its base side shows")
  eq(child.api.nvim_tabpage_list_wins(0), { code_win })
  eq(shown(code_win), "base:b.txt")
  child.cmd("Didymus diff side both")
  wait_for_render(6)
  eq(#child.api.nvim_tabpage_list_wins(0), 2)
end

T["split"]["a close of the base window shows the base buffer in the code window, with the inline layout"] = function()
  setup({ layout = "split" })
  local code_win = open_a()
  choose_file("b.txt")
  wait_for_render(2)
  child.api.nvim_win_close(find_left_win(code_win), false)
  wait_for_message("didymus: the base window closed, so the diff layout is inline")
  local render = wait_for_render(3)
  eq({ render.layout, render.base_win }, { "inline", code_win })
  eq(shown(code_win), "base:b.txt")
end

T["split"]["a hide shows the base buffer in the code window, and deletes the empty head buffer"] = function()
  setup({ layout = "split" })
  local code_win = open_a()
  choose_file("b.txt")
  wait_for_render(2)
  local empty_buf = child.api.nvim_win_get_buf(code_win)
  child.cmd("Didymus diff toggle")
  eq(child.api.nvim_tabpage_list_wins(0), { code_win })
  eq(shown(code_win), "base:b.txt")
  eq(marks(code_win), {})
  eq(child.api.nvim_buf_is_valid(empty_buf), false)
  eq(child.api.nvim_get_current_win(), code_win)

  child.cmd("Didymus diff toggle")
  local base_win = find_left_win(code_win) --[[@as integer]]
  eq(wait_for_render(3).base_win, base_win)
  eq({ shown(base_win), shown(code_win) }, { "base:b.txt", "empty:b.txt" })
end

T["next and prev stop in a deleted file at base line 1"] = function()
  local code_win = open_a()
  wait_for_position(code_win, "a.txt", 2)
  child.cmd("clearjumps")
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:b.txt", 1)
  eq(wait_for_render(2).sides, "base")
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "c.txt", 3)
  eq(wait_for_render(3).sides, "both")
  child.cmd("Didymus diff prev")
  wait_for_position(code_win, "base:b.txt", 1)
  child.api.nvim_win_set_cursor(code_win, { 3, 0 })
  -- In the hunk, prev goes to the stop of the hunk.
  child.cmd("Didymus diff prev")
  wait_for_position(code_win, "base:b.txt", 1)
  child.cmd("Didymus diff prev")
  wait_for_position(code_win, "a.txt", 2)
  child.type_keys("<C-o>")
  wait_for_position(code_win, "base:b.txt", 1)
end

T["with the base sides, next goes through the deleted file and keeps the base sides"] = function()
  local code_win = open_a()
  child.cmd("Didymus diff side base")
  wait_for_position(code_win, "base:a.txt", 2)
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:b.txt", 1)
  child.cmd("Didymus diff next")
  wait_for_position(code_win, "base:c.txt", 3)
  local renders = calls_of("render")
  eq(renders[#renders].sides, "base")
end

T["side on a deleted file keeps its base buffer, and applies to the next file"] = function()
  local code_win = open_a()
  choose_file("b.txt")
  wait_for_render(2)
  child.cmd("Didymus diff side head")
  wait_for_message("didymus: b.txt is deleted, so only its base side shows")
  eq(shown(code_win), "base:b.txt")
  choose_file("c.txt")
  eq(wait_for_render(3).sides, "head")

  -- The base sides are temporary, as on a head file.
  choose_file("b.txt")
  wait_for_render(4)
  child.cmd("Didymus diff side base")
  eq(shown(code_win), "base:b.txt")
  choose_file("c.txt")
  eq(wait_for_render(5).sides, "head")
end

T["a hide keeps the base buffer of a deleted file in the code window, with no marks"] = function()
  local code_win = open_a()
  choose_file("b.txt")
  local base_buf = wait_for_render(2).base_buf
  child.cmd("Didymus diff toggle")
  eq(shown(code_win), "base:b.txt")
  eq(marks(code_win), {})
  child.cmd("Didymus diff toggle")
  local render = wait_for_render(3)
  eq({ render.path, render.base_buf }, { "b.txt", base_buf })
  eq(marks(code_win), { "1 diff inline base" })

  -- With no diff, the buffer goes when the code window shows a different buffer.
  child.cmd("Didymus diff toggle")
  choose_file("a.txt")
  eq(shown(code_win), "a.txt")
  eq(child.api.nvim_buf_is_valid(base_buf), false)
  choose_file("b.txt")
  wait_for_message("didymus: b.txt is deleted in #1")
  eq(shown(code_win), "a.txt")
end

return T
