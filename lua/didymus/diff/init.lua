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

--- Go to the next hunk of the diff in the code window. At the last hunk of a file, go to the first
--- hunk of the next file with hunks, in the order of the panel. Do not wrap.
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
