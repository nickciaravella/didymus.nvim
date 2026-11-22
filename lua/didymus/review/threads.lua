--- The inline threads: a sign at the line of each head thread, and the thread under the line (or
--- above line 1 for outdated, base-side and file-level threads), folded or unfolded in a 4-sided
--- box with markdown highlights and a subtle background. The marks show only in the windows of the
--- review tabpage. It does not call the provider. See docs/architecture/review.md#inline-threads.

local config = require("didymus.config")
local markdown = require("didymus.review.markdown")

local M = {}

--- The one namespace of the review.
M.namespace = vim.api.nvim_create_namespace("didymus.review")

--- Shift an RGB color slightly darker by `delta` per channel (or slightly lighter if near black).
---@param color integer
---@param delta integer
---@return integer
local function shade_bg(color, delta)
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  if math.max(r, g, b) < 10 then
    r = math.min(255, r + delta + 1)
    g = math.min(255, g + delta + 1)
    b = math.min(255, b + delta + 1)
  else
    r = math.max(0, r - delta)
    g = math.max(0, g - delta)
    b = math.max(0, b - delta)
  end
  return r * 65536 + g * 256 + b
end

local function set_highlights()
  vim.api.nvim_set_hl(0, "DidymusThread", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadResolved", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadPending", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadTime", { link = "Comment", default = true })

  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local thread_hl = vim.api.nvim_get_hl(0, { name = "DidymusThread", link = false })
  local resolved_hl = vim.api.nvim_get_hl(0, { name = "DidymusThreadResolved", link = false })
  local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local card_bg = normal.bg
      and (vim.o.background == "light" and "#fbf1c7" or shade_bg(normal.bg, 7))
    or nil

  vim.api.nvim_set_hl(0, "DidymusThreadBg", { bg = card_bg, default = true })
  vim.api.nvim_set_hl(0, "DidymusThreadAuthor", { fg = thread_hl.fg, bold = true, default = true })
  vim.api.nvim_set_hl(
    0,
    "DidymusThreadResolvedAuthor",
    { fg = resolved_hl.fg, bold = true, default = true }
  )
  if card_bg then
    vim.api.nvim_set_hl(
      0,
      "DidymusThreadBorder",
      { fg = thread_hl.fg, bg = card_bg, default = true }
    )
    vim.api.nvim_set_hl(
      0,
      "DidymusThreadResolvedBorder",
      { fg = resolved_hl.fg, bg = card_bg, default = true }
    )
    vim.api.nvim_set_hl(
      0,
      "DidymusThreadTitle",
      { fg = thread_hl.fg, bg = card_bg, default = true }
    )
    vim.api.nvim_set_hl(
      0,
      "DidymusThreadFooter",
      { fg = comment_hl.fg, bg = card_bg, default = true }
    )
  else
    vim.api.nvim_set_hl(0, "DidymusThreadBorder", { link = "DidymusThread", default = true })
    vim.api.nvim_set_hl(
      0,
      "DidymusThreadResolvedBorder",
      { link = "DidymusThreadResolved", default = true }
    )
    vim.api.nvim_set_hl(0, "DidymusThreadTitle", { link = "DidymusThread", default = true })
    vim.api.nvim_set_hl(0, "DidymusThreadFooter", { link = "Comment", default = true })
  end
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

--- Format an ISO-8601 timestamp (such as `"2026-11-21T14:30:00Z"`) as local `"YYYY-MM-DD HH:MM"`.
--- Returns nil if `iso` is nil or does not match an ISO-8601 date-time.
---@param iso string?
---@return string?
function M.format_time(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, m, d, hour, min, sec, tz =
    iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
  if not y then
    return nil
  end
  local ts = os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  })
  if not ts then
    return nil
  end
  local tz_offset = 0
  local sign, tzh, tzm = tz:match("^([+-])(%d%d):?(%d%d)")
  if sign then
    tz_offset = (tonumber(tzh) * 3600 + tonumber(tzm) * 60) * (sign == "+" and 1 or -1)
  end
  if tz:sub(1, 1) == "Z" or sign then
    local now = os.time()
    local utc_now = os.date("!*t", now)
    utc_now.isdst = false
    local local_offset = os.difftime(now, os.time(utc_now))
    ts = ts - tz_offset + local_offset
  end
  return os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
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

--- Styled header chunks for one comment: optional status emoji (first comment), bold author,
--- state tags, and lighter local date/time.
---@param thread didymus.review.Thread
---@param comment didymus.review.Comment
---@param index integer 1-based comment index.
---@param include_tags boolean? Include `[outdated]`, `[base]`, `[file]` on the first comment.
---@return [string, string?][]
local function get_comment_header_chunks(thread, comment, index, include_tags)
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local icons = config.options.review.icons
  local icon = thread.resolved and icons.resolved or icons.active
  local chunks = {}
  if index == 1 and icon ~= "" then
    table.insert(chunks, { icon .. " ", dim })
  end
  table.insert(chunks, {
    "@" .. comment.author,
    thread.resolved and "DidymusThreadResolvedAuthor" or "DidymusThreadAuthor",
  })
  if comment.pending then
    table.insert(chunks, { " [pending]", dim or "DidymusThreadPending" })
  end
  if index == 1 and include_tags then
    for _, tag in ipairs(get_state_tags(thread)) do
      table.insert(chunks, { tag[1], dim or tag[2] })
    end
  end
  local formatted_time = M.format_time(comment.created_at)
  if formatted_time then
    table.insert(chunks, { "  " .. formatted_time, "DidymusThreadTime" })
  end
  return chunks
