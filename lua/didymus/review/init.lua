--- The review API: open a change in the review tabpage, and close it.
--- See docs/architecture/review.md#workspace-flow.

local config = require("didymus.config")
local picker = require("didymus.ui.picker")
local providers = require("didymus.review.provider")
local Session = require("didymus.review.session")
local workspace = require("didymus.review.workspace")

local M = {}

---@type didymus.review.Session?
local current

--- Each `open()` gets a number. The callbacks of an older `open()` do nothing.
local open_count = 0

---@class didymus.review.Flow The state of one `open()`.
---@field adapter didymus.picker.Adapter
---@field provider didymus.review.Provider
---@field cwd string
---@field number integer The number of the `open()`.

---@return didymus.review.Session?
function M.current()
  return current
end

---@param message string
local function show_error(message)
  vim.notify("didymus: " .. message, vim.log.levels.ERROR)
end

--- The name of a change in messages, such as "#12". A URL stays a URL.
---@param id string
---@return string
local function label(id)
  return id:match("^%d+$") and "#" .. id or id
end

--- Wrap `fn`, so that it does nothing after a newer `open()`.
---@generic F: function
---@param flow didymus.review.Flow
---@param fn F
---@return F
local function guard(flow, fn)
  return function(...)
    if flow.number == open_count then
      return fn(...)
    end
  end
end

--- Show a progress message while `start` works.
---@param text string
---@param start fun(done: fun(err: string?, result: any))
---@param cb fun(err: string?, result: any)
local function track(text, start, cb)
  ---@param status "running"|"success"|"failed"
  local function show(status)
    vim.api.nvim_echo({ { text } }, false, {
      id = "didymus.review.open",
      kind = "progress",
      source = "didymus",
      title = "didymus",
      status = status,
    })
  end
  show("running")
  start(function(err, result)
    show(err and "failed" or "success")
    cb(err, result)
  end)
end

