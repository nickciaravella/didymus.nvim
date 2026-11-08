local helpers = dofile("tests/e2e/agent/helpers.lua")

local eq = MiniTest.expect.equality
local no_eq = MiniTest.expect.no_equality

local child = MiniTest.new_child_neovim()

local fake_cmd, wait_for = helpers.fake_cmd, helpers.wait_for

---@param agent table?
local function setup(agent)
  child.lua(
    "require('didymus').setup(...)",
    { { agent = vim.tbl_extend("force", { cmd = fake_cmd("--name", "config") }, agent or {}) } }
  )
end

---@param opts table?
local function toggle(opts)
  child.lua("require('didymus.agent').toggle(...)", { opts })
end

---@return integer?
local function agent_buf()
  return helpers.agent_buf(child)
end

---@return integer
local function agent_pid()
  return child.lua_get("vim.fn.jobpid(vim.bo[...].channel)", { agent_buf() })
end

--- The windows that show the agent buffer, as "float" or "split".
---@return string[]
local function agent_views()
  local views = {}
  for _, win in ipairs(child.api.nvim_list_wins()) do
    if child.api.nvim_win_get_buf(win) == agent_buf() then
      local relative = child.api.nvim_win_get_config(win).relative
      table.insert(views, relative == "" and "split" or "float")
    end
  end
  return views
end

---@return { row: integer, col: integer, width: integer, height: integer }
local function current_float()
  local win_config = child.api.nvim_win_get_config(0)
  no_eq(win_config.relative, "")
  return {
    row = win_config.row,
    col = win_config.col,
    width = win_config.width,
    height = win_config.height,
  }
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 24, 80
      child.cmd("runtime plugin/didymus.lua")
      setup()
    end,
    post_once = child.stop,
  },
})

T["the float is in the center of the editor, with the default size and a border"] = function()
  child.o.winborder = "single"
  child.cmd("Didymus agent toggle float")
  helpers.wait_for_text(child, "fake agent config")

  -- 23 rows above the command line. The border adds 2 columns and 2 rows.
  eq(current_float(), { row = 1, col = 5, width = 68, height = 19 })
  eq(child.api.nvim_win_get_config(0).border[1], "┌")
  eq(child.api.nvim_get_current_buf(), agent_buf())
  eq(child.wo.number, false)
  MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["the inside of the float has the code background, and an empty 'winborder' gives a border"] = function()
  child.cmd("hi Normal guibg=#111111 | hi NormalFloat guibg=#444444 | hi FloatBorder guibg=#222222")
  child.o.winborder = ""
  child.cmd("Didymus agent toggle float")
  helpers.wait_for_text(child, "fake agent config")
  eq(child.api.nvim_win_get_config(0).border[1], "╭")

  -- Two floats on top of the agent float: one with the code background, and one with the float
  -- background. They do not take the focus.
  child.lua([[
    for row, winhighlight in pairs({ [15] = "NormalFloat:Normal", [17] = "" }) do
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor", row = row, col = 10, width = 5, height = 1, zindex = 100,
      })
      vim.wo[win].winhighlight = winhighlight
    end
  ]])
  local attr = child.get_screenshot().attr
  -- Row 10 is in the agent float, and row 2 is its top border.
  eq(attr[10][40], attr[16][12])
  no_eq(attr[10][40], attr[18][12])
  no_eq(attr[2][40], attr[10][40])
end

T["agent.float sets the size, and a float that is too large fits in the editor"] = function()
  setup({ float = { width = 40, height = 10 } })
  child.o.winborder = "none"
  toggle({ view = "float" })
  eq(current_float(), { row = 5, col = 19, width = 40, height = 10 })
  toggle()

  setup({ float = { width = 200, height = 0.5 } })
  child.o.winborder = "single"
  toggle({ view = "float" })
  eq(current_float(), { row = 5, col = 0, width = 78, height = 11 })
end

T["the float goes to the center again when the editor changes size"] = function()
  toggle({ view = "float" })
  child.o.columns = 100
  child.api.nvim_exec_autocmds("VimResized", {})
  eq(current_float(), { row = 1, col = 6, width = 85, height = 19 })
