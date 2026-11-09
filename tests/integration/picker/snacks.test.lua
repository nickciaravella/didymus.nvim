local wait_for = dofile("tests/helpers.lua").wait_for
local helpers = dofile("tests/integration/helpers.lua")
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.restart(child)
    end,
    post_once = child.stop,
  },
})

--- The window of the current tabpage that shows a buffer with `filetype`, else 0.
---@param filetype string
---@return integer
local function find_win(filetype)
  return child.lua_get(
    [[(function(filetype)
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == filetype then
          return win
        end
      end
      return 0
    end)(...)]],
    { filetype }
  )
end

--- The lines that are not empty. A list line starts with the column of the selection mark.
---@param filetype string
---@return string[]
local function lines(filetype)
  local win = find_win(filetype)
  if win == 0 then
    return {}
  end
  local result = {}
  for _, line in ipairs(child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, false)) do
    if line ~= "" then
      table.insert(result, filetype == "snacks_picker_list" and line:gsub("^ ", "") or line)
    end
  end
  return result
end

---@param filetype string
---@param expected string[]
local function wait_for_lines(filetype, expected)
  wait_for(function()
    return vim.deep_equal(lines(filetype), expected)
  end, function()
    return ("%s shows %s, not %s"):format(
      filetype,
      vim.inspect(lines(filetype)),
      vim.inspect(expected)
    )
  end)
end

---@param name string
---@param expected any
local function wait_for_global(name, expected)
  wait_for(function()
    return vim.deep_equal(child.lua_get("_G[...]", { name }), expected)
  end, function()
    return ("_G.%s is %s, not %s"):format(
      name,
      vim.inspect(child.lua_get("_G[...]", { name })),
      vim.inspect(expected)
    )
  end)
end

--- Let the child run its scheduled callbacks, such as an auto close of snacks.
local function settle()
  child.lua("vim.wait(50)")
end

T["select()"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        _G.start_win = vim.api.nvim_get_current_win()
        _G.chosen, _G.choose_win, _G.cancelled = vim.NIL, vim.NIL, false
        require("didymus.ui.picker.snacks").select({
          title = "Test",
          items = {
            { text = "one", value = 1, preview = { lines = { "preview of one" } } },
            { text = "two", value = 2, preview = { lines = { "preview of two" } } },
          },
          on_choose = function(item)
            _G.chosen, _G.choose_win = item.value, vim.api.nvim_get_current_win()
          end,
          on_cancel = function()
            _G.cancelled = true
          end,
        })
      ]])
      wait_for_lines("snacks_picker_list", { "one", "two" })
    end,
  },
})

T["select()"]["shows the items and the preview, and calls on_choose with the chosen item"] = function()
  wait_for_lines("snacks_picker_preview", { "preview of one" })
  child.type_keys("<Down>")
  wait_for_lines("snacks_picker_preview", { "preview of two" })

  child.type_keys("<CR>")
  wait_for_global("chosen", 2)
  eq(find_win("snacks_picker_list"), 0)
  eq(child.lua_get("_G.choose_win == _G.start_win"), true)
  eq(child.lua_get("_G.cancelled"), false)
end

T["select()"]["filters the items with the search"] = function()
  child.type_keys("tw")
  wait_for_lines("snacks_picker_list", { "two" })
  child.type_keys("<CR>")
  wait_for_global("chosen", 2)
end

T["select()"]["calls on_cancel when the user closes it"] = function()
  child.type_keys("<Esc>", "<Esc>")
  wait_for_global("cancelled", true)
  eq(find_win("snacks_picker_list"), 0)
  eq(child.lua_get("_G.chosen"), vim.NIL)
end

--- Open a panel with the items of `_G.items`.
---@param opts table? More panel options.
local function open_panel(opts)
  child.lua(
    [[
      _G.code_win = vim.api.nvim_get_current_win()
      _G.chosen, _G.marked = {}, vim.NIL
      _G.panel = require("didymus.ui.picker.snacks").panel(vim.tbl_extend("force", {
        title = "Panel",
        items = function()
          return _G.items
        end,
        on_choose = function(item)
          table.insert(_G.chosen, item.value)
        end,
        actions = {
          {
            key = "x",
            name = "mark",
            fn = function(item)
              _G.marked = item and item.value or "no item"
            end,
          },
        },
      }, ...))
    ]],
    { opts or {} }
  )
