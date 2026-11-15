local eq = MiniTest.expect.equality
local no_eq = MiniTest.expect.no_equality
local expect_screenshot = MiniTest.expect.reference_screenshot

local child = MiniTest.new_child_neovim()

--- Open the input float with one action, `submit`. The callbacks keep the result in `_G.result`.
---@param opts table? `submit_key` sets the key of the action. Default `<C-y>`.
local function open(opts)
  child.lua(
    [[
      _G.result = { submitted = {}, cancelled = 0 }
      local opts = ...
      local on_submit = function(text)
        table.insert(_G.result.submitted, text)
        _G.result.mode = vim.api.nvim_get_mode().mode
        _G.result.win = vim.api.nvim_get_current_win()
      end
      opts.actions = { { key = opts.submit_key or "<C-y>", name = "submit", on_submit = on_submit } }
      opts.submit_key = nil
      opts.on_cancel = function()
        _G.result.cancelled = _G.result.cancelled + 1
      end
      require("didymus.ui.input").open(opts)
    ]],
    { opts or { title = "Prompt" } }
  )
end

---@return table
local function result()
  return child.lua_get("_G.result")
end

---@return integer?
local function input_win()
  for _, win in ipairs(child.api.nvim_list_wins()) do
    if child.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

---@return integer
local function input_height()
  return child.api.nvim_win_get_height(assert(input_win()))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 20, 50
      child.api.nvim_buf_set_lines(0, 0, -1, false, {
        "local M = {}",
        "",
        "function M.setup(opts)",
        "  M.opts = opts",
        "end",
        "",
        "return M",
      })
      child.api.nvim_win_set_cursor(0, { 3, 9 })
    end,
    post_once = child.stop,
  },
})

T["opens with one line above the cursor line, in the center of the window"] = function()
  child.api.nvim_win_set_cursor(0, { 7, 0 })
  open({ title = "Prompt", width = 30, max_height = 4 })
  eq(child.api.nvim_get_mode().mode, "i")
  eq(input_height(), 1)
  eq(child.api.nvim_get_current_win(), input_win())
  eq(child.bo.filetype, "didymus_input")
  expect_screenshot(child.get_screenshot())
end

T["opens under the line on the first line of the window"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  open({ title = "Prompt", width = 30 })
  expect_screenshot(child.get_screenshot())
end

T["does not cover a wrapped line"] = function()
  child.api.nvim_buf_set_lines(0, 6, 7, false, { ("long "):rep(15) })
  child.api.nvim_win_set_cursor(0, { 7, 70 })
  open({ title = "Prompt", width = 30, max_height = 2 })
  expect_screenshot(child.get_screenshot())
end

T["stays in the code window when the agent split is open"] = function()
  child.lua("require('didymus').setup(...)", { { agent = { backend = "test" } } })
  child.lua("require('didymus.agent').toggle()")
  child.cmd("wincmd p")
  child.api.nvim_win_set_cursor(0, { 7, 0 })
  open({ title = "Prompt", width = 20, max_height = 4 })
  expect_screenshot(child.get_screenshot())
end

T["with a range, opens above the first line"] = function()
  open({ title = "Prompt", width = 20, max_height = 1, range = { 4, 7 } })
  expect_screenshot(child.get_screenshot())
end

T["with a range, opens under the last line"] = function()
  open({ title = "Prompt", width = 20, range = { 3, 5 } })
  expect_screenshot(child.get_screenshot())
end

T["highlights only the current window, if two windows show the buffer"] = function()
  child.cmd("vsplit")
  open({ title = "Prompt", width = 20, range = { 2, 4 } })
  expect_screenshot(child.get_screenshot())
end

--- The highlight attributes of a screen row.
---@param row integer
---@return string
local function row_attrs(row)
  return table.concat(child.get_screenshot().attr[row])
end

T["highlights the lines until the float closes"] = MiniTest.new_set({
  parametrize = { { "<C-y>" }, { "<Esc>q" } },
})

T["highlights the lines until the float closes"]["with"] = function(keys)
  local plain = row_attrs(3)
  open({ range = { 2, 4 } })
  no_eq(row_attrs(3), plain)
  eq(child.api.nvim_get_hl(0, { name = "DidymusInputContext" }).link, "Visual")
  child.type_keys("text", keys)
  eq(input_win(), nil)
  eq(row_attrs(3), plain)
end

T["fits in a window narrower than width"] = function()
  child.cmd("vsplit")
  child.api.nvim_win_set_cursor(0, { 7, 0 })
  open({ title = "Prompt", width = 30, max_height = 4 })
  eq(child.api.nvim_win_get_width(assert(input_win())), 23)
  expect_screenshot(child.get_screenshot())
end

T["a width below 1 is a fraction of the window width"] = function()
  child.cmd("vsplit")
  open({ width = 0.5 })
  eq(child.api.nvim_win_get_width(assert(input_win())), 12)
end

T["above the line, grows up when the text wraps"] = function()
  child.api.nvim_win_set_cursor(0, { 7, 0 })
  open({ width = 20, max_height = 4 })
  --- The 0-based screen row of the bottom border. The position updates on a redraw.
  local function bottom_row()
    child.cmd("redraw")
    local win = assert(input_win())
    return child.api.nvim_win_get_position(win)[1] + child.api.nvim_win_get_height(win) + 1
  end
  -- The row above the cursor line.
  eq(bottom_row(), 5)
  child.type_keys("one two three four five six")
  eq(input_height(), 2)
  eq(bottom_row(), 5)
  expect_screenshot(child.get_screenshot())
end

T["grows when the text wraps, and stops at max_height"] = function()
  open({ width = 20, max_height = 3 })
  child.type_keys("one two three four")
  eq(input_height(), 1)
  child.type_keys(" five")
  eq(input_height(), 2)
  child.type_keys(" six seven eight nine ten eleven twelve thirteen")
  eq(input_height(), 3)
  expect_screenshot(child.get_screenshot())
end

T["<CR> adds a line"] = function()
  open()
  child.type_keys("one<CR>two")
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "two" })
  eq(input_height(), 2)
  eq(result().submitted, {})
