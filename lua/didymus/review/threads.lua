--- The inline threads: a sign at the line of each head thread, and the thread under the line (or
--- above line 1 for outdated, base-side and file-level threads), folded or unfolded in a 4-sided
--- box with markdown treesitter highlights. The marks show only in the windows of the review
--- tabpage. It does not call the provider. See docs/architecture/review.md#inline-threads.

local config = require("didymus.config")
local markdown = require("didymus.review.markdown")

local M = {}

--- The one namespace of the review.
M.namespace = vim.api.nvim_create_namespace("didymus.review")

local function set_highlights()
  vim.api.nvim_set_hl(0, "DidymusThread", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadResolved", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadPending", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadBorder", { link = "DidymusThread", default = true })
end
set_highlights()
-- A color scheme clears the highlight groups.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("didymus.review.threads", {}),
  callback = set_highlights,
})

--- Show the marks only in `wins`. `nvim__ns_set()` is experimental. If a later Neovim does not
--- have it, the marks show in all windows.
---@param wins integer[] Not empty, because an empty list shows the marks in all windows.
function M.scope(wins)
  local set_namespace = vim.api.nvim__ns_set
  if set_namespace then
    set_namespace(M.namespace, { wins = wins })
  end
end

--- The head line where the thread shows in the file: the last line of its range, as on GitHub.
--- Nil if the thread has no head line: outdated, on the base side, or on the file.
---@param thread didymus.review.Thread
---@return integer?
function M.get_line(thread)
  if thread.side == "head" and not thread.outdated and thread.range then
    return thread.range.last
  end
end

--- Tags for a thread that shows above line 1 (outdated, base side, or file level).
---@param thread didymus.review.Thread
---@return [string, string][]
local function get_state_tags(thread)
  local tags = {}
  if thread.outdated then
    table.insert(tags, { " [outdated]", "DiagnosticWarn" })
  end
  if thread.side == "base" then
    table.insert(tags, { " [base]", "DiagnosticWarn" })
  end
  if not thread.range and not thread.outdated then
    table.insert(tags, { " [file]", "Comment" })
  end
  return tags
end

--- The icon of the state, the author, the first line of the first comment, and the pending and
--- outdated tags.
---@param thread didymus.review.Thread
---@param text_hl string? The highlight of the text. A resolved thread is dim.
---@param opts { extra_tags: boolean? }? Include `[base]` and `[file]` tags for inline top-of-file rows.
---@return [string, string?][]
function M.get_summary(thread, text_hl, opts)
  local comment = thread.comments[1]
  local author = comment and comment.author or "ghost"
  local first_line = comment and vim.trim(vim.trim(comment.body):match("^[^\n]*")) or ""
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local icons = config.options.review.icons
  local icon = thread.resolved and icons.resolved or icons.active
  local segments = {}
  if icon ~= "" then
    table.insert(segments, { icon .. " ", dim })
  end
  vim.list_extend(segments, {
    { "@" .. author, dim or "DidymusThread" },
    { " " .. first_line, dim or text_hl },
  })
  -- The first comment is pending until the user submits the review that started the thread.
  if comment and comment.pending then
    table.insert(segments, { " [pending]", dim or "DidymusThreadPending" })
  end
  if thread.outdated then
    table.insert(segments, { " [outdated]", dim or "DiagnosticWarn" })
  end
  if opts and opts.extra_tags then
    if thread.side == "base" then
      table.insert(segments, { " [base]", dim or "DiagnosticWarn" })
    end
    if not thread.range and not thread.outdated then
      table.insert(segments, { " [file]", dim or "Comment" })
    end
  end
  return segments
end

--- Plain header text for the title of a focused inline thread box.
---@param thread didymus.review.Thread
---@return string
function M.get_header_text(thread)
  local comment = thread.comments[1]
  local author = comment and comment.author or "ghost"
  local icons = config.options.review.icons
  local icon = thread.resolved and icons.resolved or icons.active
  local parts = {}
  if icon ~= "" then
    table.insert(parts, icon)
  end
  table.insert(parts, "@" .. author)
  if comment and comment.pending then
    table.insert(parts, "[pending]")
  end
  for _, tag in ipairs(get_state_tags(thread)) do
    table.insert(parts, vim.trim(tag[1]))
  end
  return table.concat(parts, " ")
end

---@param count integer
---@return string
local function get_sign_text(count)
  return count <= 9 and tostring(count) or "9+"
end

--- The text width of the unfolded threads in each buffer, at the last `draw()`. Nil if the buffer
--- has no unfolded thread or inline box, because a folded thread does not wrap.
---@type table<integer, integer>
local drawn_widths = {}

