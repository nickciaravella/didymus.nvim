--- The diff API: show the diff of the change in the review tabpage. See docs/architecture/diff.md.

local M = {}

--- The diff view of the review, in the review tabpage. Nil with no review. Then a warning shows.
---@return didymus.diff.View?
local function focus_view()
  local session = require("didymus.review").current()
  if not session then
    vim.notify("didymus: no review is open", vim.log.levels.WARN)
    return
  end
  session:focus()
  return session.diff_view
end

--- Show or hide the diff in the review tabpage. From a different tabpage, go to the review tabpage
--- first.
function M.toggle()
  local view = focus_view()
  if view then
    view:toggle()
  end
end

local layouts = { inline = true, split = true }

---@class didymus.diff.LayoutOpts
---@field layout didymus.diff.Layout? Nil changes to the other layout.

--- Set the layout of the diff, and show a hidden diff. With no layout, change to the other layout.
---@param opts didymus.diff.LayoutOpts?
function M.layout(opts)
  local layout = opts and opts.layout
  if layout and not layouts[layout] then
    vim.notify(
      ("didymus: unknown layout %q. Use inline or split."):format(layout),
      vim.log.levels.ERROR
    )
    return
  end
  local view = focus_view()
  if view then
    view:set_layout(layout)
  end
end

local sides = { both = true, base = true, head = true }

---@class didymus.diff.SideOpts
---@field side didymus.diff.Sides? Nil goes to the next sides: both, head, base.

--- Set the sides of the diff, and show a hidden diff. "base" shows the base buffer in the code
--- window, until the code window shows a different buffer. With no side, go to the next sides.
---@param opts didymus.diff.SideOpts?
function M.side(opts)
  local side = opts and opts.side
  if side and not sides[side] then
    vim.notify(
      ("didymus: unknown side %q. Use both, base or head."):format(side),
      vim.log.levels.ERROR
    )
    return
  end
  local view = focus_view()
  if view then
    view:set_sides(side)
  end
end

--- Go to the next hunk of the diff in the code window. In the base window, or with the "base" sides,
--- use the base lines. At the last hunk of a file, go to the first hunk of the next file with hunks,
--- in the order of the panel. Do not wrap.
function M.next()
  local view = focus_view()
  if view then
    view:go_to(1)
  end
end

--- Go to the previous hunk of the diff, also in the previous files. Do not wrap.
function M.prev()
  local view = focus_view()
  if view then
    view:go_to(-1)
  end
end

return M
