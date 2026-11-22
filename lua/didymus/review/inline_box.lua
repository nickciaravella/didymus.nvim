--- Interactive inline boxes embedded in the `virt_lines` space of a review buffer, plus a
--- bottom-split fallback for deleted files with no buffer. Supports read-only thread focus and
--- editable markdown comment/reply boxes.

local M = {}

-- Register the markdown treesitter parser for `didymus_input` and `didymus_thread` so
-- `vim.treesitter.get_parser(buf)` (and plugins such as render-markdown.nvim) can parse them
-- without triggering markdown filetype autocmds that race with our per-buffer render state.
pcall(vim.treesitter.language.register, "markdown", "didymus_input")
pcall(vim.treesitter.language.register, "markdown", "didymus_thread")

--- Render markdown in `buf`/`win` with no anti-conceal under the cursor (works with both
--- render-markdown.nvim and built-in Neovim conceal). Calls `on_rendered` after extmarks settle.
---@param buf integer
---@param win integer
---@param on_rendered fun()?
local function show_rendered_markdown(buf, win, on_rendered)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
    return
  end
  vim.wo[win][0].conceallevel = 3
  vim.wo[win][0].concealcursor = "nvc"
  local ok, render_markdown = pcall(require, "render-markdown")
  if ok and render_markdown and type(render_markdown.render) == "function" then
    local rm_state = package.loaded["render-markdown.state"]
    if rm_state and type(rm_state.cache) == "table" then
      rm_state.cache[buf] = nil
    end
    pcall(render_markdown.render, {
      buf = buf,
      win = win,
      config = {
        enabled = true,
        debounce = 0,
        anti_conceal = { enabled = false },
        win_options = {
          conceallevel = { rendered = 3 },
          concealcursor = { rendered = "nvc" },
        },
      },
    })
  end
  if on_rendered then
    -- `render-markdown.nvim` schedules its updater via `vim.schedule`, so run `on_rendered` after it.
    vim.schedule(on_rendered)
  end
end

--- Show raw markdown source with treesitter syntax highlights in `buf`/`win` (no conceal and no
--- render-markdown.nvim overlays).
---@param buf integer
---@param win integer
local function show_raw_markdown(buf, win)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local rm_state = package.loaded["render-markdown.state"]
  if rm_state and type(rm_state.cache) == "table" and rm_state.cache[buf] then
    rm_state.cache[buf].enabled = false
  end
  local rm_ui = package.loaded["render-markdown.core.ui"]
  if rm_ui and rm_ui.ns then
    vim.api.nvim_buf_clear_namespace(buf, rm_ui.ns, 0, -1)
    if type(rm_ui.get) == "function" then
      pcall(function()
        rm_ui.get(buf):clear(rm_ui.ns)
      end)
    end
  end
  vim.wo[win][0].conceallevel = 0
  vim.wo[win][0].concealcursor = ""
  pcall(vim.treesitter.start, buf, "markdown")
end

--- Schedule rendered markdown setup so it runs after window layout and lazy plugin attach settle.
---@param buf integer
---@param win integer
---@param on_rendered fun()?
local function configure_readonly_markdown(buf, win, on_rendered)
  vim.wo[win][0].conceallevel = 3
  vim.wo[win][0].concealcursor = "nvc"
  vim.schedule(function()
    show_rendered_markdown(buf, win, on_rendered)
  end)
end

--- Namespace for highlighting the commented lines while a new comment box is open.
M.context_namespace = vim.api.nvim_create_namespace("didymus.review.inline_context")
--- Namespace for smooth divider overlays and comment headers in raw source mode.
M.divider_namespace = vim.api.nvim_create_namespace("didymus.review.inline_divider")
--- Namespace for Path B pre-rendered markdown highlights and inline padding in focused threads.
M.render_namespace = vim.api.nvim_create_namespace("didymus.review.inline_render")
--- Namespace for shortcut popup highlights.
M.help_namespace = vim.api.nvim_create_namespace("didymus.review.inline_help")

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
---@field source? { key: string|false }

