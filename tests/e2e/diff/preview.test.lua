local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local file_row, new_row, third_row = "M file.txt +1 -1", "A new.txt +1 -0", "A third.txt +1 -0"

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua(
        "require('didymus').setup({ review = { picker = 'test', provider = 'test' }, diff = { provider = 'test' } })"
      )
      child.lua("_G.setup_opts = require('didymus.config').options")
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
      child.lua([[
        local provider = require("didymus.diff.provider.test")
        provider.hunks_by_path = {
          ["file.txt"] = { { kind = "change", base = { start = 2, count = 1 }, head = { start = 2, count = 1 } } },
          ["new.txt"] = { { kind = "add", base = { start = 0, count = 0 }, head = { start = 1, count = 1 } } },
          ["third.txt"] = { { kind = "add", base = { start = 0, count = 0 }, head = { start = 1, count = 1 } } },
        }
      ]])
    end,
    post_once = child.stop,
  },
})

--- Open the review of a change that modifies file.txt and adds new.txt and third.txt. other.txt is
--- not in the change.
local function open_review()
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n", ["other.txt"] = "other\n" },
    head = { ["file.txt"] = "one\n2\nthree\n", ["new.txt"] = "new\n", ["third.txt"] = "third\n" },
  })
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", {})
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
end

--- Show a row of the panel in the preview float.
---@param target integer|string
---@return integer win
local function preview(target)
  return child.lua_get("require('didymus.ui.picker.test').preview(...)", { target })
end

local function hide_preview()
  child.lua("require('didymus.ui.picker.test').hide_preview()")
end

---@param method string
---@return table[]
local function calls_of(method)
  return vim.tbl_filter(function(call)
    return call.method == method
  end, child.lua_get("require('didymus.diff.provider.test').calls"))
end

---@param count integer
local function wait_for_renders(count)
  wait_for(function()
    return #calls_of("render") >= count
  end, function()
    return ("render %d: %s"):format(count, vim.inspect(calls_of("render")))
  end)
end

--- The text of the diff marks in `win`.
---@param win integer
---@return string[]
local function marks(win)
  return child.lua_get(
    [[
    (function(win)
      local ns = vim.api.nvim_get_namespaces()["didymus.diff.test." .. win]
      if not ns then
        return {}
      end
      return vim.tbl_map(function(mark)
        return mark[4].virt_text[1][1]
      end, vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, { details = true }))
    end)(...)
  ]],
    { win }
  )
end

local function settle()
  child.lua("vim.wait(50, function() return false end)")
end

---@param path string
---@return integer
local function find_buf(path)
  return child.fn.bufnr(path)
end

---@param path string
---@return boolean
local function is_prepared(path)
  return child.lua_get(
    "require('didymus.diff.provider.test'):is_prepared(vim.fn.bufnr(...))",
    { path }
  )
end

---@param paths string[]
local function wait_for_prepared(paths)
  for _, path in ipairs(paths) do
    wait_for(function()
      return is_prepared(path)
    end, "the preload of " .. path)
  end
end

--- The paths of the `prepare` calls, in order.
---@return string[]
local function prepared_paths()
  return vim.tbl_map(function(call)
    return call.path
  end, calls_of("prepare"))
end

--- The name of the buffer in `win`, relative to the current directory.
---@param win integer
---@return string
local function buf_name(win)
  return child.fn.fnamemodify(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(win)), ":.")
end

--- The hidden floats of the current tabpage.
---@return integer
local function count_hidden_floats()
  return child.lua_get([[#vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).hide == true
  end, vim.api.nvim_tabpage_list_wins(0))]])
end

local function set_fake_lsp()
  child.lua([[
    vim.lsp.config("fake", {
      filetypes = { "text" },
      root_markers = { ".git" },
      cmd = function(dispatchers)
        local closing = false
        return {
          request = function(method, _, callback)
            if method == "initialize" then
              callback(nil, { capabilities = {} })
            elseif method == "shutdown" then
              callback(nil, nil)
            end
            return true, 1
          end,
          notify = function(method)
            if method == "exit" then
              dispatchers.on_exit(0, 15)
            end
            return true
          end,
          is_closing = function()
            return closing
          end,
          terminate = function()
            closing = true
          end,
        }
      end,
    })
    vim.lsp.enable("fake")
  ]])
