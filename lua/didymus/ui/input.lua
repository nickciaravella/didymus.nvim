local layout = require("didymus.ui.layout")

local M = {}

---@class didymus.ui.input.Keys
---@field cancel string? In normal mode. `<Esc>` in normal mode also cancels.

--- A key that submits the text.
---@class didymus.ui.input.Action
---@field key string|false In normal and insert mode. False turns off the action.
---@field name string The name in the footer, for example "send".
---@field on_submit fun(text: string)

---@class didymus.ui.input.Opts
---@field title string?
---@field actions didymus.ui.input.Action[] The footer shows the keys in this order.
---@field on_cancel fun()?
---@field width number? A width below 1 is a fraction of the current window width.
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

---@param win integer
---@param max_height integer
local function update_height(win, max_height)
  local text_height = vim.api.nvim_win_text_height(win, {}).all
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

--- Open a float for a prompt, above or under the code. `<CR>` adds a line.
---@param opts didymus.ui.input.Opts
function M.open(opts)
  vim.validate("opts.actions", opts.actions, "table")
  vim.validate("opts.on_cancel", opts.on_cancel, "function", true)
  vim.validate("opts.range", opts.range, "table", true)
  vim.validate("opts.text", opts.text, "string", true)
  vim.validate("opts.allow_empty", opts.allow_empty, "boolean", true)
  vim.validate("opts.on_empty", opts.on_empty, "function", true)
  local actions = vim.tbl_filter(function(action)
    return action.key
  end, opts.actions)
  opts = vim.tbl_deep_extend("force", defaults, opts)
  local keys = opts.keys

  if cancel_current then
    cancel_current()
  end

  local origin_win = vim.api.nvim_get_current_win()
  local cursor_line = vim.api.nvim_win_get_cursor(origin_win)[1]
  local range = opts.range or { cursor_line, cursor_line }
  local width = resolve_width(opts.width, vim.api.nvim_win_get_width(origin_win))
  local position, max_height = find_position(origin_win, range, width, opts.max_height)
  highlight_context(origin_win, range)
  local footer_parts = vim.tbl_map(function(action)
    return ("%s %s"):format(action.key, action.name)
  end, actions)
  table.insert(footer_parts, ("%s cancel"):format(keys.cancel))
  local footer = (" %s "):format(table.concat(footer_parts, "  "))
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

  local win_config = vim.tbl_extend("force", position, {
    width = width,
    height = 1,
    style = "minimal",
    -- A title needs a border.
    border = (vim.o.winborder == "" or vim.o.winborder == "none") and "rounded" or nil,
    title = opts.title and (" %s "):format(opts.title),
  })
  -- Neovim cuts a long footer from the start. Show it only if it fits.
  if vim.api.nvim_strwidth(footer) <= width then
    win_config.footer, win_config.footer_pos = footer, "right"
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
      close(on_submit, table.concat(lines, "\n"))
    end)
  end

  local map_opts = { buffer = buf, nowait = true }
  ---@param modes string[]
  local function map_actions(modes)
    for _, action in ipairs(actions) do
      vim.keymap.set(modes, action.key --[[@as string]], function()
        submit(action.on_submit)
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
      update_height(win, max_height)
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
