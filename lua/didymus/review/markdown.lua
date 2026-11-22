--- Render markdown text with the built-in treesitter parsers of Neovim 0.12 (and optional
--- `render-markdown.nvim` marks when installed), and wrap styled chunks to a display width. Used
--- for inline threads in `virt_lines`.

local M = {}

-- Register `didymus_thread` to the `markdown` parser so `render-markdown.nvim` can parse scratch
-- thread buffers before `inline_box.lua` loads.
pcall(vim.treesitter.language.register, "markdown", "didymus_thread")

---@alias didymus.review.markdown.Hl string|string[]
---@alias didymus.review.markdown.Chunk [string, didymus.review.markdown.Hl?]

--- Captures that are not highlight groups.
local ignored_captures = {
  spell = true,
  nospell = true,
  conceal = true,
}

--- Return true when two highlight specs (nil, string or string array) are equal.
---@param a didymus.review.markdown.Hl?
---@param b didymus.review.markdown.Hl?
---@return boolean
local function hl_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for index = 1, #a do
    if a[index] ~= b[index] then
      return false
    end
  end
  return true
end

--- Append `hl` (string or list of strings) to `list`, skipping adjacent duplicates.
---@param list string[]
---@param hl didymus.review.markdown.Hl?
local function push_hl(list, hl)
  if type(hl) == "string" and hl ~= "" then
    if list[#list] ~= hl then
      table.insert(list, hl)
    end
  elseif type(hl) == "table" then
    for _, item in ipairs(hl) do
      push_hl(list, item)
    end
  end
end

--- Combine a base highlight and an overlay highlight (highest priority last).
---@param base didymus.review.markdown.Hl?
---@param top didymus.review.markdown.Hl?
---@return didymus.review.markdown.Hl?
local function combine_hl(base, top)
  local list = {}
  push_hl(list, base)
  push_hl(list, top)
  if #list == 0 then
    return nil
  end
  if #list == 1 then
    return list[1]
  end
  return list
end

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
---@param chunks didymus.review.markdown.Chunk[]
---@return integer
function M.chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

--- Cut `chunks` so that their display width is `max_width` or less.
---@param chunks didymus.review.markdown.Chunk[]
---@param max_width integer
---@return didymus.review.markdown.Chunk[]
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

--- AST node types for inline markdown syntax delimiters concealed under `conceallevel = 3`.
local inline_delimiter_types = {
  code_span_delimiter = true,
  emphasis_delimiter = true,
  strikethrough_delimiter = true,
}

--- Record a conceal range across all 1-based lines covered by `(sr, sc) .. (er, ec)`.
---@param conceals_by_line table<integer, { start_col: integer, end_col: integer, replacement: string, hl: didymus.review.markdown.Hl? }[]>
---@param line_count integer
---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
---@param replacement string
---@param hl didymus.review.markdown.Hl?
local function add_conceal(conceals_by_line, line_count, sr, sc, er, ec, replacement, hl)
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
        hl = hl,
      })
    end
  end
end

--- Walk `node` and conceal markdown syntax delimiter nodes even if `highlights.scm` (such as
--- nvim-treesitter) does not tag them with `conceal`.
---@param node TSNode
---@param conceals_by_line table<integer, { start_col: integer, end_col: integer, replacement: string, hl: didymus.review.markdown.Hl? }[]>
---@param line_count integer
---@param conceal_fences boolean
local function collect_delimiter_conceals(node, conceals_by_line, line_count, conceal_fences)
  local node_type = node:type()
  if
    inline_delimiter_types[node_type]
    or (conceal_fences and node_type == "fenced_code_block_delimiter")
  then
    local sr, sc, er, ec = node:range()
    add_conceal(conceals_by_line, line_count, sr, sc, er, ec, "")
    return
  end
  for child in node:iter_children() do
    collect_delimiter_conceals(child, conceals_by_line, line_count, conceal_fences)
  end
end

