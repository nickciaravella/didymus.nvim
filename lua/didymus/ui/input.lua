local layout = require("didymus.ui.layout")
local overlay = require("didymus.ui.overlay")

local M = {}

---@class didymus.ui.input.Keys
---@field cancel string? In normal mode. In a float, `<Esc>` in normal mode also cancels.

--- A key that submits the text.
---@class didymus.ui.input.Action
---@field key string|false In normal and insert mode. False turns off the action.
---@field name string The name in the footer, for example "send".
---@field on_submit fun(text: string)

--- A key that inserts lines, and does not submit.
---@class didymus.ui.input.Insert
---@field key string|false In normal and insert mode. False turns off the insert.
---@field name string The name in the footer, for example "suggest".
---@field get_lines fun(): string[], integer? The lines, and the index of the line for the cursor. Default: the last line.

--- The state of an inline input, for the virtual lines of its place.
---@class didymus.ui.input.InlineState
---@field lines string[] The text.
---@field shown boolean True while the window of the input shows. Then the window covers the body.
---@field height integer The rows of the body while the window shows.
---@field keys { key: string, name: string }[] The keys of the input, for the last row of the frame.

--- The input stays in the text of a window, in virtual lines that the caller draws. A window on the
--- body shows only while the cursor is in the input. The input stays open when the cursor leaves.
---@class didymus.ui.input.Inline
---@field win integer The window of the text.
---@field on_change fun(state: didymus.ui.input.InlineState) Draw the virtual lines of the input again, at once.
---@field get_span fun(): didymus.ui.overlay.Span? The span of the body in the virtual lines.
---@field on_leave fun(direction: "up"|"down"|"away") The cursor left the input: `k` on the first line, `j` on the last line, or a scroll.

---@class didymus.ui.input.Opts
---@field title string?
---@field inline didymus.ui.input.Inline? Show the input in the text, not in a float above it.
---@field actions didymus.ui.input.Action[] The footer shows the keys in this order.
---@field inserts didymus.ui.input.Insert[]? The footer shows their keys after the actions.
---@field on_cancel fun()?
---@field width number? A width below 1 is a fraction of the current window width. Not for `inline`: it has the text width.
---@field max_height integer?
---@field keys didymus.ui.input.Keys?
---@field range integer[]? The first and the last line of the code, 1-based. These lines have a highlight. Default: the cursor line. An inline input has a highlight only with `range`.
---@field text string? The text at the start. Insert mode starts at its end.
---@field allow_empty boolean? A submit with no text calls `on_submit` with "". Default false: the float stays open.
---@field on_empty fun()? Called on a submit with no text, if `allow_empty` is false.

--- An open inline input.
---@class didymus.ui.input.Handle
---@field focus fun(at_end: boolean?): boolean Show the window, and put the cursor at the end, or with `false` on the first line. False if the input does not show.
---@field cancel fun()
---@field update fun() Put the window on the span again, for example after a draw of the virtual lines.
---@field get_lines fun(): string[] The text, with no blank lines at the end.
---@field is_shown fun(): boolean

local defaults = {
  width = 60,
  max_height = 10,
  keys = { cancel = "q" },
}

--- Cancels the open input.
---@type fun()?
local cancel_current

-- The border uses two rows and two columns.
local border_size = 2

local namespace = vim.api.nvim_create_namespace("didymus.ui.input")
local redraw_namespace = vim.api.nvim_create_namespace("didymus.ui.input.redraw")

--- The lines that have the highlight, while a float is open.
---@type { win: integer, buf: integer, range: integer[] }?
local context

-- An extmark belongs to a buffer, so it shows in each window of the buffer. The provider
-- highlights only the window of the prompt.
vim.api.nvim_set_decoration_provider(namespace, {
  on_win = function(_, win, buf)
    if context and context.win == win and context.buf == buf then
      vim.api.nvim_buf_set_extmark(buf, namespace, context.range[1] - 1, 0, {
        end_row = context.range[2],
        end_col = 0,
        strict = false,
        hl_group = "DidymusInputContext",
        hl_eol = true,
        ephemeral = true,
      })
    end
    return false
  end,
})

---@param width number
---@param win_width integer
---@return integer
local function resolve_width(width, win_width)
  return math.max(1, math.min(layout.resolve_size(width, win_width), win_width - border_size))
end