---@class didymus.review.InlineBoxOpts
---@field mode "focus"|"edit"
---@field kind "focus"|"reply"|"comment"
---@field path string
---@field thread_id string?
---@field range didymus.review.Range?
---@field location string
---@field title string?
---@field title_hl string?
---@field border string[]?
---@field border_hl string?
---@field lines string[]?
---@field initial_height integer?
---@field dividers didymus.review.CommentDivider[]?
---@field headers didymus.review.CommentHeader[]?
---@field render_rendered (fun(box_width: integer): didymus.review.RenderedRow[])?
---@field render_raw (fun(): string[], didymus.review.CommentDivider[], didymus.review.CommentHeader[])?
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
---@field private dividers didymus.review.CommentDivider[]
---@field private headers didymus.review.CommentHeader[]
---@field private render_rendered (fun(box_width: integer): didymus.review.RenderedRow[])?
---@field private render_raw (fun(): string[], didymus.review.CommentDivider[], didymus.review.CommentHeader[])?
---@field private show_raw boolean
---@field private rendered_width integer?
---@field private help_items { key: string, desc: string }[]
---@field private help_win integer?
---@field private opening_help boolean
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
  if opts.mode ~= "edit" then
    return ""
  end
  local parts = {}
  for _, action in ipairs(opts.actions or {}) do
    if action.key then
      table.insert(parts, ("%s %s"):format(action.key, action.name))
    end
  end
  if opts.cancel_key ~= false then
    table.insert(parts, ("%s cancel"):format(opts.cancel_key or "q"))
  end
  return table.concat(parts, "  ")
end

---@param opts didymus.review.InlineBoxOpts
---@return { key: string, desc: string }[]
local function build_help_items(opts)
  local items = {}
  if opts.mode == "edit" then
    for _, action in ipairs(opts.actions or {}) do
      if action.key then
        table.insert(items, { key = action.key, desc = action.name })
      end
    end
    table.insert(items, { key = "<Esc>", desc = "leave box (keep draft)" })
    if opts.cancel_key ~= false then
      table.insert(items, { key = opts.cancel_key or "q", desc = "cancel draft" })
    end
  else
    local tk = opts.thread_keys or {}
    if tk.reply and tk.reply.key then
      table.insert(items, { key = tk.reply.key, desc = "reply to thread" })
    end
    if tk.resolve and tk.resolve.key then
      table.insert(items, { key = tk.resolve.key, desc = tk.resolve.name .. " thread" })
    end
    if tk.fold and tk.fold.key then
      table.insert(items, { key = tk.fold.key, desc = "fold thread" })
    end
    if tk.source and tk.source.key then
      table.insert(items, { key = tk.source.key, desc = "toggle markdown source" })
    end
    table.insert(items, { key = "q / <Esc>", desc = "close thread focus" })
  end
  table.insert(items, { key = "?", desc = "show or close shortcuts" })
  return items
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
  local screen_top, win_text_top, win_text_bottom = measure_slot(host_win, anchor)
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
  local config = {
    relative = "win",
    win = host_win,
    row = screen_top - win_text_top,
    col = anchor.indent,
    width = width,
    height = inner_height,
    border = self.border,
    hide = false,
  }
  if self.title and self.title ~= "" then
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
    config.title = { { title_prefix, self.border_hl }, { title, self.title_hl } }
    config.title_pos = "left"
  else
    config.title = nil
  end
  local footer = self.footer ~= "" and (" %s "):format(self.footer) or ""
  if footer ~= "" and vim.fn.strdisplaywidth(footer) + 1 <= width then
    config.footer = { { "─", self.border_hl }, { footer, "DidymusThreadFooter" } }
    config.footer_pos = "left"
  else
    config.footer = nil
  end
  return config
end

