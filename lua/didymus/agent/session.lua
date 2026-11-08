local View = require("didymus.agent.view")

---@class didymus.agent.BackendOpts
---@field cmd string|string[] A string runs through 'shell'.
---@field cwd string
---@field width integer The size before a view shows the buffer.
---@field height integer
---@field on_exit fun(code: integer)

--- A backend module returns `{ new = fun(opts: didymus.agent.BackendOpts): didymus.agent.Backend }`.
--- `new()` throws an error if the agent cannot start.
---@class didymus.agent.Backend
---@field append fun(self, prompt: didymus.agent.Prompt) Put the prompt in the agent input.
---@field send fun(self, prompt: didymus.agent.Prompt) Put the prompt in the agent input and submit it.
---@field buf fun(self): integer? The buffer for the view. Nil means no view.
---@field focus? fun(self, win: integer) Called after the view focuses `win`.
---@field is_running fun(self): boolean
---@field stop fun(self) Stop the agent and delete the buffer.

local backends = {
  terminal = "didymus.agent.backends.terminal",
}

---@class didymus.agent.Session
---@field cmd string|string[]
---@field cwd string
---@field private backend_name string
---@field private backend didymus.agent.Backend?
---@field private view didymus.agent.View
local Session = {}
Session.__index = Session

---@param cmd string|string[]
---@return string
function Session.format_cmd(cmd)
  return type(cmd) == "table" and table.concat(cmd, " ") or cmd --[[@as string]]
end

--- Start the backend.
---@param opts { cmd: string|string[], cwd: string, backend: string }
---@return didymus.agent.Session
function Session.new(opts)
  local self = setmetatable({ backend_name = opts.backend, view = View.new() }, Session)
  self:restart(opts)
  return self
end

--- Start a new backend. Delete the buffer of the old backend.
---@param opts { cmd: string|string[], cwd: string }
function Session:restart(opts)
  local width, height = View.size("split")
  local backend
  backend = require(backends[self.backend_name]).new({
    cmd = opts.cmd,
    cwd = opts.cwd,
    width = width,
    height = height,
    on_exit = function(code)
      -- Ignore the exit of a backend that stop() or restart() replaced.
      if self.backend ~= backend then
        return
      end
      local level = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
      vim.notify(
        ("didymus: `%s` exited with code %d"):format(Session.format_cmd(self.cmd), code),
        level
      )
    end,
  })
  local old = self.backend
  self.backend, self.cmd, self.cwd = backend, opts.cmd, opts.cwd
  if old then
    old:stop()
  end
end

--- Show the backend buffer in the view, and focus it.
---@param kind didymus.agent.ViewKind
function Session:show(kind)
  local buf = self.backend and self.backend:buf()
  if not buf then
    return
  end
  local win = self.view:show(buf, kind)
  if self.backend.focus then
    self.backend:focus(win)
  end
end

function Session:hide()
  self.view:hide()
end

---@return boolean
function Session:is_visible()
  return self.view:is_visible()
end

---@return boolean
function Session:is_running()
  return self.backend ~= nil and self.backend:is_running()
end

---@param prompt didymus.agent.Prompt
function Session:append(prompt)
  if self.backend then
    self.backend:append(prompt)
  end
end

---@param prompt didymus.agent.Prompt
function Session:send(prompt)
  if self.backend then
    self.backend:send(prompt)
  end
end

--- Hide the view and stop the backend.
function Session:stop()
  self.view:hide()
  local backend = self.backend
  self.backend = nil
  if backend then
    backend:stop()
  end
end

return Session
