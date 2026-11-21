--- Interactive inline boxes embedded in the `virt_lines` space of a review buffer, plus a
--- bottom-split fallback for deleted files with no buffer. Supports read-only thread focus and
--- editable markdown comment/reply boxes.

local M = {}

--- Namespace for highlighting the commented lines while a new comment box is open.
M.context_namespace = vim.api.nvim_create_namespace("didymus.review.inline_context")

local box_border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }
local reply_border = { "├", "─", "┤", "│", "┘", "─", "└", "│" }

M.borders = {
  box = box_border,
  reply = reply_border,
}

---@class didymus.review.InlineAnchor
---@field buf integer
---@field row integer 0-based anchor line in `buf`.
---@field above boolean True for top-of-file threads (`virt_lines_above`).
---@field offset integer Number of `virt_lines` before this slot on `row`.
---@field total_above integer Total `virt_lines_above` lines on row 0 (only when `above` is true).
---@field indent integer Indent of the box in columns.
---@field box_width integer Outer width of the box, including the left and right borders.
---@field outer_height integer Total height of the box, including the top and bottom borders.

---@class didymus.review.InlineBoxAction
---@field key string|false In normal and insert mode. False turns off the action.
---@field name string Label in the footer, such as "comment now".
---@field on_submit fun(text: string)

---@class didymus.review.InlineThreadKeys
---@field reply? { key: string|false, fn: fun() }
---@field resolve? { key: string|false, name: string, fn: fun() }
---@field fold? { key: string|false, fn: fun() }

---@class didymus.review.InlineBoxOpts
---@field mode "focus"|"edit"
---@field kind "focus"|"reply"|"comment"
---@field path string
---@field thread_id string?
---@field range didymus.review.Range?
---@field location string
---@field title string
---@field title_hl string?
---@field border string[]?
---@field border_hl string?
---@field lines string[]?
---@field max_height integer
---@field split boolean? True for a bottom split under the code window (for deleted files).
---@field actions didymus.review.InlineBoxAction[]?
---@field cancel_key (string|false)?
---@field thread_keys didymus.review.InlineThreadKeys?
---@field on_attach fun(box: didymus.review.InlineBox)?
---@field on_change fun()
---@field on_close fun()?
---@field get_host_win fun(): integer?
---@field get_anchor fun(): didymus.review.InlineAnchor?
---@field open_host fun(): integer? Open the file in the code window if not currently visible.

---@class didymus.review.InlineBox
---@field mode "focus"|"edit"
---@field kind "focus"|"reply"|"comment"
---@field path string
---@field thread_id string?
---@field range didymus.review.Range?
---@field location string
---@field split boolean
---@field buf integer
---@field win integer
---@field height integer Desired inner height (excluding borders).
---@field max_height integer
---@field private title string
---@field private title_hl string
---@field private border string[]
---@field private border_hl string
---@field private footer string
---@field private on_change fun()
---@field private on_close fun()?
---@field private get_host_win fun(): integer?
---@field private get_anchor fun(): didymus.review.InlineAnchor?
---@field private open_host fun(): integer?
---@field private group integer
---@field private closed boolean
---@field private context_buf integer?
---@field private last_config table?
local InlineBox = {}
InlineBox.__index = InlineBox

--- Scope the context highlight namespace to the windows of the review tabpage.
---@param wins integer[]
function M.scope_context(wins)
  local set_namespace = vim.api.nvim__ns_set
  if set_namespace and #wins > 0 then
    set_namespace(M.context_namespace, { wins = wins })
  end
end

--- Clear context highlights from all loaded buffers.
function M.clear_context()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.context_namespace, 0, -1)
    end
  end
end

