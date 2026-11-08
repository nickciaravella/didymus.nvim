--- A backend without a process, for tests.

local prompt_text = require("didymus.agent.prompt")

---@alias didymus.agent.backends.test.Kind "append"|"send"

---@class didymus.agent.backends.test.Entry
---@field kind didymus.agent.backends.test.Kind
---@field prompt didymus.agent.Prompt

---@class didymus.agent.backends.Test: didymus.agent.Backend
---@field prompts didymus.agent.backends.test.Entry[]
---@field private bufnr integer
---@field private running boolean
---@field private on_exit fun(code: integer)?
local Test = {}
Test.__index = Test

local M = {}

---@param opts didymus.agent.BackendOpts
---@return didymus.agent.Backend
function M.new(opts)
  return setmetatable({
    prompts = {},
    bufnr = vim.api.nvim_create_buf(false, true),
    running = true,
    on_exit = opts.on_exit,
  }, Test)
end

---@param kind didymus.agent.backends.test.Kind
---@param prompt didymus.agent.Prompt
function Test:add(kind, prompt)
  table.insert(self.prompts, { kind = kind, prompt = prompt })
  local lines = { kind .. ":" }
  vim.list_extend(lines, vim.split(prompt_text.to_text(prompt), "\n", { trimempty = true }))
  -- The first prompt replaces the empty line of the new buffer.
  local start = #self.prompts == 1 and 0 or -1
  vim.api.nvim_buf_set_lines(self.bufnr, start, -1, true, lines)
end

---@param prompt didymus.agent.Prompt
function Test:append(prompt)
  self:add("append", prompt)
end

---@param prompt didymus.agent.Prompt
function Test:send(prompt)
  self:add("send", prompt)
end

---@return integer
function Test:buf()
  return self.bufnr
end

---@return boolean
function Test:is_running()
  return self.running
end

--- Act as if the agent exited with `code`. The buffer stays.
---@param code integer
function Test:exit(code)
  local on_exit = self.on_exit
  self.running, self.on_exit = false, nil
  -- A backend calls on_exit one time.
  if on_exit then
    on_exit(code)
  end
end

--- Delete the buffer.
function Test:stop()
  self:exit(0)
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
end

return M
