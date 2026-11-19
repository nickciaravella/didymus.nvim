--- The files panel: the header, the changed files and their threads, as picker items. The picker
--- adapter draws them. See docs/architecture/review.md#parts.

local config = require("didymus.config")
local patch = require("didymus.review.patch")
local picker = require("didymus.ui.picker")
local threads = require("didymus.review.threads")

local M = {}

---@class didymus.review.panel.Value
---@field kind "header"|"file"|"thread"
---@field file? didymus.review.ChangedFile
---@field thread? didymus.review.Thread

--- The letter and the highlight of each file status.
---@type table<string, [string, string]>
local statuses = {
  added = { "A", "Added" },
  modified = { "M", "Changed" },
  deleted = { "D", "Removed" },
  renamed = { "R", "Changed" },
}

---@param id string
---@param segments [string, string?][]
---@param value didymus.review.panel.Value
---@return didymus.picker.Item
local function make_item(id, segments, value)
  return { text = picker.join_segments(segments), id = id, segments = segments, value = value }
end

---@param session didymus.review.Session
---@return didymus.picker.Item[]
local function get_header_items(session)
  local change = session.change
  return {
    make_item(
      "header:title",
      { { session.label, "Number" }, { " " .. change.title, "Title" } },
      { kind = "header" }
    ),
    make_item("header:branches", {
      { "@" .. change.author, "Comment" },
      { (" %s ← %s"):format(change.base_branch, change.head_branch) },
    }, { kind = "header" }),
    make_item("header:threads", {
      { session.thread_filter == "active" and "Active threads" or "All threads", "Comment" },
    }, { kind = "header" }),
  }
end

--- The head line of the first change of the first hunk. Nil if the file has no hunks.
---@param file didymus.review.ChangedFile
---@return integer?
local function get_first_change(file)
  local first_hunk = patch.parse(file.patch).hunks[1]
  return first_hunk and first_hunk.first_change
end

---@param session didymus.review.Session
---@param file didymus.review.ChangedFile
---@param thread_count integer
---@return didymus.picker.Item
local function get_file_item(session, file, thread_count)
  local status = statuses[file.status]
  local segments = {
    { status[1], status[2] },
    { " " .. file.path },
    { " +" .. file.additions, "Added" },
    { " -" .. file.deletions, "Removed" },
  }
  -- A count of 0 on each row makes the rows long and adds no information.
  if thread_count > 0 then
    local noun = thread_count == 1 and "thread" or "threads"
    table.insert(segments, { (" %d %s"):format(thread_count, noun), "Comment" })
  end
  local item = make_item("file:" .. file.path, segments, { kind = "file", file = file })
  -- The preview shows the location. A deleted file is not in the checkout.
  if file.status ~= "deleted" then
    item.location = { path = session:get_full_path(file.path), line = get_first_change(file) }
  end
  return item
end

---@param session didymus.review.Session
---@param thread didymus.review.Thread
---@return didymus.picker.Item
local function get_thread_item(session, thread)
  local item = make_item(
    "thread:" .. thread.id,
    threads.get_summary(thread),
    { kind = "thread", thread = thread }
  )
  item.depth = 1
  local line = session:get_thread_line(thread)
  if line then
    item.location = { path = session:get_full_path(thread.path), line = line }
  end
  return item
end

--- The header, then a row for each changed file, in the order of the provider. The threads of
--- each file come under it, in the order of the session. The thread count counts the threads
--- that show.
---@param session didymus.review.Session
---@return didymus.picker.Item[]
local function get_items(session)
  local file_threads = {}
  for _, thread in ipairs(session.threads) do
    if session.thread_filter == "all" or not thread.resolved then
      file_threads[thread.path] = file_threads[thread.path] or {}
      table.insert(file_threads[thread.path], thread)
    end
  end
  local items = get_header_items(session)
  for _, file in ipairs(session.change.files) do
    local list = file_threads[file.path] or {}
    table.insert(items, get_file_item(session, file, #list))
    for _, thread in ipairs(list) do
      table.insert(items, get_thread_item(session, thread))
    end
  end
  return items
end

---@param session didymus.review.Session
---@param item didymus.picker.Item
local function choose(session, item)
  ---@type didymus.review.panel.Value
  local value = item.value
  if value.kind == "thread" then
    if session:get_thread_line(value.thread) then
      return session:open_thread(value.thread)
    end
    -- The thread has no line in the file. The float is the only place that shows it.
    return threads.open_float(value.thread)
  end
  if value.kind ~= "file" then
    return
  end
  if value.file.status == "deleted" then
    vim.notify(("didymus: %s is deleted in %s"):format(value.file.path, session.label))
    return
  end
  session:open_file(value.file.path, get_first_change(value.file) or 1)
end

--- The keys of `review.panel.keys`. False turns a key off.
---@param session didymus.review.Session
---@return didymus.picker.Action[]
local function get_actions(session)
  local keys = config.options.review.panel.keys
  local actions = {}
  if keys.toggle_active then
    table.insert(actions, {
      key = keys.toggle_active,
      name = "show all threads or only the active threads",
      fn = function()
        session:toggle_thread_filter()
      end,
    })
  end
  if keys.comment then
    table.insert(actions, {
      key = keys.comment,
      name = "comment on the file",
      fn = function(item)
        ---@type didymus.review.panel.Value?
        local value = item and item.value
        local file = value and (value.file or value.thread)
        if file then
          require("didymus.review").comment({ kind = "file", path = file.path })
        end
      end,
    })
  end
  if keys.refresh then
    table.insert(actions, {
      key = keys.refresh,
      name = "refresh",
      fn = function()
        -- A require at the top makes a loop: the review module loads the session, which loads
        -- this module.
        require("didymus.review").refresh()
      end,
    })
  end
  return actions
end

--- Open the files panel of `session` in the current tabpage.
---@param adapter didymus.picker.Adapter
---@param session didymus.review.Session
---@return didymus.picker.Panel
function M.open(adapter, session)
  return adapter.panel({
    title = "Review " .. session.label,
    kind = "files",
    items = function()
      return get_items(session)
    end,
    on_choose = function(item)
      choose(session, item)
    end,
    actions = get_actions(session),
  })
end

return M
