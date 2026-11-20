--- The review API: open a change in the review tabpage, show its threads, and close it.
--- See docs/architecture/review.md#workspace-flow.

local config = require("didymus.config")
local blocks = require("didymus.review.blocks")
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

---@class didymus.review.Results The results of `call_all()`, by the name of the call.
---@field change didymus.review.Change?
---@field threads didymus.review.Thread[]?
---@field comments didymus.review.Comment[]?
---@field errors table<string, string> The error of each call that failed.

--- Start the calls at the same time. When all are done, call `cb` with the first error and the
--- results. The error of the change comes first, then the threads, then the comments.
---@param calls table<"change"|"threads"|"comments", fun(cb: fun(err: string?, result: any))>
---@param cb fun(err: string?, results: didymus.review.Results)
local function call_all(calls, cb)
  local results, waiting = { errors = {} }, vim.tbl_count(calls)
  for name, start in pairs(calls) do
    start(function(err, result)
      results[name], results.errors[name], waiting = result, err, waiting - 1
      if waiting == 0 then
        local errors = results.errors
        cb(errors.change or errors.threads or errors.comments, results)
      end
    end)
  end
end

--- Get the threads and the general comments at the same time, and show them in the session.
---@param session didymus.review.Session
local function load_threads(session)
  local is_newest = start_load(session)
  track(("get the threads of %s"):format(session.label), function(done)
    call_all({
      threads = function(cb)
        session.provider:get_threads(session.change, cb)
      end,
      comments = function(cb)
        session.provider:get_comments(session.change, cb)
      end,
    }, done)
  end, function(_, results)
    if not is_newest() then
      return
    end
    -- Each result that the provider gave shows, also if the other call failed.
    local errors = results.errors
    if errors.threads then
      show_error(("cannot get the threads of %s: %s"):format(session.label, errors.threads))
    else
      session:set_threads(filter_threads(session, results.threads))
    end
    if errors.comments then
      show_error(("cannot get the comments of %s: %s"):format(session.label, errors.comments))
    else
      session:set_comments(results.comments)
    end
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
        kind = "changes",
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
  local adapter, picker_err = picker.get(options.picker, options.picker_config)
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

--- Fold or unfold the threads at the cursor line. With `all`, fold all threads of the review if
--- one of them is unfolded. Else, unfold all threads.
---@param opts { all: boolean? }?
function M.fold(opts)
  local session = get_open_review()
  if not session then
    return
  end
  if opts and opts.all then
    session:toggle_all_folds()
  else
    session:toggle_fold()
  end
end

---@type table<string, boolean>
local stop_kinds = { thread = true, file = true, hunk = true }

---@param direction 1|-1
---@param opts { kind: didymus.review.StopKind? }?
local function go_to(direction, opts)
  local kind = opts and opts.kind or "thread"
  if not stop_kinds[kind] then
    local name = direction > 0 and "next" or "previous"
    return show_error(("cannot go to the %s %s. Use thread, file or hunk."):format(name, kind))
  end
  local session = get_open_review()
  if session then
    session:go_to(kind, direction)
  end
end

--- Go to the next thread, file or hunk in the order of the panel, also in a different file.
---@param opts { kind: didymus.review.StopKind? }? The default kind is "thread".
function M.next(opts)
  go_to(1, opts)
end

--- Go to the previous thread, file or hunk in the order of the panel, also in a different file.
---@param opts { kind: didymus.review.StopKind? }? The default kind is "thread".
function M.prev(opts)
  go_to(-1, opts)
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
    call_all({
      change = function(cb)
        session.provider:get_change(session.open_id, cb)
      end,
      -- The change of the session is enough, because its id does not change.
      threads = function(cb)
        session.provider:get_threads(session.change, cb)
      end,
      comments = function(cb)
        session.provider:get_comments(session.change, cb)
      end,
    }, done)
  end, function(err, results)
    if not is_newest() then
      return
    end
    if err then
      return show_error(("cannot refresh %s: %s"):format(session.label, err))
    end
    local old_head = session.change.head_sha
    session:set_change(assert(results.change), filter_threads(session, assert(results.threads)))
    session:set_comments(assert(results.comments))
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

--- `path:3` for one line, `path:3-5` for more lines, `path` for the file. Lines on the base side
--- get `(base)`.
---@param path string
---@param range didymus.review.Range?
---@param side didymus.review.Side?
---@return string
local function format_location(path, range, side)
  if not range then
    return path
  end
  local location = ("%s:%d"):format(path, range.first)
  if range.first ~= range.last then
    location = ("%s-%d"):format(location, range.last)
  end
  return side == "base" and location .. " (base)" or location
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

--- The file of the change that `buf` shows, and the side: the head file, or the base buffer of the
--- diff. Nil if `buf` shows no file of the change.
---@param session didymus.review.Session
---@param buf integer
---@return didymus.review.ChangedFile?
---@return didymus.review.Side?
local function find_comment_file(session, buf)
  local base_file = session.diff_view:find_base_file(buf)
  if not base_file then
    local index = session:find_file_index(buf)
    return index and session.change.files[index], "head"
  end
  for _, file in ipairs(session.change.files) do
    if file.path == base_file.path then
      return file, "base"
    end
  end
end

--- Check that `buf` shows a file of the change with no unsaved changes, and that the lines accept
--- comments. If a check fails, show the reason.
---@param session didymus.review.Session
---@param buf integer
---@param range didymus.review.Range
---@return didymus.review.ChangedFile?
---@return didymus.review.Side?
---@return string? out_of_hunks The reason if the lines are not in one commentable range. Then the file can get a comment.
local function check_comment(session, buf, range)
  local file, side = find_comment_file(session, buf)
  if not file then
    show_warning(("the current window does not show a file of %s"):format(session.label))
    return
  end
  if vim.bo[buf].modified then
    show_warning(
      ("%s is modified. A comment needs the lines of the head of %s."):format(
        file.path,
        session.label
      )
    )
    return
  end
  if not patch.is_commentable(patch.parse(file.patch), side, range) then
    local name = side == "base" and "the base of " .. file.path or file.path
    local reason
    if range.first == range.last then
      reason = ("Line %d of %s is not in a hunk of %s"):format(range.first, name, session.label)
    else
      reason = ("Lines %d-%d of %s are not in one hunk of %s"):format(
        range.first,
        range.last,
        name,
        session.label
      )
    end
    return file, side, reason
  end
  return file, side
end

--- Add the comment with the provider. Then show the new thread. If the provider fails, keep the
--- text for the next comment at these lines.
---@param session didymus.review.Session
---@param draft didymus.review.CommentDraft
---@param release fun()? Removes the text that the inline input keeps in the file.
local function add_comment(session, draft, release)
  local location = format_location(draft.path, draft.range, draft.side)
  local verb = draft.pending and "add" or "post"
  track(("%s a comment at %s"):format(verb, location), function(done)
    session.provider:add_comment(session.change, draft, done)
  end, function(err, thread)
    -- The new thread replaces the text in the same redraw.
    if release then
      release()
    end
    if err then
      local message = ("cannot %s the comment at %s: %s"):format(verb, location, err)
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
      if draft.pending then
        -- The pending comments from the provider are now new, not deleted.
        session.discarded_at = nil
      end
      session:add_thread(thread)
    end
    local done = draft.pending and "added a pending comment" or "posted a comment"
    vim.notify(("didymus: %s at %s"):format(done, location))
  end)
end

--- A suggestion block with `lines`, as on github.com. The cursor goes to the last line of code.
--- The fence is longer than each fence in the code.
---@param lines string[]
---@return string[] lines
---@return integer cursor_index
local function make_suggestion(lines)
  local fence = "```"
  for _, line in ipairs(lines) do
    while line:find(fence, 1, true) do
      fence = fence .. "`"
    end
  end
  local block = { fence .. "suggestion" }
  vim.list_extend(block, lines)
  table.insert(block, fence)
  return block, #block - 1
end

--- The place of an input in the virtual lines of a file window.
---@class didymus.review.InputPlace
---@field win integer
---@field row integer The 0-based row of the line. The input shows under the line.
---@field above boolean? True above line 1, for a comment on the file.
---@field reply_to string? The input shows under this thread.

--- Open the input at `place` in the file, or the input float at the cursor line with no place.
---@param session didymus.review.Session
---@param place didymus.review.InputPlace?
---@param opts didymus.ui.input.Opts
local function open_input(session, place, opts)
  if not place then
    return input.open(opts)
  end
  blocks.open_draft(session, {
    win = place.win,
    row = place.row,
    above = place.above or false,
    reply_to = place.reply_to,
    input = opts,
  })
end

--- Open the input for a comment on `range` of `path`, or on the file with no range.
---@param session didymus.review.Session
---@param path string
---@param side didymus.review.Side
---@param range didymus.review.Range?
---@param code string[]? The lines of the range, for a suggestion. GitHub applies a suggestion only on the head side.
---@param place didymus.review.InputPlace? Else the input float opens at the cursor line.
local function open_comment_input(session, path, side, range, code, place)
  local options = config.options.review.input
  local failed = session.failed_draft
  local text
  if
    failed
    and failed.path == path
    and failed.side == side
    and vim.deep_equal(failed.range, range)
  then
    text = failed.body
    session.failed_draft = nil
  end
  local inserts = {}
  if code then
    table.insert(inserts, {
      key = options.keys.suggest,
      name = "suggest",
      get_lines = function()
        return make_suggestion(code)
      end,
    })
  end
  open_input(session, place, {
    title = format_location(path, range, side),
    range = range and { range.first, range.last },
    text = text,
    width = options.width,
    max_height = options.max_height,
    keys = { cancel = options.keys.cancel },
    inserts = inserts,
    actions = {
      {
        key = options.keys.post,
        name = "comment now",
        on_submit = function(body, release)
          add_comment(
            session,
            { path = path, side = side, range = range, body = body, pending = false },
            release
          )
        end,
      },
      {
        key = options.keys.add,
        name = "add to review",
        on_submit = function(body, release)
          add_comment(
            session,
            { path = path, side = side, range = range, body = body, pending = true },
            release
          )
        end,
      },
    },
  })
end

--- Open the input for a comment on the file of the current window, or on `path`. The input shows
--- above line 1 of the file. A deleted file is not in the checkout, so it gets the input float. A
--- comment on the file has no lines, so it needs no check of the lines.
---@param session didymus.review.Session
---@param path string?
local function comment_on_file(session, path)
  local win = vim.api.nvim_get_current_win()
  local shown = find_comment_file(session, vim.api.nvim_win_get_buf(win))
  if not path and not shown then
    return show_warning(("the current window does not show a file of %s"):format(session.label))
  end
  path = path or shown.path
  threads.close_float()
  if shown and shown.path == path then
    -- The input shows above line 1, and the cursor line stays in the window.
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    return open_comment_input(session, path, "head", nil, nil, { win = win, row = 0, above = true })
  end
  local file = session:get_file(path)
  if file and file.status ~= "deleted" then
    if session:open_file(path, 1) then
      open_comment_input(
        session,
        path,
        "head",
        nil,
        nil,
        { win = vim.api.nvim_get_current_win(), row = 0, above = true }
      )
    end
    return
  end
  open_comment_input(session, path, "head")
end

--- Ask to comment on the file, because the lines are not in one commentable range.
---@param session didymus.review.Session
---@param path string
---@param reason string
local function offer_file_comment(session, path, reason)
  call_picker(picker.confirm, session.adapter, {
    title = ("%s. Comment on the file?"):format(reason),
    choice = "Comment on the file",
    cb = function(confirmed)
      if confirmed and session:is_open() then
        comment_on_file(session, path)
      end
    end,
  })
end

--- Post a general comment with the provider. Then show it in the panel. If the provider fails,
--- keep the text for the next general comment.
---@param session didymus.review.Session
---@param body string
local function post_change_comment(session, body)
  track(("post a comment on %s"):format(session.label), function(done)
    session.provider:post_change_comment(session.change, body, done)
  end, function(err, comment)
    if err then
      local message = ("cannot post the comment on %s: %s"):format(session.label, err)
      if session:is_open() then
        session.failed_change_comment = body
        -- One line, because a message with more lines makes the user press Enter.
        message = ("%s. The next comment on %s starts with its text."):format(
          (message:gsub("%.$", "")),
          session.label
        )
      end
      return show_error(message)
    end
    -- The comment is on the code host, also after a close of the review.
    if session:is_open() then
      session:add_change_comment(comment)
    end
    vim.notify(("didymus: posted a comment on %s"):format(session.label))
  end)
end

--- Open the input float for a general comment, at the cursor line. A general comment is not in a
--- review, so the float has only the action that posts it at once.
---@param session didymus.review.Session
local function comment_on_change(session)
  local options = config.options.review.input
  local text = session.failed_change_comment
  session.failed_change_comment = nil
  threads.close_float()
  input.open({
    title = "Comment on " .. session.label,
    text = text,
    width = options.width,
    max_height = options.max_height,
    keys = { cancel = options.keys.cancel },
    actions = {
      {
        key = options.keys.post,
        name = "comment now",
        on_submit = function(body)
          post_change_comment(session, body)
        end,
      },
    },
  })
end

---@alias didymus.review.CommentKind "line"|"file"|"change"

---@class didymus.review.CommentOpts
---@field kind didymus.review.CommentKind? Default "line".
---@field range integer[]? The first and the last line, for a comment on lines.
---@field path string? The file of a comment on the file. Default: the file of the current window.

--- Add a comment on the current line, the selection or `range`. Post it at once, or add it to the
--- pending review. Check the lines first. Then open the input float above them. With the kind
--- "file", add a comment on the file. With the kind "change", post a general comment.
---@param opts didymus.review.CommentOpts?
function M.comment(opts)
  opts = opts or {}
  local kind = opts.kind or "line"
  if kind ~= "line" and kind ~= "file" and kind ~= "change" then
    return show_error(("cannot comment on %q. Use line, file or change."):format(kind))
  end
  local range
  if kind == "line" then
    range = opts.range and { first = opts.range[1], last = opts.range[2] } or get_cursor_range()
  end
  local session = get_open_review()
  if not session then
    return
  end
  if kind == "file" then
    return comment_on_file(session, opts.path)
  end
  if kind == "change" then
    return comment_on_change(session)
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local file, side, out_of_hunks = check_comment(session, buf, range)
  if not file then
    return
  end
  if out_of_hunks then
    return offer_file_comment(session, file.path, out_of_hunks)
  end
  local code = side == "head"
      and vim.api.nvim_buf_get_lines(buf, range.first - 1, range.last, false)
    or nil
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
    -- The checks are async. Open the float only at the same place.
    local function open_input()
      if
        session:is_open()
        and vim.api.nvim_get_current_win() == win
        and vim.api.nvim_win_get_buf(win) == buf
      then
        open_comment_input(
          session,
          file.path,
          side,
          range,
          code,
          { win = win, row = range.last - 1 }
        )
      end
    end
    -- The base buffer has the text of a commit, so only the head file can change.
    if side == "base" then
      return open_input()
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
      open_input()
    end)
  end)