end

T["agent.view sets the default, and the view option overrides it"] = function()
  setup({ view = "float" })
  child.cmd("Didymus agent toggle")
  eq(agent_views(), { "float" })
  child.cmd("Didymus agent toggle")
  eq(agent_views(), {})

  child.cmd("Didymus agent stop")
  child.cmd("Didymus agent toggle split")
  eq(agent_views(), { "split" })
end

T["toggle with a view shows that view, and closes the other view"] = function()
  child.cmd("Didymus agent toggle split")
  helpers.wait_for_text(child, "fake agent config")
  local buf, pid = agent_buf(), agent_pid()

  child.cmd("Didymus agent toggle float")
  eq(agent_views(), { "float" })
  eq(#child.api.nvim_list_wins(), 2)

  toggle({ view = "split" })
  eq(agent_views(), { "split" })
  eq(#child.api.nvim_list_wins(), 2)

  eq(agent_buf(), buf)
  eq(agent_pid(), pid)
  eq(child.lua_get("require('didymus.agent').current():is_running()"), true)
end

T["toggle hides and shows the float"] = function()
  child.cmd("Didymus agent toggle float")
  eq(agent_views(), { "float" })
  child.cmd("Didymus agent toggle float")
  eq(agent_views(), {})

  -- With no view, toggle uses the last view.
  child.cmd("Didymus agent toggle")
  eq(agent_views(), { "float" })
  child.cmd("Didymus agent toggle")
  eq(agent_views(), {})
end

T["the float hides when the focus goes to a different window"] = function()
  local code_win = child.api.nvim_get_current_win()
  child.cmd("Didymus agent toggle float")
  helpers.wait_for_text(child, "fake agent config")
  local pid = agent_pid()

  child.api.nvim_set_current_win(code_win)
  wait_for(function()
    return #agent_views() == 0
  end, "the float hides")
  eq(agent_pid(), pid)

  child.cmd("Didymus agent toggle")
  eq(agent_views(), { "float" })
end

T["agent.keys.leave goes back to the code, and the float hides"] = function()
  setup({ keys = { leave = "<C-a>" } })
  local code_win = child.api.nvim_get_current_win()
  child.cmd("Didymus agent toggle float")
  helpers.wait_for_text(child, "fake agent config")
  wait_for(function()
    return child.api.nvim_get_mode().mode == "t"
  end, "terminal mode")

  child.type_keys("<C-a>")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(child.api.nvim_get_mode().mode, "n")
  wait_for(function()
    return #agent_views() == 0
  end, "the float hides")

  -- The split stays visible.
  child.cmd("Didymus agent toggle split")
  child.type_keys("<C-\\><C-n>", "<C-a>")
  eq(child.api.nvim_get_current_win(), code_win)
  eq(agent_views(), { "split" })
end

T["agent.keys.focus shows and focuses the agent"] = function()
  eq(child.fn.maparg("<C-a>", "n"), "")
  setup({ keys = { focus = "<C-a>" } })
  child.type_keys("<C-a>")
  eq(agent_views(), { "split" })
  eq(child.api.nvim_get_current_buf(), agent_buf())

  child.cmd("wincmd p")
  child.type_keys("<C-a>")
  eq(agent_views(), { "split" })
  eq(child.api.nvim_get_current_buf(), agent_buf())

  setup()
  eq(child.fn.maparg("<C-a>", "n"), "")
end

T[":Didymus agent focus shows the view, and does not hide it"] = function()
  child.cmd("Didymus agent focus split")
  child.cmd("Didymus agent focus split")
  eq(agent_views(), { "split" })

  child.cmd("Didymus agent focus float")
  eq(agent_views(), { "float" })
  eq(child.fn.getcompletion("Didymus agent focus ", "cmdline"), { "float", "split" })
end

T["an unknown view shows an error and does not start the agent"] = function()
  toggle({ view = "tab" })
  eq(child.lua_get("require('didymus.agent').current()"), vim.NIL)
  no_eq(child.cmd_capture("messages"):find('unknown view "tab"', 1, true), nil)
end

return T
