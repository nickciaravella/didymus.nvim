--- The preload of the files of a review, so that the preview of the files panel shows a file and
--- its diff at once. It loads one file at a time, and yields to the main loop between files. The
--- provider attaches only to a buffer in a window of the current tabpage, so the preload shows the
--- buffer in a hidden float of the review tabpage while it prepares it.
--- See docs/architecture/diff.md#preload.

---@class didymus.diff.PreloadOpts
---@field tabpage integer The review tabpage.
---@field cwd string The root of the checkout.
---@field limit integer The most buffers that the preload keeps loaded. Above it, the buffer that the preview used last goes away.
---@field prepare fun(buf: integer, file: didymus.diff.File?, cb: fun(err: string?)) Attach the buffer and prepare its diff. Nil `file` is a path that is not in the target.
---@field is_prepared fun(buf: integer): boolean False if the diff of a ready buffer changed.

---@class didymus.diff.preload.Owned A buffer that the preload loaded.
---@field existed boolean True if the buffer existed before, unloaded.
---@field listed boolean 'buflisted' before the load. A change tells that the user opened the buffer.
---@field used integer The number of the last `get_buf()` that gave it. The lowest goes first.

---@class didymus.diff.preload.Waiting The newest `get_buf()` of a buffer that is not ready.
---@field path string
---@field cb fun()

---@class didymus.diff.Preload
---@field private opts didymus.diff.PreloadOpts
---@field private queue { path: string, file: didymus.diff.File? }[] The files to prepare, in order.
---@field private bufs table<string, integer> The buffer of each path.
---@field private ready table<string, true|"failed"> The paths whose buffer is prepared. A failed path shows with no diff.
---@field private owned table<integer, didymus.diff.preload.Owned>
---@field private use_count integer
---@field private waiting didymus.diff.preload.Waiting?
---@field private running string? The path that the preload prepares now.
---@field private run_scheduled boolean
---@field private generation integer `reset()` makes the callbacks of an older generation old.
---@field private win integer? The hidden float.
local Preload = {}
Preload.__index = Preload

---@param opts didymus.diff.PreloadOpts
---@return didymus.diff.Preload
function Preload.new(opts)
  return setmetatable({
    opts = opts,
    queue = {},
    bufs = {},
    ready = {},
    owned = {},
    use_count = 0,
    run_scheduled = false,
    generation = 0,
  }, Preload)
end

---@param path string
---@return string
function Preload:get_full_path(path)
  return vim.fs.joinpath(self.opts.cwd, path)
end

--- Unload `buf` if only the preload loaded it, no window shows it, and it has no changes. Forget it.
---@param buf integer
function Preload:release(buf)
  local before = self.owned[buf]
  self.owned[buf] = nil
  if
    before
    and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buflisted == before.listed
    and not vim.bo[buf].modified
    and #vim.fn.win_findbuf(buf) == 0
  then
    -- A buffer that the preload made goes away. An older buffer only unloads.
    vim.api.nvim_buf_delete(buf, { unload = before.existed })
  end
end

--- Release the buffers that the preview used last, until the preload keeps `limit` buffers or fewer.
---@param keep integer The buffer to keep.
function Preload:release_old(keep)
  local candidates = {}
  for buf, owned in pairs(self.owned) do
    if
      buf ~= keep
      and (not self.waiting or self.bufs[self.waiting.path] ~= buf)
      and #vim.fn.win_findbuf(buf) == 0
    then
      table.insert(candidates, { buf = buf, used = owned.used })
    end
  end
  table.sort(candidates, function(a, b)
    return a.used < b.used
  end)
  local count = vim.tbl_count(self.owned)
  for _, candidate in ipairs(candidates) do
    if count <= math.max(self.opts.limit, 1) then
      return
    end
    self:release(candidate.buf)
    count = count - 1
  end
end

--- The loaded buffer of `path`.
---@param path string
---@return integer
function Preload:load(path)
  local full_path = self:get_full_path(path)
  local existed = vim.fn.bufexists(full_path) == 1
  local buf = vim.fn.bufadd(full_path)
  if not vim.api.nvim_buf_is_loaded(buf) then
    self.owned[buf] = { existed = existed, listed = vim.bo[buf].buflisted, used = 0 }
    -- A swap file of an other Neovim shows a prompt that blocks the UI.
    vim.bo[buf].swapfile = false
    vim.fn.bufload(buf)
    self:release_old(buf)
  end
  self.bufs[path] = buf
  return buf
