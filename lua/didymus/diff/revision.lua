--- Read-only buffers with the text of a file at a revision, from `git show`. They have the filetype
--- of the file. The `nofile` buffer type keeps LSP and gitsigns off. See docs/architecture/diff.md.

local M = {}

---@class didymus.diff.revision.GetOpts
---@field cwd string
---@field revision didymus.diff.Revision
---@field path string Relative to `cwd`.
---@field empty boolean? The file is not in the revision, such as the base of an added file.

--- The buffers that wait for `git show`, by name.
---@type table<string, fun(buf: integer?, err: string?)[]>
local waiting = {}

--- The loaded buffer with `name`. Delete an unloaded one: it lost its text, because it is
--- `nofile`, and its name blocks a new buffer.
---@param name string
---@return integer?
local function find_buf(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      if vim.api.nvim_buf_is_loaded(buf) then
        return buf
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

---@param name string
---@param path string
---@param lines string[]
---@return integer
local function make_buf(name, path, lines)
  -- A scratch buffer: `nofile`, `bufhidden=hide`, and no swap file.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  local filetype = vim.filetype.match({ filename = path, buf = buf })
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

---@param text string
---@return string[]
local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Get the buffer of `opts.path` at `opts.revision`. A buffer of the same revision and path is used
--- again. Call `cb` in the main loop.
---@param opts didymus.diff.revision.GetOpts
---@param cb fun(buf: integer?, err: string?)
function M.get(opts, cb)
  local revision = opts.revision
  if revision.kind ~= "commit" then
    vim.schedule(function()
      cb(nil, ("a %q revision has no buffer yet"):format(revision.kind))
    end)
    return
  end
  local sha = revision.sha --[[@as string]]
  local name = ("didymus://%s/%s"):format(sha:sub(1, 7), opts.path)
  local buf = find_buf(name)
  if buf or opts.empty then
    vim.schedule(function()
      cb(buf or find_buf(name) or make_buf(name, opts.path, {}))
    end)
    return
  end
  if waiting[name] then
    table.insert(waiting[name], cb)
    return
  end
  waiting[name] = { cb }
  local function finish(lines, err)
    local callbacks = waiting[name]
    waiting[name] = nil
    local result = lines and (find_buf(name) or make_buf(name, opts.path, lines))
    for _, waiting_cb in ipairs(callbacks) do
      waiting_cb(result, err)
    end
  end
  -- "./" makes the path relative to `cwd`, not to the root of the repo.
  local ok, err = pcall(
    vim.system,
    { "git", "show", ("%s:./%s"):format(sha, opts.path) },
    { cwd = opts.cwd, text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or ""):match("[^\n]*")
        return finish(nil, ("git show failed: %s"):format(message))
      end
      finish(split_lines(result.stdout or ""))
    end)
  )
  if not ok then
    vim.schedule(function()
      finish(nil, ("git show failed: %s"):format(err))
    end)
  end
end

return M
