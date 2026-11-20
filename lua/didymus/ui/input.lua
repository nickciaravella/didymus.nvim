local layout = require("didymus.ui.layout")

local M = {}

---@class didymus.ui.input.Keys
---@field cancel string? In normal mode. `<Esc>` in normal mode also cancels.

--- A key that submits the text.
---@class didymus.ui.input.Action
---@field key string|false In normal and insert mode. False turns off the action.
---@field name string The name in the footer, for example "send".
---@field on_submit fun(text: string, release: fun()?) In inline mode, the frame keeps the text until a call of `release`.

--- A key that inserts lines, and does not submit.
---@class didymus.ui.input.Insert
---@field key string|false In normal and insert mode. False turns off the insert.
---@field name string The name in the footer, for example "suggest".
---@field get_lines fun(): string[], integer? The lines, and the index of the line for the cursor. Default: the last line.

--- The input shows in a window of the text, under a line, as the virtual lines of an extmark.
---@class didymus.ui.input.Inline
---@field win integer The window of the text.
---@field line integer The input shows under this line, after its other virtual lines. 0 shows it above line 1.
---@field hl string? The highlight of the frame, the title and the keys. Default: "Title".

---@class didymus.ui.input.Opts
---@field title string?
---@field inline didymus.ui.input.Inline? Show the input in the text, not in a float above it.
---@field actions didymus.ui.input.Action[] The footer shows the keys in this order.
---@field inserts didymus.ui.input.Insert[]? The footer shows their keys after the actions.
---@field on_cancel fun()?
---@field width number? A width below 1 is a fraction of the current window width. Not for `inline`: the input has the text width.
---@field max_height integer?
---@field keys didymus.ui.input.Keys?
---@field range integer[]? The first and the last line of the code, 1-based. These lines have a highlight. Default: the cursor line.
---@field text string? The text at the start. Insert mode starts at its end.
---@field allow_empty boolean? A submit with no text calls `on_submit` with "". Default false: the float stays open.
---@field on_empty fun()? Called on a submit with no text, if `allow_empty` is false.

local defaults = {
  width = 60,
  max_height = 10,
  keys = { cancel = "q" },
}

--- Cancels the open input float.
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

--- Highlight the lines that the prompt is about in `win`, while the float is open.
---@param win integer
---@param range integer[]
local function highlight_context(win, range)
  vim.api.nvim_set_hl(0, "DidymusInputContext", { link = "Visual", default = true })
  context = { win = win, buf = vim.api.nvim_win_get_buf(win), range = range }
  -- The provider does not make Neovim draw the lines again, but a change of an extmark does.
  -- So these extmarks have no visible highlight. They exist until the float closes.
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

local inline_namespace = vim.api.nvim_create_namespace("didymus.ui.input.inline")

-- The frame is a character and a space in front of each line, as the frame of a review thread.
local frame_width = 2

--- The window of each inline mark: the open input, and the texts that wait for a release.
---@type table<integer, integer>
local inline_wins = {}

--- Show the inline marks only in their windows. `nvim__ns_set()` is experimental. If a later
--- Neovim does not have it, the marks show in all windows of the buffer.
local function update_inline_scope()
  local set_namespace = vim.api.nvim__ns_set
  local wins = {}
  for _, win in pairs(inline_wins) do
    if vim.api.nvim_win_is_valid(win) and not vim.list_contains(wins, win) then
      table.insert(wins, win)
    end
  end
  -- An empty list shows the marks in all windows.
  if set_namespace and #wins > 0 then
    set_namespace(inline_namespace, { wins = wins })
  end
end

--- Checks the place of the open inline input at the end of each redraw.
---@type fun()?
local check_inline

vim.api.nvim_set_decoration_provider(inline_namespace, {
  on_end = function()
    if check_inline then
      check_inline()
    end
  end,
})

---@param indent integer
---@param hl string
---@param frame string
---@param chunks [string, string?][]?
---@return [string, string?][]
local function make_frame_line(indent, hl, frame, chunks)
  return vim.list_extend({ { (" "):rep(indent) }, { frame .. " ", hl } }, chunks or {})
