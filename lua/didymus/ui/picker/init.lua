--- The picker interface. It does not know about agents, diffs or reviews.
--- See docs/architecture/review.md#picker-interface.

---@class didymus.picker.Item
---@field text string Plain text, for search and for pickers with no highlights.
---@field id? string A stable key. `update()` uses it to keep the cursor on the same item. Default `text`.
---@field segments? [string, string?][] Text and highlight group, for pickers with highlights.
---@field depth? integer The indent in a tree. 0 is the top level. Default 0.
---@field location? { path: string, line: integer? } A file to show in the preview.
---@field preview? { lines: string[], filetype: string? } Text to show in the preview.
---@field value any The data that the caller gets back.

---@class didymus.picker.Action
---@field key string
---@field name string
---@field fn fun(item: didymus.picker.Item?) The item under the cursor. Nil if the panel is empty.

---@class didymus.picker.SelectOpts
---@field title string
---@field items didymus.picker.Item[]
---@field on_choose fun(item: didymus.picker.Item) The picker closes first.
---@field on_cancel? fun()

---@class didymus.picker.PanelOpts
---@field title string
---@field items fun(): didymus.picker.Item[] The panel calls it on open and on `update()`.
---@field on_choose fun(item: didymus.picker.Item) The panel stays open, and its window stays current.
---@field actions? didymus.picker.Action[] Keys in the panel, such as `R` for refresh.
---@field position? "left"|"right" Default "left".
---@field width? number Below 1, a fraction of the editor width. Else columns. Default 40.

---@class didymus.picker.Panel
---@field update fun(self) Call `items()` again and show the new items. Keep the cursor on the same item.
---@field focus fun(self)
---@field close fun(self)
---@field is_open fun(self): boolean

---@class didymus.picker.Adapter
---@field select fun(opts: didymus.picker.SelectOpts)
---@field panel fun(opts: didymus.picker.PanelOpts): didymus.picker.Panel
---@field health fun() Report the dependencies with `vim.health`.

local M = {}

M.default_width = 40

local builtin = {
  snacks = "didymus.ui.picker.snacks",
  test = "didymus.ui.picker.test",
}

--- The adapter of `spec`: the name of a built-in adapter, or an adapter table.
---@param spec string|didymus.picker.Adapter
---@return didymus.picker.Adapter? adapter
---@return string? err
function M.get(spec)
  if type(spec) == "table" then
    return spec
  end
  local module = builtin[spec]
  if not module then
    return nil,
      ('unknown picker %q. Use "snacks", "test" or an adapter table.'):format(tostring(spec))
  end
  return require(module)
end

---@param item didymus.picker.Item
---@return string
function M.id(item)
  return item.id or item.text
end

--- The index of the item with `id`, else nil.
---@param items didymus.picker.Item[]
---@param id string?
---@return integer?
function M.find(items, id)
  for index, item in ipairs(items) do
    if M.id(item) == id then
      return index
    end
  end
end

return M
