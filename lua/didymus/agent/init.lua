local config = require("didymus.config")
local Session = require("didymus.agent.session")
local View = require("didymus.agent.view")

local M = {}

---@type didymus.agent.Session?
local standalone

---@return didymus.agent.Session?
function M.current()
  return standalone
end

--- The view kind of `opts`, else the last view of the session, else `agent.view`.
---@param view didymus.agent.ViewKind?
---@return didymus.agent.ViewKind? kind Nil if the kind is not valid.
local function resolve_view(view)
  local kind = view or (standalone and standalone:view_kind()) or config.options.agent.view
  if not View.kinds[kind] then
    vim.notify(
      ('didymus: unknown view %q. Use "float" or "split".'):format(tostring(kind)),
      vim.log.levels.ERROR
    )
    return nil
  end
  return kind
end

--- Start a session if no session runs.
---@param cmd string|string[]? Nil uses `agent.cmd`.
---@param view didymus.agent.ViewKind The view that will show the agent. It sets the size.
---@return didymus.agent.Session? session Nil if the start failed.
---@return boolean started
local function ensure_running(cmd, view)
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

  local opts = {
    cmd = cmd or config.options.agent.cmd,
    cwd = vim.fn.getcwd(),
    backend = config.options.agent.backend,
    view = view,
  }
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
  local view = resolve_view(nil)
  if not view then
    return
  end
  local restart = standalone ~= nil
  local session, started = ensure_running(opts.cmd, view)
  if session and started and not restart then
    vim.notify(("didymus: started `%s`"):format(Session.format_cmd(session.cmd)))
  end
end

--- Start the agent if necessary, then show and focus it. If the other view is visible, it closes.
---@param opts { cmd: string|string[]?, view: didymus.agent.ViewKind? }?
function M.focus(opts)
  opts = opts or {}
  local view = resolve_view(opts.view)
  if not view then
    return
  end
  local session = ensure_running(opts.cmd, view)
  if session then
    session:show(view)
  end
end

--- Hide the agent if it is visible. If not, do as `focus()`.
--- With `view`, hide or show that view.
---@param opts { cmd: string|string[]?, view: didymus.agent.ViewKind? }?
function M.toggle(opts)
  opts = opts or {}
  if standalone and standalone:is_visible(opts.view) then
    standalone:hide()
    return
  end
  M.focus(opts)
end

--- Stop the agent and close its view.
function M.stop()
  if standalone then
    standalone:stop()
    standalone = nil
  end
end

return M
