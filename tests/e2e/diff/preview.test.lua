local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local file_row, new_row = "M file.txt +1 -1", "A new.txt +1 -0"

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua(
        "require('didymus').setup({ review = { picker = 'test', provider = 'test' }, diff = { provider = 'test' } })"
      )
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

--- Open the review of a change that modifies file.txt and adds new.txt. other.txt is not in the
--- change.
local function open_review()
  local repo = helpers.make_repo({
    base = { ["file.txt"] = "one\ntwo\nthree\n", ["other.txt"] = "other\n" },
    head = { ["file.txt"] = "one\n2\nthree\n", ["new.txt"] = "new\n" },
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

T["the preview of a file shows the inline diff in the preview window"] = function()
  open_review()
  local win = preview(file_row)
  wait_for_renders(1)

  local render = calls_of("render")[1]
  eq(render.path, "file.txt")
  eq({ render.layout, render.sides }, { "inline", "both" })
  eq(render.head_win, win)
  eq(render.head_buf, child.api.nvim_win_get_buf(win))
  eq(child.api.nvim_buf_get_name(render.head_buf), child.fn.getcwd() .. "/file.txt")
  eq(marks(win), { "diff inline both" })
end

T["a move to a different row shows its diff, and the code window keeps its diff"] = function()
  open_review()
  child.lua("require('didymus.ui.picker.test').choose(...)", { file_row })
  wait_for_renders(1)
  local code_win = child.api.nvim_get_current_win()

  local win = preview(new_row)
  wait_for_renders(2)
  eq(calls_of("render")[2].path, "new.txt")
  eq(marks(win), { "diff inline both" })
  eq(marks(code_win), { "diff inline both" })

  -- A header row is not a file of the change.
  preview(1)
  settle()
  eq(calls_of("clear")[#calls_of("clear")].win, win)
  eq(#calls_of("render"), 2)
  eq(marks(code_win), { "diff inline both" })
end

T["the diff leaves the preview when the panel loses the focus"] = function()
  open_review()
  local win = preview(file_row)
  wait_for_renders(1)

  hide_preview()
  eq(calls_of("clear"), { { method = "clear", win = win } })
end

T["a preview that hides before attach ends does not render"] = function()
  child.lua("require('didymus.diff.provider.test').delays = { ['file.txt'] = 200 }")
  open_review()
  preview(file_row)
  hide_preview()
  child.lua("vim.wait(300, function() return false end)")
  eq(calls_of("render"), {})
end

T["the preview is inline, also with the split layout, and keeps the head sides"] = function()
  open_review()
  child.cmd("Didymus diff layout split")
  local win = preview(file_row)
  wait_for_renders(1)
  eq({ calls_of("render")[1].layout, calls_of("render")[1].sides }, { "inline", "both" })
  eq(calls_of("render")[1].base_win, nil)

  child.cmd("Didymus diff side head")
  preview(new_row)
  wait_for_renders(2)
  eq({ calls_of("render")[2].layout, calls_of("render")[2].sides }, { "inline", "head" })
  eq(marks(win), { "diff inline head" })
end

T["a hidden diff does not show in the preview, and toggle removes it"] = function()
  open_review()
  local win = preview(file_row)
  wait_for_renders(1)

  child.cmd("Didymus diff toggle")
  eq(marks(win), {})
  preview(new_row)
  settle()
  eq(#calls_of("render"), 1)
end

T["an attach in the preview shows no progress message"] = function()
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
  preview(file_row)
  wait_for_renders(1)
  eq(child.lua_get("_G.progress"), {})
end

T["a buffer that only the preview loaded goes away, with its LSP client, when the preview moves on"] = function()
  -- An LSP server in the child, for the "text" filetype of the files.
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
  open_review()
  preview(file_row)
  local buf = find_buf("file.txt")
  wait_for(function()
    return child.lua_get("#vim.lsp.get_clients({ bufnr = ... })", { buf }) == 1
  end, "the LSP client of the preview")
  wait_for_renders(1)

  preview(new_row)
  settle()
  eq(child.api.nvim_buf_is_valid(buf), false)
  eq(find_buf("file.txt"), -1)
  eq(calls_of("detach")[1].buf, buf)

  hide_preview()
  settle()
  eq(find_buf("new.txt"), -1)
end

T["a buffer that the user loaded stays loaded after the preview"] = function()
  open_review()
  child.lua("require('didymus.ui.picker.test').choose(...)", { file_row })
  local buf = find_buf("file.txt")
  -- file.txt is hidden now, but the user opened it.
  child.cmd("edit other.txt")

  preview(file_row)
  preview(new_row)
  hide_preview()
  settle()
  eq(child.api.nvim_buf_is_loaded(buf), true)
  eq(child.lua_get("vim.bo[...].buflisted", { buf }), true)
end

T["a buffer that the preview loaded stays after the user opens it"] = function()
  open_review()
  preview(file_row)
  local buf = find_buf("file.txt")
  child.lua("require('didymus.ui.picker.test').choose(...)", { file_row })

  preview(new_row)
  hide_preview()
  settle()
  eq(child.api.nvim_buf_is_loaded(buf), true)
  eq(child.api.nvim_win_get_buf(child.api.nvim_get_current_win()), buf)
end

return T
