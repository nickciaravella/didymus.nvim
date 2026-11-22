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

--- AST node types that are markdown syntax delimiters to conceal even if `highlights.scm` (such as
--- nvim-treesitter) does not tag them with `conceal`.
local concealed_node_types = {
  fenced_code_block_delimiter = true,
  code_span_delimiter = true,
  emphasis_delimiter = true,
  strikethrough_delimiter = true,
}

--- Record a conceal range across all 1-based lines covered by `(sr, sc) .. (er, ec)`.
---@param conceals_by_line table<integer, { start_col: integer, end_col: integer, replacement: string }[]>
---@param line_count integer
---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
---@param replacement string
local function add_conceal(conceals_by_line, line_count, sr, sc, er, ec, replacement)
  local first_row = math.max(0, sr)
  local last_row = math.min(line_count - 1, ec == 0 and er - 1 or er)
  for row = first_row, last_row do
    local line_num = row + 1
    local col_start = row == sr and sc or 0
    local col_end = row == er and ec or math.huge
    if col_end > col_start then
      conceals_by_line[line_num] = conceals_by_line[line_num] or {}
      table.insert(conceals_by_line[line_num], {
        start_col = col_start,
        end_col = col_end,
        replacement = replacement,
      })
    end
  end
end

--- Walk `node` and conceal any markdown syntax delimiter nodes (such as code fences).
---@param node TSNode
---@param conceals_by_line table<integer, { start_col: integer, end_col: integer, replacement: string }[]>
---@param line_count integer
local function collect_delimiter_conceals(node, conceals_by_line, line_count)
  if concealed_node_types[node:type()] then
    local sr, sc, er, ec = node:range()
    add_conceal(conceals_by_line, line_count, sr, sc, er, ec, "")
    return
  end
  for child in node:iter_children() do
    collect_delimiter_conceals(child, conceals_by_line, line_count)
  end
end

--- Collect highlight spans and conceal ranges for each 1-based line from the treesitter markdown
--- parser.
---@param source string Lines joined with `\n`, with a trailing `\n`.
---@param line_count integer
---@return table<integer, { start_col: integer, end_col: integer, hl: string, prio: integer, order: integer }[]>
---@return table<integer, { start_col: integer, end_col: integer, replacement: string }[]>
local function parse_spans(source, line_count)
  local spans_by_line = {}
  local conceals_by_line = {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "markdown")
  if not ok or not parser then
    return spans_by_line, conceals_by_line
  end
  local parse_ok = pcall(function()
    parser:parse(true)
  end)
  if not parse_ok then
    return spans_by_line, conceals_by_line
  end

  local order = 0
  parser:for_each_tree(function(tstree, ltree)
    local lang = ltree:lang()
    if lang == "markdown" or lang == "markdown_inline" then
      collect_delimiter_conceals(tstree:root(), conceals_by_line, line_count)
    end
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end
    for id, node, metadata in query:iter_captures(tstree:root(), source) do
      local capture = query.captures[id]
      if capture and not vim.startswith(capture, "_") then
        local capture_meta = metadata and metadata[id]
        local conceal = (capture_meta and capture_meta.conceal) or (metadata and metadata.conceal)
        local sr, sc, er, ec = node:range()
        local first_row = math.max(0, sr)
        local last_row = math.min(line_count - 1, ec == 0 and er - 1 or er)

        -- Conceal markdown syntax delimiters (`**`, `` ` ``, link URLs, code fences), but keep the
        -- code block language label visible.
        if (capture == "conceal" or conceal ~= nil) and capture ~= "label" then
          add_conceal(
            conceals_by_line,
            line_count,
            sr,
            sc,
            er,
            ec,
            type(conceal) == "string" and conceal or ""
          )
        end

        if not ignored_captures[capture] then
          order = order + 1
          local prio = tonumber(
            (capture_meta and capture_meta.priority) or (metadata and metadata.priority)
          ) or 100
          local hl = ("@%s.%s"):format(capture, lang)
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
    end
  end)
  return spans_by_line, conceals_by_line
end

--- Build `[text, hl][]` chunks for one line from its overlapping highlight spans and conceal
--- ranges. Returns nil if a non-empty line was completely concealed (such as a closing code fence).
---@param line string
---@param spans { start_col: integer, end_col: integer, hl: string, prio: integer, order: integer }[]?
---@param conceals { start_col: integer, end_col: integer, replacement: string }[]?
---@param override_hl string?
---@return [string, string?][]?
local function apply_spans(line, spans, conceals, override_hl)
  if line == "" then
    return { { "", override_hl } }
  end
  local len = #line
  local hls = {}
  local prios = {}
  local orders = {}
  if override_hl then
    for byte = 1, len do
      hls[byte] = override_hl
    end
  elseif spans then
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
  end

  local concealed = {}
  local replacements = {}
  if conceals then
    for _, item in ipairs(conceals) do
      local first = math.max(1, item.start_col + 1)
      local last = math.min(len, item.end_col)
      for byte = first, last do
        concealed[byte] = true
      end
      if item.replacement ~= "" and first <= len then
        replacements[first] = { text = item.replacement, hl = hls[first] }
      end
    end
  end

  local chunks = {}
  local function push_text(text, hl)
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

  local byte = 1
  while byte <= len do
    if concealed[byte] then
      local rep = replacements[byte]
      if rep then
        push_text(rep.text, rep.hl)
      end
      byte = byte + 1
    else
      local run_start = byte
      local run_hl = hls[byte]
      byte = byte + 1
      while byte <= len and not concealed[byte] and hls[byte] == run_hl do
        byte = byte + 1
      end
      push_text(line:sub(run_start, byte - 1), run_hl)
    end
  end

  if #chunks == 0 then
    return nil
  end
  return chunks
end

--- Render markdown `text` into one array of `[text, hl]` chunks for each visible line, hiding
--- markdown delimiters (`**`, `` ` ``, link URLs, code fences) via treesitter `@conceal`.
---@param text string
---@param opts { tabstop: integer?, hl: string? }? With `hl`, apply `hl` to all text (for resolved threads).
---@return [string, string?][][]
function M.highlight(text, opts)
  opts = opts or {}
  local tabstop = opts.tabstop or 8
  local raw_lines = vim.split(text, "\n")
  local lines = {}
  for index, raw in ipairs(raw_lines) do
    lines[index] = M.expand_tabs((raw:gsub("%s+$", "")), tabstop)
  end

  local source = table.concat(lines, "\n") .. "\n"
  local spans_by_line, conceals_by_line = parse_spans(source, #lines)
  local result = {}
  for index, line in ipairs(lines) do
    local chunks = apply_spans(line, spans_by_line[index], conceals_by_line[index], opts.hl)
    if chunks then
      table.insert(result, chunks)
    end
  end
  if #result == 0 then
    return { { { "", opts.hl } } }
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
