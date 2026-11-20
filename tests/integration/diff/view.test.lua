-- The diff view of a review with the real gitsigns: the flow from the open of a file to the close.

local review_helpers = dofile("tests/e2e/review/helpers.lua")
local helpers = dofile("tests/integration/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.restart(child, { "gitsigns.nvim" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua("require('gitsigns').setup()")
      child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
    end,
    post_once = child.stop,
  },
})

---@param threads didymus.review.Thread[]?
---@return didymus.test.Repo
local function open_review(threads)
  local repo = review_helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n", ["other.txt"] = "other\n" },
    head = { ["file.txt"] = "one\n2\nthree\n" },
  })
  child.fn.chdir(repo.dir)
  review_helpers.set_changes(child, { repo.change })
  review_helpers.set_threads(child, "1", threads or {})
  child.cmd("Didymus review open 1")
  review_helpers.wait_for_review(child, "1")
  for index, item in ipairs(review_helpers.picker_calls(child, "panel")[1].items) do
    if item.value.kind == "file" then
      child.lua("require('didymus.ui.picker.test').choose(...)", { index })
      break
    end
  end
  return repo
end

---@return boolean
local function has_view()
  return child.lua_get(
    "require('gitsigns.unified').get_view(vim.api.nvim_get_current_win()) ~= nil"
  )
end

--- The base of the gitsigns hunks of the current buffer. Nil is the index.
---@return string?
local function base()
  local revision = child.lua_get([[
    (function()
      local entry = require("gitsigns.cache").cache[vim.api.nvim_get_current_buf()]
      return entry and entry.git_obj.revision
    end)()
  ]])
  return revision ~= vim.NIL and revision or nil
end

T["the code window shows the unified view against the merge-base, and toggle hides it"] = function()
  local repo = open_review()
  wait_for(has_view, "the unified view")
  eq(base(), repo.change.base_sha)
  eq(child.lua_get("#require('gitsigns').get_hunks(0)"), 1)

  child.cmd("Didymus diff toggle")
  eq(has_view(), false)
  wait_for(function()
    return base() == nil
  end, "the base of the gitsigns config")

  child.cmd("Didymus diff toggle")
  wait_for(has_view, "the unified view after toggle")
end

T["the close of the review puts back the base of the gitsigns config"] = function()
  open_review()
  wait_for(has_view, "the unified view")
  local buf = child.api.nvim_get_current_buf()

  child.cmd("Didymus review close")
  child.cmd("buffer " .. buf)
  wait_for(function()
    return base() == nil
  end, "the base of the gitsigns config")
  eq(has_view(), false)
end

--- The window options that `:diffthis` changes.
local diff_options = {
  "diff",
  "scrollbind",
  "cursorbind",
  "wrap",
  "foldmethod",
  "foldcolumn",
  "foldenable",
  "foldlevel",
}

---@param win integer
---@return table<string, any>
local function get_options(win)
  local options = {}
  for _, name in ipairs(diff_options) do
    options[name] = child.api.nvim_get_option_value(name, { win = win, scope = "local" })
  end
  return options
end

--- Change to the split layout, and wait for native diff mode in the code window.
---@return integer code_win
---@return integer base_win
local function show_split()
  local code_win = child.api.nvim_get_current_win()
  child.cmd("Didymus diff layout split")
  wait_for(function()
    return get_options(code_win).diff
  end, "'diff' in the code window")
  return code_win, child.fn.win_getid(child.fn.winnr("h"))
end

T["the split layout uses native diff mode, and inline puts back the options"] = function()
  open_review()
  wait_for(has_view, "the unified view")
  local code_win = child.api.nvim_get_current_win()
  child.cmd("setlocal foldmethod=indent foldcolumn=1 nowrap")
  local options = get_options(code_win)

  local _, base_win = show_split()
  MiniTest.expect.no_equality(base_win, code_win)
  eq(has_view(), false)
  eq(child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(base_win), 0, -1, true), {
    "one",
    "two",
    "three",
  })
  for _, win in ipairs({ code_win, base_win }) do
    local win_options = get_options(win)
    eq({ win_options.diff, win_options.scrollbind, win_options.cursorbind }, { true, true, true })
  end
  -- The gitsigns signs stay.
  eq(child.lua_get("#require('gitsigns').get_hunks(0)"), 1)

  child.cmd("Didymus diff layout inline")
  wait_for(has_view, "the unified view after inline")
  eq(child.api.nvim_win_is_valid(base_win), false)
  eq(get_options(code_win), options)
end