end

--- Add the reply with the provider: post it at once, or add it to the pending review. Then show it
--- in the thread. If the provider fails, keep the text for the next reply to the thread.
---@param session didymus.review.Session
---@param thread didymus.review.Thread
---@param draft didymus.review.ReplyDraft
---@param release fun()? Removes the text that the inline input keeps in the file.
local function add_reply(session, thread, draft, release)
  local location = threads.get_location(thread)
  local verb = draft.pending and "add" or "post"
  track(("%s a reply at %s"):format(verb, location), function(done)
    session.provider:reply(session.change, draft, done)
  end, function(err, comment)
    -- The new comment replaces the text in the same redraw.
    if release then
      release()
    end
    if err then
      local message = ("cannot %s the reply at %s: %s"):format(verb, location, err)
      if session:is_open() then
        session.failed_reply = draft
        -- One line, because a message with more lines makes the user press Enter.
        message = ("%s. The next reply to this thread starts with its text."):format(
          (message:gsub("%.$", ""))
        )
      end
      return show_error(message)
    end
    -- The reply is on the code host, also after a close of the review.
    if session:is_open() then
      if draft.pending then
        -- The pending comments from the provider are now new, not deleted.
        session.discarded_at = nil
      end
      session:add_reply(thread.id, comment)
    end
    local done = draft.pending and "added a pending reply" or "posted a reply"
    vim.notify(("didymus: %s at %s"):format(done, location))
  end)
