--- A picker adapter with no UI, for end-to-end tests. It records each call. The functions
--- `choose()`, `cancel()` and `press()` act as the user on the last open picker.

local picker = require("didymus.ui.picker")

---@class didymus.picker.test.Call
---@field kind "select"|"panel"
---@field opts didymus.picker.SelectOpts|didymus.picker.PanelOpts
---@field items didymus.picker.Item[] The items that show now.
---@field cursor integer The index of the item under the cursor.
---@field open boolean
---@field focus_count integer The number of `focus()` calls of a panel.

local M = {}

---@type didymus.picker.test.Call[]
M.calls = {}

---@param kind "select"|"panel"
---@param opts didymus.picker.SelectOpts|didymus.picker.PanelOpts
---@param items didymus.picker.Item[]
---@return didymus.picker.test.Call
local function record(kind, opts, items)
  local call = { kind = kind, opts = opts, items = items, cursor = 1, open = true, focus_count = 0 }
  table.insert(M.calls, call)
  return call
end

---@param opts didymus.picker.SelectOpts
function M.select(opts)
  record("select", opts, opts.items)
end

---@class didymus.picker.test.Panel: didymus.picker.Panel
---@field call didymus.picker.test.Call
local Panel = {}
Panel.__index = Panel

---@param opts didymus.picker.PanelOpts
---@return didymus.picker.Panel
function M.panel(opts)
  return setmetatable({ call = record("panel", opts, opts.items()) }, Panel)
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

function Panel:close()
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

return M