end

---@param buf integer
---@return integer
local function count_clients(buf)
  return child.lua_get("#vim.lsp.get_clients({ bufnr = ... })", { buf })
end

T["the preload prepares the files of the change in the order of the panel, in a hidden float"] = function()
  open_review()
  wait_for_prepared({ "file.txt", "new.txt", "third.txt" })
  eq(prepared_paths(), { "file.txt", "new.txt", "third.txt" })
  eq(#calls_of("render"), 0)
  -- The float closes at the end.
  eq(count_hidden_floats(), 0)
  eq(find_buf("other.txt"), -1)
end

T["the preload stops while the review tabpage is not current"] = function()
  child.lua("require('didymus.diff.provider.test').delays = { ['file.txt'] = 200 }")
  open_review()
  eq(count_hidden_floats(), 1)
  child.cmd("tabprevious")
  child.lua("vim.wait(400, function() return false end)")
  eq(prepared_paths(), { "file.txt" })

  child.cmd("tabnext")
  wait_for_prepared({ "new.txt", "third.txt" })
end

T["a prepared file shows at once, with its inline diff"] = function()
  open_review()
  wait_for_prepared({ "file.txt" })
  local result = child.lua_get(
    [[(function(target)
    local win = require("didymus.ui.picker.test").preview(target)
    local ns = vim.api.nvim_get_namespaces()["didymus.diff.test." .. win]
    return { win = win, marks = #vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, {}) }
  end)(...)]],
    { file_row }
  )
  eq(result.marks, 1)
  eq(buf_name(result.win), "file.txt")
  local show = calls_of("show_prepared")[1]
  eq({ show.layout, show.sides, show.head_win }, { "inline", "both", result.win })
  eq(marks(result.win), { "diff inline both" })
end

T["the file under the cursor goes before the other files"] = function()
  child.lua("require('didymus.diff.provider.test').delays = { ['file.txt'] = 200 }")
  open_review()
  preview(third_row)
  wait_for_prepared({ "file.txt", "new.txt", "third.txt" })
  eq(prepared_paths(), { "file.txt", "third.txt", "new.txt" })
end

T["a file that is not ready keeps the last file in the float, until it shows with its diff"] = function()
  child.lua("require('didymus.diff.provider.test').prepare_delays = { ['new.txt'] = 300 }")
  open_review()
  wait_for_prepared({ "file.txt" })
  local win = preview(file_row)

  eq(preview(new_row), win)
  eq(buf_name(win), "file.txt")
  eq(marks(win), { "diff inline both" })
  eq(child.api.nvim_win_get_config(win).hide, false)
  wait_for(function()
    return buf_name(win) == "new.txt"
  end, "new.txt in the float")
  eq(marks(win), { "diff inline both" })
end

T["a move to a different row shows its diff, and the code window keeps its diff"] = function()
  open_review()
  wait_for_prepared({ "file.txt", "new.txt" })
  child.lua("require('didymus.ui.picker.test').choose(...)", { file_row })
  wait_for_renders(1)
  local code_win = child.api.nvim_get_current_win()

  local win = preview(new_row)
  eq(calls_of("show_prepared")[1].path, "new.txt")
  eq(marks(win), { "diff inline both" })
  eq(marks(code_win), { "diff inline both" })

  -- A header row is not a file of the change.
  preview(1)
  eq(calls_of("clear")[#calls_of("clear")].win, win)
  eq(marks(code_win), { "diff inline both" })
end

T["the diff leaves the preview when the panel loses the focus"] = function()
  open_review()
  wait_for_prepared({ "file.txt" })
  local win = preview(file_row)

  hide_preview()
  eq(calls_of("clear"), { { method = "clear", win = win } })
end

T["the preview is inline, also with the split layout, and keeps the head sides"] = function()
  open_review()
  wait_for_prepared({ "file.txt", "new.txt" })
  child.cmd("Didymus diff layout split")
  local win = preview(file_row)
  eq(
    { calls_of("show_prepared")[1].layout, calls_of("show_prepared")[1].sides },
    { "inline", "both" }
  )

  child.cmd("Didymus diff side head")
  preview(new_row)
  eq(
    { calls_of("show_prepared")[2].layout, calls_of("show_prepared")[2].sides },
    { "inline", "head" }
  )
  eq(marks(win), { "diff inline head" })
end

T["with a hidden diff, the preview shows the file with no diff"] = function()
  open_review()
  wait_for_prepared({ "file.txt" })
  local win = preview(file_row)

  child.cmd("Didymus diff toggle")
  eq(marks(win), {})
  preview(new_row)
  wait_for(function()
    return buf_name(win) == "new.txt"
  end, "new.txt in the float")
  eq(marks(win), {})
  eq(#calls_of("show_prepared"), 1)
end

T["a file whose diff fails shows with no diff"] = function()
  child.lua("require('didymus.diff.provider.test').errors = { prepare = 'no hunks' }")
  open_review()
  wait_for_prepared({ "new.txt" })
  local win = preview(file_row)
  eq(buf_name(win), "file.txt")
  eq(marks(win), {})
  eq(
    child.cmd_capture("messages"):find("cannot show the diff of file.txt: no hunks", 1, true) ~= nil,
    true
  )
end

T["the preload shows no progress message"] = function()
  child.lua([[
    _G.progress = {}
    local echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, history, opts)
      if opts.kind == "progress" and opts.id == "didymus.diff.progress" then
        table.insert(_G.progress, chunks[1][1])
      end
      return echo(chunks, history, opts)
    end
    require("didymus.diff.provider.test").delays = { ["file.txt"] = 700 }
  ]])
  open_review()
  wait_for_prepared({ "file.txt" })
  eq(child.lua_get("_G.progress"), {})
end

T["above diff.preload, a load unloads the buffer that the preview used last"] = function()
  child.lua("_G.setup_opts.diff.preload = 1")
  open_review()
  wait_for_prepared({ "file.txt" })
  child.lua("vim.wait(100, function() return false end)")
  eq(prepared_paths(), { "file.txt" })
  local file_buf = find_buf("file.txt")
  preview(file_row)

  local win = preview(new_row)
  wait_for(function()
    return buf_name(win) == "new.txt"
  end, "new.txt in the float")
  -- The float showed file.txt during the load of new.txt.
  eq(child.api.nvim_buf_is_loaded(file_buf), true)

  preview(third_row)
  wait_for(function()
    return buf_name(win) == "third.txt"
  end, "third.txt in the float")
  eq(child.api.nvim_buf_is_valid(file_buf), false)
  -- The float showed new.txt during the load of third.txt.
  eq(child.api.nvim_buf_is_loaded(find_buf("new.txt")), true)
end

T["LSP clients attach to the preloaded buffers, and go away when the review closes"] = function()
  set_fake_lsp()
  open_review()
  wait_for_prepared({ "file.txt", "new.txt", "third.txt" })
  local buf = find_buf("file.txt")
  wait_for(function()
    return count_clients(buf) == 1
  end, "the LSP client of file.txt")

  child.cmd("Didymus review close")
  eq(child.api.nvim_buf_is_valid(buf), false)
  for _, path in ipairs({ "file.txt", "new.txt", "third.txt" }) do
    eq(find_buf(path), -1)
  end
end

T["a preloaded buffer that the user opened stays after the review closes"] = function()
  open_review()
  wait_for_prepared({ "file.txt" })
  local buf = find_buf("file.txt")
  child.lua("require('didymus.ui.picker.test').choose(...)", { file_row })
  child.cmd("edit other.txt")

  child.cmd("Didymus review close")
  eq(child.api.nvim_buf_is_loaded(buf), true)
  eq(child.lua_get("vim.bo[...].buflisted", { buf }), true)
end

T["a buffer that the user loaded before the review stays loaded"] = function()
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n" },
    head = { ["file.txt"] = "one\n2\nthree\n" },
  })
  child.fn.chdir(repo.dir)
  helpers.git(repo.dir, { "checkout", "-q", "feature" })
  child.cmd("badd file.txt")
  local buf = find_buf("file.txt")
  child.fn.bufload(buf)
  helpers.git(repo.dir, { "checkout", "-q", "main" })
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", {})
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  wait_for_prepared({ "file.txt" })

  child.cmd("Didymus review close")
  eq(child.api.nvim_buf_is_loaded(buf), true)
end

return T
