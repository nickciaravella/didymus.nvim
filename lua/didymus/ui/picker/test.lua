--- A picker adapter with no UI, for end-to-end tests. It records each call. The functions
--- `choose()`, `cancel()`, `press()`, `preview()` and `hide_preview()` act as the user on the last
--- open picker.

local picker = require("didymus.ui.picker")

---@class didymus.picker.test.Call
---@field kind "select"|"panel" The role. `opts.kind` is the kind of list, such as "files".
---@field opts didymus.picker.SelectOpts|didymus.picker.PanelOpts
---@field config didymus.picker.Config?
---@field items didymus.picker.Item[] The items that show now.
---@field cursor integer The index of the item under the cursor.
---@field open boolean
---@field focus_count integer The number of `focus()` calls of a panel.
---@field preview_win integer? The float of the preview, as the snacks sidebar has.
---@field preview_count integer The number of previews. Only the `ready()` of the newest one applies.
---@field preview_bufs didymus.picker.PreviewBufs

local M = {}

---@type didymus.picker.test.Call[]
M.calls = {}

---@param kind "select"|"panel"
---@param opts didymus.picker.SelectOpts|didymus.picker.PanelOpts
---@param config didymus.picker.Config?
---@param items didymus.picker.Item[]
---@return didymus.picker.test.Call
local function record(kind, opts, config, items)
  local call = {
    kind = kind,
    opts = opts,
    config = config,
    items = items,
    cursor = 1,
    open = true,
    focus_count = 0,
    preview_count = 0,
    preview_bufs = picker.new_preview_bufs(),
  }
  table.insert(M.calls, call)
  return call
end

---@param opts didymus.picker.SelectOpts
---@param config didymus.picker.Config?
function M.select(opts, config)
  record("select", opts, config, opts.items)
end

---@class didymus.picker.test.Panel: didymus.picker.Panel
---@field call didymus.picker.test.Call
local Panel = {}
Panel.__index = Panel

---@param opts didymus.picker.PanelOpts
---@param config didymus.picker.Config?
---@return didymus.picker.Panel
function M.panel(opts, config)
  return setmetatable({ call = record("panel", opts, config, opts.items()) }, Panel)
end

function Panel:update()
  local call = self.call
  if not call.open then
    return
  end
  local current = call.items[call.cursor]
  call.items = call.opts.items()
  call.cursor = current and picker.find(call.items, picker.id(current)) or 1
end

function Panel:focus()
  self.call.focus_count = self.call.focus_count + 1
end

---@param call didymus.picker.test.Call
local function hide_preview(call)
  local win = call.preview_win
  if not win then
    return
  end
  call.preview_win = nil
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if call.opts.on_preview then
    call.opts.on_preview(nil, nil)
  end
  call.preview_bufs:release()
end

function Panel:close()
  hide_preview(self.call)
  self.call.open = false
end

---@return boolean
function Panel:is_open()
  return self.call.open
end

function M.health()
  vim.health.ok("the test picker is configured (review.picker)")
end

---@param kind ("select"|"panel")?
---@return didymus.picker.test.Call
local function last_open(kind)
  for index = #M.calls, 1, -1 do
    local call = M.calls[index]
    if call.open and (not kind or call.kind == kind) then
      return call
    end
  end
  error(("no open %s"):format(kind or "picker"), 3)
end

--- Move the cursor to `target`: the index or the text of an item. Nil keeps the cursor.
---@param call didymus.picker.test.Call
---@param target (integer|string)?
local function move(call, target)
  local index = target
  if type(target) == "string" then
    index = nil
    for item_index, item in ipairs(call.items) do
      if item.text == target then
        index = item_index
        break
      end
    end
  end
  if target ~= nil and not call.items[index] then
    error(("no item %s"):format(vim.inspect(target)), 3)
  end
  call.cursor = index or call.cursor
end

--- Choose an item in the last open picker. A select closes first. A panel stays open.
---@param target (integer|string)? The index or the text of an item. Nil is the item under the cursor.
function M.choose(target)
  local call = last_open()
  move(call, target)
  local item = call.items[call.cursor]
  if not item then
    error("no item to choose", 2)
  end
  if call.kind == "select" then
    call.open = false
  end
  call.opts.on_choose(item)
end

--- Close the last open picker with no choice.
function M.cancel()
  local call = last_open()
  call.open = false
  if call.opts.on_cancel then
    call.opts.on_cancel()
  end
end

--- Press the key of an action in the last open panel.
---@param key string
---@param target (integer|string)? The index or the text of an item. Nil is the item under the cursor.
function M.press(key, target)
  local call = last_open("panel")
  move(call, target)
  for _, action in ipairs(call.opts.actions or {}) do
    if action.key == key then
      action.fn(call.items[call.cursor])
      return
    end
  end
  error(("no action for %q"):format(key), 2)
end

--- Show the item in the preview float of the last open panel, as a cursor move in the panel does.
--- A `location` shows the real buffer of the file. Call `on_preview`. Hide the float until its
--- `ready()`, if it returns true.
---@param target (integer|string)? The index or the text of an item. Nil is the item under the cursor.
---@return integer win The preview float.
function M.preview(target)
  local call = last_open("panel")
  move(call, target)
  local item = call.items[call.cursor]
  local location = item and item.location
  local buf = location and call.preview_bufs:load(location.path)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  if call.preview_win and vim.api.nvim_win_is_valid(call.preview_win) then
    vim.api.nvim_win_set_buf(call.preview_win, buf)
  else
    call.preview_win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 40,
      height = 10,
    })
  end
  if location and location.line then
    pcall(vim.api.nvim_win_set_cursor, call.preview_win, { location.line, 0 })
  end
  local win, wait, is_ready = call.preview_win, false, false
  call.preview_count = call.preview_count + 1
  local count = call.preview_count
  if call.opts.on_preview then
    wait = call.opts.on_preview(item, win, function()
      is_ready = true
      if call.preview_count == count and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, { hide = false })
      end
    end)
  end
  vim.api.nvim_win_set_config(win, { hide = wait == true and not is_ready })
  call.preview_bufs:release(buf)
  return call.preview_win
end

--- Close the preview float of the last open panel, as a move of the focus out of the panel does.
function M.hide_preview()
  hide_preview(last_open("panel"))
end

return M