end

T["starts with the text, in insert mode at its end"] = function()
  open({ title = "Prompt", text = "one\ntwo", max_height = 5 })
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "two" })
  eq(input_height(), 2)
  eq(child.api.nvim_get_mode().mode, "i")
  child.type_keys(" three<C-y>")
  eq(result().submitted, { "one\ntwo three" })
end

T["<C-y> in insert mode submits the full text and closes the float"] = function()
  local origin = child.api.nvim_get_current_win()
  open()
  child.type_keys("one<CR>two<CR><CR><C-y>")
  eq(result().submitted, { "one\ntwo" })
  eq(result().mode, "n")
  eq(result().win, origin)
  eq(input_win(), nil)
  eq(child.api.nvim_win_get_cursor(0), { 3, 9 })
  eq(result().cancelled, 0)
end

T["<C-y> in normal mode submits"] = function()
  open()
  child.type_keys("one", "<Esc>", "<C-y>")
  eq(result().submitted, { "one" })
  eq(input_win(), nil)
end

T["<C-y> submits when a completion plugin maps <C-y> on InsertEnter"] = function()
  -- As LazyVim configures blink.cmp: a buffer mapping with no fallback.
  child.lua([[
    vim.api.nvim_create_autocmd("InsertEnter", {
      callback = function()
        vim.keymap.set("i", "<C-y>", function() end, { buffer = true })
      end,
    })
  ]])
  open()
  child.type_keys("one", "<C-y>")
  eq(result().submitted, { "one" })
  eq(input_win(), nil)
end

T["turns off completion"] = function()
  child.o.autocomplete = true
  open()
  child.type_keys("lo")
  eq(child.fn.pumvisible(), 0)
  -- blink.cmp reads `b:completion`.
  eq(child.b.completion, false)

  -- Make sure that the test can show the menu.
  child.type_keys("<Esc>", "q")
  child.type_keys("o", "lo")
  eq(child.fn.pumvisible(), 1)
end

T["<C-y> with no text does nothing"] = function()
  open()
  child.type_keys(" <CR><C-y>")
  eq(result().submitted, {})
  eq(child.api.nvim_get_current_win(), input_win())
end

T["cancel"] = MiniTest.new_set({
  parametrize = { { "q" }, { "<Esc>" }, { "<C-w>p" }, { ":q<CR>" } },
})

T["cancel"]["calls on_cancel and closes the float"] = function(keys)
  local origin = child.api.nvim_get_current_win()
  open()
  child.type_keys("one", "<Esc>", keys)
  eq(result().cancelled, 1)
  eq(result().submitted, {})
  eq(input_win(), nil)
  eq(child.api.nvim_get_current_win(), origin)
  eq(child.api.nvim_get_mode().mode, "n")
end

T["a second open cancels the first"] = function()
  open()
  child.lua([[
    require("didymus.ui.input").open({
      actions = { { key = "<C-y>", name = "submit", on_submit = function(text) _G.second = text end } },
    })
  ]])
  eq(result().cancelled, 1)
  eq(#child.api.nvim_list_wins(), 2)
  child.type_keys("two<C-y>")
  eq(child.lua_get("_G.second"), "two")
end

T["custom keys work"] = function()
  open({ submit_key = "<C-s>", keys = { cancel = "<C-c>" } })
  child.type_keys("one<C-y>")
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { "one" })
  child.type_keys("<C-s>")
  eq(result().submitted, { "one" })

  open({ submit_key = "<C-s>", keys = { cancel = "<C-c>" } })
  child.type_keys("<Esc>", "<C-c>")
  eq(result().cancelled, 1)
  eq(input_win(), nil)
end

T["each action calls its own callback, and the footer shows the keys in order"] = function()
  child.lua([[
    _G.calls = {}
    local function action(key, name)
      return {
        key = key,
        name = name,
        on_submit = function(text)
          table.insert(_G.calls, { name, text })
        end,
      }
    end
    _G.open = function()
      require("didymus.ui.input").open({
        actions = { action("<C-s>", "send"), action("<C-y>", "append"), action(false, "off") },
      })
    end
    _G.open()
  ]])
  local footer = child.api.nvim_win_get_config(assert(input_win())).footer
  eq(footer[1][1], " <C-s> send  <C-y> append  q cancel ")
  child.type_keys("one<C-s>")
  child.lua("_G.open()")
  child.type_keys("two", "<Esc>", "<C-y>")
  eq(child.lua_get("_G.calls"), { { "send", "one" }, { "append", "two" } })
end

return T