---@param buf integer
---@param range didymus.review.Range
local function highlight_context(buf, range)
  vim.api.nvim_set_hl(0, "DidymusInputContext", { link = "Visual", default = true })
  vim.api.nvim_buf_clear_namespace(buf, M.context_namespace, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local first = math.min(range.first, line_count)
  local last = math.min(range.last, line_count)
  vim.api.nvim_buf_set_extmark(buf, M.context_namespace, first - 1, 0, {
    end_row = last,
    end_col = 0,
    strict = false,
    hl_group = "DidymusInputContext",
    hl_eol = true,
  })
end

---@param opts didymus.review.InlineBoxOpts
---@return string
local function build_footer(opts)
  local parts = {}
  if opts.mode == "edit" then
    for _, action in ipairs(opts.actions or {}) do
      if action.key then
        table.insert(parts, ("%s %s"):format(action.key, action.name))
      end
    end
    if opts.cancel_key ~= false then
      table.insert(parts, ("%s cancel"):format(opts.cancel_key or "q"))
    end
  else
    local tk = opts.thread_keys or {}
    if tk.reply and tk.reply.key then
      table.insert(parts, ("%s reply"):format(tk.reply.key))
    end
    if tk.resolve and tk.resolve.key then
      table.insert(parts, ("%s %s"):format(tk.resolve.key, tk.resolve.name))
    end
    if tk.fold and tk.fold.key then
      table.insert(parts, ("%s fold"):format(tk.fold.key))
    end
    table.insert(parts, "q close")
  end
  return table.concat(parts, "  ")
end

--- Compute the 1-based screen row of the top of the spacer slot in `host_win`, or nil if off screen.
---@param host_win integer
---@param anchor didymus.review.InlineAnchor
---@return integer? screen_top
---@return integer win_text_top
---@return integer win_text_bottom
---@return integer textoff
local function measure_slot(host_win, anchor)
  local info = vim.fn.getwininfo(host_win)[1]
  local win_text_top = info.winrow + info.winbar
  local win_text_bottom = win_text_top + info.height - 1

  if anchor.above then
    local sp1 = vim.fn.screenpos(host_win, 1, 1)
    if sp1.row > 0 then
      local screen_top = (sp1.row - anchor.total_above) + anchor.offset
      return screen_top, win_text_top, win_text_bottom, info.textoff
    end
    if info.topline == 1 then
      local topfill = vim.api.nvim_win_call(host_win, function()
        return vim.fn.winsaveview().topfill
      end)
      local first_visible = anchor.total_above - topfill
      local screen_top = win_text_top + anchor.offset - first_visible
      return screen_top, win_text_top, win_text_bottom, info.textoff
    end
    return nil, win_text_top, win_text_bottom, info.textoff
  end

  local line_num = anchor.row + 1
  local line_text = vim.api.nvim_buf_get_lines(anchor.buf, anchor.row, anchor.row + 1, true)[1]
    or ""
  local sp = vim.fn.screenpos(host_win, line_num, math.max(1, #line_text))
  if sp.row == 0 then
    return nil, win_text_top, win_text_bottom, info.textoff
  end
  local screen_top = sp.row + 1 + anchor.offset
  return screen_top, win_text_top, win_text_bottom, info.textoff
end

--- Scroll `host_win` so that the anchor line and its inline slot fit inside `host_win`.
---@param host_win integer
---@param anchor didymus.review.InlineAnchor
local function scroll_slot_into_view(host_win, anchor)
  local info = vim.fn.getwininfo(host_win)[1]
  local win_height = info.height
  if anchor.above then
    local needed_topfill = math.min(anchor.total_above, anchor.total_above - anchor.offset)
    vim.api.nvim_win_call(host_win, function()
      local view = vim.fn.winsaveview()
      if view.topline > 1 or view.topfill < needed_topfill then
        vim.fn.winrestview({ topline = 1, topfill = needed_topfill, lnum = 1 })
      end
    end)
    return
  end

  local line = anchor.row + 1
  local line_count = vim.api.nvim_buf_line_count(anchor.buf)
  local function rows_from(top)
    local opts = { start_row = top - 1, start_vcol = 0 }
    if line == line_count then
      return vim.api.nvim_win_text_height(host_win, opts).all
    end
    opts.end_row = line
    local next_line =
      vim.api.nvim_win_text_height(host_win, { start_row = line, start_vcol = 0, end_row = line })
    return vim.api.nvim_win_text_height(host_win, opts).all - next_line.all
  end

  vim.api.nvim_win_call(host_win, function()
    local view = vim.fn.winsaveview()
    local top = view.topline
    if line < top then
      top = math.max(1, line - vim.o.scrolloff)
      vim.fn.winrestview({ topline = top, topfill = 0, lnum = line })
    end
    -- Keep the anchor line in view (respecting 'scrolloff' if it fits).
    local last_top = math.max(top, line - vim.o.scrolloff)
    local new_top = top
    while new_top < last_top and rows_from(new_top) > win_height do
      new_top = new_top + 1
    end
    -- If it still does not fit with scrolloff, scroll up to the anchor line itself.
    while new_top < line and rows_from(new_top) > win_height do
      new_top = new_top + 1
    end
    if new_top ~= top then
      vim.fn.winrestview({ topline = new_top, topfill = 0 })
    end
  end)
end

---@return boolean
function InlineBox:is_active()
  return not self.closed and (self.win == -1 or vim.api.nvim_win_is_valid(self.win))
end

---@return boolean
function InlineBox:is_open()
  return not self.closed and vim.api.nvim_win_is_valid(self.win)
end

---@return boolean
function InlineBox:is_focused()
  return self:is_open() and vim.api.nvim_get_current_win() == self.win
end

---@return integer
function InlineBox:get_desired_height()
  if not self:is_open() then
    return self.height
  end
  local text_height = vim.api.nvim_win_text_height(self.win, {}).all
  return math.max(1, math.min(text_height, self.max_height))
end

--- Compute the window config for `self.win` inside `host_win`, or nil if hidden.
---@param host_win integer
---@param anchor didymus.review.InlineAnchor
---@return vim.api.keyset.win_config?
function InlineBox:compute_win_config(host_win, anchor)
  local screen_top, win_text_top, win_text_bottom, textoff = measure_slot(host_win, anchor)
  if not screen_top then
    return nil
  end
  local screen_bottom = screen_top + anchor.outer_height - 1
  if screen_top < win_text_top or screen_top > win_text_bottom then
    return nil
  end
  local visible_outer = math.min(screen_bottom, win_text_bottom) - screen_top + 1
  -- Need at least top border + 1 text row + bottom border.
  if visible_outer < 3 then
    return nil
  end
  local width = math.max(1, anchor.box_width - 2)
  local inner_height = math.max(1, visible_outer - 2)
  local title_prefix = "─"
  local title = (" %s "):format(self.title)
  local max_title_width = math.max(0, width - 1)
  if vim.fn.strdisplaywidth(title) > max_title_width then
    local chars = vim.fn.split(title, [[\zs]])
    local kept, used = {}, 0
    for _, char in ipairs(chars) do
      local w = vim.fn.strdisplaywidth(char)
      if used + w > max_title_width then
        break
      end
      table.insert(kept, char)
      used = used + w
    end
    title = table.concat(kept)
  end
  local config = {
    relative = "win",
    win = host_win,
    row = screen_top - win_text_top,
    col = textoff + anchor.indent,
    width = width,
    height = inner_height,
    border = self.border,
    title = { { title_prefix, self.border_hl }, { title, self.title_hl } },
    title_pos = "left",
    hide = false,
  }
  local footer = self.footer ~= "" and (" %s "):format(self.footer) or ""
  if footer ~= "" and vim.fn.strdisplaywidth(footer) + 1 <= width then
    config.footer = { { "─", self.border_hl }, { footer, "Comment" } }
    config.footer_pos = "left"
  else
    config.footer = nil
  end
  return config
end

--- Update position, size, and visibility of `self.win` to match the `virt_lines` slot.
---@param scroll_into_view boolean?
function InlineBox:sync(scroll_into_view)
  if self.split or not self:is_open() then
    return
  end
  local host_win = self.get_host_win()
  local anchor = host_win and self.get_anchor()
  if not host_win or not anchor then
    if not self.last_config or not self.last_config.hide then
      vim.api.nvim_win_set_config(self.win, { hide = true })
      self.last_config = { hide = true }
    end
    return
  end

  if scroll_into_view or self:is_focused() then
    scroll_slot_into_view(host_win, anchor)
  end

  local cfg = self:compute_win_config(host_win, anchor)
  if not cfg then
    if not self.last_config or not self.last_config.hide then
      vim.api.nvim_win_set_config(self.win, { hide = true })
      self.last_config = { hide = true }
    end
    return
  end

  if not vim.deep_equal(cfg, self.last_config) then
    vim.api.nvim_win_set_config(self.win, cfg)
    self.last_config = cfg
  end
  if self.mode == "edit" then
    local text_height = vim.api.nvim_win_text_height(self.win, {}).all
    if text_height <= cfg.height then
      vim.api.nvim_win_call(self.win, function()
        vim.fn.winrestview({ topline = 1, skipcol = 0 })
      end)
    end
  end
end

--- Grow or shrink the box height when the buffer text changes or wraps.
function InlineBox:update_height()
  if not self:is_open() then
    return
  end
  local new_height = self:get_desired_height()
  if self.split then
    if new_height ~= self.height then
      self.height = new_height
      vim.api.nvim_win_set_height(self.win, math.max(3, new_height))
    end
    return
  end
  if new_height ~= self.height then
    self.height = new_height
    self.on_change()
  end
  self:sync(true)
end

--- Focus the inline box. If its file is not currently shown, open it first.
function InlineBox:focus()
  if not self:is_open() then
    return
  end
  if not self.split then
    local host_win = self.get_host_win()
    if not host_win and self.open_host then
      self.open_host()
    end
    self.on_change()
    self:sync(true)
  end
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    if self.mode == "edit" then
      vim.cmd.startinsert({ bang = true })
    end
  end
end

--- Leave the inline box and return focus to the host window, keeping the box open as a draft.
function InlineBox:leave()
  if not self:is_open() then
    return
  end
  local host_win = self.get_host_win()
  if host_win and vim.api.nvim_win_is_valid(host_win) then
    vim.api.nvim_set_current_win(host_win)
  end
end

--- Close the inline box, restore focus to the host window if needed, and clear spacers.
---@param cb fun(...)?
---@param ... any
function InlineBox:close(cb, ...)
  if self.closed then
    return
  end
  self.closed = true
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
  end
  if self.context_buf and vim.api.nvim_buf_is_valid(self.context_buf) then
    vim.api.nvim_buf_clear_namespace(self.context_buf, M.context_namespace, 0, -1)
  end
  local was_focused = vim.api.nvim_win_is_valid(self.win)
    and vim.api.nvim_get_current_win() == self.win
  local host_win = self.get_host_win()
  if was_focused and host_win and vim.api.nvim_win_is_valid(host_win) then
    vim.api.nvim_set_current_win(host_win)
  end
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if self.on_close then
    self.on_close()
  end
  self.on_change()
  if cb then
    cb(...)
  end
end

--- Set up buffer keymaps and autocmds for `self`.
---@param opts didymus.review.InlineBoxOpts
function InlineBox:setup_interactions(opts)
  local map_opts = { buffer = self.buf, nowait = true }
  if self.mode == "edit" then
    local actions = vim.tbl_filter(function(action)
      return action.key
    end, opts.actions or {})

    ---@param on_submit fun(text: string)
    local function submit(on_submit)
      local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
      while #lines > 0 and lines[#lines]:match("^%s*$") do
        table.remove(lines)
      end
      if #lines == 0 then
        return
      end
      -- Close after leaving insert mode, so insert mode does not stay on in the code window.
      vim.cmd.stopinsert()
      vim.schedule(function()
        self:close(on_submit, table.concat(lines, "\n"))
      end)
    end

    ---@param modes string[]
    local function map_actions(modes)
      for _, action in ipairs(actions) do
        vim.keymap.set(modes, action.key --[[@as string]], function()
          submit(action.on_submit)
        end, map_opts)
      end
    end

    map_actions({ "n", "i" })
    if opts.cancel_key ~= false then
      vim.keymap.set("n", opts.cancel_key or "q", function()
        self:close()
      end, map_opts)
    end
    vim.keymap.set("n", "<Esc>", function()
      self:leave()
    end, map_opts)

    -- Completion plugins can set buffer mappings on InsertEnter. Set the submit mappings after them.
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = self.group,
      buffer = self.buf,
      callback = function()
        vim.schedule(function()
          if not self.closed and vim.api.nvim_buf_is_valid(self.buf) then
            map_actions({ "i" })
          end
        end)
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = self.group,
      buffer = self.buf,
      callback = function()
        self:update_height()
      end,
    })
  else
    local close_focus = function()
      self:close()
    end
    vim.keymap.set("n", "q", close_focus, map_opts)
    vim.keymap.set("n", "<Esc>", close_focus, map_opts)

    local tk = opts.thread_keys or {}
    if tk.reply and tk.reply.key then
      vim.keymap.set(
        "n",
        tk.reply.key --[[@as string]],
        tk.reply.fn,
        vim.tbl_extend("force", map_opts, { desc = "didymus: review reply" })
      )
    end
    if tk.resolve and tk.resolve.key then
      vim.keymap.set(
        "n",
        tk.resolve.key --[[@as string]],
        tk.resolve.fn,
        vim.tbl_extend("force", map_opts, { desc = "didymus: review " .. tk.resolve.name })
      )
    end
    if tk.fold and tk.fold.key then
      vim.keymap.set(
        "n",
        tk.fold.key --[[@as string]],
        tk.fold.fn,
        vim.tbl_extend("force", map_opts, { desc = "didymus: review fold" })
      )
    end

    if not self.split then
      -- A focused inline thread has no unsaved text, so leaving it reverts cleanly to `virt_lines`.
      vim.api.nvim_create_autocmd("WinLeave", {
        group = self.group,
        buffer = self.buf,
        callback = function()
          vim.schedule(function()
            self:close()
          end)
        end,
      })
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(self.win),
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })

  if not self.split then
    vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "BufWinEnter", "TabEnter" }, {
      group = self.group,
      callback = function()
        if not self.closed then
          self:sync(false)
        end
      end,
    })
  end
