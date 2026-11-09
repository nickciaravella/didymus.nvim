--- The git state of the current checkout: `HEAD`, the uncommitted changes and the merge-base. It
--- does not know about the code host. See docs/architecture/review.md#workspace-flow.

local picker = require("didymus.ui.picker")

local M = {}

--- The warning shows only this number of files. The preview shows all files.
local max_warning_files = 10

---@class didymus.review.workspace.Status
---@field head string? The sha of `HEAD`. Nil in a repo with no commits.
---@field branch string? Nil if `HEAD` is detached.
---@field changed_files string[] The tracked files with uncommitted changes, staged or not.

--- Run git in `cwd`. Call `cb` in the main loop.
---@param cwd string
---@param args string[]
---@param cb fun(err: string?, stdout: string?, code: integer?)
---@param ok_codes integer[]? The exit codes that are not errors. Default `{ 0 }`.
local function git(cwd, args, cb, ok_codes)
  local label = "git " .. args[1]
  local ok, err = pcall(
    vim.system,
    vim.list_extend({ "git" }, args),
    { cwd = cwd, text = true },
    function(result)
      vim.schedule(function()
        if vim.list_contains(ok_codes or { 0 }, result.code) then
          cb(nil, result.stdout, result.code)
        else
          cb(("%s: %s"):format(label, vim.trim(result.stderr or "")))
        end
      end)
    end
  )
  if not ok then
    -- `vim.system` gives an error at once if it cannot start the program.
    local message = tostring(err):find("ENOENT", 1, true) and "`git` is not on $PATH" or err
    vim.schedule(function()
      cb(("%s: %s"):format(label, message))
    end)
  end
end

--- The fields before the path in each kind of entry of `git status --porcelain=v2`.
local field_counts = { ["1"] = 8, ["2"] = 9, u = 10 }

--- Parse the output of `git status --porcelain=v2 --branch -z`.
---@param stdout string
---@return didymus.review.workspace.Status
local function parse_status(stdout)
  local status = { changed_files = {} }
  local records = vim.split(stdout, "\0", { plain = true, trimempty = true })
  local index = 1
  while index <= #records do
    local record = records[index]
    local header, value = record:match("^# (%S+) (.*)$")
    if header == "branch.oid" then
      status.head = value ~= "(initial)" and value or nil
    elseif header == "branch.head" then
      status.branch = value ~= "(detached)" and value or nil
    elseif field_counts[record:sub(1, 1)] then
      local kind = record:sub(1, 1)
      -- A path can have spaces, so take the text after the fixed fields.
      local path = record:match(("^" .. ("%S+ "):rep(field_counts[kind]) .. "(.*)$"))
      table.insert(status.changed_files, path)
      if kind == "2" then
        -- The original path of a rename is the next record.
        index = index + 1
      end
    end
    index = index + 1
  end
  return status
end

--- Get `HEAD`, the branch and the uncommitted changes. Untracked files are not changes, because
--- they stay after a checkout, and git refuses the checkout if one of them conflicts.
---@param cwd string
---@param cb fun(err: string?, status: didymus.review.workspace.Status?)
function M.get_status(cwd, cb)
  git(
    cwd,
    { "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no" },
    function(err, stdout)
      if err then
        return cb(err)
      end
      cb(nil, parse_status(stdout --[[@as string]]))
    end
  )
end

--- Show a warning with the changed files. Then ask the user to check out over them.
---@param adapter didymus.picker.Adapter
---@param label string The change, such as "#12".
---@param files string[]
---@param cb fun(confirmed: boolean)
function M.confirm_checkout(adapter, label, files, cb)
  local lines = {}
  for index = 1, math.min(#files, max_warning_files) do
    table.insert(lines, "  " .. files[index])
  end
  if #files > max_warning_files then
    table.insert(lines, ("  and %d more"):format(#files - max_warning_files))
  end
  -- The warning stays in the messages after the picker closes.
  vim.notify(
    "didymus: these files have uncommitted changes:\n" .. table.concat(lines, "\n"),
    vim.log.levels.WARN
  )
  picker.confirm(adapter, {
    title = ("Uncommitted changes. Check out %s?"):format(label),
    choice = "Check out",
    preview = { lines = files },
    cb = cb,
  })
end

---@param cwd string
---@param base_sha string
---@param head_sha string
---@param cb fun(err: string?, merge_base: string?)
function M.get_merge_base(cwd, base_sha, head_sha, cb)
  git(cwd, { "merge-base", base_sha, head_sha }, function(err, stdout)
    if err then
      return cb(err)
    end
    cb(nil, vim.trim(stdout --[[@as string]]))
  end)
end

--- Check if `path` in the working tree is different from `path` in `commit`.
---@param cwd string
---@param commit string
---@param path string Relative to `cwd`.
---@param cb fun(err: string?, changed: boolean?)
function M.has_changes(cwd, commit, path, cb)
  git(cwd, { "diff", "--quiet", commit, "--", path }, function(err, _, code)
    if err then
      return cb(err)
    end
    cb(nil, code == 1)
  end, { 0, 1 })
end

return M