--- Call a function of the picker. The snacks adapter gives an error if snacks.nvim is not available.
---@param fn function
---@param ... any
local function call_picker(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

---@param change didymus.review.ChangeSummary
---@return { lines: string[], filetype: string }
local function get_preview(change)
  local lines = { "# " .. change.title }
  if change.body ~= "" then
    table.insert(lines, "")
    vim.list_extend(lines, vim.split(change.body, "\n"))
  end
  return { lines = lines, filetype = "markdown" }
end

---@param change didymus.review.ChangeSummary
---@return didymus.picker.Item
local function to_item(change)
  local segments = {
    { label(change.id), "Number" },
    { " " .. change.title },
    { " @" .. change.author, "Comment" },
  }
  if change.is_draft then
    table.insert(segments, { " [draft]", "DiagnosticWarn" })
  end
  local texts = vim.tbl_map(function(segment)
    return segment[1]
  end, segments)
  return {
    text = table.concat(texts),
    id = change.id,
    segments = segments,
    preview = get_preview(change),
    value = change,
  }
end

---@param session didymus.review.Session
local function on_close(session)
  if current == session then
    current = nil
  end
  local before = ""
  if session.old_branch then
    before = (" The branch before the review was %s."):format(session.old_branch)
  elseif session.old_head then
    before = (" Before the review, HEAD was at the commit %s."):format(session.old_head:sub(1, 7))
  end
  vim.notify(("didymus: closed the review of %s.%s"):format(label(session.change.id), before))
end

--- Get the merge-base, and open the review tabpage.
---@param flow didymus.review.Flow
---@param change didymus.review.Change
---@param status didymus.review.workspace.Status The state of `HEAD` before the checkout.
local function start_session(flow, change, status)
  workspace.get_merge_base(
    flow.cwd,
    change.base_sha,
    change.head_sha,
    guard(flow, function(err, merge_base)
      if err then
        -- No MVP feature uses the merge-base, so the review can open.
        vim.notify(
          ("didymus: no merge-base for %s: %s"):format(label(change.id), err),
          vim.log.levels.WARN
        )
      end
      current = Session.new({
        change = change,
        cwd = flow.cwd,
        merge_base = merge_base,
        old_branch = status.branch,
        old_head = status.head,
        on_close = on_close,
      })
      vim.notify(("didymus: opened the review of %s: %s"):format(label(change.id), change.title))
    end)
  )
end

---@param flow didymus.review.Flow
---@param change didymus.review.Change
---@param status didymus.review.workspace.Status
local function check_out(flow, change, status)
  track(("check out %s"):format(label(change.id)), function(done)
    flow.provider:checkout(change, done)
  end, function(err)
    if err then
      return guard(flow, show_error)(("cannot check out %s: %s"):format(label(change.id), err))
    end
    -- The open buffers show the files of the change head, also after a newer `open()`.
    vim.cmd.checktime()
    guard(flow, start_session)(flow, change, status)
  end)
end

--- If `HEAD` is not the change head, check out the change. Ask first if there are uncommitted
--- changes.
---@param flow didymus.review.Flow
---@param change didymus.review.Change
local function prepare_workspace(flow, change)
  workspace.get_status(
    flow.cwd,
    guard(flow, function(err, status)
      if err then
        return show_error(err)
      end
      if status.head == change.head_sha then
        return start_session(flow, change, status)
      end
      if #status.changed_files == 0 then
        return check_out(flow, change, status)
      end
      call_picker(
        workspace.confirm_checkout,
        flow.adapter,
        label(change.id),
        status.changed_files,
        guard(flow, function(confirmed)
          if confirmed then
            check_out(flow, change, status)
          end
        end)
      )
    end)
  )
end

--- Only one review is open at a time. If it is a different change, ask to close it first.
---@param flow didymus.review.Flow
---@param change didymus.review.Change
local function open_change(flow, change)
  if not current then
    return prepare_workspace(flow, change)
  end
  if current.change.id == change.id then
    return current:focus()
  end
  call_picker(picker.confirm, flow.adapter, {
    title = ("Close the review of %s and open %s?"):format(
      label(current.change.id),
      label(change.id)
    ),
    choice = "Open " .. label(change.id),
    preview = get_preview(change),
    cb = guard(flow, function(confirmed)
      if not confirmed then
        return
      end
      if current then
        current:close()
        if current then
          -- The close failed, and showed the error.
          return
        end
      end
      prepare_workspace(flow, change)
    end),
  })
end

---@param flow didymus.review.Flow
---@param id string
local function open_id(flow, id)
  if current and current.change.id == id then
    return current:focus()
  end
  track(
    ("get %s"):format(label(id)),
    function(done)
      flow.provider:get_change(id, done)
    end,
    guard(flow, function(err, change)
      if err then
        return show_error(err)
      end
      open_change(flow, change)
    end)
  )
end

---@param flow didymus.review.Flow
local function pick(flow)
  track(
    "get the open pull requests",
    function(done)
      flow.provider:list_changes({}, done)
    end,
    guard(flow, function(err, changes)
      if err then
        return show_error(err)
      end
      if #changes == 0 then
        return vim.notify("didymus: there are no open pull requests")
      end
      call_picker(flow.adapter.select, {
        title = "Pull requests",
        items = vim.tbl_map(to_item, changes),
        on_choose = guard(flow, function(item)
          open_id(flow, item.value.id)
        end),
      })
    end)
  )
end

--- Open a change in the review tabpage. Check it out first if `HEAD` is not the change head.
---@param opts { id: string|integer? }? A PR number or a PR URL. Nil shows the picker.
function M.open(opts)
  opts = opts or {}
  local options = config.options.review
  local adapter, picker_err = picker.get(options.picker)
  if not adapter then
    return show_error(("%s (review.picker)"):format(picker_err))
  end
  local provider, provider_err = providers.get(options.provider)
  if not provider then
    return show_error(("%s (review.provider)"):format(provider_err))
  end

  open_count = open_count + 1
  local flow =
    { adapter = adapter, provider = provider, cwd = vim.fn.getcwd(), number = open_count }
  if opts.id then
    open_id(flow, tostring(opts.id))
  else
    pick(flow)
  end
end

--- Close the review tabpage. Do not check out the branch from before the review.
function M.close()
  if not current then
    vim.notify("didymus: no review is open", vim.log.levels.WARN)
    return
  end
  current:close()
end

return M