--- Put the float above the lines, in the center of the window. If the space above is too
--- small, put it under the lines. The float covers no part of the lines, also when a line wraps.
---@param win integer
---@param range integer[] The first and the last line, 1-based.
---@param width integer
---@param max_height integer
---@return vim.api.keyset.win_config position
---@return integer max_height The max height that fits.
local function find_position(win, range, width, max_height)
  local info = vim.fn.getwininfo(win)[1]
  local text_top = info.winrow + info.winbar
  local text_bottom = text_top + info.height - 1
  local first, last = range[1], range[2]
  local last_line = vim.api.nvim_buf_get_lines(info.bufnr, last - 1, last, true)[1]
  -- A row of 0 means that part of the lines is outside the window.
  local lines_top = vim.fn.screenpos(win, first, 1).row
  local lines_bottom = vim.fn.screenpos(win, last, math.max(1, #last_line)).row
  lines_top = lines_top > 0 and lines_top or text_top
  lines_bottom = lines_bottom > 0 and lines_bottom or text_bottom

  -- Screen rows are 1-based, and float rows are 0-based.
  local col = info.wincol - 1 + layout.center_offset(width + border_size, info.width)
  local rows_above = lines_top - text_top - border_size
  local rows_below = text_bottom - lines_bottom - border_size
  if rows_above >= max_height or rows_above >= rows_below then
    -- With the SW anchor, the float ends on the row above the lines and grows up.
    return { relative = "editor", anchor = "SW", row = lines_top - 1, col = col },
      math.max(1, math.min(max_height, rows_above))
  end
  return { relative = "editor", anchor = "NW", row = lines_bottom, col = col },
    math.max(1, math.min(max_height, rows_below))
end

--- Highlight the lines that the prompt is about in `win`, while the input shows.
---@param win integer
---@param range integer[]
local function highlight_context(win, range)
  vim.api.nvim_set_hl(0, "DidymusInputContext", { link = "Visual", default = true })
  context = { win = win, buf = vim.api.nvim_win_get_buf(win), range = range }
  -- The provider does not make Neovim draw the lines again, but a change of an extmark does.
  -- So these extmarks have no visible highlight. They exist until the input hides.
  for lnum = range[1], range[2] do
    vim.api.nvim_buf_set_extmark(context.buf, redraw_namespace, lnum - 1, 0, {
      line_hl_group = "DidymusInputContextRedraw",
    })
  end
end

local function clear_context()
  if context and vim.api.nvim_buf_is_valid(context.buf) then
    vim.api.nvim_buf_clear_namespace(context.buf, redraw_namespace, 0, -1)
  end
  context = nil
end

--- The rows of the text of the window.
---@param win integer
---@return integer
local function get_text_height(win)
  return vim.api.nvim_win_text_height(win, {}).all
end

---@param win integer
---@param max_height integer
local function update_height(win, max_height)
  local text_height = get_text_height(win)
  local height = math.max(1, math.min(text_height, max_height))
  if height ~= vim.api.nvim_win_get_height(win) then
    vim.api.nvim_win_set_height(win, height)
  end
  if text_height <= max_height then
    -- After the float grows, the first lines can stay above the top of the window.
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, skipcol = 0 })
    end)
  end
end

--- Make the buffer of an input.
---@param text string?
---@param bufhidden string
---@return integer
local function make_buffer(text, bufhidden)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = bufhidden
  vim.bo[buf].autocomplete = false
  -- blink.cmp and snacks.nvim read `b:completion`. Set it before the filetype, so that
  -- FileType autocmds of the user can change it.
  vim.b[buf].completion = false
  vim.bo[buf].filetype = "didymus_input"
  if text then
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, vim.split(text, "\n"))
  end
  return buf
end

--- The lines of `buf`, with no blank lines at the end.
---@param buf integer
---@return string[]
local function get_text_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

---@class didymus.ui.input.MapOpts
---@field buf integer
---@field get_win fun(): integer
---@field actions didymus.ui.input.Action[]
---@field inserts didymus.ui.input.Insert[]
---@field submit fun(on_submit: fun(text: string))
---@field resize fun()
---@field group integer