end

--- Plain header text for the title of a split view or summary.
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

--- Stack `DidymusThreadBg` underneath `hl` so every cell in a thread card has the subtle card
--- background while higher-priority highlights (such as code blocks) stay on top.
---@param hl didymus.review.markdown.Hl?
---@return didymus.review.markdown.Hl
local function with_card_bg(hl)
  if not hl then
    return "DidymusThreadBg"
  end
  if type(hl) == "string" then
    return { "DidymusThreadBg", hl }
  end
  local combined = { "DidymusThreadBg" }
  vim.list_extend(combined, hl)
  return combined
end

--- Compute box indent (always 0 so boxes extend left to the line numbers), outer width (including
--- borders), and inner text width.
---@param text_width integer
---@return integer indent
---@return integer box_width
---@return integer inner_width
local function get_box_geometry(text_width)
  local box_width = math.max(6, text_width)
  local inner_width = math.max(1, box_width - 4)
  return 0, box_width, inner_width
end

--- Build a smooth horizontal border rule: `┌───┐`, `├───┤`, or `└───┘`.
---@param left_char string
---@param right_char string
---@param box_width integer
---@param border_hl string
---@return didymus.review.markdown.Chunk[]
local function make_rule_line(left_char, right_char, box_width, border_hl)
  return {
    {
      left_char .. ("─"):rep(math.max(0, box_width - 2)) .. right_char,
      with_card_bg(border_hl),
    },
  }
end

--- Build a boxed body line padded to the right border: `│ <chunks>   │`.
---@param chunks didymus.review.markdown.Chunk[]
---@param inner_width integer
---@param border_hl string
---@param eol_hl didymus.review.markdown.Hl?
---@return didymus.review.markdown.Chunk[]
local function make_body_line(chunks, inner_width, border_hl, eol_hl)
  local line = { { "│ ", with_card_bg(border_hl) } }
  local fitted = markdown.truncate_chunks(chunks, inner_width)
  for _, chunk in ipairs(fitted) do
    if chunk[1] ~= "" then
      table.insert(line, { chunk[1], with_card_bg(chunk[2]) })
    end
  end
  local pad = math.max(0, inner_width - markdown.chunks_width(fitted))
  if pad > 0 then
    table.insert(line, { (" "):rep(pad), with_card_bg(eol_hl) })
  end
  table.insert(line, { " │", with_card_bg(border_hl) })
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

---@class didymus.review.RenderedRow
---@field kind "content"|"divider"
---@field chunks didymus.review.markdown.Chunk[]?
---@field eol_hl didymus.review.markdown.Hl?
---@field hl string?

---@class didymus.review.threads.RenderOpts
---@field box_width integer
---@field tabstop integer
---@field include_tags boolean? True for top-of-file threads (`[outdated]`, `[base]`, `[file]`).

--- Single shared renderer for both unfocused `virt_lines` and focused read-only floats (Path B).
--- Produces inner content rows (header, blank separator line, rendered markdown body) and divider
--- rows between replies, so unfocused and focused views match cell-for-cell.
---@param thread didymus.review.Thread
---@param opts didymus.review.threads.RenderOpts
---@return didymus.review.RenderedRow[]
function M.render_thread_rows(thread, opts)
  local dim = thread.resolved and "DidymusThreadResolved" or nil
  local border_hl = thread.resolved and "DidymusThreadResolvedBorder" or "DidymusThreadBorder"
  local inner_width = math.max(1, opts.box_width - 4)
  ---@type didymus.review.RenderedRow[]
  local rows = {}

  for index, comment in ipairs(thread.comments) do
    if index > 1 then
      table.insert(rows, { kind = "divider", hl = border_hl })
    end

    local header = get_comment_header_chunks(thread, comment, index, opts.include_tags)
    table.insert(rows, { kind = "content", chunks = markdown.truncate_chunks(header, inner_width) })
    table.insert(rows, { kind = "content", chunks = { { "" } } })

    -- Keep the indent of the first line, because it can be code.
    local body = comment.body:gsub("^%s*\n", ""):gsub("%s+$", "")
    if body ~= "" then
      local rendered_lines = markdown.render_lines(body, {
        tabstop = opts.tabstop,
        hl = dim,
        width = inner_width,
      })
      for _, rendered_line in ipairs(rendered_lines) do
        table.insert(rows, {
          kind = "content",
          chunks = markdown.truncate_chunks(rendered_line.chunks, inner_width),
          eol_hl = rendered_line.eol_hl,
        })
      end
    else
      table.insert(rows, { kind = "content", chunks = { { "" } } })
    end
  end

  if #rows == 0 then
    table.insert(rows, { kind = "content", chunks = { { "" } } })
  end
  return rows
