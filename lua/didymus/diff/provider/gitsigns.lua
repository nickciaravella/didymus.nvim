--- The gitsigns diff provider. gitsigns computes the hunks against the base commit and shows the
--- signs. Its unified view shows the deleted lines in the code window. The split layout uses native
--- diff mode in the base window and the code window. The "base" sides highlight the deleted lines of
--- the base buffer.
--- See docs/architecture/diff.md#gitsigns-provider and agents/expertise/gitsigns.md.

local hunks = require("didymus.diff.hunks")

--- The calls to internal gitsigns modules. gitsigns has no public API for them. If gitsigns
--- changes, fix them here. Each one gives nil and an error if the call fails.
local internal = {}

--- True if gitsigns has the hunks of `buf` against `sha`. `get_hunks()` gives `{}` also while
--- gitsigns computes the hunks, so it cannot tell this.
---@param buf integer
---@param sha string
---@return boolean? ready
---@return string? err
function internal.has_hunks(buf, sha)
  local ok, result = pcall(function()
    local entry = require("gitsigns.cache").cache[buf]
    -- An update that started before `change_base()` can set hunks after it, with no compare_text.
    return entry ~= nil
      and entry.hunks ~= nil
      and entry.compare_text ~= nil
      and entry.git_obj.revision == sha
  end)
  if not ok then
    return nil, "gitsigns.cache failed: " .. tostring(result)
  end
  return result
end

--- True if gitsigns does not compute the hunks of `buf` now, or does not know `buf`. An update that
--- reads the base text during `change_base()` keeps the text of the old base, so wait for this.
---@param buf integer
---@return boolean? idle
---@return string? err
function internal.is_idle(buf)
  local ok, result = pcall(function()
    local entry = require("gitsigns.cache").cache[buf]
    return entry == nil or (entry.hunks ~= nil and entry.compare_text ~= nil)
  end)
  if not ok then
    return nil, "gitsigns.cache failed: " .. tostring(result)
  end
  return result
end

--- True if `win` has a unified view of the buffer that it shows. gitsigns has no public function
--- for this, and a second `diffthis()` closes the view.
---@param win integer
---@return boolean? open
---@return string? err
function internal.has_view(win)
  local ok, result = pcall(function()
    return require("gitsigns.unified").get_view(win) ~= nil
  end)
  if not ok then
    return nil, "gitsigns.unified failed: " .. tostring(result)
  end
  return result
end

--- Close the unified view of `win`. The public `diffthis()` closes only a view of the buffer that
--- the current window shows now.
---@param win integer
---@return string? err
function internal.close_view(win)
  local ok, err = pcall(function()
    require("gitsigns.unified").close(win)
  end)
  if not ok then
    return "gitsigns.unified failed: " .. tostring(err)
  end
end

--- The base of the gitsigns config. `change_base(nil)` sets the index, not this base.
---@return string?
function internal.config_base()
  local ok, base = pcall(function()
    return require("gitsigns.config").config.base
  end)
  return ok and base or nil
end

--- The internal functions that are missing, such as `gitsigns.unified.close`.
---@return string[]
function internal.find_missing()
  local missing = {}
  for module, names in pairs({
    ["gitsigns.cache"] = { "cache" },
    ["gitsigns.unified"] = { "get_view", "close" },
  }) do
    local ok, value = pcall(require, module)
    for _, name in ipairs(names) do
      if not (ok and type(value) == "table" and value[name] ~= nil) then
        table.insert(missing, ("%s.%s"):format(module, name))
      end
    end
  end
  table.sort(missing)
  return missing
end

---@class didymus.diff.provider.Gitsigns: didymus.diff.Provider
---@field timeout integer The time in milliseconds before `attach()` stops to wait for gitsigns.
local M = {
  capabilities = {
    layouts = { inline = true, split = true },
    sides = { both = true, base = true, head = true },
    bases = { commit = true },
    heads = { worktree = true },
  },
  timeout = 5000,
}