--- Overlay smooth horizontal dividers on `***` separator lines and style comment header lines
--- (bold author, tags, lighter datetime) so focused threads match unfocused threads.
function InlineBox:draw_dividers()
  if not self:is_open() or (#self.dividers == 0 and #self.headers == 0) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buf, M.divider_namespace, 0, -1)
  local inner_width = math.max(1, vim.api.nvim_win_get_width(self.win) - (self.split and 0 or 1))
  local line_count = vim.api.nvim_buf_line_count(self.buf)
  for _, divider in ipairs(self.dividers) do
    if divider.row < line_count then
      local border_hl = divider.resolved and "DidymusThreadResolvedBorder" or self.border_hl
      vim.api.nvim_buf_set_extmark(self.buf, M.divider_namespace, divider.row, 0, {
        virt_text = { { ("─"):rep(inner_width), border_hl } },
        virt_text_pos = "overlay",
        priority = 5000,
      })
    end
  end
  for _, header in ipairs(self.headers) do
    if header.row < line_count then
      local col = 0
      for _, chunk in ipairs(header.chunks) do
        local len = #chunk[1]
        if chunk[2] and len > 0 then
          vim.api.nvim_buf_set_extmark(self.buf, M.divider_namespace, header.row, col, {
            end_row = header.row,
            end_col = col + len,
            hl_group = chunk[2],
            priority = 5000,
          })
        end
        col = col + len
      end
    end
  end
end

--- Close the shortcuts popup if it is open, optionally returning focus to `self.win`.
---@param refocus boolean?
function InlineBox:close_help(refocus)
  local help_win = self.help_win
  self.help_win = nil
  if refocus and self:is_open() then
    vim.api.nvim_set_current_win(self.win)
  end
  if help_win and vim.api.nvim_win_is_valid(help_win) then
    vim.api.nvim_win_close(help_win, true)
  end
end

--- Open or close a floating popup listing the active shortcuts for this inline box.
function InlineBox:toggle_help()
  if self.help_win and vim.api.nvim_win_is_valid(self.help_win) then
    self:close_help(true)
    return
  end
  if not self:is_open() or #self.help_items == 0 then
    return
  end

  local key_width = 0
  for _, item in ipairs(self.help_items) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(item.key))
  end

  local lines = {}
  local max_width = vim.fn.strdisplaywidth(" Shortcuts ") + 2
  for _, item in ipairs(self.help_items) do
    local pad = (" "):rep(key_width - vim.fn.strdisplaywidth(item.key))
    local line = (" %s%s  %s "):format(item.key, pad, item.desc)
    table.insert(lines, line)
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  for index, item in ipairs(self.help_items) do
    vim.api.nvim_buf_set_extmark(buf, M.help_namespace, index - 1, 1, {
      end_row = index - 1,
      end_col = 1 + #item.key,
      hl_group = "DidymusThreadAuthor",
    })
  end

  local width = math.min(max_width, math.max(10, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local row = math.max(0, math.floor((vim.o.lines - height - 2) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))

  self.opening_help = true
  local ok, help_win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = box_border,
    title = { { " Shortcuts ", "DidymusThreadTitle" } },
    title_pos = "center",
    zindex = 60,
  })
  self.opening_help = false
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    return
  end

  self.help_win = help_win
  vim.wo[help_win][0].winhighlight =
    "Normal:DidymusThreadBg,FloatBorder:DidymusThreadBorder,FloatTitle:DidymusThreadTitle"

  local map_opts = { buffer = buf, nowait = true }
  local function close_and_refocus()
    self:close_help(true)
  end
  vim.keymap.set("n", "q", close_and_refocus, map_opts)
  vim.keymap.set("n", "<Esc>", close_and_refocus, map_opts)
  vim.keymap.set("n", "?", close_and_refocus, map_opts)

  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if self.help_win == help_win then
          self:close_help(false)
          if self.mode == "focus" and not self.split and not self:is_focused() then
            self:close()
          end
        end
      end)
    end,
  })
end