end

---@class didymus.review.threads.UnfoldOpts
---@field box_width integer
---@field inner_width integer
---@field tabstop integer
---@field omit_bottom boolean? True when an inline reply box attaches directly below.
---@field include_tags boolean? True for top-of-file threads (`[outdated]`, `[base]`, `[file]`).

--- The `virt_lines` of an unfolded thread: smooth 4-sided box wrapping `M.render_thread_rows()`.
---@param thread didymus.review.Thread
---@param opts didymus.review.threads.UnfoldOpts
---@return didymus.review.markdown.Chunk[][]
local function get_unfolded_lines(thread, opts)
  local border_hl = thread.resolved and "DidymusThreadResolvedBorder" or "DidymusThreadBorder"
  local lines = {}

  table.insert(lines, make_rule_line("┌", "┐", opts.box_width, border_hl))

  for _, row in ipairs(M.render_thread_rows(thread, opts)) do
    if row.kind == "divider" then
      table.insert(lines, make_rule_line("├", "┤", opts.box_width, row.hl or border_hl))
    else
      table.insert(
        lines,
        make_body_line(row.chunks or { { "" } }, opts.inner_width, border_hl, row.eol_hl)
      )
    end
  end

  if not opts.omit_bottom then
    table.insert(lines, make_rule_line("└", "┘", opts.box_width, border_hl))
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

  -- Pass 1: top-of-file threads (`virt_lines_above` on row 0).
  -- Combine `virt_lines` into one extmark per (row, above), because Neovim's marktree does not
  -- preserve insertion order across separate extmarks at the same (row, col).
  local top_ids = {}
  local top_virt_lines = {}
  local above_offset = 0
  for index, thread in ipairs(threads) do
    if thread.path == path and M.get_line(thread) == nil then
      local indent, box_width, inner_width = get_box_geometry(opts.width)
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
        local thread_lines = get_unfolded_lines(thread, {
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
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
        virt_lines = get_unfolded_lines(thread, {
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
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
      mark_opts.virt_lines_leftcol = true
    end
    vim.api.nvim_buf_set_extmark(buf, M.namespace, 0, 0, mark_opts)
  end

  -- Pass 2: head-line threads under their line, grouped by line for deterministic `virt_lines` order.
  ---@type table<integer, { ids: integer[], virt_lines: didymus.review.markdown.Chunk[][], comment_count: integer, resolved: boolean }>
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
      local indent, box_width, inner_width = get_box_geometry(opts.width)
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
        local thread_lines = get_unfolded_lines(thread, {
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
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
        virt_lines = { M.get_summary(thread, "DidymusThread") }
      else
        virt_lines = get_unfolded_lines(thread, {
          box_width = box_width,
          inner_width = inner_width,
          tabstop = vim.bo[buf].tabstop,
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
    local indent, box_width = get_box_geometry(opts.width)
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
        virt_lines_leftcol = true,
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
        mark_opts.virt_lines_leftcol = true
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

---@class didymus.review.CommentDivider
---@field row integer 0-based line in the focused buffer.
---@field resolved boolean

---@class didymus.review.CommentHeader
---@field row integer 0-based line in the focused buffer.
---@field chunks [string, string?][]

--- The comments of a thread as lines for the focused inline view and the split fallback, with
--- styled header metadata (status emoji, bold author, tags, lighter datetime) and smooth
--- single-line `***` dividers between replies so focusing keeps the exact layout and height of the
--- unfocused thread box.
---@param thread didymus.review.Thread
---@param opts { include_tags: boolean? }? Include `[outdated]`, `[base]`, `[file]` on the first comment.
---@return string[] lines
---@return didymus.review.CommentDivider[] dividers
---@return didymus.review.CommentHeader[] headers
function M.get_lines(thread, opts)
  local include_tags = opts and opts.include_tags or false
  local lines = {}
  ---@type didymus.review.CommentDivider[]
  local dividers = {}
  ---@type didymus.review.CommentHeader[]
  local headers = {}
  for index, comment in ipairs(thread.comments) do
    if index > 1 then
      -- `***` is always a thematic break in CommonMark (never a Setext heading underline), so it
      -- isolates adjacent comments in one line without extra blank lines.
      table.insert(lines, "***")
      table.insert(dividers, {
        row = #lines - 1,
        resolved = thread.resolved,
      })
    end
    local header_chunks = get_comment_header_chunks(thread, comment, index, include_tags)
    local header_parts = {}
    for _, chunk in ipairs(header_chunks) do
      table.insert(header_parts, chunk[1])
    end
    table.insert(lines, table.concat(header_parts))
    table.insert(headers, {
      row = #lines - 1,
      chunks = header_chunks,
    })
    table.insert(lines, "")
    local body = comment.body:gsub("^%s*\n", ""):gsub("%s+$", "")
    vim.list_extend(lines, vim.split(body, "\n"))
  end
  return #lines > 0 and lines or { "" }, dividers, headers
end

return M