--- Collect highlight spans and conceal ranges for each 1-based line from the treesitter markdown
--- parser.
---@param source string Lines joined with `\n`, with a trailing `\n`.
---@param line_count integer
---@param conceal_fences boolean
---@return table<integer, { start_col: integer, end_col: integer, hl: string, prio: integer, order: integer }[]>
---@return table<integer, { start_col: integer, end_col: integer, replacement: string, hl: didymus.review.markdown.Hl? }[]>
local function parse_spans(source, line_count, conceal_fences)
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
      collect_delimiter_conceals(tstree:root(), conceals_by_line, line_count, conceal_fences)
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

--- Run `render-markdown.nvim` handlers synchronously on a hidden scratch buffer so unfocused
--- `virt_lines` threads match focused read-only windows. Returns nil if `render-markdown.nvim` is
--- not installed or not configured.
---@param lines string[]
---@param width integer
---@return table[]?
local function get_render_markdown_marks(lines, width)
  local ok_rm = pcall(require, "render-markdown")
  if not ok_rm then
    return nil
  end
  local ok_state, rm_state = pcall(require, "render-markdown.state")
  local ok_ctx, rm_context = pcall(require, "render-markdown.request.context")
  local ok_handlers, rm_handlers = pcall(require, "render-markdown.core.handlers")
  if
    not (ok_state and ok_ctx and ok_handlers)
    or not rm_state.config
    or type(rm_state.get) ~= "function"
    or type(rm_context.new) ~= "function"
    or type(rm_handlers.run) ~= "function"
  then
    return nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local win = -1
  local marks
  pcall(function()
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "didymus_thread"
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
    vim.treesitter.start(buf, "markdown")

    win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = math.max(1, width),
      height = math.max(1, #lines),
      style = "minimal",
      focusable = false,
      hide = true,
      noautocmd = true,
    })

    if type(rm_state.cache) == "table" then
      rm_state.cache[buf] = nil
    end
    local cfg = rm_state.get(buf, {
      enabled = true,
      anti_conceal = { enabled = false },
    })
    local context = rm_context.new(buf, win, cfg)
    local parser = vim.treesitter.get_parser(buf, "markdown")
    if context and parser then
      context.view:parse(parser, function()
        marks = rm_handlers.run(context, parser)
      end)
    end
  end)

  if type(rm_context.cache) == "table" then
    rm_context.cache[buf] = nil
  end
  if type(rm_state.cache) == "table" then
    rm_state.cache[buf] = nil
  end
  if win ~= -1 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  return marks
end

