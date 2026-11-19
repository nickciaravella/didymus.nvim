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

---@alias didymus.picker.Kind
---| "changes" The list of changes, such as the PR list.
---| "choice" A short list of choices, such as a confirm prompt or the verdict.
---| "files" The files panel.

--- The options of each kind, such as `review.picker_config`. `config[kind][adapter_name]` has the
--- options of one adapter. Each adapter reads its own options.
---@alias didymus.picker.Config table<didymus.picker.Kind|string, table<string, table>>

---@class didymus.picker.SelectOpts
---@field title string
---@field kind? didymus.picker.Kind The adapter uses the options of this kind.
---@field items didymus.picker.Item[]
---@field on_choose fun(item: didymus.picker.Item) The picker closes first.
---@field on_cancel? fun()

---@class didymus.picker.PanelOpts
---@field title string
---@field kind? didymus.picker.Kind The adapter uses the options of this kind.
---@field items fun(): didymus.picker.Item[] The panel calls it on open and on `update()`.
---@field on_choose fun(item: didymus.picker.Item) The panel stays open, and its window stays current.
---@field actions? didymus.picker.Action[] Keys in the panel, such as `R` for refresh.
---@field position? "left"|"right" Default "left".
---@field width? number Below 1, a fraction of the editor width. Else columns. Default 40.
---@field on_preview? fun(item: didymus.picker.Item?, win: integer?) Called after the preview shows `item` in `win`, and with nil when the preview hides. With it, the preview of a `location` shows the real buffer of the file, not a copy.

---@class didymus.picker.Panel
---@field update fun(self) Call `items()` again and show the new items. Keep the cursor on the same item.
---@field focus fun(self)
---@field close fun(self)
---@field is_open fun(self): boolean

---@class didymus.picker.Adapter
---@field select fun(opts: didymus.picker.SelectOpts, config: didymus.picker.Config?)
---@field panel fun(opts: didymus.picker.PanelOpts, config: didymus.picker.Config?): didymus.picker.Panel
---@field health fun() Report the dependencies with `vim.health`.

local M = {}

M.default_width = 40

local builtin = {
  snacks = "didymus.ui.picker.snacks",
  test = "didymus.ui.picker.test",
}

--- The adapter of `spec`, with `config`: `select()` and `panel()` give `config` to the adapter.
---@param spec string|didymus.picker.Adapter The name of a built-in adapter, or an adapter table.
---@param config didymus.picker.Config?
---@return didymus.picker.Adapter? adapter
---@return string? err
function M.get(spec, config)
  local adapter = spec
  if type(spec) ~= "table" then
    local module = builtin[spec]
    if not module then
      return nil,
        ('unknown picker %q. Use "snacks", "test" or an adapter table.'):format(tostring(spec))
    end
    adapter = require(module)
  end
  ---@cast adapter didymus.picker.Adapter
  config = config or {}
  return {
    select = function(opts)
      return adapter.select(opts, config)
    end,
    panel = function(opts)
      return adapter.panel(opts, config)
    end,
    health = adapter.health,
  }
end

---@param item didymus.picker.Item
---@return string
function M.id(item)
  return item.id or item.text
end

--- The plain text of the segments of an item.
---@param segments [string, string?][]
---@return string
function M.join_segments(segments)
  local texts = vim.tbl_map(function(segment)
    return segment[1]
  end, segments)
  return table.concat(texts)
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

--- The buffers that a preview loaded. A buffer that only the preview loaded must not stay loaded,
--- because the load can start an LSP client.
---@class didymus.picker.PreviewBufs
---@field private loaded table<integer, { existed: boolean, listed: boolean }> The state of each buffer before the preview loaded it.
local PreviewBufs = {}
PreviewBufs.__index = PreviewBufs

---@return didymus.picker.PreviewBufs
function M.new_preview_bufs()
  return setmetatable({ loaded = {} }, PreviewBufs)
end

--- The loaded buffer of `path`.
---@param path string
---@return integer
function PreviewBufs:load(path)
  local existed = vim.fn.bufexists(path) == 1
  local buf = vim.fn.bufadd(path)
  if not vim.api.nvim_buf_is_loaded(buf) then
    self.loaded[buf] = { existed = existed, listed = vim.bo[buf].buflisted }
    vim.fn.bufload(buf)
  end
  return buf
end

--- Unload the buffers that the preview loaded, except `keep`. Keep a buffer that a window shows,
--- or that the user opened after the preview loaded it.
---@param keep integer?
function PreviewBufs:release(keep)
  for buf, before in pairs(self.loaded) do
    if buf ~= keep then
      self.loaded[buf] = nil
      if
        vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buflisted == before.listed
        and not vim.bo[buf].modified
        and #vim.fn.win_findbuf(buf) == 0
      then
        -- A buffer that the preview made goes away. An older buffer only unloads.
        vim.api.nvim_buf_delete(buf, { unload = before.existed })
      end
    end
  end
end

---@class didymus.picker.ConfirmOpts
---@field title string The question.
---@field choice string The text of the item that confirms, such as "Check out".
---@field preview? { lines: string[], filetype: string? } The preview of both items.
---@field cb fun(confirmed: boolean)

--- Ask a question with the select role and the `choice` kind, because `vim.fn.confirm()` blocks
--- the UI. The items are `choice` and "Cancel". A close with no choice is a cancel.
---@param adapter didymus.picker.Adapter
---@param opts didymus.picker.ConfirmOpts
function M.confirm(adapter, opts)
  adapter.select({
    title = opts.title,
    kind = "choice",
    items = {
      { text = opts.choice, value = true, preview = opts.preview },
      { text = "Cancel", value = false, preview = opts.preview },
    },
    on_choose = function(item)
      opts.cb(item.value)
    end,
    on_cancel = function()
      opts.cb(false)
    end,
  })
end

return M
