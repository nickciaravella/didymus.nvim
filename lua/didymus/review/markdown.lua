--- Highlight markdown text with the built-in treesitter parsers of Neovim 0.12, and wrap styled
--- chunks to a display width. Used for inline threads in `virt_lines`.

local M = {}

--- Captures that are not highlight groups.
local ignored_captures = {
  spell = true,
  nospell = true,
  conceal = true,
}

--- Replace each tab with spaces, up to the next multiple of `tabstop` columns.
---@param line string
---@param tabstop integer
---@return string
function M.expand_tabs(line, tabstop)
  local column = 0
  return (
    line:gsub("([^\t]*)\t", function(before)
      column = column + vim.fn.strdisplaywidth(before)
      local spaces = tabstop - column % tabstop
      column = column + spaces
      return before .. (" "):rep(spaces)
    end)
  )
end

--- The total display width of `chunks`.
---@param chunks [string, string?][]
---@return integer
function M.chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

--- Cut `chunks` so that their display width is `max_width` or less.
---@param chunks [string, string?][]
---@param max_width integer
---@return [string, string?][]
function M.truncate_chunks(chunks, max_width)
  max_width = math.max(max_width, 0)
  local result = {}
  local used = 0
  for _, chunk in ipairs(chunks) do
    local text, hl = chunk[1], chunk[2]
    local chunk_width = vim.fn.strdisplaywidth(text)
    if used + chunk_width <= max_width then
      table.insert(result, { text, hl })
      used = used + chunk_width
    else
      local kept = {}
      for _, char in ipairs(vim.fn.split(text, [[\zs]])) do
        local char_width = vim.fn.strdisplaywidth(char)
        if used + char_width > max_width then
          break
        end
        table.insert(kept, char)
        used = used + char_width
      end
      if #kept > 0 then
        table.insert(result, { table.concat(kept), hl })
      end
      break
    end
  end
  return result
end

--- Collect highlight spans for each 1-based line from the treesitter markdown parser.
---@param source string Lines joined with `\n`, with a trailing `\n`.
---@param line_count integer
---@return table<integer, { start_col: integer, end_col: integer, hl: string, prio: integer, order: integer }[]>
local function parse_spans(source, line_count)
  local spans_by_line = {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "markdown")
  if not ok or not parser then
    return spans_by_line
  end
  local parse_ok = pcall(function()
    parser:parse(true)
  end)
  if not parse_ok then
    return spans_by_line
  end

  local order = 0
  parser:for_each_tree(function(tstree, ltree)
    local lang = ltree:lang()
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end
    for id, node, metadata in query:iter_captures(tstree:root(), source) do
      local capture = query.captures[id]
      if capture and not ignored_captures[capture] and not vim.startswith(capture, "_") then
        order = order + 1
        local capture_meta = metadata and metadata[id]
        local prio = tonumber(
          (capture_meta and capture_meta.priority) or (metadata and metadata.priority)
        ) or 100
        local hl = ("@%s.%s"):format(capture, lang)
        local sr, sc, er, ec = node:range()
        local first_row = math.max(0, sr)
        local last_row = math.min(line_count - 1, ec == 0 and er - 1 or er)
        for row = first_row, last_row do
          local line_num = row + 1
          local col_start = row == sr and sc or 0
          local col_end = row == er and ec or math.huge
          if col_end > col_start then
            spans_by_line[line_num] = spans_by_line[line_num] or {}
            table.insert(spans_by_line[line_num], {
              start_col = col_start,
              end_col = col_end,
              hl = hl,
              prio = prio,
              order = order,
            })
          end
        end
      end
    end
  end)
  return spans_by_line
end

--- Build `[text, hl][]` chunks for one line from its overlapping highlight spans.
---@param line string
---@param spans { start_col: integer, end_col: integer, hl: string, prio: integer, order: integer }[]?
---@return [string, string?][]
local function apply_spans(line, spans)
  if line == "" or not spans or #spans == 0 then
    return { { line } }
  end
  local len = #line
  local hls = {}
  local prios = {}
  local orders = {}
  for _, span in ipairs(spans) do
    local first = math.max(1, span.start_col + 1)
    local last = math.min(len, span.end_col)
    for byte = first, last do
      local old_prio = prios[byte]
      if
        not old_prio
        or span.prio > old_prio
        or (span.prio == old_prio and span.order > orders[byte])
      then
        hls[byte] = span.hl
        prios[byte] = span.prio
        orders[byte] = span.order
      end
    end
  end

  local chunks = {}
  local run_start = 1
  local run_hl = hls[1]
  for byte = 2, len + 1 do
    local hl = byte <= len and hls[byte] or nil
    if byte > len or hl ~= run_hl then
      table.insert(chunks, { line:sub(run_start, byte - 1), run_hl })
      run_start = byte
      run_hl = hl
    end
  end
  return chunks
