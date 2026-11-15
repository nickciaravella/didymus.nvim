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

---@param snacks_item table?
---@return boolean
local function has_preview(snacks_item)
  return snacks_item ~= nil and (snacks_item.preview ~= nil or snacks_item.file ~= nil)
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

--- A preview in the main window is a float over the code. Show it only for an item with a preview,
--- and only while the picker has the focus.
local function update_main_preview(snacks_picker)
  if snacks_picker.closed or not snacks_picker.preview.main then
    return
  end
  local show = has_preview(snacks_picker:current()) and snacks_picker:is_focused()
  if show == snacks_picker.layout:is_hidden("preview") then
    snacks_picker:toggle("preview", { enable = show })
  end
end

--- The snacks options of each kind. The user options of the kind go over them.
local kind_defaults = {
  changes = { layout = { preset = "default" } },
  choice = { layout = { preset = "select" } },
}

--- Merge the options: first `base`, then the options of the kind, then the user options of the
--- kind, then `required`. didymus needs the options in `required`, so the user cannot change them.
---@param kind didymus.picker.Kind?
---@param config didymus.picker.Config?
---@param base table
---@param required table
---@return table
local function merge_options(kind, config, base, required)
  local kind_config = config and kind and config[kind]
  local user = kind_config and kind_config.snacks or {}
  -- `tbl_deep_extend()` does not copy a table that only one argument has, and snacks can change it.
  return vim.tbl_deep_extend(
    "force",
    base,
    vim.deepcopy(kind_defaults[kind] or {}),
    vim.deepcopy(user),
    required
  )
end

---@param opts didymus.picker.SelectOpts
---@param config didymus.picker.Config?
function M.select(opts, config)
  local done = false
  require_snacks_picker().pick(merge_options(opts.kind, config, {
    title = opts.title,
    preview = preview,
  }, {
    items = to_snacks_items(opts.items),
    format = format,
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
  }))
end

---@class didymus.picker.snacks.Panel: didymus.picker.Panel
---@field private picker table The snacks picker.
local Panel = {}
Panel.__index = Panel

---@param opts didymus.picker.PanelOpts
---@param config didymus.picker.Config?
---@return didymus.picker.Panel
function M.panel(opts, config)
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

  local snacks_picker = require_snacks_picker().pick(merge_options(opts.kind, config, {
    title = opts.title,
    -- The options of the snacks explorer, so that the panel stays open next to the code.
    layout = {
      preset = "sidebar",
      preview = "main",
      layout = { position = opts.position or "left", width = width, min_width = width },
    },
    preview = preview,
    on_change = update_main_preview,
    auto_close = false,
    jump = { close = false },
    focus = "list",
    tree = true,
    -- A search keeps the order of the tree.
    sort = { fields = { "idx" } },
  }, {
    finder = function()
      return to_snacks_items(opts.items())
    end,
    format = format,
    show_empty = true,
    confirm = function(snacks_picker, snacks_item)
      if snacks_item then
        snacks_picker:norm(function()
          opts.on_choose(snacks_item.didymus_item)
        end)
      end
    end,
    actions = actions,
    win = { list = { keys = keys } },
  }))
  -- snacks shows the main preview again only when the focus goes to a window that is not a float.
  -- The list of a sidebar is a float.
  snacks_picker.list.win:on("WinEnter", function()
    update_main_preview(snacks_picker)
  end, { buf = true })
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