---@class didymus.diff.provider.gitsigns.Attached
---@field sha string The base commit.
---@field ready boolean True after `attach()` calls `cb` with no error.
---@field base_changed boolean True after the call of `change_base()`. Then `detach()` puts back the base.

---@type table<integer, didymus.diff.provider.gitsigns.Attached>
local attached = {}

--- The buffer of each window where the provider opened a unified view. `detach()` closes only
--- these views, so that it does not close a view of the user (D3). gitsigns tells if a view is open.
---@type table<integer, integer>
local opened_views = {}

--- The window options that `:diffthis` changes. `:diffoff` does not put back all of them, for example
--- 'foldenable'. See agents/expertise/neovim.md#windows.
local diff_options = {
  "diff",
  "scrollbind",
  "cursorbind",
  "wrap",
  "foldmethod",
  "foldcolumn",
  "foldenable",
  "foldlevel",
}

--- The window options from before `:diffthis`, for each window and buffer where the provider turned
--- on diff mode. Neovim keeps the window options of each buffer, so diff mode comes back when the
--- buffer comes back to the window. Then the provider turns it off.
---@type table<integer, table<integer, table<string, any>>>
local diff_wins = {}

--- 'scrollopt' from before the first `:diffthis`. `:diffthis` adds "hor", and `:diffoff` removes it.
---@type string?
local saved_scrollopt

---@param win integer
---@param buf integer
local function forget_diff(win, buf)
  local bufs = diff_wins[win]
  if bufs then
    bufs[buf] = nil
    if next(bufs) == nil then
      diff_wins[win] = nil
    end
  end
  if next(diff_wins) == nil and saved_scrollopt then
    vim.o.scrollopt = saved_scrollopt
    saved_scrollopt = nil
  end
end

--- Turn off diff mode in `win`, and put back its options, if the provider turned it on for the
--- buffer that `win` shows.
---@param win integer
local function turn_off_diff(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local saved = diff_wins[win] and diff_wins[win][buf]
  if not saved then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("diffoff")
  end)
  for _, name in ipairs(diff_options) do
    vim.api.nvim_set_option_value(name, saved[name], { win = win, scope = "local" })
  end
  forget_diff(win, buf)
end

local diff_group = vim.api.nvim_create_augroup("didymus.diff.gitsigns", {})
-- A hidden buffer stays in the diff of the tabpage, so the next diff would compare three or more
-- buffers. Only `:diffoff` while the window shows the buffer removes it. Neovim saved the window
-- options of the buffer before this event, so `BufWinEnter` must still put them back.
vim.api.nvim_create_autocmd("BufWinLeave", {
  group = diff_group,
  callback = function(args)
    for win, bufs in pairs(diff_wins) do
      if
        bufs[args.buf]
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == args.buf
        and vim.wo[win].diff
      then
        vim.api.nvim_win_call(win, function()
          vim.cmd("diffoff")
        end)
      end
    end
  end,
})
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = diff_group,
  callback = function()
    turn_off_diff(vim.api.nvim_get_current_win())
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = diff_group,
  callback = function(args)
    for buf in pairs(diff_wins[tonumber(args.match)] or {}) do
      forget_diff(tonumber(args.match) --[[@as integer]], buf)
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = diff_group,
  callback = function(args)
    for win in pairs(diff_wins) do
      forget_diff(win, args.buf)
    end
  end,
})

--- Turn on diff mode in `win`. Save the options first, so that `turn_off_diff()` puts them back.
---@param win integer
local function turn_on_diff(win)
  local buf = vim.api.nvim_win_get_buf(win)
  diff_wins[win] = diff_wins[win] or {}
  if not diff_wins[win][buf] then
    local saved = {}
    for _, name in ipairs(diff_options) do
      saved[name] = vim.api.nvim_get_option_value(name, { win = win, scope = "local" })
    end
    diff_wins[win][buf] = saved
  end
  saved_scrollopt = saved_scrollopt or vim.o.scrollopt
  vim.api.nvim_win_call(win, function()
    vim.cmd("diffthis")
  end)
end