--- Set the keys of the actions and the inserts in normal and insert mode.
---@param opts didymus.ui.input.MapOpts
local function map_keys(opts)
  local buf = opts.buf
  --- Put the lines after the cursor line. An empty cursor line gets the first line.
  ---@param insert didymus.ui.input.Insert
  local function insert_lines(insert)
    local win = opts.get_win()
    local lines, cursor_index = insert.get_lines()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local first = vim.api.nvim_buf_get_lines(buf, row - 1, row, true)[1] == "" and row - 1 or row
    vim.api.nvim_buf_set_lines(buf, first, row, true, lines)
    local cursor_row = first + (cursor_index or #lines)
    local cursor_line = vim.api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, true)[1]
    vim.api.nvim_win_set_cursor(win, { cursor_row, #cursor_line })
    opts.resize()
  end

  local map_opts = { buffer = buf, nowait = true }
  ---@param modes string[]
  local function map_actions(modes)
    for _, action in ipairs(opts.actions) do
      vim.keymap.set(modes, action.key --[[@as string]], function()
        opts.submit(action.on_submit)
      end, map_opts)
    end
    for _, insert in ipairs(opts.inserts) do
      vim.keymap.set(modes, insert.key --[[@as string]], function()
        insert_lines(insert)
      end, map_opts)
    end
  end
  map_actions({ "n", "i" })

  -- Completion plugins, such as blink.cmp, set buffer mappings on InsertEnter. Some of these
  -- mappings do not fall back to ours. Set the submit mappings again after them.
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = opts.group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          map_actions({ "i" })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = opts.group,
    buffer = buf,
    callback = function()
      opts.resize()
    end,
  })
end

