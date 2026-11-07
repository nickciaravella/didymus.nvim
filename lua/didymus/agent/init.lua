local config = require("didymus.config")
local Session = require("didymus.agent.session")

local M = {}

---@type didymus.agent.Session?
local standalone

---@return didymus.agent.Session?
function M.current()
  return standalone
end

--- Start a session if no session runs.
---@param cmd string|string[]? Nil uses `agent.cmd`.
---@return didymus.agent.Session? session Nil if the start failed.
---@return boolean started
local function ensure_running(cmd)
  local session = M.current()
  if session and session:is_running() then
    if cmd and not vim.deep_equal(cmd, session.cmd) then
      vim.notify(
        ("didymus: `%s` runs. To start `%s`, stop the agent first."):format(
          Session.format_cmd(session.cmd),
          Session.format_cmd(cmd)
        ),
        vim.log.levels.WARN
      )
    end
    return session, false
  end

  local opts =
    { cmd = cmd or config.options.agent.cmd, cwd = vim.fn.getcwd(), backend = "terminal" }
  local ok, err = pcall(function()
    if session then
      session:restart(opts)
    else
      standalone = Session.new(opts)
    end
  end)
  if not ok then
    vim.notify(
      ("didymus: cannot start `%s`: %s"):format(Session.format_cmd(opts.cmd), err),
      vim.log.levels.ERROR
    )
    return nil, false
  end
  if session then
    vim.notify(("didymus: new conversation with `%s`"):format(Session.format_cmd(opts.cmd)))
  end
  return standalone, true
end

--- Start the agent if it does not run. Do not show it.
---@param opts { cmd: string|string[]? }?
function M.start(opts)
  opts = opts or {}
  local restart = standalone ~= nil
  local session, started = ensure_running(opts.cmd)
  if session and started and not restart then
    vim.notify(("didymus: started `%s`"):format(Session.format_cmd(session.cmd)))
  end
end

--- Hide the agent if it is visible. If not, start it if necessary, then show and focus it.
---@param opts { cmd: string|string[]?, view: didymus.agent.ViewKind? }?
function M.toggle(opts)
  opts = opts or {}
  if standalone and standalone:is_visible() then
    standalone:hide()
    return
  end
  local session = ensure_running(opts.cmd)
  if session then
    session:show(opts.view or "split")
  end
end

--- Stop the agent and close its view.
function M.stop()
  if standalone then
    standalone:stop()
    standalone = nil
  end
end

return M