--- Split `text` into lines of `width` display cells or fewer, at the spaces. A word that is longer
--- than a line breaks at the width. An empty text gives one empty line.
---@param text string With no tabs and no newlines.
---@param width integer
---@return string[]
function M.wrap(text, width)
  return vim.tbl_map(function(chunks)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, chunks))
  end, markdown.wrap_chunks({ { text } }, width))
end

--- The keys that the user mapped to each `<Plug>` mapping of didymus, in `buf` or global. A key is
--- in the notation of `keytrans()`, such as `<Space>rr`.
---@param buf integer
---@return table<string, string>
local function get_mapped_keys(buf)
  local keys = {}
  local maps = vim.list_extend(vim.api.nvim_buf_get_keymap(buf, "n"), vim.api.nvim_get_keymap("n"))
  for _, map in ipairs(maps) do
    if map.rhs and vim.startswith(map.rhs, "<Plug>(didymus-") and not keys[map.rhs] then
      keys[map.rhs] = map.lhsraw and vim.fn.keytrans(map.lhsraw) or map.lhs
    end
  end
  return keys
end

--- The keys of the user for the actions on `thread`. Nil if the user mapped no key, or if the line
--- is wider than `width`.
---@param thread didymus.review.Thread
---@param keys table<string, string> From `get_mapped_keys()`.
---@param width integer
---@param dim string? The highlight of a resolved thread.
---@return [string, string?][]?
local function get_keys_chunks(thread, keys, width, dim)
  local actions = {
    { plug = "<Plug>(didymus-review-reply)", name = "reply" },
    {
      plug = "<Plug>(didymus-review-resolve)",
      name = thread.resolved and "unresolve" or "resolve",
    },
    { plug = "<Plug>(didymus-review-fold)", name = "fold" },
    { plug = "<Plug>(didymus-review-focus)", name = "focus" },
  }
  local chunks = {}
  for _, action in ipairs(actions) do
    local key = keys[action.plug]
    if key then
      table.insert(chunks, { (#chunks > 0 and "  " or "") .. key, dim or "DidymusThread" })
      table.insert(chunks, { " " .. action.name, dim or "Comment" })
    end
  end
  if #chunks > 0 and markdown.chunks_width(chunks) <= width then
    return chunks
  end
end

--- Compute box indent, outer width (including borders), and inner text width.
---@param text_width integer
---@param raw_indent integer
---@return integer indent
---@return integer box_width
---@return integer inner_width
local function get_box_geometry(text_width, raw_indent)
  local indent = math.max(0, math.min(raw_indent, text_width - 8))
  local box_width = math.max(6, text_width - indent)
  local inner_width = math.max(1, box_width - 4)
  return indent, box_width, inner_width
end

--- Build a horizontal border rule: `┌─ <chunks> ───┐`, `├─ <chunks> ───┤`, or `└───┘`.
---@param indent_str string
---@param left_char string
---@param right_char string
---@param chunks [string, string?][]?
---@param box_width integer
---@param border_hl string
---@return [string, string?][]
local function make_rule_line(indent_str, left_char, right_char, chunks, box_width, border_hl)
  local line = {}
  if indent_str ~= "" then
    table.insert(line, { indent_str })
  end
  if chunks and #chunks > 0 and box_width >= 6 then
    local max_label = box_width - 5
    local fitted = markdown.truncate_chunks(chunks, max_label)
    local used = markdown.chunks_width(fitted)
    local fill = math.max(0, max_label - used)
    table.insert(line, { left_char .. "─ ", border_hl })
    vim.list_extend(line, fitted)
    table.insert(line, { " " .. ("─"):rep(fill) .. right_char, border_hl })
  else
    table.insert(
      line,
      { left_char .. ("─"):rep(math.max(0, box_width - 2)) .. right_char, border_hl }
    )
  end
  return line
end

--- Build a boxed body line padded to the right border: `│ <chunks>   │`.
---@param indent_str string
---@param chunks didymus.review.markdown.Chunk[]
---@param inner_width integer
---@param border_hl string
---@return didymus.review.markdown.Chunk[]
local function make_body_line(indent_str, chunks, inner_width, border_hl)
  local line = {}
  if indent_str ~= "" then
    table.insert(line, { indent_str })
  end
  table.insert(line, { "│ ", border_hl })
  local fitted = markdown.truncate_chunks(chunks, inner_width)
  vim.list_extend(line, fitted)
  local pad = math.max(0, inner_width - markdown.chunks_width(fitted))
  if pad > 0 then
    table.insert(line, { (" "):rep(pad) })
  end
  table.insert(line, { " │", border_hl })
  return line
end

---@param count integer
---@return [string, string?][][]
local function make_spacer_lines(count)
  local lines = {}
  for _ = 1, count do
    table.insert(lines, { { "" } })
  end
  return lines
end

---@class didymus.review.threads.UnfoldOpts
---@field indent integer
---@field box_width integer
---@field inner_width integer
---@field tabstop integer
---@field keys table<string, string> From `get_mapped_keys()`.
---@field omit_bottom boolean? True when an inline reply box attaches directly below.
---@field include_tags boolean? True for top-of-file threads (`[outdated]`, `[base]`, `[file]`).

--- The `virt_lines` of an unfolded thread: all comments in a 4-sided box, with markdown highlights
--- and the keys of the user in the bottom border.
---@param thread didymus.review.Thread
---@param opts didymus.review.threads.UnfoldOpts
---@return [string, string?][][]
local function get_unfolded_lines(thread, opts)
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local border_hl = dim or "DidymusThreadBorder"
  local icons = config.options.review.icons
  local icon = thread.resolved and icons.resolved or icons.active
  local indent_str = (" "):rep(opts.indent)
  local lines = {}

  for index, comment in ipairs(thread.comments) do
    local header = {}
    if index == 1 and icon ~= "" then
      table.insert(header, { icon .. " ", dim })
    end
    table.insert(header, { "@" .. comment.author, dim or "DidymusThread" })
    if comment.pending then
      table.insert(header, { " [pending]", dim or "DidymusThreadPending" })
    end
    if index == 1 and opts.include_tags then
      for _, tag in ipairs(get_state_tags(thread)) do
        table.insert(header, { tag[1], dim or tag[2] })
      end
    end

    if index == 1 then
      table.insert(
        lines,
        make_rule_line(indent_str, "┌", "┐", header, opts.box_width, border_hl)
      )
    else
      table.insert(
        lines,
        make_rule_line(indent_str, "├", "┤", header, opts.box_width, border_hl)
      )
    end

    -- Keep the indent of the first line, because it can be code.
    local body = comment.body:gsub("^%s*\n", ""):gsub("%s+$", "")
    if body ~= "" then
      local rendered_lines = markdown.render(body, {
        tabstop = opts.tabstop,
        hl = dim,
        width = opts.inner_width,
      })
      for _, rendered_line in ipairs(rendered_lines) do
        table.insert(lines, make_body_line(indent_str, rendered_line, opts.inner_width, border_hl))
      end
    else
      table.insert(lines, make_body_line(indent_str, { { "" } }, opts.inner_width, border_hl))
    end
  end

  if not opts.omit_bottom then
    local keys_max_width = math.max(0, opts.box_width - 5)
    local keys = get_keys_chunks(thread, opts.keys, keys_max_width, dim)
    table.insert(lines, make_rule_line(indent_str, "└", "┘", keys, opts.box_width, border_hl))
  end

  return lines
end

---@class didymus.review.threads.InlineSlot
---@field kind "focus"|"reply"|"comment"
---@field path string
---@field thread_id string?
---@field range didymus.review.Range?
---@field height integer Desired inner height (excluding top and bottom borders).

---@class didymus.review.threads.DrawOpts
---@field width integer The width of the text area. Unfolded threads wrap at it.
---@field is_folded fun(thread: didymus.review.Thread): boolean
---@field inline_slot didymus.review.threads.InlineSlot?

--- Draw the threads of `path` in `buf`. Head-line threads draw under their line with a sign.
--- Outdated, base-side and file-level threads draw above line 1. Returns the anchor of
--- `opts.inline_slot` if it matched in `buf`.
---@param buf integer
---@param path string
---@param threads didymus.review.Thread[]
---@param opts didymus.review.threads.DrawOpts
---@return didymus.review.InlineAnchor?
function M.draw(buf, path, threads, opts)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  drawn_widths[buf] = nil
  local line_count = vim.api.nvim_buf_line_count(buf)
  local slot = opts.inline_slot
  ---@type didymus.review.InlineAnchor?
  local slot_anchor
  ---@type table<string, string>?
  local keys

  -- Pass 1: top-of-file threads (`virt_lines_above` on row 0).
  -- Combine `virt_lines` into one extmark per (row, above), because Neovim's marktree does not
  -- preserve insertion order across separate extmarks at the same (row, col).
  local top_ids = {}
  local top_virt_lines = {}
  local above_offset = 0
  for index, thread in ipairs(threads) do
    if thread.path == path and M.get_line(thread) == nil then
      local indent, box_width, inner_width = get_box_geometry(opts.width, 0)
      local virt_lines
      if slot and slot.kind == "focus" and slot.thread_id == thread.id then
        local outer = slot.height + 2
        slot_anchor = {
          buf = buf,
          row = 0,
          above = true,
          offset = above_offset,
          total_above = 0,
          indent = indent,
          box_width = box_width,
          outer_height = outer,
        }
        virt_lines = make_spacer_lines(outer)
        drawn_widths[buf] = opts.width
      elseif slot and slot.kind == "reply" and slot.thread_id == thread.id then
        keys = keys or get_mapped_keys(buf)
        local thread_lines = get_unfolded_lines(thread, {
          indent = indent,
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
          keys = keys,
          omit_bottom = true,
          include_tags = true,
        })
        local outer = slot.height + 2
        slot_anchor = {
          buf = buf,
          row = 0,
          above = true,
          offset = above_offset + #thread_lines,
          total_above = 0,
          indent = indent,
          box_width = box_width,
          outer_height = outer,
        }
        virt_lines = vim.list_extend(thread_lines, make_spacer_lines(outer))
        drawn_widths[buf] = opts.width
      elseif opts.is_folded(thread) or #thread.comments == 0 then
        virt_lines = { M.get_summary(thread, "DidymusThread", { extra_tags = true }) }
      else
        keys = keys or get_mapped_keys(buf)
        virt_lines = get_unfolded_lines(thread, {
          indent = indent,
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
          keys = keys,
          include_tags = true,
        })
        drawn_widths[buf] = opts.width
      end
      above_offset = above_offset + #virt_lines
      vim.list_extend(top_virt_lines, virt_lines)
      table.insert(top_ids, index)
    end
  end

  if slot_anchor and slot_anchor.above then
    slot_anchor.total_above = above_offset
  end
  for pos, id in ipairs(top_ids) do
    local mark_opts = { id = id }
    if pos == 1 then
      mark_opts.virt_lines = top_virt_lines
      mark_opts.virt_lines_above = true
    end
    vim.api.nvim_buf_set_extmark(buf, M.namespace, 0, 0, mark_opts)
  end

  -- Pass 2: head-line threads under their line, grouped by line for deterministic `virt_lines` order.
  ---@type table<integer, { ids: integer[], virt_lines: [string, string?][][], comment_count: integer, resolved: boolean }>
  local by_line = {}
  local line_order = {}
  for index, thread in ipairs(threads) do
    local line = thread.path == path and M.get_line(thread)
    if line then
      -- The file in the checkout can be shorter than the change head.
      line = math.min(line, line_count)
      local group = by_line[line]
      if not group then
        group = { ids = {}, virt_lines = {}, comment_count = 0, resolved = true }
        by_line[line] = group
        table.insert(line_order, line)
      end
      local raw_indent = vim.api.nvim_buf_call(buf, function()
        return vim.fn.indent(line)
      end)
      local indent, box_width, inner_width = get_box_geometry(opts.width, raw_indent)
      local offset = #group.virt_lines
      local virt_lines
      if slot and slot.kind == "focus" and slot.thread_id == thread.id then
        local outer = slot.height + 2
        slot_anchor = {
          buf = buf,
          row = line - 1,
          above = false,
          offset = offset,
          total_above = 0,
          indent = indent,
          box_width = box_width,
          outer_height = outer,
        }
        virt_lines = make_spacer_lines(outer)
        drawn_widths[buf] = opts.width
      elseif slot and slot.kind == "reply" and slot.thread_id == thread.id then
        keys = keys or get_mapped_keys(buf)
        local thread_lines = get_unfolded_lines(thread, {
          indent = indent,
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
          keys = keys,
          omit_bottom = true,
        })
        local outer = slot.height + 2
        slot_anchor = {
          buf = buf,
          row = line - 1,
          above = false,
          offset = offset + #thread_lines,
          total_above = 0,
          indent = indent,
          box_width = box_width,
          outer_height = outer,
        }
        virt_lines = vim.list_extend(thread_lines, make_spacer_lines(outer))
        drawn_widths[buf] = opts.width
      elseif opts.is_folded(thread) or #thread.comments == 0 then
        local summary = M.get_summary(thread, "DidymusThread")
        table.insert(summary, 1, { (" "):rep(indent) })
        virt_lines = { summary }
      else
        keys = keys or get_mapped_keys(buf)
        virt_lines = get_unfolded_lines(thread, {
          indent = indent,
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
          keys = keys,
        })
        drawn_widths[buf] = opts.width
      end
      vim.list_extend(group.virt_lines, virt_lines)
      table.insert(group.ids, index)
      group.comment_count = group.comment_count + #thread.comments
      if not thread.resolved then
        group.resolved = false
      end
    end
  end

  -- Pass 3: spacer for a new comment box under its target line (appended after existing threads on that line).
  if slot and slot.kind == "comment" and slot.path == path and slot.range then
    local line = math.min(slot.range.last, line_count)
    local raw_indent = vim.api.nvim_buf_call(buf, function()
      return vim.fn.indent(line)
    end)
    local indent, box_width = get_box_geometry(opts.width, raw_indent)
    local group = by_line[line]
    local offset = group and #group.virt_lines or 0
    local outer = slot.height + 2
    slot_anchor = {
      buf = buf,
      row = line - 1,
      above = false,
      offset = offset,
      total_above = 0,
      indent = indent,
      box_width = box_width,
      outer_height = outer,
    }
    drawn_widths[buf] = opts.width
    if group then
      vim.list_extend(group.virt_lines, make_spacer_lines(outer))
    else
      vim.api.nvim_buf_set_extmark(buf, M.namespace, line - 1, 0, {
        id = #threads + 1,
        virt_lines = make_spacer_lines(outer),
      })
    end
  end

  for _, line in ipairs(line_order) do
    local group = by_line[line]
    for pos, id in ipairs(group.ids) do
      local mark_opts = { id = id }
      if pos == 1 then
        mark_opts.sign_text = get_sign_text(group.comment_count)
        mark_opts.sign_hl_group = group.resolved and "DidymusThreadResolved" or "DidymusThread"
        mark_opts.virt_lines = group.virt_lines
      end
      vim.api.nvim_buf_set_extmark(buf, M.namespace, line - 1, 0, mark_opts)
    end
  end

  return slot_anchor
end

--- The text width of the last `draw()` in `buf`. Nil if `buf` has no unfolded thread or inline box.
---@param buf integer
---@return integer?
function M.get_drawn_width(buf)
  return drawn_widths[buf]
end

--- Remove the marks from all buffers.
function M.clear()
  drawn_widths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
    end
  end
end

--- The threads with a mark on the cursor line. The marks move with the text.
---@param threads didymus.review.Thread[] The list that `draw()` used.
---@return didymus.review.Thread[]
function M.at_cursor(threads)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local marks = vim.api.nvim_buf_get_extmarks(0, M.namespace, { row, 0 }, { row, -1 }, {})
  local result = {}
  for _, mark in ipairs(marks) do
    local thread = threads[mark[1]]
    if thread then
      table.insert(result, thread)
    end
  end
  return result
end

--- The path and the line of the thread in messages, such as `file.txt:19`. Only the path if the
--- thread has no line.
---@param thread didymus.review.Thread
---@return string
function M.get_location(thread)
  if thread.range then
    return ("%s:%d"):format(thread.path, thread.range.last)
  end
  return thread.path
end

--- The title of a thread in a split view: path, line, and state tags.
---@param thread didymus.review.Thread
---@return string
function M.get_title(thread)
  local title = M.get_location(thread)
  local tags = {}
  if thread.side == "base" then
    table.insert(tags, "base")
  end
  if thread.resolved then
    table.insert(tags, "resolved")
  end
  if thread.outdated then
    table.insert(tags, "outdated")
  end
  if #tags > 0 then
    title = ("%s (%s)"):format(title, table.concat(tags, ", "))
  end
  return title
end

--- The comments of a thread as markdown lines, for the focused inline view and the split fallback.
---@param thread didymus.review.Thread
---@param opts { include_first_author: boolean? }? Default false because the box border shows the first author.
---@return string[]
function M.get_lines(thread, opts)
  local include_first = opts and opts.include_first_author or false
  local lines = {}
  for index, comment in ipairs(thread.comments) do
    if index > 1 then
      vim.list_extend(lines, { "", "---", "" })
    end
    if index > 1 or include_first then
      local author = ("**@%s**"):format(comment.author)
      table.insert(lines, comment.pending and author .. " *pending*" or author)
      table.insert(lines, "")
    end
    local body = comment.body:gsub("^%s*\n", ""):gsub("%s+$", "")
    vim.list_extend(lines, vim.split(body, "\n"))
  end
  return #lines > 0 and lines or { "" }
end

return M