--- Open an input in the text of `opts.inline.win`. See `didymus.ui.input.Inline`.
---@param opts didymus.ui.input.Opts
---@param actions didymus.ui.input.Action[]
---@param inserts didymus.ui.input.Insert[]
---@return didymus.ui.input.Handle
local function open_inline(opts, actions, inserts)
  local inline = opts.inline --[[@as didymus.ui.input.Inline]]
  local keys = opts.keys
  local code_win = inline.win
  local key_parts = vim.tbl_map(function(item)
    return { key = item.key, name = item.name }
  end, vim.list_extend(vim.list_slice(actions), inserts))
  table.insert(key_parts, { key = keys.cancel, name = "cancel" })
  -- The input stays open when its window closes.
  local buf = make_buffer(opts.text, "hide")
  local group = vim.api.nvim_create_augroup(("didymus.ui.input.%d"):format(buf), {})
  ---@type integer?
  local win
  local done = false
  local height = 1
  ---@type fun()
  local cancel

  local function get_max_height()
    -- The frame uses two rows: the title and the keys.
    return math.max(1, math.min(opts.max_height, vim.api.nvim_win_get_height(code_win) - 3))
  end

  local function is_shown()
    return win ~= nil and vim.api.nvim_win_is_valid(win)
  end

  local function notify_change()
    inline.on_change({
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      shown = is_shown(),
      height = height,
      keys = key_parts,
    })
  end

  --- Scroll the window of the text so that the frame shows: the title row, the body and the keys
  --- row.
  ---@param span didymus.ui.overlay.Span The body.
  local function show_frame(span)
    local frame =
      vim.tbl_extend("force", span, { offset = span.offset - 1, height = span.height + 2 })
    if not overlay.is_shown(code_win, frame) then
      overlay.scroll_to(code_win, frame)
    end
  end

  --- Put the window on the span. With `scroll`, scroll the window of the text so that all of the
  --- frame shows.
  ---@param scroll boolean
  ---@return boolean shown
  local function place(scroll)
    local span = inline.get_span()
    if not (span and is_shown() and vim.api.nvim_win_is_valid(code_win)) then
      return false
    end
    if scroll then
      show_frame(span)
    end
    return overlay.move(win --[[@as integer]], code_win, span)
  end

  --- Set the height for the text, and draw the virtual lines again.
  local function resize()
    if not is_shown() then
      return
    end
    local shown_win = win --[[@as integer]]
    local new_height = math.max(1, math.min(get_text_height(shown_win), get_max_height()))
    if new_height ~= height then
      height = new_height
      vim.api.nvim_win_set_height(shown_win, height)
      notify_change()
      place(true)
    end
    if get_text_height(shown_win) <= height then
      -- After the window grows, the first lines can stay above the top of the window.
      vim.api.nvim_win_call(shown_win, function()
        vim.fn.winrestview({ topline = 1, skipcol = 0 })
      end)
    end
  end

  --- Close the window. The text stays in the virtual lines.
  local function hide()
    if not is_shown() then
      return
    end
    local closing = win --[[@as integer]]
    win = nil
    clear_context()
    if vim.api.nvim_get_current_win() == closing then
      vim.cmd.stopinsert()
      if vim.api.nvim_win_is_valid(code_win) then
        vim.api.nvim_set_current_win(code_win)
      end
    end
    vim.api.nvim_win_close(closing, true)
    notify_change()
  end

  ---@param cb fun(...)?
  local function close(cb, ...)
    if done then
      return
    end
    done = true
    if cancel_current == cancel then
      cancel_current = nil
    end
    hide()
    vim.api.nvim_del_augroup_by_id(group)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if cb then
      cb(...)
    end
  end

  cancel = function()
    close(opts.on_cancel)
  end

  ---@param on_submit fun(text: string)
  local function submit(on_submit)
    local lines = get_text_lines(buf)
    if #lines == 0 and not opts.allow_empty then
      if opts.on_empty then
        opts.on_empty()
      end
      return
    end
    -- Close after the mode change. Else insert mode stays on in the original window.
    vim.cmd.stopinsert()
    vim.schedule(function()
      close(on_submit, table.concat(lines, "\n"))
    end)
  end

  --- Open the window on the body.
  ---@return boolean shown
  local function show()
    -- Draw the block first, so that it has a place.
    notify_change()
    local span = inline.get_span()
    if not span then
      return false
    end
    -- The height of the text needs a window with the width of the body.
    local text_win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = math.max(1, vim.fn.getwininfo(code_win)[1].width - span.col),
      height = 1,
      hide = true,
      style = "minimal",
      border = "none",
      -- Under the floats of other plugins, such as a picker.
      zindex = 10,
    })
    vim.wo[text_win][0].wrap = true
    vim.wo[text_win][0].linebreak = true
    vim.wo[text_win][0].winfixbuf = true
    -- The window has the background of the text.
    vim.wo[text_win][0].winhighlight = "NormalFloat:Normal"
    height = math.max(1, math.min(get_text_height(text_win), get_max_height()))
    win = text_win
    -- The body is empty while the window shows, and it has the height of the window.
    notify_change()
    span = inline.get_span()
    if span then
      show_frame(span)
    end
    local config = span and overlay.get_config(code_win, span)
    if not config then
      win = nil
      vim.api.nvim_win_close(text_win, true)
      notify_change()
      return false
    end
    config.hide = false
    config.height = height
    vim.api.nvim_win_set_config(text_win, config)
    if opts.range then
      highlight_context(code_win, opts.range)
    end
    return true
  end

  ---@param at_end boolean?
  ---@return boolean
  local function focus(at_end)
    if done or not vim.api.nvim_win_is_valid(code_win) then
      return false
    end
    if not is_shown() and not show() then
      return false
    end
    local shown_win = win --[[@as integer]]
    vim.api.nvim_set_current_win(shown_win)
    local last = vim.api.nvim_buf_line_count(buf)
    if at_end ~= false then
      local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, true)[1]
      vim.api.nvim_win_set_cursor(shown_win, { last, #line })
    else
      vim.api.nvim_win_set_cursor(shown_win, { 1, 0 })
    end
    return true
  end

  map_keys({
    buf = buf,
    get_win = function()
      return win --[[@as integer]]
    end,
    actions = actions,
    inserts = inserts,
    submit = submit,
    resize = resize,
    group = group,
  })
  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", keys.cancel, function()
    cancel()
  end, map_opts)
  -- `j` on the last line and `k` on the first line leave the input, as in the text around it.
  ---@param direction "up"|"down"
  local function move(direction)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local edge = direction == "up" and 1 or vim.api.nvim_buf_line_count(buf)
    if row == edge then
      hide()
      inline.on_leave(direction)
    else
      local key = direction == "up" and "k" or "j"
      vim.cmd.normal({ ("%d%s"):format(vim.v.count1, key), bang = true })
    end
  end
  for _, key in ipairs({ "k", "<Up>" }) do
    vim.keymap.set("n", key, function()
      move("up")
    end, map_opts)
  end
  for _, key in ipairs({ "j", "<Down>" }) do
    vim.keymap.set("n", key, function()
      move("down")
    end, map_opts)
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      -- Close the window outside the autocmd, because an autocmd cannot always change the layout.
      vim.schedule(function()
        if is_shown() and vim.api.nvim_get_current_win() ~= win then
          hide()
        end
      end)
    end,
  })
  -- A scroll or a resize of the window of the text moves the input. If its first row goes out of
  -- the window, the cursor goes back to the text.
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        if is_shown() and not place(false) then
          hide()
          inline.on_leave("away")
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(code_win),
    callback = function()
      vim.schedule(cancel)
    end,
  })

  cancel_current = cancel
  ---@type didymus.ui.input.Handle
  local handle = {
    focus = focus,
    cancel = function()
      cancel()
    end,
    update = function()
      if is_shown() then
        place(false)
      end
    end,
    get_lines = function()
      return get_text_lines(buf)
    end,
    is_shown = is_shown,
  }
  if focus(true) then
    -- The user adds to the end of `opts.text`.
    vim.cmd.startinsert({ bang = true })
  end
  return handle
