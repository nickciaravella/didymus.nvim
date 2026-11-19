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
---@param edit fun(change: didymus.review.Change)? Change the change before the review opens.
local function open_review(edit)
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
  if edit then
    edit(repo.change)
  end
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

--- Wait for a render of `path` in `layout`, after `count` renders.
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

---@param win integer
---@return string[]
local function win_lines(win)
  return child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, true)
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

--- Open a.txt, change to the split layout, and wait for the render.
---@return integer code_win
---@return integer base_win
local function open_split()
  open_review()
  choose_file("a.txt")
  wait_for_render(1)
  child.cmd("Didymus diff layout split")
  local render = wait_for_render(2)
  return render.head_win, render.base_win
end

T["layout split opens the base window with the base text, and layout inline closes it"] = function()
  local code_win, base_win = open_split()
  local render = calls_of("render")[2]
  eq(render.layout, "split")
  eq(render.sides, "both")
  eq(render.path, "a.txt")
  eq(code_win, child.api.nvim_get_current_win())
  eq(render.base_buf, child.api.nvim_win_get_buf(base_win))
  eq(win_lines(base_win), vim.split(make_text("a", 7), "\n", { trimempty = true }))

  -- On the left of the code window, with half of its width.
  eq(child.fn.win_id2win(base_win) + 1, child.fn.win_id2win(code_win))
  eq(child.api.nvim_win_get_width(base_win), 60)
  local base_buf = render.base_buf
  local function get_option(name)
    return child.api.nvim_get_option_value(name, { buf = base_buf })
  end
  eq(get_option("buftype"), "nofile")
  eq(get_option("modifiable"), false)
  eq(get_option("filetype"), "text")
  eq(child.api.nvim_buf_get_name(base_buf):match("^didymus://%x+/a%.txt$") ~= nil, true)

  eq(marks(code_win), { "4 diff split both", "8 diff split both" })
  eq(marks(base_win), { "2 diff split both", "6 diff split both" })

  child.cmd("Didymus diff layout inline")
  local inline = wait_for_render(3)
  eq(inline.layout, "inline")
  eq(inline.base_win, nil)
  eq(child.api.nvim_win_is_valid(base_win), false)
  eq(marks(code_win), { "4 diff inline both", "8 diff inline both" })
end

T["layout with no argument changes to the other layout"] = function()
  open_review()
  choose_file("a.txt")
  wait_for_render(1)
  child.cmd("Didymus diff layout")
  eq(wait_for_render(2).layout, "split")
  child.cmd("Didymus diff layout")
  eq(wait_for_render(3).layout, "inline")
end

T["diff.layout and diff.split.width set the layout when the review opens"] = function()
  setup({ layout = "split", split = { width = 30 } })
  open_review()
  choose_file("a.txt")
  local render = wait_for_render(1)
  eq(render.layout, "split")
  eq(child.api.nvim_win_get_width(render.base_win), 30)
end

T["the base window follows the code window"] = function()
  local code_win, base_win = open_split()
  child.cmd("edit c.txt")
  local render = wait_for_render(3)
  eq(render.path, "c.txt")
  eq(render.base_win, base_win)
  eq(win_lines(base_win), vim.split(make_text("c", 5), "\n", { trimempty = true }))
  eq(marks(base_win), { "3 diff split both" })
  eq(marks(code_win), { "1 diff split both" })

  -- An added file has an empty base buffer.
  choose_file("b.txt")
  eq(wait_for_render(4).path, "b.txt")
  eq(win_lines(base_win), { "" })
  eq(child.api.nvim_get_current_win(), code_win)
end