---@return boolean
local function is_set_up()
  return vim.fn.exists(":Gitsigns") == 2
end

---@param buf integer
---@return boolean
local function is_in_current_tabpage(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

--- The reason that `attach()` cannot start, or nil.
---@param buf integer
---@param target didymus.diff.Target
---@return string?
local function check_attach(buf, target)
  if not pcall(require, "gitsigns") then
    return "gitsigns.nvim is not available"
  end
  if not is_set_up() then
    return 'gitsigns.nvim is not set up. Call require("gitsigns").setup().'
  end
  if not M.capabilities.bases[target.base.kind] then
    return ("the gitsigns provider does not accept the base %q"):format(target.base.kind)
  end
  if not M.capabilities.heads[target.head.kind] then
    return ("the gitsigns provider does not accept the head %q"):format(target.head.kind)
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return "the buffer is not loaded"
  end
  -- gitsigns does not update the hunks of a buffer that is not in a window of the current tabpage.
  if not is_in_current_tabpage(buf) then
    return "the buffer is not in a window of the current tabpage"
  end
end

--- The `change_base()` calls of each buffer that wait or run. The first one runs.
---@type table<integer, fun()[]>
local base_queues = {}

--- Call `change_base()` for `buf` after the calls before it, when gitsigns does not compute the
--- hunks. Two calls at the same time can end in any order, and the last one to end sets the base.
---@param buf integer
---@param base string?
---@param cb fun(err: string?)
local function change_base(buf, base, cb)
  local function run_next()
    local queue = base_queues[buf]
    table.remove(queue, 1)
    if #queue > 0 then
      queue[1]()
    else
      base_queues[buf] = nil
    end
  end
  local waited = 0
  local function run()
    if not vim.api.nvim_buf_is_loaded(buf) then
      cb("the buffer is not loaded")
      run_next()
      return
    end
    local idle, err = internal.is_idle(buf)
    if err then
      cb(err)
      run_next()
      return
    end
    -- After the timeout, call `change_base()` also if gitsigns does not become idle.
    if not idle and waited < M.timeout then
      waited = waited + 20
      vim.defer_fn(run, 20)
      return
    end
    vim.api.nvim_buf_call(buf, function()
      require("gitsigns").change_base(
        base,
        false,
        vim.schedule_wrap(function(err)
          cb(err)
          run_next()
        end)
      )
    end)
  end
  if base_queues[buf] then
    table.insert(base_queues[buf], run)
  else
    base_queues[buf] = { run }
    run()
  end
end

--- Put back the base of the gitsigns config, as before `attach()`.
---@param buf integer
local function restore_base(buf)
  change_base(buf, internal.config_base(), function(err)
    if err and vim.api.nvim_buf_is_loaded(buf) then
      vim.notify(
        ("didymus: gitsigns did not put back the base: %s"):format(err),
        vim.log.levels.WARN
      )
    end
  end)
end

---@param buf integer
---@param file didymus.diff.File
---@param target didymus.diff.Target
---@param cb fun(err: string?)
function M:attach(buf, file, target, cb)
  local state = { sha = target.base.sha, ready = false, base_changed = false }
  local finished, timer = false, nil

  ---@param err string?
  local function finish(err)
    if finished then
      return
    end
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if err and attached[buf] == state then
      attached[buf] = nil
      if state.base_changed then
        restore_base(buf)
      end
    end
    state.ready = err == nil
    vim.schedule(function()
      cb(err)
    end)
  end

  local err = check_attach(buf, target)
  if err then
    finish(err)
    return
  end
  attached[buf] = state
  timer = vim.defer_fn(function()
    finish(("gitsigns did not attach to %s in %d ms"):format(file.path, self.timeout))
  end, self.timeout)

  local gitsigns = require("gitsigns")

  ---@param check fun(): boolean?, string?
  ---@param next fun()
  local function wait(check, next)
    if finished then
      return
    end
    if attached[buf] ~= state then
      finish("the buffer was detached")
      return
    end
    local done, check_err = check()
    if check_err then
      finish(check_err)
    elseif done then
      next()
    else
      vim.defer_fn(function()
        wait(check, next)
      end, 20)
    end
  end

  local function has_hunks()
    return internal.has_hunks(buf, state.sha)
  end

  local function set_base()
    state.base_changed = true
    change_base(buf, state.sha, function(base_err)
      if base_err then
        finish("gitsigns: " .. base_err)
      else
        -- The `cb` of `change_base()` can come before the new hunks.
        wait(has_hunks, function()
          finish(nil)
        end)
      end
    end)
  end

  local function is_attached()
    return gitsigns.get_hunks(buf) ~= nil
  end

  gitsigns.attach(
    { bufnr = buf },
    vim.schedule_wrap(function(attach_err)
      if attach_err then
        finish("gitsigns: " .. attach_err)
      else
        -- If gitsigns already attaches the buffer, such as after `BufRead`, `attach()` returns
        -- before that attach ends.
        wait(is_attached, set_base)
      end
    end)
  )
end

---@param buf integer
function M:detach(buf)
  for win, view_buf in pairs(opened_views) do
    if view_buf == buf then
      M:clear(win)
    end
  end
  for win in pairs(diff_wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      turn_off_diff(win)
    end
  end
  local state = attached[buf]
  attached[buf] = nil
  if state and state.base_changed then
    restore_base(buf)
  end
end

--- The marks of the "base" sides in each window. Each window has its own namespace, so that the
--- marks show only in that window.
---@type table<integer, { ns: integer, buf: integer }>
local base_marks = {}

---@param win integer
local function clear_base_marks(win)
  local marks = base_marks[win]
  base_marks[win] = nil
  if marks and vim.api.nvim_buf_is_valid(marks.buf) then
    vim.api.nvim_buf_clear_namespace(marks.buf, marks.ns, 0, -1)
  end
end

vim.api.nvim_create_autocmd("WinClosed", {
  group = diff_group,
  callback = function(args)
    clear_base_marks(tonumber(args.match) --[[@as integer]])
  end,
})

--- Highlight the base lines of the hunks in `buf`, only in `win`.
---@param win integer
---@param buf integer
---@param file_hunks didymus.diff.Hunk[]
local function put_base_marks(win, buf, file_hunks)
  clear_base_marks(win)
  local ns = vim.api.nvim_create_namespace(("didymus.diff.gitsigns.base.%d"):format(win))
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(file_hunks) do
    local last = math.min(hunk.base.start + hunk.base.count - 1, line_count)
    for line = hunk.base.start, last do
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = "DiffDelete" })
    end
  end
  vim.api.nvim__ns_set(ns, { wins = { win } })
  base_marks[win] = { ns = ns, buf = buf }
