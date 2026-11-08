local M = {}

---@class didymus.ui.input.Keys
---@field submit string? In normal and insert mode.
---@field cancel string? In normal mode. `<Esc>` in normal mode also cancels.

---@class didymus.ui.input.Opts
---@field title string?
---@field on_submit fun(text: string)
---@field on_cancel fun()?
---@field width number? A width below 1 is a fraction of the current window width.
---@field max_height integer?
---@field keys didymus.ui.input.Keys?

local defaults = {
  width = 60,
  max_height = 10,
  keys = { submit = "<C-y>", cancel = "q" },
}

--- Cancels the open input float.
---@type fun()?
local cancel_current

-- The border uses two rows and two columns.
local border_size = 2

---@param width number
---@param win_width integer
---@return integer
local function resolve_width(width, win_width)
  width = width < 1 and math.floor(win_width * width) or width
  return math.max(1, math.min(width, win_width - border_size))
end

--- Put the float above the cursor line, in the center of the window. If the space above the
--- line is too small, put it under the line. The float covers no part of a wrapped line.
---@param win integer
---@param width integer
---@param max_height integer
---@return vim.api.keyset.win_config position
---@return integer max_height The max height that fits.
local function find_position(win, width, max_height)
  local info = vim.fn.getwininfo(win)[1]
  local text_top = info.winrow + info.winbar
  local text_bottom = text_top + info.height - 1
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local last_col = math.max(1, #vim.api.nvim_buf_get_lines(info.bufnr, lnum - 1, lnum, true)[1])
  -- A row of 0 means that part of the line is outside the window.
  local line_top = vim.fn.screenpos(win, lnum, 1).row
  local line_bottom = vim.fn.screenpos(win, lnum, last_col).row
  line_top = line_top > 0 and line_top or text_top
  line_bottom = line_bottom > 0 and line_bottom or text_bottom

  -- Screen rows are 1-based, and float rows are 0-based.
  local col = info.wincol - 1 + math.floor((info.width - width - border_size) / 2)
  local rows_above = line_top - text_top - border_size
  local rows_below = text_bottom - line_bottom - border_size
  if rows_above >= max_height or rows_above >= rows_below then
    -- With the SW anchor, the float ends on the row above the line and grows up.
    return { relative = "editor", anchor = "SW", row = line_top - 1, col = col },
      math.max(1, math.min(max_height, rows_above))
  end
  return { relative = "editor", anchor = "NW", row = line_bottom, col = col },
    math.max(1, math.min(max_height, rows_below))
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

--- Open a float above the cursor line for a prompt. `<CR>` adds a line.
---@param opts didymus.ui.input.Opts
function M.open(opts)
  vim.validate("opts.on_submit", opts.on_submit, "function")
  vim.validate("opts.on_cancel", opts.on_cancel, "function", true)
  opts = vim.tbl_deep_extend("force", defaults, opts)
  local keys = opts.keys

  if cancel_current then
    cancel_current()
  end

  local origin_win = vim.api.nvim_get_current_win()
  local width = resolve_width(opts.width, vim.api.nvim_win_get_width(origin_win))
  local position, max_height = find_position(origin_win, width, opts.max_height)
  local footer = (" %s submit  %s cancel "):format(keys.submit, keys.cancel)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].autocomplete = false
  -- blink.cmp and snacks.nvim read `b:completion`. Set it before the filetype, so that
  -- FileType autocmds of the user can change it.
  vim.b[buf].completion = false
  vim.bo[buf].filetype = "didymus_input"

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

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and lines[#lines]:match("^%s*$") do
      table.remove(lines)
    end
    if #lines == 0 then
      return
    end
    -- Close after the mode change. Else insert mode stays on in the original window.
    vim.cmd.stopinsert()
    vim.schedule(function()
      close(opts.on_submit, table.concat(lines, "\n"))
    end)
  end

  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set({ "n", "i" }, keys.submit, submit, map_opts)
  vim.keymap.set("n", keys.cancel, cancel, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)

  -- Completion plugins, such as blink.cmp, set buffer mappings on InsertEnter. Some of these
  -- mappings do not fall back to ours. Set the submit mapping again after them.
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.keymap.set("i", keys.submit, submit, map_opts)
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

  vim.cmd.startinsert()
end

return M