end

--- The keys for the last line of the frame. Remove the last keys until they fit in `width`.
---@param parts { key: string, name: string }[]
---@param hl string
---@param width integer
---@return [string, string?][]
local function make_keys_chunks(parts, hl, width)
  for count = #parts, 1, -1 do
    local chunks, chunks_width = {}, 0
    for index = 1, count do
      local key = (index > 1 and "  " or "") .. parts[index].key
      local name = " " .. parts[index].name
      vim.list_extend(chunks, { { key, hl }, { name, "Comment" } })
      chunks_width = chunks_width + vim.api.nvim_strwidth(key .. name)
    end
    if chunks_width <= width then
      return chunks
    end
  end
  return {}
end

---@class didymus.ui.input.InlinePlace
---@field mark_id integer?
---@field lines [string, string?][][]? The virtual lines of the mark.
---@field config vim.api.keyset.win_config?

--- The text width of `win`: its width without the sign column and the number column.
---@param win integer
---@return integer
local function get_text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

---@param win integer
---@param max_height integer
---@return boolean changed
local function update_height(win, max_height)
  local text_height = vim.api.nvim_win_text_height(win, {}).all
  local height = math.max(1, math.min(text_height, max_height))
  local changed = height ~= vim.api.nvim_win_get_height(win)
  if changed then
    vim.api.nvim_win_set_height(win, height)
  end
  if text_height <= max_height then
    -- After the float grows, the first lines can stay above the top of the window.
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, skipcol = 0 })
    end)
  end
  return changed
end

