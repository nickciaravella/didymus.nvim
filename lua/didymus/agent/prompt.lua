---@class didymus.agent.Context
---@field path string Relative to the current directory, or absolute if outside it.
---@field start_line integer 1-based, inclusive.
---@field end_line integer 1-based, inclusive.
---@field text string
---@field filetype string?

---@class didymus.agent.Prompt
---@field text string? Nil for an append with no text.
---@field context didymus.agent.Context[]

local M = {}

---@param mode string A visual mode.
---@return string[] lines
---@return integer start_line
---@return integer end_line
local function get_selection(mode)
  local pos1, pos2 = vim.fn.getpos("v"), vim.fn.getpos(".")
  local start_line, end_line = math.min(pos1[2], pos2[2]), math.max(pos1[2], pos2[2])
  local lines
  -- getregion() ignores `$` in a block selection. It stops at the cursor column on all lines.
  if mode == "\22" and vim.fn.winsaveview().curswant == vim.v.maxcol then
    lines = {}
    for _, segment in ipairs(vim.fn.getregionpos(pos1, pos2, { type = mode, eol = true })) do
      local start = segment[1]
      local line_end = { start[1], start[2], vim.v.maxcol, 0 }
      table.insert(lines, vim.fn.getregion(start, line_end, { type = "v" })[1])
    end
  else
    lines = vim.fn.getregion(pos1, pos2, { type = mode })
  end
  return lines, start_line, end_line
end

--- With no range: the current line, or the selection in visual mode. Then `buf` must be the current buffer.
--- Throws an error if the buffer has no file.
---@param opts { buf: integer, range: integer[]? } `range` is the first and the last line.
---@return didymus.agent.Context
function M.context(opts)
  local name = vim.api.nvim_buf_get_name(opts.buf)
  if name == "" then
    error("didymus: the buffer has no file", 0)
  end

  local lines, start_line, end_line
  local mode = vim.fn.mode()
  if opts.range then
    start_line, end_line = opts.range[1], opts.range[2]
    lines = vim.api.nvim_buf_get_lines(opts.buf, start_line - 1, end_line, true)
  elseif mode == "v" or mode == "V" or mode == "\22" then
    lines, start_line, end_line = get_selection(mode)
  else
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
    lines = vim.api.nvim_buf_get_lines(opts.buf, start_line - 1, start_line, true)
  end

  local filetype = vim.bo[opts.buf].filetype
  return {
    path = vim.fs.relpath(vim.fn.getcwd(), name) or name,
    start_line = start_line,
    end_line = end_line,
    text = table.concat(lines, "\n"),
    filetype = filetype ~= "" and filetype or nil,
  }
end

---@param text string
---@return string
local function make_fence(text)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return ("`"):rep(math.max(3, longest + 1))
end

--- `path:10` for one line, `path:10-12` for more lines.
---@param context didymus.agent.Context
---@return string
function M.location(context)
  if context.start_line == context.end_line then
    return ("%s:%d"):format(context.path, context.start_line)
  end
  return ("%s:%d-%d"):format(context.path, context.start_line, context.end_line)
end

---@param context didymus.agent.Context
---@return string
local function format_context(context)
  local fence = make_fence(context.text)
  return table.concat(
    { M.location(context), fence .. (context.filetype or ""), context.text, fence },
    "\n"
  )
end

---@param prompt didymus.agent.Prompt
---@return string
function M.to_text(prompt)
  local parts = vim.tbl_map(format_context, prompt.context)
  if not prompt.text then
    -- For append, the user types the rest of the prompt under the block.
    return table.concat(parts, "\n\n") .. "\n"
  end
  table.insert(parts, prompt.text)
  return table.concat(parts, "\n\n")
end

return M
