--- The picker adapter for snacks.nvim.

local layout = require("didymus.ui.layout")
local picker = require("didymus.ui.picker")

local M = {}

---@return table? snacks_picker `Snacks.picker`, or nil if snacks.nvim is not available.
local function get_snacks_picker()
  local ok, snacks_picker = pcall(function()
    return require("snacks").picker
  end)
  return ok and snacks_picker or nil
end

---@return table
local function require_snacks_picker()
  return get_snacks_picker()
    or error("didymus: snacks.nvim is not available. See :checkhealth didymus.", 0)
end

--- The snacks tree formatter draws the indent from `parent` and `last`.
---@param items didymus.picker.Item[]
---@return table[]
local function to_snacks_items(items)
  local result = {}
  -- `parents[depth + 1]` is the last item at `depth`.
  local parents = {}
  local last_child = {}
  for _, item in ipairs(items) do
    local depth = item.depth or 0
    local location = item.location
    local snacks_item = {
      text = item.text,
      didymus_item = item,
      parent = parents[depth],
      last = true,
      file = location and location.path,
      pos = location and location.line and { location.line, 0 },
      preview = item.preview and {
        text = table.concat(item.preview.lines, "\n"),
        ft = item.preview.filetype,
        loc = false,
      },
    }
    for key = #parents, depth + 2, -1 do
      parents[key] = nil
    end
    parents[depth + 1] = snacks_item
    local parent = snacks_item.parent
    if parent then
      if last_child[parent] then
        last_child[parent].last = false
      end
      last_child[parent] = snacks_item
    end
    table.insert(result, snacks_item)
  end
  return result
end

local function format(snacks_item, snacks_picker)
  local result = snacks_item.parent
      and require("snacks").picker.format.tree(snacks_item, snacks_picker)
    or {}
  local item = snacks_item.didymus_item
  for _, segment in ipairs(item.segments or { { item.text } }) do
    table.insert(result, { segment[1], segment[2] })
  end
  return result
end

local function preview(ctx)
  local previewers = require("snacks").picker.preview
  if ctx.item.preview then
    return previewers.preview(ctx)
  elseif ctx.item.file then
    return previewers.file(ctx)
  end
  ctx.preview:reset()
end

---@param opts didymus.picker.SelectOpts
function M.select(opts)
  local done = false
  require_snacks_picker().pick({
    title = opts.title,
    items = to_snacks_items(opts.items),
    format = format,
    preview = preview,
    confirm = function(snacks_picker, snacks_item)
      if done then
        return
      end
      done = true
      snacks_picker:close()
      -- snacks closes its windows in a scheduled callback. Wait for it, as its `vim.ui.select` does.
      vim.schedule(function()
        if snacks_item then
          opts.on_choose(snacks_item.didymus_item)
        elseif opts.on_cancel then
          opts.on_cancel()
        end
      end)
    end,
    on_close = function()
      if done then
        return
      end
      done = true
      if opts.on_cancel then
        vim.schedule(opts.on_cancel)
      end
    end,
  })
end

---@class didymus.picker.snacks.Panel: didymus.picker.Panel
---@field private picker table The snacks picker.
local Panel = {}
Panel.__index = Panel

---@param opts didymus.picker.PanelOpts
---@return didymus.picker.Panel
function M.panel(opts)
  local width = layout.resolve_size(opts.width or picker.default_width, vim.o.columns)
  local actions, keys = {}, {}
  for index, action in ipairs(opts.actions or {}) do
    local name = "didymus_action_" .. index
    actions[name] = {
      desc = action.name,
      action = function(_, snacks_item)
        action.fn(snacks_item and snacks_item.didymus_item)
      end,
    }
    keys[action.key] = name
  end

  local snacks_picker = require_snacks_picker().pick({
    title = opts.title,
    finder = function()
      return to_snacks_items(opts.items())
    end,
    format = format,
    -- The options of the snacks explorer, so that the panel stays open next to the code.
    layout = {
      preset = "sidebar",
      -- The sidebar shows the preview in the code window.
      preview = false,
      layout = { position = opts.position or "left", width = width, min_width = width },
    },
    auto_close = false,
    jump = { close = false },
    focus = "list",
    tree = true,
    show_empty = true,
    -- A search keeps the order of the tree.
    sort = { fields = { "idx" } },
    confirm = function(snacks_picker, snacks_item)
      if snacks_item then
        snacks_picker:norm(function()
          opts.on_choose(snacks_item.didymus_item)
        end)
      end
    end,
    actions = actions,
    win = { list = { keys = keys } },
  })
  return setmetatable({ picker = snacks_picker }, Panel)
end

function Panel:update()
  local snacks_picker = self.picker
  if snacks_picker.closed then
    return
  end
  local current = snacks_picker:current()
  local id = current and picker.id(current.didymus_item)
  -- `refresh()` keeps the cursor on the same index. Find the same item after the update.
  snacks_picker.list:set_target()
  snacks_picker:find({
    on_done = function()
      if snacks_picker.closed then
        return
      end
      local items = vim.tbl_map(function(snacks_item)
        return snacks_item.didymus_item
      end, snacks_picker:items())
      local index = picker.find(items, id)
      if index then
        snacks_picker.list:view(index)
      end
    end,
  })
end

function Panel:focus()
  self.picker:focus("list")
end

function Panel:close()
  self.picker:close()
end

---@return boolean
function Panel:is_open()
  return not self.picker.closed
end

function M.health()
  if get_snacks_picker() then
    vim.health.ok("snacks.nvim is available (review.picker)")
  else
    vim.health.error(
      "snacks.nvim is not available (review.picker)",
      "Install snacks.nvim, or set `review.picker`."
    )
  end
end

return M