end

--- Open an inline box embedded in `virt_lines` space, or a bottom split when `opts.split` is true.
---@param opts didymus.review.InlineBoxOpts
---@return didymus.review.InlineBox?
function M.open(opts)
  local lines = opts.lines and #opts.lines > 0 and opts.lines or { "" }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if opts.mode == "edit" then
    vim.bo[buf].autocomplete = false
    -- blink.cmp and snacks.nvim read `b:completion`. Set before filetype so user FileType autocmds can override.
    vim.b[buf].completion = false
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].filetype = "markdown"
  if opts.mode == "focus" then
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  end

  local initial_height = math.max(1, math.min(#lines, opts.max_height))
  local self = setmetatable({
    mode = opts.mode,
    kind = opts.kind,
    path = opts.path,
    thread_id = opts.thread_id,
    range = opts.range,
    location = opts.location,
    split = opts.split or false,
    buf = buf,
    win = -1,
    height = initial_height,
    max_height = opts.max_height,
    title = opts.title,
    title_hl = opts.title_hl or "DidymusThread",
    border = opts.border or box_border,
    border_hl = opts.border_hl or "DidymusThreadBorder",
    footer = build_footer(opts),
    on_change = opts.on_change,
    on_close = opts.on_close,
    get_host_win = opts.get_host_win,
    get_anchor = opts.get_anchor,
    open_host = opts.open_host,
    closed = false,
  }, InlineBox)

  if opts.on_attach then
    opts.on_attach(self)
  end

  if self.split then
    local height = math.max(3, math.min(#lines + 1, opts.max_height))
    vim.cmd(("botright %dsplit"):format(height))
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.win, buf)
    vim.wo[self.win][0].wrap = true
    vim.wo[self.win][0].linebreak = true
    vim.wo[self.win][0].winfixbuf = true
    vim.wo[self.win][0].winfixheight = true
    vim.wo[self.win][0].number = false
    vim.wo[self.win][0].relativenumber = false
    vim.wo[self.win][0].signcolumn = "no"
    local bar = self.footer ~= "" and (" %s  (%s) "):format(self.title, self.footer)
      or (" %s "):format(self.title)
    vim.wo[self.win][0].winbar = bar:gsub("%%", "%%%%")
  else
    -- Draw the spacer first so `get_anchor()` has the exact row, offset and box width.
    self.on_change()
    local host_win = self.get_host_win()
    local anchor = host_win and self.get_anchor()
    if not host_win or not anchor then
      vim.api.nvim_buf_delete(buf, { force = true })
      self.closed = true
      self.on_change()
      return nil
    end

    if self.kind == "comment" and self.range then
      self.context_buf = anchor.buf
      highlight_context(anchor.buf, self.range)
    end

    scroll_slot_into_view(host_win, anchor)
    local cfg = self:compute_win_config(host_win, anchor)
    if not cfg then
      -- Fallback minimal config if the window is very small.
      local info = vim.fn.getwininfo(host_win)[1]
      cfg = {
        relative = "win",
        win = host_win,
        row = 0,
        col = info.textoff + anchor.indent,
        width = math.max(1, anchor.box_width - 2),
        height = math.max(1, math.min(self.height, math.max(1, info.height - 2))),
        border = self.border,
        title = { { "─", self.border_hl }, { (" %s "):format(self.title), self.title_hl } },
        title_pos = "left",
        hide = false,
      }
    end
    cfg.style = "minimal"
    self.win = vim.api.nvim_open_win(buf, true, cfg)
    self.last_config = vim.tbl_extend("force", {}, cfg)
    self.last_config.style = nil

    vim.wo[self.win][0].wrap = true
    vim.wo[self.win][0].linebreak = true
    vim.wo[self.win][0].winfixbuf = true
    vim.wo[self.win][0].conceallevel = 0
    -- One-cell left margin aligns the buffer text with `│ ` in `virt_lines`.
    vim.wo[self.win][0].statuscolumn = " "
    vim.wo[self.win][0].winhighlight = ("Normal:Normal,FloatBorder:%s,FloatTitle:%s,FloatFooter:Comment"):format(
      self.border_hl,
      self.title_hl
    )

    -- Re-measure height after wrapping inside the window.
    local desired = self:get_desired_height()
    if desired ~= self.height then
      self.height = desired
      self.on_change()
      self:sync(true)
    end
  end

  self.group = vim.api.nvim_create_augroup(("didymus.review.inline_box.%d"):format(self.win), {})
  self:setup_interactions(opts)

  if self.mode == "edit" then
    vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(buf), 0 })
    vim.cmd.startinsert({ bang = true })
  end

  return self
end

return M