end

--- Highlight markdown `text` into one array of `[text, hl]` chunks for each line.
---@param text string
---@param opts { tabstop: integer?, hl: string? }? With `hl`, skip treesitter and use `hl` for all text.
---@return [string, string?][][]
function M.highlight(text, opts)
  opts = opts or {}
  local tabstop = opts.tabstop or 8
  local raw_lines = vim.split(text, "\n")
  local lines = {}
  for index, raw in ipairs(raw_lines) do
    lines[index] = M.expand_tabs((raw:gsub("%s+$", "")), tabstop)
  end

  if opts.hl then
    local result = {}
    for index, line in ipairs(lines) do
      result[index] = { { line, opts.hl } }
    end
    return result
  end

  local source = table.concat(lines, "\n") .. "\n"
  local spans_by_line = parse_spans(source, #lines)
  local result = {}
  for index, line in ipairs(lines) do
    result[index] = apply_spans(line, spans_by_line[index])
  end
  return result
end

--- Append `text` with `hl` to `chunks`, merging with the last chunk if it has the same highlight.
---@param chunks [string, string?][]
---@param text string
---@param hl string?
local function append_chunk(chunks, text, hl)
  if text == "" then
    return
  end
  local last = chunks[#chunks]
  if last and last[2] == hl then
    last[1] = last[1] .. text
  else
    table.insert(chunks, { text, hl })
  end
end

--- Split a list of styled characters into alternating space runs and word runs.
---@param chunks [string, string?][]
---@return { is_space: boolean, width: integer, chars: { char: string, width: integer, hl: string? }[] }[]
local function tokenize_chunks(chunks)
  local tokens = {}
  for _, chunk in ipairs(chunks) do
    local text, hl = chunk[1], chunk[2]
    for _, char in ipairs(vim.fn.split(text, [[\zs]])) do
      local is_space = char:match("^%s$") ~= nil
      local char_width = vim.fn.strdisplaywidth(char)
      local last = tokens[#tokens]
      if not last or last.is_space ~= is_space then
        last = { is_space = is_space, width = 0, chars = {} }
        table.insert(tokens, last)
      end
      table.insert(last.chars, { char = char, width = char_width, hl = hl })
      last.width = last.width + char_width
    end
  end
  return tokens
end

--- Wrap one line of styled `[text, hl]` chunks into lines of `width` display cells or fewer, at
--- spaces. A word longer than `width` breaks across lines. Spaces at the start of the line stay.
--- An empty line stays as one empty line.
---@param chunks [string, string?][]
---@param width integer
---@return [string, string?][][]
function M.wrap_chunks(chunks, width)
  width = math.max(width, 1)
  local tokens = tokenize_chunks(chunks)
  local lines = {}
  ---@type [string, string?][]
  local line = {}
  local line_width = 0

  local function push()
    if #line == 0 then
      table.insert(lines, { { "" } })
    else
      table.insert(lines, line)
    end
    line = {}
    line_width = 0
  end

  local index = 1
  while index <= #tokens do
    local spaces, word
    if tokens[index].is_space then
      spaces = tokens[index]
      index = index + 1
    end
    if index <= #tokens and not tokens[index].is_space then
      word = tokens[index]
      index = index + 1
    end

    local spaces_width = spaces and spaces.width or 0
    local word_width = word and word.width or 0

    if line_width > 0 and line_width + spaces_width + word_width > width then
      push()
    elseif spaces then
      -- The spaces at the start of a line can be the indent of code.
      for _, item in ipairs(spaces.chars) do
        if line_width + item.width > width then
          break
        end
        append_chunk(line, item.char, item.hl)
        line_width = line_width + item.width
      end
    end

    if word then
      if line_width + word_width <= width then
        for _, item in ipairs(word.chars) do
          append_chunk(line, item.char, item.hl)
        end
        line_width = line_width + word_width
      else
        for _, item in ipairs(word.chars) do
          if line_width > 0 and line_width + item.width > width then
            push()
          end
          append_chunk(line, item.char, item.hl)
          line_width = line_width + item.width
        end
      end
    end
  end

  if line_width > 0 or #lines == 0 then
    push()
  end
  return lines
end

return M