T["the threads show in the code window in the split layout"] = function()
  open_review({
    review_helpers.make_thread("open", "file.txt", {
      range = { first = 2, last = 2 },
      comments = { { author = "octocat", body = "Why 2?", pending = false } },
    }),
  })
  review_helpers.wait_for_threads(child, 1)
  local code_win = show_split()
  child.cmd("redraw")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(#review_helpers.thread_marks(child), 1)
  local screen = table.concat(
    vim.tbl_map(function(line)
      return table.concat(line)
    end, child.get_screenshot().text),
    "\n"
  )
  eq(screen:find("Why 2?", 1, true) ~= nil, true)
end

T["a different buffer in the base window has no diff state"] = function()
  open_review()
  local code_win, base_win = show_split()
  child.api.nvim_set_current_win(base_win)
  child.cmd("edit other.txt")
  wait_for(function()
    return child.lua_get("require('gitsigns.unified').get_view(...) ~= nil", { code_win })
  end, "the unified view in the code window")
  local base_options = get_options(base_win)
  eq(
    { base_options.diff, base_options.scrollbind, base_options.cursorbind },
    { false, false, false }
  )
  eq(get_options(code_win).diff, false)
end

T["the cursor of the base window follows the cursor of the code window"] = function()
  open_review()
  local code_win, base_win = show_split()
  child.api.nvim_win_set_cursor(code_win, { 3, 0 })
  child.cmd("redraw")
  eq(child.api.nvim_win_get_cursor(base_win)[1], 3)
end

T["the base sides highlight the deleted lines of the base buffer in the code window"] = function()
  open_review()
  wait_for(has_view, "the unified view")
  local code_win = child.api.nvim_get_current_win()
  local head_buf = child.api.nvim_get_current_buf()
  child.cmd("Didymus diff side base")
  local function get_marks()
    return child.lua(
      [[
      local win = ...
      local ns = vim.api.nvim_get_namespaces()["didymus.diff.gitsigns.base." .. win]
      local buf = vim.api.nvim_win_get_buf(win)
      return vim.tbl_map(function(mark)
        return { mark[2] + 1, mark[4].line_hl_group }
      end, ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) or {})
    ]],
      { code_win }
    )
  end
  wait_for(function()
    return #get_marks() > 0
  end, "the marks of the base sides")
  eq(get_marks(), { { 2, "DiffDelete" } })
  eq(child.api.nvim_buf_get_lines(0, 0, -1, true), { "one", "two", "three" })
  eq(has_view(), false)

  child.cmd("Didymus diff side both")
  eq(child.api.nvim_get_current_buf(), head_buf)
  wait_for(has_view, "the unified view after the both sides")
end

T["the preview of the snacks files panel shows the unified view, until the panel loses the focus"] = function()
  helpers.restart(child, { "gitsigns.nvim", "snacks.nvim" })
  child.cmd("runtime plugin/didymus.lua")
  child.lua("require('gitsigns').setup()")
  child.lua("require('didymus').setup({ review = { picker = 'snacks', provider = 'test' } })")
  child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
  local repo = review_helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n" },
    head = { ["file.txt"] = "one\n2\nthree\n" },
  })
  child.fn.chdir(repo.dir)
  review_helpers.set_changes(child, { repo.change })
  review_helpers.set_threads(child, "1", {})
  child.cmd("Didymus review open 1")
  review_helpers.wait_for_review(child, "1")
  wait_for(function()
    return child.bo.filetype == "snacks_picker_list"
  end, "the focus in the panel")

  -- Each redraw of file.txt in the preview float that shows. `on_win` comes also for a hidden float.
  child.lua([[
    _G.frames = {}
    vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("test.frames"), {
      on_win = function(_, win, buf)
        local name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))
        if vim.w[win].snacks_picker_preview and name == "file.txt" and not vim.api.nvim_win_get_config(win).hide then
          local ns = vim.api.nvim_get_namespaces()["gitsigns_unified_" .. win]
          table.insert(_G.frames, ns and #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0 or false)
        end
        return false
      end,
    })
  ]])
  -- The rows: the title, the branches, the thread filter, then file.txt.
  child.type_keys("G")
  local function preview_win()
    return child.lua_get([[(function()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.w[win].snacks_picker_preview then
          return win
        end
      end
      return 0
    end)()]])
  end
  local function preview_has_view()
    local win = preview_win()
    return win ~= 0 and child.lua_get("require('gitsigns.unified').get_view(...) ~= nil", { win })
  end
  wait_for(preview_has_view, "the unified view in the preview")
  wait_for(function()
    return #child.lua_get("_G.frames") > 0
  end, "a redraw of the preview")
  -- The float shows file.txt only with its diff.
  eq(vim.tbl_contains(child.lua_get("_G.frames"), false), false)
  local buf = child.api.nvim_win_get_buf(preview_win())
  eq(child.fn.fnamemodify(child.api.nvim_buf_get_name(buf), ":t"), "file.txt")

  child.cmd("wincmd l")
  wait_for(function()
    return preview_win() == 0 and not child.api.nvim_buf_is_loaded(buf)
  end, "no preview, and file.txt is not loaded")
end

T["with no gitsigns, a warning shows and the review works"] = function()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.cmd("runtime plugin/didymus.lua")
  child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
  child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
  open_review()
  wait_for(function()
    return child.cmd_capture("messages"):find(
      "didymus: cannot show the diff of file.txt: gitsigns.nvim is not available",
      1,
      true
    ) ~= nil
  end, "the warning")
  eq(child.fn.expand("%:t"), "file.txt")
end

return T
