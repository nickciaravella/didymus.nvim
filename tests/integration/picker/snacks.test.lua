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

--- The preview window of the current tabpage, else 0.
---@return integer
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

--- Open a select of `kind` through `get()`, as the review does.
---@param kind string?
---@param config string? The Lua source of the config. A function cannot go through RPC.
local function open_select(kind, config)
  child.lua(
    [[
      local kind, config = ...
      _G.chosen = vim.NIL
      require("didymus.ui.picker").get("snacks", loadstring("return " .. config)()).select({
        title = "Kind",
        kind = kind,
        items = {
          { text = "one", value = 1, preview = { lines = { "preview of one" } } },
          { text = "two", value = 2, preview = { lines = { "preview of two" } } },
        },
        on_choose = function(item)
          _G.chosen = item.value
        end,
      })
    ]],
    { kind, config or "{}" }
  )
  wait_for_lines("snacks_picker_list", { "one", "two" })
end

T["select() kinds"] = MiniTest.new_set()

T["select() kinds"]["changes shows the preview on the right of the list"] = function()
  open_select("changes")
  wait_for_lines("snacks_picker_preview", { "preview of one" })
  local list_col = child.fn.win_screenpos(find_win("snacks_picker_list"))[2]
  local preview_col = child.fn.win_screenpos(find_win("snacks_picker_preview"))[2]
  eq(preview_col > list_col + 20, true)
end

T["select() kinds"]["choice shows no preview"] = function()
  open_select("choice")
  settle()
  eq(preview_win(), 0)
end

T["select() kinds"]["the user options of the kind go over the defaults, but not over the callbacks"] = function()
  open_select(
    "changes",
    [[{
      changes = { snacks = { layout = { preset = "select" }, confirm = function() _G.chosen = "user" end } },
      choice = { snacks = { layout = { preset = "default" } } },
    }]]
  )
  settle()
  eq(preview_win(), 0)

  child.type_keys("<CR>")
  wait_for_global("chosen", 1)
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

local preview_items = {
  { text = "header" },
  {
    text = "numbers.txt",
    location = { path = "tests/fixtures/picker/numbers.txt", line = 20 },
    value = "numbers",
  },
  { text = "text", preview = { lines = { "a text preview" } } },
}

---@param expected integer
local function wait_for_preview_line(expected)
  wait_for(function()
    local win = preview_win()
    return win ~= 0 and child.api.nvim_win_get_cursor(win)[1] == expected
  end, "the preview at line " .. expected)
end

T["panel()"]["a cursor move shows the item in the code window, and a header shows no preview"] = function()
  child.lua("_G.items = ...", { preview_items })
  open_panel()
  wait_for_lines("snacks_picker_list", { "header", "numbers.txt", "text" })
  settle()
  eq(preview_win(), 0)

  child.type_keys("j")
  wait_for_preview_line(20)
  local win = preview_win()
  local win_config = child.api.nvim_win_get_config(win)
  eq({ win_config.relative, win_config.win }, { "win", child.lua_get("_G.code_win") })
  local buf = child.api.nvim_win_get_buf(win)
  eq(child.api.nvim_buf_get_lines(buf, 19, 20, false), { "line 20" })

  child.type_keys("j")
  wait_for_lines("snacks_picker_preview", { "a text preview" })

  child.type_keys("gg")
  wait_for(function()
    return preview_win() == 0
  end, "no preview on the header")

  child.type_keys("j", "<CR>")
  wait_for_global("chosen", { "numbers" })
  eq(is_open(), true)
end

T["panel()"]["the preview hides while the focus is in the code window"] = function()
  child.lua("_G.items = ...", { { preview_items[2] } })
  open_panel()
  wait_for_preview_line(20)

  child.lua("vim.api.nvim_set_current_win(_G.code_win)")
  settle()
  eq(preview_win(), 0)
  child.lua("_G.panel:update()")
  settle()
  eq(preview_win(), 0)

  child.lua("_G.panel:focus()")
  wait_for_preview_line(20)
end

T["panel()"]["with buffer_preview, a buffer that is not ready keeps the last buffer in the preview"] = function()
  child.lua("_G.items = ...", {
    {
      preview_items[2],
      { text = "list.json", location = { path = "tests/fixtures/github/list.json", line = 1 } },
    },
  })
  child.lua([[
    _G.shows, _G.hides, _G.ready = {}, 0, { ["tests/fixtures/picker/numbers.txt"] = true }
    _G.code_win = vim.api.nvim_get_current_win()
    _G.panel = require("didymus.ui.picker.snacks").panel({
      title = "Panel",
      items = function() return _G.items end,
      on_choose = function() end,
      buffer_preview = {
        get_buf = function(item, cb)
          local path = item.location.path
          if not _G.ready[path] then
            _G.pending = cb
            return nil
          end
          local buf = vim.fn.bufadd(path)
          vim.fn.bufload(buf)
          return buf
        end,
        on_show = function(item, win)
          local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), ":t")
          table.insert(_G.shows, { text = item.text, win = win, name = name })
        end,
        on_hide = function() _G.hides = _G.hides + 1 end,
      },
    })
  ]])
  wait_for_preview_line(20)
  local win = preview_win()
  local buf = child.fn.bufnr("tests/fixtures/picker/numbers.txt")
  eq(child.api.nvim_win_get_buf(win), buf)
  eq(
    child.lua_get("_G.shows[#_G.shows]"),
    { text = "numbers.txt", win = win, name = "numbers.txt" }
  )

  local show_count = child.lua_get("#_G.shows")
  child.type_keys("j")
  wait_for(function()
    return child.lua_get("_G.pending ~= nil")
  end, "get_buf() of list.json")
  settle()
  eq(child.api.nvim_win_get_buf(win), buf)
  eq(child.lua_get("#_G.shows"), show_count)

  child.lua("_G.ready['tests/fixtures/github/list.json'] = true; _G.pending()")
  wait_for_preview_line(1)
  eq(child.lua_get("_G.shows[#_G.shows]").name, "list.json")

  child.lua("vim.api.nvim_set_current_win(_G.code_win)")
  settle()
  eq(preview_win(), 0)
  eq(child.lua_get("_G.hides"), 1)
end

T["panel()"]["the user options of files go over the defaults"] = function()
  child.lua("_G.items = ...", { preview_items })
  child.lua([[
    _G.panel = require("didymus.ui.picker").get("snacks", {
      files = { snacks = { layout = { layout = { width = 50, min_width = 50 } } } },
    }).panel({ title = "Files", kind = "files", items = function() return _G.items end, on_choose = function() end })
  ]])
  wait_for_lines("snacks_picker_list", { "header", "numbers.txt", "text" })
  eq(child.api.nvim_win_get_width(find_win("snacks_picker_list")), 50)
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
