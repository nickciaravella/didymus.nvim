--- The diff API: show the diff of the change in the review tabpage. See docs/architecture/diff.md.

local M = {}

--- Show or hide the diff in the review tabpage. From a different tabpage, go to the review tabpage
--- first.
function M.toggle()
  local session = require("didymus.review").current()
  if not session then
    vim.notify("didymus: no review is open", vim.log.levels.WARN)
    return
  end
  session:focus()
  session.diff_view:toggle()
end

return M
