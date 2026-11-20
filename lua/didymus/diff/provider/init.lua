--- The diff provider interface. A provider connects the diff view to a diff tool, such as gitsigns.
--- The types of the target, the hunks and the display are in `didymus.diff.target`.
--- See docs/architecture/diff.md#interfaces.

---@class didymus.diff.Capabilities
---@field layouts table<didymus.diff.Layout, boolean>
---@field sides table<didymus.diff.Sides, boolean>
---@field bases table<didymus.diff.RevisionKind, boolean> The base revisions that `attach` accepts.
---@field heads table<didymus.diff.RevisionKind, boolean> The head revisions that `attach` accepts.

--- All async methods take a final `cb(err)` and do not block the UI.
--- Rules:
--- 1. Do not open, close or focus windows. The diff view owns them.
--- 2. Decorate only the windows and buffers that `render()` gets. Scope window marks with
---    `nvim__ns_set()`.
--- 3. Buffer state, such as the gitsigns base, is permitted. `detach()` puts it back.
--- 4. Call each `cb` in the main loop, one time.
--- 5. Do not decide which lines are commentable.
---@class didymus.diff.Provider
---@field capabilities didymus.diff.Capabilities
---@field attach fun(self, buf: integer, file: didymus.diff.File, target: didymus.diff.Target, cb: fun(err: string?)) Compute the hunks of the head buffer against the base. Call `cb` when `hunks()` has them.
---@field detach fun(self, buf: integer) Remove the diff state of the buffer. Put back the state from before `attach`.
---@field hunks fun(self, buf: integer): didymus.diff.Hunk[]? Nil before `attach` calls its `cb`.
---@field render fun(self, display: didymus.diff.Display, cb: fun(err: string?)) Show the diff in the windows of `display`.
---@field clear fun(self, win: integer) Remove the diff from the window.
---@field prepare? fun(self, buf: integer, cb: fun(err: string?)) Prepare the inline diff of an attached buffer, so that `show_prepared()` can show it at once. Yield to the main loop often.
---@field is_prepared? fun(self, buf: integer): boolean True after `prepare()` calls its `cb` with no error, until the hunks change.
---@field show_prepared? fun(self, display: didymus.diff.Display): string? Show the inline diff of a prepared buffer in `display.head_win`, with no yield, so that the next redraw shows it. Give an error if the buffer is not prepared.
---@field health fun() Report the dependencies with `vim.health`.

local M = {}

local builtin = {
  gitsigns = "didymus.diff.provider.gitsigns",
  test = "didymus.diff.provider.test",
}

--- The provider of `spec`: the name of a built-in provider, or a provider table.
---@param spec string|didymus.diff.Provider
---@return didymus.diff.Provider? provider
---@return string? err
function M.get(spec)
  if type(spec) == "table" then
    return spec
  end
  local module = builtin[spec]
  if not module then
    return nil,
      ('unknown provider %q. Use "gitsigns", "test" or a provider table.'):format(tostring(spec))
  end
  return require(module)
end

return M