T["a file that is not in the change closes the base window, and the next file opens it"] = function()
  local _, base_win = open_split()
  child.cmd("edit other.txt")
  settle()
  eq(child.api.nvim_win_is_valid(base_win), false)
  eq(#tab_wins(), 1)

  child.cmd("edit c.txt")
  local render = wait_for_render(3)
  eq(render.layout, "split")
  eq(win_lines(render.base_win), vim.split(make_text("c", 5), "\n", { trimempty = true }))
  eq(#tab_wins(), 2)
end

T["a close of the base window changes to the inline layout"] = function()
  local code_win, base_win = open_split()
  child.api.nvim_win_close(base_win, false)
  wait_for_message("didymus: the base window closed, so the diff layout is inline")
  eq(wait_for_render(3).layout, "inline")
  eq(marks(code_win), { "4 diff inline both", "8 diff inline both" })

  -- The session keeps the layout.
  child.cmd("Didymus diff toggle")
  child.cmd("Didymus diff toggle")
  eq(wait_for_render(4).layout, "inline")
end

T["a different buffer in the base window changes to the inline layout"] = function()
  local code_win, base_win = open_split()
  child.api.nvim_set_current_win(base_win)
  child.cmd("edit other.txt")
  wait_for_message(
    "didymus: the base window shows a different buffer, so the diff layout is inline"
  )
  eq(wait_for_render(3).layout, "inline")
  -- The window stays, because it is a window of the user now.
  eq(child.api.nvim_win_is_valid(base_win), true)
  eq(marks(base_win), {})
  eq(marks(code_win), { "4 diff inline both", "8 diff inline both" })
end

T["a renamed file shows the text of its base path"] = function()
  setup({ layout = "split" })
  open_review(function(change)
    for _, file in ipairs(change.files) do
      if file.path == "b.txt" then
        file.status, file.old_path = "renamed", "other.txt"
      end
    end
  end)
  choose_file("b.txt")
  local render = wait_for_render(1)
  eq(win_lines(render.base_win), { "other" })
  eq(child.api.nvim_buf_get_name(render.base_buf):match("/other%.txt$") ~= nil, true)
end

T["an error of git show shows a warning, and closes the base window"] = function()
  open_review(function(change)
    for _, file in ipairs(change.files) do
      if file.path == "b.txt" then
        file.status, file.old_path = "renamed", "missing.txt"
      end
    end
  end)
  choose_file("a.txt")
  wait_for_render(1)
  child.cmd("Didymus diff layout split")
  wait_for_render(2)
  choose_file("b.txt")
  wait_for_message("didymus: cannot show the diff of b.txt: git show failed: fatal:")
  eq(#tab_wins(), 1)
end

T["toggle closes the base window and deletes the base buffers, and keeps the layout"] = function()
  local _, base_win = open_split()
  local base_buf = calls_of("render")[2].base_buf
  child.cmd("Didymus diff toggle")
  eq(child.api.nvim_win_is_valid(base_win), false)
  eq(child.api.nvim_buf_is_valid(base_buf), false)

  child.cmd("Didymus diff toggle")
  eq(wait_for_render(3).layout, "split")
end

T["layout of a hidden diff shows the diff"] = function()
  setup({ enabled = false })
  open_review()
  choose_file("a.txt")
  child.cmd("Didymus diff layout split")
  eq(wait_for_render(1).layout, "split")
end

for _, close in ipairs({ "Didymus review close", "tabclose" }) do
  T[(":%s closes the base window with no message"):format(close)] = function()
    open_split()
    child.cmd(close)
    settle()
    eq(#child.api.nvim_list_tabpages(), 1)
    eq(child.cmd_capture("messages"):find("base window", 1, true), nil)
  end
end

T["next in the base window moves the cursor in the base window, with the base lines"] = function()
  local code_win, base_win = open_split()
  child.api.nvim_win_set_cursor(code_win, { 1, 0 })
  child.api.nvim_set_current_win(base_win)
  child.api.nvim_win_set_cursor(base_win, { 1, 0 })

  child.cmd("Didymus diff next")
  eq(child.api.nvim_get_current_win(), base_win)
  eq(child.api.nvim_win_get_cursor(base_win)[1], 2)
  eq(child.api.nvim_win_get_cursor(code_win)[1], 1)
  child.cmd("Didymus diff next")
  eq(child.api.nvim_win_get_cursor(base_win)[1], 6)

  -- The next file: the code window goes to the head stop, and the base window to the base stop.
  -- The base stop of the added b.txt is line 1 of its empty base buffer.
  ---@param path string
  ---@param base_line integer
  ---@param code_line integer
  local function wait_for_stop(path, base_line, code_line)
    wait_for(function()
      local code_buf = child.api.nvim_win_get_buf(code_win)
      return child.api.nvim_get_current_win() == base_win
        and child.fn.fnamemodify(child.api.nvim_buf_get_name(code_buf), ":.") == path
        and vim.endswith(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(base_win)), path)
        and child.api.nvim_win_get_cursor(base_win)[1] == base_line
        and child.api.nvim_win_get_cursor(code_win)[1] == code_line
    end, function()
      return ("the stop %s:%d, not %s"):format(
        path,
        base_line,
        vim.inspect({
          child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(code_win)),
          child.api.nvim_win_get_cursor(base_win),
          child.api.nvim_win_get_cursor(code_win),
          child.api.nvim_get_current_win(),
        })
      )
    end)
  end
  child.cmd("Didymus diff next")
  wait_for_stop("b.txt", 1, 1)
  child.cmd("Didymus diff next")
  wait_for_stop("c.txt", 3, 1)
  eq(win_lines(base_win)[3], "c3")

  child.cmd("Didymus diff prev")
  wait_for_stop("b.txt", 1, 1)
  child.cmd("Didymus diff prev")
  wait_for_stop("a.txt", 6, 8)
  eq(win_lines(base_win)[1], "a1")
end

T["next in the base window at the last stop shows a message, and keeps the focus"] = function()
  open_split()
  child.cmd("edit c.txt")
  local render = wait_for_render(3)
  child.api.nvim_set_current_win(render.base_win)
  child.api.nvim_win_set_cursor(render.base_win, { 4, 0 })
  child.cmd("Didymus diff next")
  wait_for_message("didymus: no next hunk")
  eq(child.api.nvim_get_current_win(), render.base_win)
  eq(child.api.nvim_win_get_cursor(render.base_win)[1], 4)
end

T["next in the code window uses the head lines in the split layout"] = function()
  local code_win = open_split()
  child.api.nvim_win_set_cursor(code_win, { 1, 0 })
  child.cmd("Didymus diff next")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(child.api.nvim_win_get_cursor(code_win)[1], 4)
end

T["the <Plug> mappings set the layout"] = function()
  open_review()
  choose_file("a.txt")
  wait_for_render(1)
  child.lua([[
    vim.keymap.set("n", "<F2>", "<Plug>(didymus-diff-layout-split)")
    vim.keymap.set("n", "<F3>", "<Plug>(didymus-diff-layout-inline)")
    vim.keymap.set("n", "<F4>", "<Plug>(didymus-diff-layout)")
  ]])
  child.type_keys("<F2>")
  eq(wait_for_render(2).layout, "split")
  child.type_keys("<F3>")
  eq(wait_for_render(3).layout, "inline")
  child.type_keys("<F4>")
  eq(wait_for_render(4).layout, "split")
end

T["an unknown layout shows an error"] = function()
  open_review()
  -- An error message in a command is an error of `child.cmd()`.
  child.lua("require('didymus.command').run('diff layout side')")
  wait_for_message('didymus: unknown layout "side". Use inline or split.')
end

T["a layout that the provider does not have shows a warning"] = function()
  child.lua("require('didymus.diff.provider.test').capabilities.layouts.split = false")
  open_review()
  choose_file("a.txt")
  wait_for_render(1)
  child.cmd("Didymus diff layout split")
  wait_for_message("didymus: the diff provider does not have the split layout")
  settle()
  eq(#calls_of("render"), 1)
  eq(#tab_wins(), 1)
end

T[":Didymus diff layout completes the layouts"] = function()
  eq(child.fn.getcompletion("Didymus diff layout ", "cmdline"), { "inline", "split" })
end

return T
