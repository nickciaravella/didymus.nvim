--- An agent CLI in a terminal buffer.

local config = require("didymus.config")
local prompt_text = require("didymus.agent.prompt")

local paste_start, paste_end = "\27[200~", "\27[201~"

---@alias didymus.agent.backends.terminal.Step { write: string }|{ wait: integer }

---@class didymus.agent.backends.Terminal: didymus.agent.Backend
---@field private bufnr integer
---@field private job integer?
---@field private seen_output boolean
---@field private ready boolean
---@field private queue didymus.agent.backends.terminal.Step[]
---@field private timer uv.uv_timer_t? The ready delay or a submit delay.
local Terminal = {}
Terminal.__index = Terminal

local M = {}

---@param opts didymus.agent.BackendOpts
---@return didymus.agent.Backend
function M.new(opts)
  local self = setmetatable({ seen_output = false, ready = false, queue = {} }, Terminal)
  local buf = vim.api.nvim_create_buf(false, true)
  -- nvim_buf_call() lets the job start with no window, so that a hidden start is possible.
  local ok, job = pcall(vim.api.nvim_buf_call, buf, function()
    return vim.fn.jobstart(opts.cmd, {
      term = true,
      cwd = opts.cwd,
      width = opts.width,
      height = opts.height,
      on_stdout = function()
        self:on_output()
      end,
      on_exit = function(_, code)
        self.job = nil
        self:drop_input()
        -- In terminal mode, the next key after the exit deletes the buffer. Keep it for the user.
        if vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_mode().mode == "t" then
          -- The mode change clears the message area, so call on_exit after it.
          vim.api.nvim_create_autocmd("ModeChanged", {
            pattern = "t:*",
            once = true,
            callback = function()
              vim.schedule(function()
                opts.on_exit(code)
              end)
            end,
          })
          vim.cmd.stopinsert()
        else
          opts.on_exit(code)
        end
      end,
    })
  end)
  if not ok or job <= 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(ok and "the program is not executable" or job, 0)
  end
  self.bufnr, self.job = buf, job
  return self
end

--- The agent cannot read input before it starts its UI. The first output tells that it started.
function Terminal:on_output()
  if self.seen_output then
    return
  end
  self.seen_output = true
  self:wait(config.options.agent.terminal.ready_delay, function()
    self.ready = true
  end)
end

---@param ms integer
---@param cb fun()
function Terminal:wait(ms, cb)
  self.timer = vim.defer_fn(function()
    self.timer = nil
    cb()
    self:write_queue()
  end, ms)
end

--- Write the queue in order. Stop at a wait, so that the next prompt comes after the submit.
function Terminal:write_queue()
  while self.ready and self.job and not self.timer and #self.queue > 0 do
    local step = table.remove(self.queue, 1)
    if step.write then
      vim.fn.chansend(self.job, step.write)
    else
      self:wait(step.wait, function() end)
    end
  end
end

---@param steps didymus.agent.backends.terminal.Step[]
function Terminal:add_to_queue(steps)
  vim.list_extend(self.queue, steps)
  self:write_queue()
end

function Terminal:drop_input()
  self.queue = {}
  if self.timer then
    self.timer:close()
    self.timer = nil
  end
end

--- Without bracketed paste, each newline submits.
---@param prompt didymus.agent.Prompt
---@return string
local function make_paste(prompt)
  -- An end marker in the text ends the paste too early.
  local text = prompt_text.to_text(prompt):gsub(vim.pesc(paste_end), "")
  return paste_start .. text .. paste_end
end

---@param prompt didymus.agent.Prompt
function Terminal:append(prompt)
  self:add_to_queue({ { write = make_paste(prompt) } })
end

---@param prompt didymus.agent.Prompt
function Terminal:send(prompt)
  -- Some TUIs ignore an Enter that comes in the same write as the paste.
  self:add_to_queue({
    { write = make_paste(prompt) },
    { wait = config.options.agent.terminal.submit_delay },
    { write = "\r" },
  })
end

---@return integer
function Terminal:buf()
  return self.bufnr
end

function Terminal:focus()
  vim.cmd.startinsert()
end

---@return boolean
function Terminal:is_running()
  return self.job ~= nil
end

--- Stop the job and delete the buffer.
function Terminal:stop()
  self:drop_input()
  if self.job then
    vim.fn.jobstop(self.job)
    self.job = nil
  end
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
end

return M