end

--- Mark the file as viewed, or unmark it. A file with new changes since the view becomes viewed.
--- With no path, use the file of the current window, else the file of the code window.
---@param opts { path: string? }?
function M.viewed(opts)
  local session = get_open_review()
  if not session then
    return
  end
  local path = opts and opts.path
  if not path then
    local position = session:get_cursor_position()
    if not position then
      return show_warning(("no window shows a file of %s"):format(session.label))
    end
    path = session.change.files[position.file_index].path
  end
  local file = session:get_file(path)
  if not file then
    return show_warning(("%s is not a file of %s"):format(path, session.label))
  end
  if not session.provider.set_viewed then
    return show_warning("the review provider cannot mark a file as viewed")
  end
  local viewed = file.viewed ~= "viewed"
  local action = viewed and "mark" or "unmark"
  track(("%s %s as viewed"):format(action, path), function(done)
    session.provider:set_viewed(session.change, path, viewed, done)
  end, function(err)
    if err then
      return show_error(("cannot %s %s as viewed: %s"):format(action, path, err))
    end
    if session:is_open() then
      session:set_viewed(path, viewed and "viewed" or "unviewed")
    end
    vim.notify(("didymus: %sed %s as viewed"):format(action, path))
  end)
end

--- Open the input for a reply to `thread`: in the file under the thread, or the input float at the
--- cursor line.
---@param session didymus.review.Session
---@param thread didymus.review.Thread
---@param place didymus.review.InputPlace?
local function open_reply_input(session, thread, place)
  local options = config.options.review.input
  local failed = session.failed_reply
  local text
  if failed and failed.thread_id == thread.id then
    text = failed.body
    session.failed_reply = nil
  end
  open_input(session, place, {
    title = "Reply to " .. threads.get_location(thread),
    text = text,
    width = options.width,
    max_height = options.max_height,
    keys = { cancel = options.keys.cancel },
    -- A reply is a comment, so it has the actions and the keys of a comment.
    actions = {
      {
        key = options.keys.post,
        name = "reply now",
        on_submit = function(body, release)
          add_reply(
            session,
            thread,
            { thread_id = thread.id, body = body, pending = false },
            release
          )
        end,
      },
      {
        key = options.keys.add,
        name = "add to review",
        on_submit = function(body, release)
          add_reply(
            session,
            thread,
            { thread_id = thread.id, body = body, pending = true },
            release
          )
        end,
      },
    },
  })
