--- A diff provider with no tool, for end-to-end tests. Tests give it the hunks of each path in
--- `hunks_by_path`. `render()` puts one extmark at the stop of each hunk, with the layout and the
--- sides in its text, so that a test can check the screen.

local hunks = require("didymus.diff.hunks")

---@class didymus.diff.provider.Test: didymus.diff.Provider
---@field hunks_by_path table<string, didymus.diff.Hunk[]> The hunks of each head path.
---@field delays table<string, integer> The time in milliseconds before `attach()` of a path calls `cb`.
---@field errors table<string, string> The next call of `attach` or `render` fails with this error.
---@field calls table[] One record of plain data for each call, such as `{ method = "attach", buf = 3, path = "a.lua" }`.
local M = {
  capabilities = {
    layouts = { inline = true, split = true },
    sides = { both = true, base = true, head = true },
    bases = { commit = true, index = true, worktree = true },
    heads = { commit = true, index = true, worktree = true },
  },
  hunks_by_path = {},
  delays = {},
  errors = {},
  calls = {},
}

---@class didymus.diff.provider.test.Attached
---@field path string
---@field hunks didymus.diff.Hunk[]? Nil until `attach()` calls `cb`.

---@type table<integer, didymus.diff.provider.test.Attached>
local attached = {}

--- The marks of each window. Each window has its own namespace, so that `clear()` of one window
--- does not remove the marks of another window with the same buffer.
---@type table<integer, { ns: integer, buf: integer }>
local rendered = {}

---@param record table
local function record(record)
  table.insert(M.calls, record)
end

--- Call `cb` with the error of `method`, if a test set one. Use the error only once.
---@param method string
---@param cb fun(err: string?)
---@return boolean failed
local function fail(method, cb)
  local err = M.errors[method]
  if not err then
    return false
  end
  M.errors[method] = nil
  vim.schedule(function()
    cb(err)
  end)
  return true
end

---@param buf integer
---@param file didymus.diff.File
---@param _ didymus.diff.Target
---@param cb fun(err: string?)
function M:attach(buf, file, _, cb)
  record({ method = "attach", buf = buf, path = file.path })
  if fail("attach", cb) then
    return
  end
  local state = { path = file.path }
  attached[buf] = state
  local function finish()
    if attached[buf] ~= state then
      cb("the buffer was detached")
      return
    end
    state.hunks = vim.deepcopy(self.hunks_by_path[file.path] or {})
    cb(nil)
  end
  local delay = self.delays[file.path]
  if delay then
    vim.defer_fn(finish, delay)
  else
    vim.schedule(finish)
  end
end

---@param win integer
local function clear_marks(win)
  local marks = rendered[win]
  rendered[win] = nil
  if marks and vim.api.nvim_buf_is_valid(marks.buf) then
    vim.api.nvim_buf_clear_namespace(marks.buf, marks.ns, 0, -1)
  end
end

---@param win integer
function M:clear(win)
  record({ method = "clear", win = win })
  clear_marks(win)
end

---@param buf integer
function M:detach(buf)
  record({ method = "detach", buf = buf })
  attached[buf] = nil
  for win, marks in pairs(rendered) do
    if marks.buf == buf then
      clear_marks(win)
    end
  end
end

---@param buf integer
---@return didymus.diff.Hunk[]?
function M:hunks(buf)
  local state = attached[buf]
  return state and vim.deepcopy(state.hunks)
end

--- The hunks of the file of the display: from the head buffer, or from any attached buffer of
--- the file, because the "base" sides have no head buffer.
---@param display didymus.diff.Display
---@return didymus.diff.Hunk[]?
local function find_hunks(display)
  if display.head_buf then
    return M:hunks(display.head_buf)
  end
  for buf, state in pairs(attached) do
    if state.path == display.file.path and state.hunks then
      return M:hunks(buf)
    end
  end
end

---@param win integer
---@param buf integer
---@param side didymus.diff.Side
---@param file_hunks didymus.diff.Hunk[]
---@param text string
local function put_marks(win, buf, side, file_hunks, text)
  clear_marks(win)
  local ns = vim.api.nvim_create_namespace(("didymus.diff.test.%d"):format(win))
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(file_hunks) do
    vim.api.nvim_buf_set_extmark(buf, ns, hunks.stop(hunk, side, line_count) - 1, 0, {
      virt_text = { { text, "Comment" } },
      virt_text_pos = "eol",
    })
  end
  vim.api.nvim__ns_set(ns, { wins = { win } })
  rendered[win] = { ns = ns, buf = buf }
end

---@param display didymus.diff.Display
---@param cb fun(err: string?)
function M:render(display, cb)
  record({
    method = "render",
    layout = display.layout,
    sides = display.sides,
    path = display.file.path,
    head_win = display.head_win,
    head_buf = display.head_buf,
    base_win = display.base_win,
    base_buf = display.base_buf,
  })
  if fail("render", cb) then
    return
  end
  local file_hunks = find_hunks(display)
  if not file_hunks then
    vim.schedule(function()
      cb(("%s is not attached"):format(display.file.path))
    end)
    return
  end
  local text = ("diff %s %s"):format(display.layout, display.sides)
  if display.head_win and display.head_buf then
    put_marks(display.head_win, display.head_buf, "head", file_hunks, text)
  end
  if display.base_win and display.base_buf then
    put_marks(display.base_win, display.base_buf, "base", file_hunks, text)
  end
  vim.schedule(function()
    cb(nil)
  end)
end

function M.health()
  vim.health.ok("The test diff provider needs no dependencies.")
end

return M