end

---@param buf integer
---@return didymus.diff.Hunk[]?
function M:hunks(buf)
  local state = attached[buf]
  if not (state and state.ready) then
    return nil
  end
  local result = {}
  for _, hunk in ipairs(require("gitsigns").get_hunks(buf) or {}) do
    table.insert(result, {
      kind = hunk.type,
      base = { start = hunk.removed.start, count = hunk.removed.count },
      head = { start = hunk.added.start, count = hunk.added.count },
    })
  end
  return result
end

---@param display didymus.diff.Display
---@return string?
local function check_render(display)
  if not M.capabilities.layouts[display.layout] then
    return ("the gitsigns provider does not have the %q layout yet"):format(display.layout)
  end
  if not M.capabilities.sides[display.sides] then
    return ("the gitsigns provider does not have the %q sides yet"):format(display.sides)
  end
  local deleted = display.file.status == "deleted"
  if deleted and display.sides ~= "base" then
    return ("%s is deleted, so it has only the base side"):format(display.file.path)
  end
  local state = display.head_buf and attached[display.head_buf]
  if not deleted and not (state and state.ready) then
    return ("%s is not attached"):format(display.file.path)
  end
  ---@param side didymus.diff.Side
  ---@return string?
  local function check_win(side)
    local win, buf = display[side .. "_win"], display[side .. "_buf"]
    if not (win and buf and vim.api.nvim_win_is_valid(win)) then
      return ("the display has no %s window"):format(side)
    end
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return ("the %s window does not show the %s buffer"):format(side, side)
    end
  end
  if display.sides == "base" then
    return check_win("base")
  end
  local err = check_win("head")
  if not err and display.layout == "split" and display.sides == "both" then
    err = check_win("base")
  end
  return err