end

--- Open a float for a prompt, above or under the code. With `opts.inline`, open an input in the
--- text, and give its handle. `<CR>` adds a line.
---@param opts didymus.ui.input.Opts
---@return didymus.ui.input.Handle?
function M.open(opts)
  vim.validate("opts.actions", opts.actions, "table")
  vim.validate("opts.on_cancel", opts.on_cancel, "function", true)
  vim.validate("opts.range", opts.range, "table", true)
  vim.validate("opts.text", opts.text, "string", true)
  vim.validate("opts.allow_empty", opts.allow_empty, "boolean", true)
  vim.validate("opts.on_empty", opts.on_empty, "function", true)
  vim.validate("opts.inserts", opts.inserts, "table", true)
  vim.validate("opts.inline", opts.inline, "table", true)
  local function has_key(item)
    return item.key
  end
  local actions = vim.tbl_filter(has_key, opts.actions)
  local inserts = vim.tbl_filter(has_key, opts.inserts or {})
  opts = vim.tbl_deep_extend("force", defaults, opts)
  local keys = opts.keys

  if cancel_current then
    cancel_current()
  end
  if opts.inline then
    return open_inline(opts, actions, inserts)
  end

  local origin_win = vim.api.nvim_get_current_win()
  local cursor_line = vim.api.nvim_win_get_cursor(origin_win)[1]
  local range = opts.range or { cursor_line, cursor_line }
  local width = resolve_width(opts.width, vim.api.nvim_win_get_width(origin_win))
  local position, max_height = find_position(origin_win, range, width, opts.max_height)
  highlight_context(origin_win, range)
  local footer_parts = vim.tbl_map(function(item)
    return ("%s %s"):format(item.key, item.name)
  end, vim.list_extend(vim.list_slice(actions), inserts))
  table.insert(footer_parts, ("%s cancel"):format(keys.cancel))
  local buf = make_buffer(opts.text, "wipe")

  local win_config = vim.tbl_extend("force", position, {
    width = width,
    height = 1,
    style = "minimal",
    -- A title needs a border.
    border = (vim.o.winborder == "" or vim.o.winborder == "none") and "rounded" or nil,
    title = opts.title and (" %s "):format(opts.title),
  })
  -- Neovim cuts a long footer from the start. So remove the last keys until the footer fits.
  while #footer_parts > 0 do
    local footer = (" %s "):format(table.concat(footer_parts, "  "))
    if vim.api.nvim_strwidth(footer) <= width then
      win_config.footer, win_config.footer_pos = footer, "right"
      break
    end
    table.remove(footer_parts)
  end
  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win][0].wrap = true
  vim.wo[win][0].linebreak = true
  vim.wo[win][0].winfixbuf = true
  if opts.text then
    update_height(win, max_height)
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end

  local group = vim.api.nvim_create_augroup(("didymus.ui.input.%d"):format(win), {})
  local done = false

  ---@param cb fun(...)?
  local function close(cb, ...)
    if done then
      return
    end
    done = true
    cancel_current = nil
    vim.api.nvim_del_augroup_by_id(group)
    clear_context()
    if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if cb then
      cb(...)
    end
  end

  local function cancel()
    close(opts.on_cancel)
  end
  cancel_current = cancel

  ---@param on_submit fun(text: string)
  local function submit(on_submit)
    local lines = get_text_lines(buf)
    if #lines == 0 and not opts.allow_empty then
      if opts.on_empty then
        opts.on_empty()
      end
      return
    end
    -- Close after the mode change. Else insert mode stays on in the original window.
    vim.cmd.stopinsert()
    vim.schedule(function()
      close(on_submit, table.concat(lines, "\n"))
    end)
  end

  map_keys({
    buf = buf,
    get_win = function()
      return win
    end,
    actions = actions,
    inserts = inserts,
    submit = submit,
    resize = function()
      update_height(win, max_height)
    end,
    group = group,
  })
  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", keys.cancel, cancel, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)

  -- Close the window outside the autocmd, because an autocmd cannot always change the layout.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(cancel)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      vim.schedule(cancel)
    end,
  })

  -- The user adds to the end of `opts.text`.
  vim.cmd.startinsert({ bang = true })
end

return M
