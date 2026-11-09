--- The review API: open a change in the review tabpage, show its threads, and close it.
--- See docs/architecture/review.md#workspace-flow.

local config = require("didymus.config")
local input = require("didymus.ui.input")
local patch = require("didymus.review.patch")
local picker = require("didymus.ui.picker")
local providers = require("didymus.review.provider")
local Session = require("didymus.review.session")
local threads = require("didymus.review.threads")
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
---@field id string? The id that `get_change()` took: a PR number or a PR URL.

---@return didymus.review.Session?
function M.current()
  return current
end

---@param message string
local function show_error(message)
  vim.notify("didymus: " .. message, vim.log.levels.ERROR)
end

---@param message string
local function show_warning(message)
  vim.notify("didymus: " .. message, vim.log.levels.WARN)
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

--- Show a progress message while `start` works. A new progress message replaces the last one.
---@param text string
---@param start fun(done: fun(err: string?, result: any))
---@param cb fun(err: string?, result: any)
local function track(text, start, cb)
  ---@param status "running"|"success"|"failed"
  local function show(status)
    vim.api.nvim_echo({ { text } }, false, {
      id = "didymus.review.progress",
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
  return {
    text = picker.join_segments(segments),
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

--- GitHub gives the deleted threads for a few seconds after a discard. For this time, in
--- milliseconds, didymus removes the pending comments from the threads of the provider.
local discard_delay = 10000

--- The threads with their pending comments removed, and with no empty threads.
---@param list didymus.review.Thread[]
---@return didymus.review.Thread[]
local function remove_pending(list)
  local kept = {}
  for _, thread in ipairs(list) do
    thread.comments = vim.tbl_filter(function(comment)
      return not comment.pending
    end, thread.comments)
    if #thread.comments > 0 then
      table.insert(kept, thread)
    end
  end
  return kept
end

--- The threads from the provider, with no pending comments just after a discard.
---@param session didymus.review.Session
---@param list didymus.review.Thread[]
---@return didymus.review.Thread[]
local function filter_threads(session, list)
  if session.discarded_at and vim.uv.now() - session.discarded_at < discard_delay then
    return remove_pending(list)
  end
  return list
end

--- Start a get of the threads. A newer get, or a close of the review, makes its result old.
---@param session didymus.review.Session
---@return fun(): boolean is_newest
local function start_load(session)
  session.load_count = session.load_count + 1
  local number = session.load_count
  return function()
    return current == session and session.load_count == number
  end
end

--- Get the threads, and show them in the session.
---@param session didymus.review.Session
local function load_threads(session)
  local is_newest = start_load(session)
  track(("get the threads of %s"):format(session.label), function(done)
    session.provider:get_threads(session.change, done)
  end, function(err, list)
    if not is_newest() then
      return
    end
    if err then
      return show_error(("cannot get the threads of %s: %s"):format(session.label, err))
    end
    session:set_threads(filter_threads(session, list))
  end)
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
        open_id = flow.id or change.id,
        label = label(change.id),
        adapter = flow.adapter,
        provider = flow.provider,
        cwd = flow.cwd,
        merge_base = merge_base,
        old_branch = status.branch,
        old_head = status.head,
        on_close = on_close,
      })
      vim.notify(("didymus: opened the review of %s: %s"):format(label(change.id), change.title))
      -- The review opens first, so that the user can read the files while the threads load.
      load_threads(current)
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
  flow.id = id
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

---@return didymus.review.Session?
local function get_open_review()
  if not current then
    vim.notify("didymus: no review is open", vim.log.levels.WARN)
  end
  return current
end

--- Close the files panel and the review tabpage. Do not check out the branch from before the
--- review.
function M.close()
  local session = get_open_review()
  if session then
    session:close()
  end
end

--- In the review tabpage, show the files panel or hide it. From a different tabpage, go to the
--- review tabpage and show the panel.
function M.files()
  local session = get_open_review()
  if session then
    session:toggle_files()
  end
end

--- Open the thread at the cursor in a float, with all its comments.
function M.thread()
  local session = get_open_review()
  if session then
    session:show_thread_at_cursor()
  end
end

--- Go to the next thread in the order of the panel, also in a different file.
function M.next()
  local session = get_open_review()
  if session then
    session:go_to_thread(1)
  end
end

--- Go to the previous thread in the order of the panel, also in a different file.
function M.prev()
  local session = get_open_review()
  if session then
    session:go_to_thread(-1)
  end
end

--- Get the change and the threads again, at the same time, and show them. If the head of the change
--- is new, show a warning. Do not check out the new head.
function M.refresh()
  local session = get_open_review()
  if not session then
    return
  end
  local is_newest = start_load(session)
  track(("refresh %s"):format(session.label), function(done)
    local results, errors, count = {}, {}, 0
    ---@param name "change"|"threads"
    local function on_result(name)
      return function(err, result)
        results[name], errors[name], count = result, err, count + 1
        if count == 2 then
          done(errors.change or errors.threads, results)
        end
      end
    end
    session.provider:get_change(session.open_id, on_result("change"))
    -- The change of the session is enough, because its id does not change.
    session.provider:get_threads(session.change, on_result("threads"))
  end, function(err, results)
    if not is_newest() then
      return
    end
    if err then
      return show_error(("cannot refresh %s: %s"):format(session.label, err))
    end
    local old_head = session.change.head_sha
    session:set_change(results.change, filter_threads(session, results.threads))
    if results.change.head_sha == old_head then
      return vim.notify(("didymus: refreshed %s"):format(session.label))
    end
    -- One line, because a message with more lines makes the user press Enter.
    show_warning(
      ("refreshed %s. Its head is now %s, but HEAD did not change. To check it out, close the review and open it again."):format(
        session.label,
        results.change.head_sha:sub(1, 7)
      )
    )
  end)
end

--- `path:3` for one line, `path:3-5` for more lines.
---@param path string
---@param range didymus.review.Range
---@return string
local function format_location(path, range)
  if range.first == range.last then
    return ("%s:%d"):format(path, range.first)
  end
  return ("%s:%d-%d"):format(path, range.first, range.last)
end

--- The lines of the selection in visual mode, else the cursor line. Leave visual mode, as a `:`
--- command does.
---@return didymus.review.Range
local function get_cursor_range()
  -- Out of visual mode, "v" is the cursor.
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    -- `:normal!` also sets `'<` and `'>`, so `gv` works.
    vim.cmd.normal({ "\27", bang = true })
  end
  return { first = math.min(first, last), last = math.max(first, last) }
end

--- Check that `buf` shows a file of the change with no unsaved changes, and that the lines accept
--- comments. If a check fails, show the reason.
---@param session didymus.review.Session
---@param buf integer
---@param range didymus.review.Range
---@return didymus.review.ChangedFile?
local function check_comment(session, buf, range)
  local index = session:find_file_index(buf)
  if not index then
    show_warning(("the current window does not show a file of %s"):format(session.label))
    return
  end
  local file = session.change.files[index]
  if vim.bo[buf].modified then
    show_warning(
      ("%s is modified. A comment needs the lines of the head of %s."):format(
        file.path,
        session.label
      )
    )
    return
  end
  if not patch.is_commentable(patch.parse(file.patch), "head", range) then
    if range.first == range.last then
      show_warning(
        ("line %d of %s is not in a hunk of %s"):format(range.first, file.path, session.label)
      )
    else
      show_warning(
        ("lines %d-%d of %s are not in one hunk of %s"):format(
          range.first,
          range.last,
          file.path,
          session.label
        )
      )
    end
    return
  end
  return file
end

--- Add the comment with the provider. Then show the new thread. If the provider fails, keep the
--- text for the next comment at these lines.
---@param session didymus.review.Session
---@param draft didymus.review.CommentDraft
local function add_comment(session, draft)
  local location = format_location(draft.path, draft.range)
  track(("add a comment at %s"):format(location), function(done)
    session.provider:add_comment(session.change, draft, done)
  end, function(err, thread)
    if err then
      local message = ("cannot add the comment at %s: %s"):format(location, err)
      if session:is_open() then
        session.failed_draft = draft
        -- One line, because a message with more lines makes the user press Enter.
        message = ("%s. The next comment at these lines starts with its text."):format(
          (message:gsub("%.$", ""))
        )
      end
      return show_error(message)
    end
    -- The comment is on the code host, also after a close of the review.
    if session:is_open() then
      -- The pending comments from the provider are now new, not deleted.
      session.discarded_at = nil
      session:add_thread(thread)
    end
    vim.notify(("didymus: added a pending comment at %s"):format(location))
  end)
end

---@param session didymus.review.Session
---@param path string
---@param range didymus.review.Range
local function open_comment_input(session, path, range)
  local options = config.options.review.input
  local failed = session.failed_draft
  local text
  if failed and failed.path == path and vim.deep_equal(failed.range, range) then
    text = failed.body
    session.failed_draft = nil
  end
  input.open({
    title = format_location(path, range),
    range = { range.first, range.last },
    text = text,
    width = options.width,
    max_height = options.max_height,
    keys = { cancel = options.keys.cancel },
    actions = {
      {
        key = options.keys.comment,
        name = "comment",
        on_submit = function(body)
          add_comment(session, { path = path, range = range, body = body })
        end,
      },
    },
  })
end

--- Add a comment on the current line, the selection or `range`, in the pending review. Check the
--- lines first. Then open the input float above them.
---@param opts { range: integer[]? }? The first and the last line.
function M.comment(opts)
  opts = opts or {}
  local range = opts.range and { first = opts.range[1], last = opts.range[2] } or get_cursor_range()
  local session = get_open_review()
  if not session then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local file = check_comment(session, buf, range)
  if not file then
    return
  end
  local head_sha = session.change.head_sha
  -- After a refresh with a new head, git can have no commit of the new head. Then `git diff` gives
  -- an error that does not tell the reason.
  workspace.get_head(session.cwd, function(head_err, head)
    if head_err then
      return show_error(head_err)
    end
    if head ~= head_sha then
      return show_warning(
        ("HEAD is not the head of %s. To check it out, close the review and open it again."):format(
          session.label
        )
      )
    end
    workspace.has_changes(session.cwd, head_sha, file.path, function(err, changed)
      if err then
        return show_error(err)
      end
      if changed then
        return show_warning(
          ("%s is different from the head of %s. A comment needs the lines of the head."):format(
            file.path,
            session.label
          )
        )
      end
      -- The checks are async. Open the float only at the same place.
      if
        session:is_open()
        and vim.api.nvim_get_current_win() == win
        and vim.api.nvim_win_get_buf(win) == buf
      then
        open_comment_input(session, file.path, range)
      end
    end)
  end)
end

--- Add the reply with the provider. Then show it in the thread. If the provider fails, keep the
--- text for the next reply to the thread.
---@param session didymus.review.Session
---@param thread didymus.review.Thread
---@param body string
local function add_reply(session, thread, body)
  local location = threads.get_location(thread)
  track(("add a reply at %s"):format(location), function(done)
    session.provider:reply(session.change, thread.id, body, done)
  end, function(err, comment)
    if err then
      local message = ("cannot add the reply at %s: %s"):format(location, err)
      if session:is_open() then
        session.failed_reply = { thread_id = thread.id, body = body }
        -- One line, because a message with more lines makes the user press Enter.
        message = ("%s. The next reply to this thread starts with its text."):format(
          (message:gsub("%.$", ""))
        )
      end
      return show_error(message)
    end
    -- The reply is on the code host, also after a close of the review.
    if session:is_open() then
      -- The pending comments from the provider are now new, not deleted.
      session.discarded_at = nil
      session:add_reply(thread.id, comment)
    end
    vim.notify(("didymus: added a pending reply at %s"):format(location))
  end)
end

--- Open the input float at the cursor line, for a reply to `thread`.
---@param session didymus.review.Session
---@param thread didymus.review.Thread
local function open_reply_input(session, thread)
  local options = config.options.review.input
  local failed = session.failed_reply
  local text
  if failed and failed.thread_id == thread.id then
    text = failed.body
    session.failed_reply = nil
  end
  input.open({
    title = "Reply to " .. threads.get_location(thread),
    text = text,
    width = options.width,
    max_height = options.max_height,
    keys = { cancel = options.keys.cancel },
    actions = {
      {
        -- A reply is a comment, so it uses the key of a comment.
        key = options.keys.comment,
        name = "reply",
        on_submit = function(body)
          add_reply(session, thread, body)
        end,
      },
    },
  })
end

--- Reply to the thread at the cursor, in the pending review. In the thread float, reply to its
--- thread. The input float opens at the cursor line of the window under the thread float.
function M.reply()
  local session = get_open_review()
  if not session then
    return
  end
  session:pick_thread_at_cursor(function(thread)
    if not thread.can_reply then
      return show_warning(
        ("you cannot reply to the thread at %s"):format(threads.get_location(thread))
      )
    end
    threads.close_float()
    open_reply_input(session, thread)
  end)
end

--- Resolve the thread at the cursor. On a resolved thread, unresolve it. In the thread float, use
--- its thread.
function M.resolve()
  local session = get_open_review()
  if not session then
    return
  end
  session:pick_thread_at_cursor(function(thread)
    local resolved = not thread.resolved
    local action = resolved and "resolve" or "unresolve"
    local location = threads.get_location(thread)
    if not (resolved and thread.can_resolve or not resolved and thread.can_unresolve) then
      return show_warning(("you cannot %s the thread at %s"):format(action, location))
    end
    threads.close_float()
    track(("%s the thread at %s"):format(action, location), function(done)
      session.provider:set_resolved(session.change, thread.id, resolved, done)
    end, function(err, new_thread)
      if err then
        return show_error(("cannot %s the thread at %s: %s"):format(action, location, err))
      end
      if session:is_open() then
        session:update_thread(new_thread)
      end
      vim.notify(("didymus: %sd the thread at %s"):format(action, location))
    end)
  end)
end

---@class didymus.review.VerdictInfo
---@field verdict didymus.review.Verdict
---@field text string The text in the picker.
---@field title string The title of the input float. `%s` is the change, such as "#12".
---@field done string The message after the submit. `%s` is the change.

--- The verdicts in the order of github.com.
---@type didymus.review.VerdictInfo[]
local verdicts = {
  { verdict = "comment", text = "Comment", title = "Comment on %s", done = "commented on %s" },
  { verdict = "approve", text = "Approve", title = "Approve %s", done = "approved %s" },
  {
    verdict = "request_changes",
    text = "Request changes",
    title = "Request changes on %s",
    done = "requested changes on %s",
  },
}

--- Submit the review with the provider. Then get the threads again. If the provider fails, keep
--- the body for the next submit.
---@param session didymus.review.Session
---@param info didymus.review.VerdictInfo
---@param body string Empty for no body.
local function submit_review(session, info, body)
  track(("submit the review of %s"):format(session.label), function(done)
    session.provider:submit_review(session.change, info.verdict, body ~= "" and body or nil, done)
  end, function(err)
    if err then
      local message = ("cannot submit the review of %s: %s"):format(session.label, err)
      if session:is_open() and body ~= "" then
        session.failed_review_body = body
        -- One line, because a message with more lines makes the user press Enter.
        message = ("%s. The next submit starts with its text."):format((message:gsub("%.$", "")))
      end
      return show_error(message)
    end
    vim.notify("didymus: " .. info.done:format(session.label))
    if session:is_open() then
      load_threads(session)
    end
  end)
end

--- Open the input float for the body of the review. A comment and a request for changes need a
--- body if the review has no pending comments, as on GitHub.
---@param session didymus.review.Session
---@param info didymus.review.VerdictInfo
local function open_submit_input(session, info)
  local options = config.options.review.input
  local text = session.failed_review_body
  session.failed_review_body = nil
  threads.close_float()
  input.open({
    title = info.title:format(session.label),
    text = text,
    width = options.width,
    max_height = options.max_height,
    keys = { cancel = options.keys.cancel },
    allow_empty = info.verdict == "approve" or #session:get_pending_comments() > 0,
    on_empty = function()
      show_warning(("a %q review needs a body or a pending comment"):format(info.text))
    end,
    actions = {
      {
        -- The body of a review is a comment, so it uses the key of a comment.
        key = options.keys.comment,
        name = "submit",
        on_submit = function(body)
          submit_review(session, info, body)
        end,
      },
    },
  })
end

--- Submit the pending review with a verdict and an optional body. With no pending review, submit
--- a review with no comments. With no verdict, ask for one in the picker.
---@param opts { verdict: didymus.review.Verdict? }?
function M.submit(opts)
  opts = opts or {}
  local info
  if opts.verdict then
    for _, item in ipairs(verdicts) do
      if item.verdict == opts.verdict then
        info = item
      end
    end
    if not info then
      return show_error(
        ("unknown verdict %q. Use approve, comment or request_changes."):format(opts.verdict)
      )
    end
  end
  local session = get_open_review()
  if not session then
    return
  end
  if info then
    return open_submit_input(session, info)
  end
  call_picker(session.adapter.select, {
    title = ("Submit the review of %s"):format(session.label),
    items = vim.tbl_map(function(item)
      return { text = item.text, value = item }
    end, verdicts),
    on_choose = function(item)
      if session:is_open() then
        open_submit_input(session, item.value)
      end
    end,
  })
end

--- Ask to confirm. Then delete the pending review with its comments, and get the threads again.
function M.discard()
  local session = get_open_review()
  if not session then
    return
  end
  local lines = vim.tbl_map(function(pending)
    local first_line = vim.trim(pending.comment.body):match("^[^\n]*")
    return ("%s: %s"):format(threads.get_location(pending.thread), first_line)
  end, session:get_pending_comments())
  if #lines == 0 then
    lines = { ("%s has no pending comments."):format(session.label) }
  end
  call_picker(picker.confirm, session.adapter, {
    title = ("Discard your pending review of %s?"):format(session.label),
    choice = "Discard",
    preview = { lines = lines },
    cb = function(confirmed)
      if not confirmed then
        return
      end
      track(("discard the pending review of %s"):format(session.label), function(done)
        session.provider:discard_review(session.change, done)
      end, function(err)
        if err then
          return show_error(
            ("cannot discard the pending review of %s: %s"):format(session.label, err)
          )
        end
        vim.notify(("didymus: discarded the pending review of %s"):format(session.label))
        if session:is_open() then
          session.discarded_at = vim.uv.now()
          load_threads(session)
        end
      end)
    end,
  })
end

return M
