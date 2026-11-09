local config = require("didymus.config")
local Session = require("didymus.agent.session")
local prompt = require("didymus.agent.prompt")
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

--- The context of the current buffer. Show an error if the buffer has no file.
---@param range integer[]?
---@return didymus.agent.Context?
local function make_context(range)
  local ok, context = pcall(prompt.context, { buf = vim.api.nvim_get_current_buf(), range = range })
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    -- Leave visual mode as a `:` command does. `:normal!` also sets `'<` and `'>`, so `gv` works.
    vim.cmd.normal({ "\27", bang = true })
  end
  if not ok then
    vim.notify(context, vim.log.levels.ERROR)
    return nil
  end
  return context
end

---@param agent_prompt didymus.agent.Prompt
---@param view didymus.agent.ViewKind?
---@param cmd string|string[]?
local function append_prompt(agent_prompt, view, cmd)
  local kind = resolve_view(view)
  if not kind then
    return
  end
  local session = ensure_running(cmd, kind)
  if session then
    session:append(agent_prompt)
    session:show(kind)
  end
end

--- Put the current line, the selection or `range` in the agent input. Then show and focus the
--- agent. The user types the rest of the prompt in the agent.
---@param opts { range: integer[]?, view: didymus.agent.ViewKind?, cmd: string|string[]? }?
function M.append(opts)
  opts = opts or {}
  local context = make_context(opts.range)
  if context then
    append_prompt({ context = { context } }, opts.view, opts.cmd)
  end
end

---@param context didymus.agent.Context
---@param text string
---@param cmd string|string[]?
local function submit(context, text, cmd)
  -- The agent stays hidden, but the view sets the size of a new agent.
  local view = resolve_view(nil)
  if not view then
    return
  end
  local session = ensure_running(cmd, view)
  if session then
    session:send({ text = text, context = { context } })
    vim.notify(("didymus: sent to `%s`"):format(Session.format_cmd(session.cmd)))
  end
end

--- Send a prompt about the current line, the selection or `range`. With no `text`, open the
--- input float. The agent does not show. The append key of the float appends the prompt instead.
---@param opts { text: string?, range: integer[]?, cmd: string|string[]? }?
function M.send(opts)
  opts = opts or {}
  local context = make_context(opts.range)
  if not context then
    return
  end
  if opts.text then
    submit(context, opts.text, opts.cmd)
    return
  end
  local input = config.options.agent.input
  require("didymus.ui.input").open({
    title = prompt.location(context),
    range = { context.start_line, context.end_line },
    width = input.width,
    max_height = input.max_height,
    keys = { cancel = input.keys.cancel },
    actions = {
      {
        key = input.keys.send,
        name = "send",
        on_submit = function(text)
          submit(context, text, opts.cmd)
        end,
      },
      {
        key = input.keys.append,
        name = "append",
        on_submit = function(text)
          append_prompt({ text = text, context = { context } }, nil, opts.cmd)
        end,
      },
    },
  })
end

--- Stop the agent and close its view.
function M.stop()
  if standalone then
    standalone:stop()
    standalone = nil
  end
end

return M