--- Append `text` with `hl` to `chunks`, merging with the last chunk if it has the same highlight.
---@param chunks didymus.review.markdown.Chunk[]
---@param text string
---@param hl didymus.review.markdown.Hl?
local function append_chunk(chunks, text, hl)
  if text == "" then
    return
  end
  local last = chunks[#chunks]
  if last and hl_equal(last[2], hl) then
    last[1] = last[1] .. text
  else
    table.insert(chunks, { text, hl })
  end
end

--- Override all highlights in `chunks` with `override_hl` when set.
---@param chunks didymus.review.markdown.Chunk[]
---@param override_hl string?
---@return didymus.review.markdown.Chunk[]
local function map_override_hl(chunks, override_hl)
  if not override_hl then
    return chunks
  end
  local result = {}
  for _, chunk in ipairs(chunks) do
    append_chunk(result, chunk[1], override_hl)
  end
  return #result > 0 and result or { { "", override_hl } }
end

--- Index `render-markdown.nvim` marks by 0-based row.
---@param marks table[]
---@param lines string[]
---@return table
local function index_marks(marks, lines)
  local line_count = #lines
  local info = {
    hidden = {},
    replace = {},
    virt_lines_above = {},
    virt_lines_below = {},
    ext_spans = {},
    eol_hl = {},
    conceals = {},
    inline = {},
    overlay = {},
    win_col = {},
    eol = {},
    right_align = {},
  }

  local order = 0
  for _, mark in ipairs(marks) do
    local opts = mark.opts or {}
    local sr = mark.start_row or 0
    local sc = mark.start_col or 0
    order = order + 1

    if opts.conceal_lines ~= nil then
      if mark.replace then
        info.replace[sr] = mark.replace
      end
      local er = opts.end_row or sr
      local last = math.min(line_count - 1, opts.end_col == 0 and er - 1 or er)
      for r = math.max(0, sr), last do
        info.hidden[r] = true
      end
    end

    if opts.virt_lines then
      local bucket = opts.virt_lines_above and info.virt_lines_above or info.virt_lines_below
      bucket[sr] = bucket[sr] or {}
      for _, vline in ipairs(opts.virt_lines) do
        table.insert(bucket[sr], vline)
      end
    end

    if opts.conceal ~= nil then
      local er = opts.end_row or sr
      local ec = opts.end_col or #(lines[er + 1] or "")
      add_conceal(info.conceals, line_count, sr, sc, er, ec, opts.conceal, opts.hl_group)
    end

    if opts.hl_group and not opts.virt_text and opts.conceal == nil then
      local prio = opts.priority or 4096
      local er = opts.end_row or sr
      if opts.hl_eol then
        local last = (opts.end_col == nil or opts.end_col == 0) and (er - 1) or er
        last = math.min(line_count - 1, math.max(sr, last))
        for r = math.max(0, sr), last do
          local line_num = r + 1
          local col_start = r == sr and sc or 0
          info.ext_spans[line_num] = info.ext_spans[line_num] or {}
          table.insert(info.ext_spans[line_num], {
            start_col = col_start,
            end_col = math.huge,
            hl = opts.hl_group,
            prio = prio,
            order = order,
          })
          local prev = info.eol_hl[r]
          if not prev or prio >= prev.prio then
            info.eol_hl[r] = { hl = opts.hl_group, prio = prio }
          end
        end
      else
        local ec = opts.end_col or #(lines[er + 1] or "")
        local last = math.min(line_count - 1, ec == 0 and er - 1 or er)
        for r = math.max(0, sr), last do
          local line_num = r + 1
          local col_start = r == sr and sc or 0
          local col_end = r == er and ec or math.huge
          if col_end > col_start then
            info.ext_spans[line_num] = info.ext_spans[line_num] or {}
            table.insert(info.ext_spans[line_num], {
              start_col = col_start,
              end_col = col_end,
              hl = opts.hl_group,
              prio = prio,
              order = order,
            })
          end
        end
      end
    end

    if opts.virt_text then
      local entry = {
        start_col = sc,
        win_col = opts.virt_text_win_col,
        virt_text = opts.virt_text,
        hl_mode = opts.hl_mode,
        prio = opts.priority or 4096,
        order = order,
      }
      local pos = opts.virt_text_win_col ~= nil and "win_col" or (opts.virt_text_pos or "eol")
      if pos == "inline" then
        info.inline[sr] = info.inline[sr] or {}
        table.insert(info.inline[sr], entry)
      elseif pos == "overlay" then
        info.overlay[sr] = info.overlay[sr] or {}
        table.insert(info.overlay[sr], entry)
      elseif pos == "win_col" then
        info.win_col[sr] = info.win_col[sr] or {}
        table.insert(info.win_col[sr], entry)
      elseif pos == "eol_right_align" or pos == "right_align" then
        info.right_align[sr] = info.right_align[sr] or {}
        table.insert(info.right_align[sr], entry)
      else
        info.eol[sr] = info.eol[sr] or {}
        table.insert(info.eol[sr], entry)
      end
    end
  end

  return info
end

--- Compute the highlight at each 1-based byte of `line` by picking the winning treesitter capture
--- and stacking any extmark highlights in priority order (highest priority last).
---@param len integer
---@param ts_spans table[]?
---@param ext_spans table[]?
---@param override_hl string?
---@return table<integer, didymus.review.markdown.Hl>
local function compute_byte_hls(len, ts_spans, ext_spans, override_hl)
  local hls = {}
  if override_hl then
    for byte = 1, len do
      hls[byte] = override_hl
    end
    return hls
  end

  local ts_hl = {}
  local ts_prio = {}
  local ts_order = {}
  if ts_spans then
    for _, span in ipairs(ts_spans) do
      local first = math.max(1, span.start_col + 1)
      local last = math.min(len, span.end_col)
      for byte = first, last do
        local old_prio = ts_prio[byte]
        if
          not old_prio
          or span.prio > old_prio
          or (span.prio == old_prio and span.order > ts_order[byte])
        then
          ts_hl[byte] = span.hl
          ts_prio[byte] = span.prio
          ts_order[byte] = span.order
        end
      end
    end
  end

  if not ext_spans or #ext_spans == 0 then
    return ts_hl
  end

  local ext_at = {}
  for _, span in ipairs(ext_spans) do
    local first = math.max(1, span.start_col + 1)
    local last = math.min(len, span.end_col)
    for byte = first, last do
      ext_at[byte] = ext_at[byte] or {}
      table.insert(ext_at[byte], span)
    end
  end

  for byte = 1, len do
    local extras = ext_at[byte]
    if not extras then
      hls[byte] = ts_hl[byte]
    else
      local stack = {}
      if ts_hl[byte] then
        table.insert(stack, { hl = ts_hl[byte], prio = ts_prio[byte], order = 0 })
      end
      for _, span in ipairs(extras) do
        table.insert(stack, { hl = span.hl, prio = span.prio, order = span.order })
      end
      table.sort(stack, function(a, b)
        if a.prio ~= b.prio then
          return a.prio < b.prio
        end
        return a.order < b.order
      end)
      local combined = {}
      for _, item in ipairs(stack) do
        push_hl(combined, item.hl)
      end
      if #combined == 1 then
        hls[byte] = combined[1]
      elseif #combined > 1 then
        hls[byte] = combined
      end
    end
  end
  return hls
end

--- Build `[text, hl][]` chunks and trailing `eol_hl` for one source line from treesitter spans,
--- conceals, and optional `render-markdown.nvim` marks. Returns nil if a non-empty line was
--- completely concealed with no virtual text.
---@param line string
---@param row integer 0-based line index.
---@param ts_spans table[]?
---@param ts_conceals table[]?
---@param rm_info table?
---@param opts { hl: string?, width: integer? }
---@return didymus.review.markdown.Chunk[]? chunks
---@return didymus.review.markdown.Hl? eol_hl
local function composite_line(line, row, ts_spans, ts_conceals, rm_info, opts)
  local line_num = row + 1
  local override_hl = opts.hl
  local width = opts.width
  local ext_spans = rm_info and rm_info.ext_spans[line_num]
  local rm_conceals = rm_info and rm_info.conceals[line_num]
  local eol_entry = rm_info and rm_info.eol_hl[row]
  local eol_hl = (not override_hl) and eol_entry and eol_entry.hl or nil

  local hls = compute_byte_hls(#line, ts_spans, ext_spans, override_hl)

  local concealed = {}
  local replacements = {}
  local function register_conceals(list)
    if not list then
      return
    end
    for _, item in ipairs(list) do
      local first = math.max(1, item.start_col + 1)
      local last = math.min(#line, item.end_col)
      for byte = first, last do
        concealed[byte] = true
      end
      if item.replacement ~= "" and first <= #line then
        replacements[first] = {
          text = item.replacement,
          hl = override_hl or item.hl or hls[first],
        }
      end
    end
  end
  register_conceals(ts_conceals)
  register_conceals(rm_conceals)

  -- Display-cell buffer: `cells[vcol]` is `{ text, width, hl }`, or `false` for the trailing cell
  -- of a double-width character.
  local cells = {}
  local max_vcol = 0

  local function clear_overlap(vcol, span_w)
    if vcol > 0 and cells[vcol] == false then
      cells[vcol - 1] = { text = " ", width = 1, hl = eol_hl }
      cells[vcol] = nil
    end
    for col = vcol, vcol + span_w - 1 do
      local existing = cells[col]
      if type(existing) == "table" and existing.width == 2 and col + 1 >= vcol + span_w then
        cells[col + 1] = { text = " ", width = 1, hl = existing.hl }
      end
      cells[col] = nil
    end
  end

  local function write_char(vcol, ch, hl, limit)
    local w = vim.fn.strdisplaywidth(ch)
    if w == 0 then
      if vcol > 0 then
        local target = cells[vcol - 1] == false and (vcol - 2) or (vcol - 1)
        if type(cells[target]) == "table" then
          cells[target].text = cells[target].text .. ch
        end
      end
      return vcol
    end
    if limit and vcol + w > limit then
      return vcol
    end
    clear_overlap(vcol, w)
    cells[vcol] = { text = ch, width = w, hl = hl }
    if w == 2 then
      cells[vcol + 1] = false
    end
    if vcol + w > max_vcol then
      max_vcol = vcol + w
    end
    return vcol + w
  end

  local function fill_gap(from_vcol, to_vcol, limit)
    local stop = limit and math.min(to_vcol, limit) or to_vcol
    for col = from_vcol, stop - 1 do
      if cells[col] == nil then
        cells[col] = { text = " ", width = 1, hl = eol_hl }
      end
    end
    if stop > max_vcol then
      max_vcol = stop
    end
  end

  local function write_virt_text(start_vcol, vt, hl_mode, limit)
    local vcol = start_vcol
    for _, chunk in ipairs(vt) do
      local text, chunk_hl = chunk[1], chunk[2]
      for _, ch in ipairs(vim.fn.split(text, [[\zs]])) do
        local hl
        if override_hl then
          hl = override_hl
        elseif hl_mode == "combine" then
          local under = type(cells[vcol]) == "table" and cells[vcol].hl or eol_hl
          hl = combine_hl(under, chunk_hl)
        else
          hl = chunk_hl
        end
        local next_vcol = write_char(vcol, ch, hl, limit)
        if limit and next_vcol == vcol and vim.fn.strdisplaywidth(ch) > 0 then
          return vcol
        end
        vcol = next_vcol
      end
    end
    return vcol
  end

  -- Index inline virtual text by 0-based byte column.
  local inline_by_col = {}
  local inline_after = {}
  if rm_info and rm_info.inline[row] then
    local list = rm_info.inline[row]
    table.sort(list, function(a, b)
      if a.start_col ~= b.start_col then
        return a.start_col < b.start_col
      end
      return a.order < b.order
    end)
    for _, entry in ipairs(list) do
      if entry.start_col >= #line then
        table.insert(inline_after, entry)
      else
        inline_by_col[entry.start_col] = inline_by_col[entry.start_col] or {}
        table.insert(inline_by_col[entry.start_col], entry)
      end
    end
  end

  -- Pass 1: source characters, conceals, and inline virtual text.
  local byte_to_vcol = {}
  local cur_vcol = 0
  local byte_pos = 1
  for _, ch in ipairs(vim.fn.split(line, [[\zs]])) do
    local col = byte_pos - 1
    byte_to_vcol[col] = cur_vcol
    if inline_by_col[col] then
      for _, entry in ipairs(inline_by_col[col]) do
        cur_vcol = write_virt_text(cur_vcol, entry.virt_text, entry.hl_mode, nil)
      end
    end
    if concealed[byte_pos] then
      local rep = replacements[byte_pos]
      if rep then
        for _, rch in ipairs(vim.fn.split(rep.text, [[\zs]])) do
          cur_vcol = write_char(cur_vcol, rch, rep.hl, nil)
        end
      end
    else
      cur_vcol = write_char(cur_vcol, ch, hls[byte_pos], nil)
    end
    byte_pos = byte_pos + #ch
  end
  byte_to_vcol[#line] = cur_vcol
  for _, entry in ipairs(inline_after) do
    cur_vcol = write_virt_text(cur_vcol, entry.virt_text, entry.hl_mode, nil)
  end

  local function resolve_vcol(col)
    if byte_to_vcol[col] ~= nil then
      return byte_to_vcol[col]
    end
    for probe = col, 0, -1 do
      if byte_to_vcol[probe] ~= nil then
        return byte_to_vcol[probe]
      end
    end
    return cur_vcol
  end

  -- Pass 2: overlay virtual text (clamped to `width` so full-width code borders and rules do not wrap).
  if rm_info and rm_info.overlay[row] then
    local list = rm_info.overlay[row]
    table.sort(list, function(a, b)
      if a.prio ~= b.prio then
        return a.prio < b.prio
      end
      return a.order < b.order
    end)
    for _, entry in ipairs(list) do
      local target = resolve_vcol(entry.start_col)
      if target > max_vcol then
        fill_gap(max_vcol, target, width)
      end
      write_virt_text(target, entry.virt_text, entry.hl_mode, width)
    end
  end

  -- Pass 3: fixed-column virtual text (such as block-width code background clearing).
  if rm_info and rm_info.win_col[row] then
    local list = rm_info.win_col[row]
    table.sort(list, function(a, b)
      if a.prio ~= b.prio then
        return a.prio < b.prio
      end
      return a.order < b.order
    end)
    for _, entry in ipairs(list) do
      local target = entry.win_col
      if not width or target < width then
        if target > max_vcol then
          fill_gap(max_vcol, target, width)
        end
        local end_vcol = write_virt_text(target, entry.virt_text, entry.hl_mode, width)
        if width and end_vcol >= width then
          eol_hl = nil
        end
      end
    end
  end

  -- Pass 4: end-of-line and right-aligned virtual text.
  if rm_info and rm_info.eol[row] then
    for _, entry in ipairs(rm_info.eol[row]) do
      write_virt_text(max_vcol, entry.virt_text, entry.hl_mode, width)
    end
  end
  if rm_info and rm_info.right_align[row] then
    for _, entry in ipairs(rm_info.right_align[row]) do
      local vt_width = M.chunks_width(entry.virt_text)
      local target = width and math.max(max_vcol, width - vt_width) or max_vcol
      if target > max_vcol then
        fill_gap(max_vcol, target, width)
      end
      write_virt_text(target, entry.virt_text, entry.hl_mode, width)
    end
  end

  if max_vcol == 0 then
    if line == "" then
      return { { "", override_hl or eol_hl } }, eol_hl
    end
    return nil, nil
  end

  local chunks = {}
  local col = 0
  while col < max_vcol do
    local cell = cells[col]
    if type(cell) == "table" then
      append_chunk(chunks, cell.text, cell.hl)
      col = col + cell.width
    elseif cell == nil then
      append_chunk(chunks, " ", override_hl or eol_hl)
      col = col + 1
    else
      col = col + 1
    end
  end
  return chunks, eol_hl
end

--- Render markdown `text` into one array of `[text, hl]` chunks for each visible line using the
--- built-in treesitter parsers, hiding markdown delimiters (`**`, `` ` ``, link URLs, code fences).
---@param text string
---@param opts { tabstop: integer?, hl: string? }? With `hl`, apply `hl` to all text (for resolved threads).
---@return didymus.review.markdown.Chunk[][]
function M.highlight(text, opts)
  opts = opts or {}
  local tabstop = opts.tabstop or 8
  local raw_lines = vim.split(text, "\n")
  local lines = {}
  for index, raw in ipairs(raw_lines) do
    lines[index] = M.expand_tabs((raw:gsub("%s+$", "")), tabstop)
  end

  local source = table.concat(lines, "\n") .. "\n"
  local spans_by_line, conceals_by_line = parse_spans(source, #lines, true)
  local result = {}
  for index, line in ipairs(lines) do
    local chunks =
      composite_line(line, index - 1, spans_by_line[index], conceals_by_line[index], nil, opts)
    if chunks then
      table.insert(result, chunks)
    end
  end
  if #result == 0 then
    return { { { "", opts.hl } } }
  end
  return result
end

--- Split a list of styled characters into alternating space runs and word runs.
---@param chunks didymus.review.markdown.Chunk[]
---@return { is_space: boolean, width: integer, chars: { char: string, width: integer, hl: didymus.review.markdown.Hl? }[] }[]
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
---@param chunks didymus.review.markdown.Chunk[]
---@param width integer
---@return didymus.review.markdown.Chunk[][]
function M.wrap_chunks(chunks, width)
  width = math.max(width, 1)
  local tokens = tokenize_chunks(chunks)
  local lines = {}
  ---@type didymus.review.markdown.Chunk[]
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

--- Pad `chunks` to `width` with spaces highlighted by `eol_hl`.
---@param chunks didymus.review.markdown.Chunk[]
---@param width integer
---@param eol_hl didymus.review.markdown.Hl?
---@return didymus.review.markdown.Chunk[]
local function pad_eol(chunks, width, eol_hl)
  if not eol_hl then
    return chunks
  end
  local used = M.chunks_width(chunks)
  local pad = width - used
  if pad <= 0 then
    return chunks
  end
  local result = {}
  for _, chunk in ipairs(chunks) do
    if chunk[1] ~= "" then
      table.insert(result, chunk)
    end
  end
  append_chunk(result, (" "):rep(pad), eol_hl)
  return result
end

---@class didymus.review.markdown.RenderedLine
---@field chunks didymus.review.markdown.Chunk[]
---@field eol_hl didymus.review.markdown.Hl?

--- Render markdown `text` wrapped to `opts.width`, keeping trailing `eol_hl` separate from
--- `chunks` so callers can pad `virt_lines` or apply inline end-of-line extmarks without adding
--- spaces to buffer text.
---@param text string
---@param opts { tabstop: integer?, hl: string?, width: integer, marks: table[]? }
---@return didymus.review.markdown.RenderedLine[]
function M.render_lines(text, opts)
  local width = math.max(1, opts.width)
  local tabstop = opts.tabstop or 8
  local raw_lines = vim.split(text, "\n")
  local lines = {}
  for index, raw in ipairs(raw_lines) do
    lines[index] = M.expand_tabs((raw:gsub("%s+$", "")), tabstop)
  end

  local marks = opts.marks
  if marks == nil then
    marks = get_render_markdown_marks(lines, width)
  end
  local rm_info = marks and index_marks(marks, lines) or nil

  local source = table.concat(lines, "\n") .. "\n"
  local spans_by_line, conceals_by_line = parse_spans(source, #lines, rm_info == nil)
  ---@type didymus.review.markdown.RenderedLine[]
  local result = {}

  for index, line in ipairs(lines) do
    local row = index - 1
    if rm_info and rm_info.virt_lines_above[row] then
      for _, vline in ipairs(rm_info.virt_lines_above[row]) do
        table.insert(result, {
          chunks = M.truncate_chunks(map_override_hl(vline, opts.hl), width),
          eol_hl = nil,
        })
      end
    end

    if rm_info and rm_info.replace[row] then
      for _, vline in ipairs(rm_info.replace[row]) do
        table.insert(result, {
          chunks = M.truncate_chunks(map_override_hl(vline, opts.hl), width),
          eol_hl = nil,
        })
      end
    elseif not (rm_info and rm_info.hidden[row]) then
      local chunks, eol_hl = composite_line(
        line,
        row,
        spans_by_line[index],
        conceals_by_line[index],
        rm_info,
        { hl = opts.hl, width = width }
      )
      if chunks then
        for _, wrapped in ipairs(M.wrap_chunks(chunks, width)) do
          table.insert(result, { chunks = wrapped, eol_hl = eol_hl })
        end
      end
    end

    if rm_info and rm_info.virt_lines_below[row] then
      for _, vline in ipairs(rm_info.virt_lines_below[row]) do
        table.insert(result, {
          chunks = M.truncate_chunks(map_override_hl(vline, opts.hl), width),
          eol_hl = nil,
        })
      end
    end
  end

  if #result == 0 then
    return { { chunks = { { "", opts.hl } }, eol_hl = nil } }
  end
  return result
end

--- Render markdown `text` wrapped to `opts.width`, combining treesitter highlights with
--- `render-markdown.nvim` marks when installed (or `opts.marks` in tests).
---@param text string
---@param opts { tabstop: integer?, hl: string?, width: integer, marks: table[]? }
---@return didymus.review.markdown.Chunk[][]
function M.render(text, opts)
  local width = math.max(1, opts.width)
  local rows = M.render_lines(text, opts)
  local result = {}
  for _, row in ipairs(rows) do
    table.insert(result, pad_eol(row.chunks, width, row.eol_hl))
  end
  return result
end

return M