end

--- Show `buf` in the hidden float.
---@param buf integer
function Preload:show_in_win(buf)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  else
    self.win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 1,
      height = 1,
      hide = true,
      focusable = false,
      style = "minimal",
      noautocmd = true,
    })
  end
end

function Preload:close_win()
  local win = self.win
  self.win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

--- Run the next file of the queue in a later tick, so that the UI does its work first.
function Preload:schedule_run()
  if self.run_scheduled then
    return
  end
  self.run_scheduled = true
  local generation = self.generation
  vim.schedule(function()
    self.run_scheduled = false
    if generation == self.generation then
      self:run()
    end
  end)
end

--- Prepare the next file of the queue. Stop while the review tabpage is not current. `resume()`
--- starts again.
function Preload:run()
  if self.running or vim.api.nvim_get_current_tabpage() ~= self.opts.tabpage then
    return
  end
  local next_file = table.remove(self.queue, 1)
  while next_file and self.ready[next_file.path] do
    next_file = table.remove(self.queue, 1)
  end
  if not next_file then
    self:close_win()
    return
  end
  local path, generation = next_file.path, self.generation
  local buf = self:load(path)
  self.running = path
  self:show_in_win(buf)
  ---@param err string?
  local function finish(err)
    if generation ~= self.generation then
      return
    end
    self.running = nil
    if vim.api.nvim_buf_is_loaded(buf) then
      self.ready[path] = err and "failed" or true
    end
    local waiting = self.waiting
    if waiting and waiting.path == path then
      self.waiting = nil
      waiting.cb()
    end
    self:schedule_run()
  end
  -- The first redraw of a buffer that is not parsed shows it with no highlights.
  local highlighter = vim.treesitter.highlighter.active[buf]
  local function prepare()
    if generation == self.generation and vim.api.nvim_buf_is_loaded(buf) then
      self.opts.prepare(buf, next_file.file, finish)
    else
      finish()
    end
  end
  if highlighter then
    highlighter.tree:parse(true, vim.schedule_wrap(prepare))
  else
    prepare()
  end
end

--- Prepare `files` in their order, up to the limit. A `get_buf()` goes first.
---@param files didymus.diff.File[]
function Preload:start(files)
  self.queue = {}
  for _, file in ipairs(files) do
    if #self.queue >= self.opts.limit then
      break
    end
    if file.status ~= "deleted" then
      table.insert(self.queue, { path = file.path, file = file })
    end
  end
  self:schedule_run()
end

function Preload:resume()
  self:schedule_run()
end

--- The buffer of `path`, if it is prepared. Else prepare it first, and call `cb` when it is ready.
---@param path string
---@param file didymus.diff.File? Nil if `path` is not in the target.
---@param cb fun()
---@return integer?
function Preload:get_buf(path, file, cb)
  local buf = self.bufs[path]
  if
    self.ready[path]
    and buf
    and vim.api.nvim_buf_is_loaded(buf)
    and (not file or self.opts.is_prepared(buf) or self.ready[path] == "failed")
  then
    self.use_count = self.use_count + 1
    if self.owned[buf] then
      self.owned[buf].used = self.use_count
    end
    return buf
  end
  self.ready[path] = nil
  self.waiting = { path = path, cb = cb }
  if self.running ~= path then
    table.insert(self.queue, 1, { path = path, file = file })
  end
  self:schedule_run()
end

--- Forget the prepared state, for example after the diff hides. Keep the buffers.
function Preload:reset()
  self.generation = self.generation + 1
  self.queue, self.ready, self.waiting, self.running = {}, {}, nil, nil
  self.run_scheduled = false
  self:close_win()
end

--- Forget `buf`, because it unloads.
---@param buf integer
function Preload:forget(buf)
  self.owned[buf] = nil
  for path, path_buf in pairs(self.bufs) do
    if path_buf == buf then
      self.bufs[path], self.ready[path] = nil, nil
    end
  end
end

--- Stop, and unload the buffers that only the preload loaded. Call it when the review closes.
function Preload:close()
  self:reset()
  for buf in pairs(self.owned) do
    self:release(buf)
  end
  self.bufs = {}
end

return Preload
