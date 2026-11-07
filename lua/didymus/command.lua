local M = {}

local views = { split = {} }

local tree = {
  agent = { start = {}, toggle = views, stop = {} },
}

---@param text string
---@return string? word
---@return string rest
local function split_word(text)
  local word, rest = text:match("^%s*(%S+)%s*(.-)%s*$")
  return word, rest or ""
end

---@param text string
---@return string?
local function non_empty(text)
  return text ~= "" and text or nil
end

local agent_actions = {
  start = function(rest)
    require("didymus.agent").start({ cmd = non_empty(rest) })
  end,
  toggle = function(rest)
    local word, after = split_word(rest)
    local view
    if views[word] then
      view, rest = word, after
    end
    require("didymus.agent").toggle({ view = view, cmd = non_empty(rest) })
  end,
  stop = function()
    require("didymus.agent").stop()
  end,
}

---@param args string
function M.run(args)
  local group, rest = split_word(args)
  local action
  action, rest = split_word(rest)
  if group ~= "agent" or not agent_actions[action] then
    vim.notify(
      "didymus: unknown command. Use :Didymus agent start, toggle or stop.",
      vim.log.levels.ERROR
    )
    return
  end
  agent_actions[action](rest)
end

---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  local words = vim.split(cmdline:sub(1, cursorpos), "%s+", { trimempty = true })
  if arglead ~= "" then
    table.remove(words)
  end
  -- The first word is the command name.
  local node = tree
  for i = 2, #words do
    node = node[words[i]]
    if not node then
      return {}
    end
  end
  local items = vim.tbl_keys(node)
  table.sort(items)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arglead)
  end, items)
end

return M
