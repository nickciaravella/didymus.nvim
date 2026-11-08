local M = {}

---@class didymus.ui.input.Keys
---@field submit string? In normal and insert mode.
---@field cancel string? In normal mode. `<Esc>` in normal mode also cancels.

---@class didymus.ui.input.Opts
---@field title string?
---@field on_submit fun(text: string)
---@field on_cancel fun()?
---@field width number? A width below 1 is a fraction of the editor width.
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

---@param width number
---@return integer
local function resolve_width(width)
  width = width < 1 and math.floor(vim.o.columns * width) or width
  -- The border uses two columns.
  return math.max(1, math.min(width, vim.o.columns - 2))
end

--- Put the float under the cursor line. If the space under the line is too small, put it above.
---@param max_height integer
---@return vim.api.keyset.win_config position
---@return integer max_height The max height that fits.
local function find_position(max_height)
  local cursor_row = vim.fn.win_screenpos(0)[1] + vim.fn.winline() - 1
  local rows_below = vim.o.lines - vim.o.cmdheight - cursor_row - 2
  local rows_above = cursor_row - 1 - 2
  if rows_below >= max_height or rows_below >= rows_above then
    return { relative = "cursor", anchor = "NW", row = 1, col = 0 },
      math.max(1, math.min(max_height, rows_below))
  end
  -- With the SW anchor, the float ends above the cursor line and grows up.
  return { relative = "cursor", anchor = "SW", row = 0, col = 0 },
    math.max(1, math.min(max_height, rows_above))
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

--- Open a float at the cursor for a prompt. `<CR>` adds a line.
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
  local position, max_height = find_position(opts.max_height)
  local width = resolve_width(opts.width)
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