--- Render the focused read-only buffer in Path B rendered mode (matching unfocused `virt_lines`
--- cell-for-cell) or raw markdown source mode (when toggled with `s`).
function InlineBox:render_focus_view()
  if self.mode ~= "focus" or not self:is_open() then
    return
  end
  local box_width = vim.api.nvim_win_get_width(self.win) + 2
  local inner_width = math.max(1, box_width - 4)
  local cursor = vim.api.nvim_win_get_cursor(self.win)

  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].readonly = false
  vim.api.nvim_buf_clear_namespace(self.buf, M.render_namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.buf, M.divider_namespace, 0, -1)

  if self.show_raw and self.render_raw then
    local raw_lines, dividers, headers = self.render_raw()
    self.dividers = dividers or {}
    self.headers = headers or {}
    self.rendered_width = nil
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, true, #raw_lines > 0 and raw_lines or { "" })
    vim.bo[self.buf].modifiable = false
    vim.bo[self.buf].readonly = true

    vim.wo[self.win][0].wrap = true
    vim.wo[self.win][0].linebreak = true
    vim.wo[self.win][0].conceallevel = 0
    vim.wo[self.win][0].concealcursor = ""
    if not self.split then
      vim.wo[self.win][0].statuscolumn = "%#DidymusThreadBg# "
    end
    pcall(vim.treesitter.start, self.buf, "markdown")
    self:draw_dividers()
  elseif self.render_rendered then
    pcall(vim.treesitter.stop, self.buf)
    local rows = self.render_rendered(box_width)
    local buf_lines = {}
    local divider_width = math.max(1, box_width - 2)
    for _, row in ipairs(rows) do
      if row.kind == "divider" then
        table.insert(buf_lines, ("─"):rep(divider_width))
      else
        local parts = {}
        for _, chunk in ipairs(row.chunks or {}) do
          table.insert(parts, chunk[1])
        end
        table.insert(buf_lines, table.concat(parts))
      end
    end
    if #buf_lines == 0 then
      buf_lines = { "" }
    end
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, true, buf_lines)
    vim.bo[self.buf].modifiable = false
    vim.bo[self.buf].readonly = true

    vim.wo[self.win][0].wrap = false
    vim.wo[self.win][0].conceallevel = 0
    vim.wo[self.win][0].concealcursor = ""
    if not self.split then
      vim.wo[self.win][0].statuscolumn = ""
    end

    for index, row in ipairs(rows) do
      local lnum = index - 1
      local text = buf_lines[index]
      if row.kind == "divider" then
        vim.api.nvim_buf_set_extmark(self.buf, M.render_namespace, lnum, 0, {
          end_row = lnum,
          end_col = #text,
          hl_group = row.hl or self.border_hl,
        })
      else
        local display_width = vim.fn.strdisplaywidth(text)
        local pad = row.eol_hl and math.max(0, inner_width - display_width) or 0
        if not self.split then
          if text == "" and pad > 0 then
            vim.api.nvim_buf_set_extmark(self.buf, M.render_namespace, lnum, 0, {
              virt_text = { { " ", "DidymusThreadBg" }, { (" "):rep(pad), row.eol_hl } },
              virt_text_pos = "inline",
              right_gravity = false,
            })
          else
            vim.api.nvim_buf_set_extmark(self.buf, M.render_namespace, lnum, 0, {
              virt_text = { { " ", "DidymusThreadBg" } },
              virt_text_pos = "inline",
              right_gravity = false,
            })
          end
        elseif text == "" and pad > 0 then
          vim.api.nvim_buf_set_extmark(self.buf, M.render_namespace, lnum, 0, {
            virt_text = { { (" "):rep(pad), row.eol_hl } },
            virt_text_pos = "inline",
            right_gravity = false,
          })
        end

        local col = 0
        for _, chunk in ipairs(row.chunks or {}) do
          local len = #chunk[1]
          if chunk[2] and len > 0 then
            vim.api.nvim_buf_set_extmark(self.buf, M.render_namespace, lnum, col, {
              end_row = lnum,
              end_col = col + len,
              hl_group = chunk[2],
            })
          end
          col = col + len
        end

        if text ~= "" and pad > 0 then
          vim.api.nvim_buf_set_extmark(self.buf, M.render_namespace, lnum, #text, {
            virt_text = { { (" "):rep(pad), row.eol_hl } },
            virt_text_pos = "inline",
          })
        end
      end
    end
    self.rendered_width = box_width
  else
    vim.bo[self.buf].modifiable = false
    vim.bo[self.buf].readonly = true
  end

  local max_line = vim.api.nvim_buf_line_count(self.buf)
  vim.api.nvim_win_set_cursor(self.win, { math.min(cursor[1], max_line), 0 })
end