--- Open a float for a prompt, above or under the code. With `opts.inline`, show the input in the
--- text, under a line. `<CR>` adds a line.
---@param opts didymus.ui.input.Opts
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
  local inline = opts.inline

  if cancel_current then
    cancel_current()
  end

  local origin_win = inline and inline.win or vim.api.nvim_get_current_win()
  local cursor_line = vim.api.nvim_win_get_cursor(origin_win)[1]
  local range = opts.range or { cursor_line, cursor_line }
  -- Above line 1, the input is about the full text, not about a line.
  if not (inline and inline.line == 0) then
    highlight_context(origin_win, range)
  end
  local key_parts = vim.tbl_map(function(item)
    return { key = item.key, name = item.name }
  end, vim.list_extend(vim.list_slice(actions), inserts))
  table.insert(key_parts, { key = keys.cancel, name = "cancel" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].autocomplete = false
  -- blink.cmp and snacks.nvim read `b:completion`. Set it before the filetype, so that
  -- FileType autocmds of the user can change it.
  vim.b[buf].completion = false
  vim.bo[buf].filetype = "didymus_input"
  if opts.text then
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, vim.split(opts.text, "\n"))
  end

  local win, max_height
  ---@type fun()?
  local place_inline
  ---@type fun(lines: string[]): fun()
  local keep_inline
  ---@type fun()?
  local remove_inline
  if inline then
    local code_buf = vim.api.nvim_win_get_buf(inline.win)
    local hl = inline.hl or "Title"
    local above = inline.line == 0
    local row = math.max(0, inline.line - 1)
    -- The frame uses two rows: the title and the keys.
    max_height = math.max(1, math.min(opts.max_height, vim.api.nvim_win_get_height(inline.win) - 3))
    ---@type didymus.ui.input.InlinePlace
    local place = {}

    ---@return integer
    local function get_indent()
      if above then
        return 0
      end
      return vim.api.nvim_buf_call(code_buf, function()
        return vim.fn.indent(inline.line)
      end)
    end

    --- The place of the float, at the body of the frame.
    ---@param height integer
    ---@return vim.api.keyset.win_config
    local function get_config(height)
      local indent = get_indent()
      local mark = place.mark_id and { ns = inline_namespace, id = place.mark_id }
      local before, after = layout.count_virt_rows(inline.win, code_buf, row, above, mark)
      local float_row
      if above then
        -- The marks after this mark show between it and line 1.
        float_row = -(after + 1 + height)
      else
        -- With `start_vcol`, the virtual lines above the line do not count, and the virtual lines
        -- under it count as a part of the next line.
        local line_rows = vim.api.nvim_win_text_height(
          inline.win,
          { start_row = row, start_vcol = 0, end_row = row }
        ).all
        float_row = line_rows + before + 1
      end
      return {
        relative = "win",
        win = inline.win,
        bufpos = { row, 0 },
        row = float_row,
        col = indent + frame_width,
        width = math.max(1, get_text_width(inline.win) - indent - frame_width),
        height = height,
      }
    end

    ---@param body_lines [string, string?][][]
    local function set_mark(body_lines)
      local indent = get_indent()
      local lines = { make_frame_line(indent, hl, "┌", { { opts.title or "", hl } }) }
      vim.list_extend(lines, body_lines)
      -- A change of an extmark draws the window again, and the redraw checks the place again.
      if place.mark_id and vim.deep_equal(lines, place.lines) then
        return
      end
      place.lines = lines
      place.mark_id = vim.api.nvim_buf_set_extmark(code_buf, inline_namespace, row, 0, {
        id = place.mark_id,
        virt_lines = lines,
        virt_lines_above = above,
      })
      inline_wins[place.mark_id] = inline.win
      update_inline_scope()
    end

    --- Draw the frame for the height of the float, and put the float on its body.
    place_inline = function()
      if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(inline.win)) then
        return
      end
      local height = vim.api.nvim_win_get_height(win)
      local indent = get_indent()
      local body = {}
      for _ = 1, height do
        table.insert(body, make_frame_line(indent, hl, "│"))
      end
      local width = get_text_width(inline.win) - indent - frame_width
      table.insert(body, make_frame_line(indent, hl, "└", make_keys_chunks(key_parts, hl, width)))
      set_mark(body)
      local config = get_config(height)
      if not vim.deep_equal(config, place.config) then
        vim.api.nvim_win_set_config(win, config)
        place.config = config
      end
    end

    --- Show the text in the frame, with no float, until a call of the result.
    keep_inline = function(lines)
      local indent = get_indent()
      local body = {}
      for index, line in ipairs(lines) do
        local frame = index == #lines and "└" or "│"
        table.insert(body, make_frame_line(indent, hl, frame, { { line, "Comment" } }))
      end
      set_mark(body)
      local mark_id = place.mark_id --[[@as integer]]
      place.mark_id = nil
      return function()
        inline_wins[mark_id] = nil
        if vim.api.nvim_buf_is_valid(code_buf) then
          vim.api.nvim_buf_del_extmark(code_buf, inline_namespace, mark_id)
        end
      end
    end

    remove_inline = function()
      if place.mark_id and vim.api.nvim_buf_is_valid(code_buf) then
        vim.api.nvim_buf_del_extmark(code_buf, inline_namespace, place.mark_id)
      end
      if place.mark_id then
        inline_wins[place.mark_id] = nil
        place.mark_id = nil
      end
    end

    local config = get_config(1)
    win = vim.api.nvim_open_win(
      buf,
      true,
      vim.tbl_extend("force", config, {
        style = "minimal",
        border = "none",
        -- Under the floats of other plugins, such as a picker.
        zindex = 10,
      })
    )
    place.config = config
    -- The input has the background of the text.
    vim.wo[win][0].winhighlight = "NormalFloat:Normal"
  else
    local width = resolve_width(opts.width, vim.api.nvim_win_get_width(origin_win))
    local position
    position, max_height = find_position(origin_win, range, width, opts.max_height)
    local win_config = vim.tbl_extend("force", position, {
      width = width,
      height = 1,
      style = "minimal",
      -- A title needs a border.
      border = (vim.o.winborder == "" or vim.o.winborder == "none") and "rounded" or nil,
      title = opts.title and (" %s "):format(opts.title),
    })
    -- Neovim cuts a long footer from the start. So remove the last keys until the footer fits.
    local footer_parts = vim.tbl_map(function(part)
      return ("%s %s"):format(part.key, part.name)
    end, key_parts)
    while #footer_parts > 0 do
      local footer = (" %s "):format(table.concat(footer_parts, "  "))
      if vim.api.nvim_strwidth(footer) <= width then
        win_config.footer, win_config.footer_pos = footer, "right"
        break
      end
      table.remove(footer_parts)
    end
    win = vim.api.nvim_open_win(buf, true, win_config)
  end
  vim.wo[win][0].wrap = true
  vim.wo[win][0].linebreak = true
  vim.wo[win][0].winfixbuf = true

  --- Set the height for the text. In inline mode, draw the frame again and show all of it.
  ---@param force boolean? Draw the frame also if the height did not change.
  local function resize(force)
    local changed = update_height(win, max_height)
    if place_inline and (changed or force) then
      place_inline()
      if inline.line == 0 then
        layout.show_lines_above_first(inline.win)
      else
        layout.show_lines_under(inline.win, inline.line)
      end
    end
  end
  resize(true)
  if opts.text then
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
    check_inline = nil
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
    if remove_inline then
      remove_inline()
    end
    close(opts.on_cancel)
  end
  cancel_current = cancel

  ---@param on_submit fun(text: string, release: fun()?)
  local function submit(on_submit)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and lines[#lines]:match("^%s*$") do
      table.remove(lines)
    end
    if #lines == 0 and not opts.allow_empty then
      if opts.on_empty then
        opts.on_empty()
      end
      return
    end
    -- Close after the mode change. Else insert mode stays on in the original window.
    vim.cmd.stopinsert()
    vim.schedule(function()
      if done then
        return
      end
      local release = keep_inline and keep_inline(lines)
      close(on_submit, table.concat(lines, "\n"), release)
    end)
  end

  --- Put the lines after the cursor line. An empty cursor line gets the first line.
  ---@param insert didymus.ui.input.Insert
  local function insert_lines(insert)
    local lines, cursor_index = insert.get_lines()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local first = vim.api.nvim_buf_get_lines(buf, row - 1, row, true)[1] == "" and row - 1 or row
    vim.api.nvim_buf_set_lines(buf, first, row, true, lines)
    local cursor_row = first + (cursor_index or #lines)
    local cursor_line = vim.api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, true)[1]
    vim.api.nvim_win_set_cursor(win, { cursor_row, #cursor_line })
    resize()
  end

  local map_opts = { buffer = buf, nowait = true }
  ---@param modes string[]
  local function map_actions(modes)
    for _, action in ipairs(actions) do
      vim.keymap.set(modes, action.key --[[@as string]], function()
        submit(action.on_submit)
      end, map_opts)
    end
    for _, insert in ipairs(inserts) do
      vim.keymap.set(modes, insert.key --[[@as string]], function()
        insert_lines(insert)
      end, map_opts)
    end
  end
  map_actions({ "n", "i" })
  vim.keymap.set("n", keys.cancel, cancel, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)

  -- Completion plugins, such as blink.cmp, set buffer mappings on InsertEnter. Some of these
  -- mappings do not fall back to ours. Set the submit mappings again after them.
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
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
    group = group,
    buffer = buf,
    callback = function()
      resize()
    end,
  })
  -- Close the window outside the autocmd, because an autocmd cannot always change the layout.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(cancel)
    end,
  })
  if inline then
    -- A resize can move the top line of the window, so the input can go out of the window.
    vim.api.nvim_create_autocmd("WinResized", {
      group = group,
      callback = function()
        if vim.list_contains(vim.v.event.windows, inline.win) then
          vim.schedule(function()
            if not done then
              resize(true)
            end
          end)
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = inline and { tostring(win), tostring(inline.win) } or tostring(win),
    callback = function()
      vim.schedule(cancel)
    end,
  })

  if place_inline then
    -- Other marks at the line can change, for example when the threads draw again. A resize of the
    -- window changes the width. A decoration provider must not change the extmarks or the windows.
    local scheduled = false
    check_inline = function()
      if scheduled then
        return
      end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        if not done and place_inline then
          place_inline()
        end
      end)
    end
  end

  -- The user adds to the end of `opts.text`.
  vim.cmd.startinsert({ bang = true })
end

return M