end

--- Open the unified view in `win`, if it has no view.
---@param win integer
---@param sha string
---@param cb fun(err: string?)
local function open_view(win, sha, cb)
  local open, err = internal.has_view(win)
  if err or open then
    cb(err)
    return
  end
  if vim.wo[win].diff then
    cb("gitsigns does not show the unified view in a window with 'diff'")
    return
  end
  vim.api.nvim_win_call(win, function()
    require("gitsigns").diffthis(
      sha,
      { unified = true },
      vim.schedule_wrap(function(diff_err)
        if diff_err then
          cb("gitsigns: " .. diff_err)
          return
        end
        local opened, view_err = internal.has_view(win)
        if view_err then
          cb(view_err)
        elseif not opened then
          cb("gitsigns did not show the unified view")
        else
          opened_views[win] = vim.api.nvim_win_get_buf(win)
          cb(nil)
        end
      end)
    )
  end)
end

---@param display didymus.diff.Display
---@param cb fun(err: string?)
function M:render(display, cb)
  local function done(err)
    vim.schedule(function()
      cb(err)
    end)
  end
  local err = check_render(display)
  if err then
    done(err)
    return
  end
  local win, buf =
    display.head_win, --[[@as integer]]
    display.head_buf --[[@as integer]]
  if display.sides == "base" then
    local base_win, base_buf =
      display.base_win, --[[@as integer]]
      display.base_buf --[[@as integer]]
    -- A deleted file has no head buffer.
    local file_hunks = display.file.status == "deleted"
        and hunks.get_deleted_file_hunks(vim.api.nvim_buf_line_count(base_buf))
      or M:hunks(buf)
      or {}
    put_base_marks(base_win, base_buf, file_hunks)
    done(nil)
    return
  end
  if display.sides == "head" then
    opened_views[win] = nil
    done(internal.close_view(win))
    return
  end
  if display.layout == "split" then
    -- gitsigns does not show the unified view in a window with 'diff'.
    if opened_views[win] then
      opened_views[win] = nil
      err = internal.close_view(win)
      if err then
        done(err)
        return
      end
    end
    turn_on_diff(display.base_win --[[@as integer]])
    turn_on_diff(win)
    done(nil)
    return
  end
  open_view(win, attached[buf].sha, done)
end

---@param win integer
function M:clear(win)
  clear_base_marks(win)
  opened_views[win] = nil
  internal.close_view(win)
  if vim.api.nvim_win_is_valid(win) then
    turn_off_diff(win)
  end
end

---@param message string
---@param advice string
local function warn(message, advice)
  vim.health.warn(
    ("%s (diff.provider)"):format(message),
    advice .. " The review works with no diff."
  )
end

function M.health()
  if #vim.api.nvim_get_runtime_file("lua/gitsigns.lua", false) == 0 then
    warn("gitsigns.nvim is not available", "Install gitsigns.nvim, or set `diff.provider`.")
  elseif #vim.api.nvim_get_runtime_file("lua/gitsigns/unified.lua", false) == 0 then
    warn("gitsigns.nvim has no unified view", "Update gitsigns.nvim, or set `diff.provider`.")
  elseif not is_set_up() then
    warn("gitsigns.nvim is not set up", 'Call require("gitsigns").setup(), or set `diff.provider`.')
  else
    local missing = internal.find_missing()
    if #missing > 0 then
      warn(
        ("gitsigns.nvim has no %s"):format(table.concat(missing, ", ")),
        "Use a gitsigns.nvim version that has them, or set `diff.provider`."
      )
    else
      vim.health.ok("gitsigns.nvim is available (diff.provider)")
    end
  end
end

return M