--- Toggle between rendered markdown (Path B) and raw markdown source in a focused thread.
function InlineBox:toggle_source()
  if self.mode ~= "focus" or not self.render_raw or not self.render_rendered then
    return
  end
  self.show_raw = not self.show_raw
  self:render_focus_view()
  self:update_height()
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
    if self.mode == "focus" and not self.show_raw and self.render_rendered then
      if self.rendered_width ~= anchor.box_width then
        self:render_focus_view()
        self:update_height()
        return
      end
    else
      self:draw_dividers()
    end
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
  self:close_help(false)
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
    vim.keymap.set("n", "?", function()
      self:toggle_help()
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

    -- Render draft markdown while unfocused, and restore raw highlighted markdown on focus.
    vim.api.nvim_create_autocmd("WinLeave", {
      group = self.group,
      buffer = self.buf,
      callback = function()
        if not self.closed and not self.opening_help then
          show_rendered_markdown(self.buf, self.win, function()
            if not self.closed then
              self:update_height()
            end
          end)
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = self.group,
      buffer = self.buf,
      callback = function()
        if not self.closed then
          show_raw_markdown(self.buf, self.win)
          self:update_height()
        end
      end,
    })
  else
    local close_focus = function()
      self:close()
    end
    vim.keymap.set("n", "q", close_focus, map_opts)
    vim.keymap.set("n", "<Esc>", close_focus, map_opts)
    vim.keymap.set("n", "?", function()
      self:toggle_help()
    end, map_opts)

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
    if tk.source and tk.source.key then
      vim.keymap.set("n", tk.source.key --[[@as string]], function()
        self:toggle_source()
      end, vim.tbl_extend("force", map_opts, { desc = "didymus: toggle markdown source" }))
    end

    if not self.split then
      -- A focused inline thread has no unsaved text, so leaving it reverts cleanly to `virt_lines`.
      vim.api.nvim_create_autocmd("WinLeave", {
        group = self.group,
        buffer = self.buf,
        callback = function()
          if self.opening_help then
            return
          end
          vim.schedule(function()
            if
              self.help_win
              and vim.api.nvim_win_is_valid(self.help_win)
              and vim.api.nvim_get_current_win() == self.help_win
            then
              return
            end
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
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  if opts.mode == "edit" then
    vim.bo[buf].autocomplete = false
    -- blink.cmp and snacks.nvim read `b:completion`. Set before filetype so user FileType autocmds can override.
    vim.b[buf].completion = false
    -- Use a custom filetype with treesitter markdown highlights so plugins such as
    -- render-markdown.nvim do not conceal raw markdown while editing.
    vim.bo[buf].filetype = "didymus_input"
    pcall(vim.treesitter.start, buf, "markdown")
  else
    vim.bo[buf].filetype = "didymus_thread"
    if not opts.render_rendered then
      pcall(vim.treesitter.start, buf, "markdown")
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  end

  local initial_height = math.max(1, math.min(opts.initial_height or #lines, opts.max_height))
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
    title = opts.title or "",
    title_hl = opts.title_hl or "DidymusThreadTitle",
    border = opts.border or box_border,
    border_hl = opts.border_hl or "DidymusThreadBorder",
    dividers = opts.dividers or {},
    headers = opts.headers or {},
    render_rendered = opts.render_rendered,
    render_raw = opts.render_raw,
    show_raw = false,
    rendered_width = nil,
    help_items = build_help_items(opts),
    help_win = nil,
    opening_help = false,
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
    local height = math.max(3, math.min(initial_height + 1, opts.max_height))
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
    if self.mode == "focus" then
      if self.render_rendered then
        self:render_focus_view()
        self:update_height()
      else
        self:draw_dividers()
        configure_readonly_markdown(buf, self.win, function()
          if not self.closed then
            self:draw_dividers()
            self:update_height()
          end
        end)
      end
    else
      show_raw_markdown(buf, self.win)
    end
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
        col = anchor.indent,
        width = math.max(1, anchor.box_width - 2),
        height = math.max(1, math.min(self.height, math.max(1, info.height - 2))),
        border = self.border,
        hide = false,
      }
      if self.title and self.title ~= "" then
        cfg.title = { { "─", self.border_hl }, { (" %s "):format(self.title), self.title_hl } }
        cfg.title_pos = "left"
      end
    end
    cfg.style = "minimal"
    self.win = vim.api.nvim_open_win(buf, true, cfg)
    self.last_config = vim.tbl_extend("force", {}, cfg)
    self.last_config.style = nil

    vim.wo[self.win][0].wrap = true
    vim.wo[self.win][0].linebreak = true
    vim.wo[self.win][0].winfixbuf = true
    -- One-cell left margin aligns editable/raw text with `│ ` in `virt_lines` and shares the card bg.
    vim.wo[self.win][0].statuscolumn = "%#DidymusThreadBg# "
    vim.wo[self.win][0].winhighlight = ("Normal:DidymusThreadBg,FloatBorder:%s,FloatTitle:%s,FloatFooter:DidymusThreadFooter"):format(
      self.border_hl,
      self.title_hl
    )
    if self.mode == "focus" then
      if self.render_rendered then
        self:render_focus_view()
      else
        self:draw_dividers()
        configure_readonly_markdown(buf, self.win, function()
          if not self.closed then
            self:draw_dividers()
            self:update_height()
          end
        end)
      end
    else
      show_raw_markdown(buf, self.win)
    end

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