end

--- The warning for a command on a thread when the cursor is not in a thread.
---@param action string
local function warn_no_thread(action)
  show_warning(
    ("the cursor is not in a thread. To %s, put the cursor in the thread with j or k."):format(
      action
    )
  )
end

--- Reply to the thread with the cursor, or to the thread of the open thread float. Post the reply
--- at once, or add it to the pending review. In a file, the input shows under the thread. For the
--- thread float, the input float opens at the cursor line of the window under it, such as the
--- panel.
function M.reply()
  local session = get_open_review()
  if not session then
    return
  end
  local thread = session:get_cursor_thread()
  if not thread then
    return warn_no_thread("reply")
  end
  if not thread.can_reply then
    return show_warning(
      ("you cannot reply to the thread at %s"):format(threads.get_location(thread))
    )
  end
  local cursor = session.block_cursor
  local place
  if cursor and blocks.get_cursor_key(session) == "thread:" .. thread.id then
    local mark_id, group = threads.find_block(cursor.buf, cursor.key)
    if mark_id and group then
      place = {
        win = cursor.win,
        row = threads.get_mark_row(cursor.buf, mark_id) or group.row,
        above = group.above,
        reply_to = thread.id,
      }
    end
  end
  threads.close_float()
  open_reply_input(session, thread, place)
end

--- Resolve the thread with the cursor, or the thread of the open thread float. On a resolved
--- thread, unresolve it.
function M.resolve()
  local session = get_open_review()
  if not session then
    return
  end
  local thread = session:get_cursor_thread()
  if not thread then
    return warn_no_thread("resolve")
  end
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
      -- As on github.com, a resolve folds the thread, and an unresolve unfolds it.
      session:reset_fold(new_thread.id)
      session:update_thread(new_thread)
    end
    vim.notify(("didymus: %sd the thread at %s"):format(action, location))
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
        -- A submit posts the review at once, so it uses the key of a post.
        key = options.keys.post,
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
    kind = "choice",
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