end

---@return boolean
local function is_open()
  return child.lua_get("_G.panel:is_open()")
end

local tree = {
  { text = "a.lua", value = "a" },
  { text = "thread 1", depth = 1, value = "a1" },
  { text = "thread 2", depth = 1, value = "a2" },
  { text = "b.lua", value = "b" },
}

T["panel()"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.lua("_G.items = ...", { tree })
    end,
  },
})

T["panel()"]["shows the items as a tree, and focuses the list"] = function()
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })
  eq(child.api.nvim_get_current_win(), find_win("snacks_picker_list"))
end

T["panel()"]["stays open when the focus goes to a different window"] = function()
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  child.lua("vim.api.nvim_set_current_win(_G.code_win)")
  settle()
  eq(is_open(), true)
  eq(lines("snacks_picker_list"), { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  child.lua("_G.panel:focus()")
  eq(child.api.nvim_get_current_win(), find_win("snacks_picker_list"))
end

T["panel()"]["on_choose does not close the panel"] = function()
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  child.type_keys("j", "<CR>")
  wait_for_global("chosen", { "a1" })
  settle()
  eq(is_open(), true)
  eq(child.api.nvim_get_current_win(), find_win("snacks_picker_list"))
end

T["panel()"]["update() shows the new items, and the cursor stays on the same item"] = function()
  child.lua("_G.items = ...", {
    {
      { id = "a", text = "a.lua" },
      { id = "b", text = "b.lua" },
      { id = "c", text = "c.lua" },
    },
  })
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "b.lua", "c.lua" })
  child.type_keys("j")

  child.lua("_G.items = ...", {
    {
      { id = "new", text = "new.lua" },
      { id = "a", text = "a.lua" },
      { id = "b", text = "b.lua 1 thread", value = "b" },
      { id = "c", text = "c.lua" },
    },
  })
  child.lua("_G.panel:update()")
  wait_for_lines("snacks_picker_list", { "new.lua", "a.lua", "b.lua 1 thread", "c.lua" })
  wait_for(function()
    return child.api.nvim_win_get_cursor(find_win("snacks_picker_list"))[1] == 3
  end, "the cursor on line 3")
  child.type_keys("x")
  wait_for_global("marked", "b")
end

T["panel()"]["the key of an action calls its fn with the item under the cursor"] = function()
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  child.type_keys("jj", "x")
  wait_for_global("marked", "a2")
  eq(is_open(), true)
end

T["panel()"]["does not show in a different tabpage"] = function()
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  child.cmd("tabnew")
  settle()
  eq(#child.api.nvim_tabpage_list_wins(0), 1)
  eq(find_win("snacks_picker_list"), 0)

  child.cmd("tabprevious")
  settle()
  eq(is_open(), true)
  eq(lines("snacks_picker_list"), { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })
end

T["panel()"]["uses width and position"] = function()
  open_panel({ width = 0.25, position = "right" })
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  local win = find_win("snacks_picker_list")
  eq(child.api.nvim_win_get_width(win), 30)
  local col = child.fn.win_screenpos(win)[2]
  eq(col > 90, true)
end

T["panel()"]["stays open with no items, and an action gets no item"] = function()
  child.lua("_G.items = {}")
  open_panel()
  wait_for(function()
    return child.api.nvim_get_current_win() == find_win("snacks_picker_list")
  end, "the focus in the panel")
  settle()
  eq(is_open(), true)

  child.type_keys("x")
  wait_for_global("marked", "no item")
end

T["panel()"]["close() closes the panel"] = function()
  open_panel()
  wait_for_lines("snacks_picker_list", { "a.lua", "├╴thread 1", "└╴thread 2", "b.lua" })

  child.lua("_G.panel:close()")
  eq(is_open(), false)
  settle()
  eq(find_win("snacks_picker_list"), 0)
end

T["health() reports OK"] = function()
  child.cmd("runtime plugin/didymus.lua")
  -- The default provider runs `gh auth status`, which uses the network.
  child.lua('require("didymus").setup({ review = { provider = "test" } })')
  child.cmd("checkhealth didymus")
  local report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  MiniTest.expect.no_equality(
    report:find("OK snacks.nvim is available (review.picker)", 1, true),
    nil
  )
end

return T
