local wait_for = dofile("tests/helpers.lua").wait_for
local helpers = dofile("tests/integration/helpers.lua")
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

---@param dir string
---@param ... string
---@return string
local function git(dir, ...)
  local result = vim
    .system(
      { "git", "-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com", ... },
      { text = true }
    )
    :wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.writefile(lines, path)
end

--- A repo with three commits. `base` is the base of the diff, `middle` is between, and `HEAD` is the
--- head. The working tree is at `HEAD`.
---@return { dir: string, base: string, middle: string }
local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q")
  write(dir .. "/a.txt", { "one", "two", "three", "four", "five" })
  write(dir .. "/b.txt", { "b" })
  git(dir, "add", ".")
  git(dir, "commit", "-q", "--no-gpg-sign", "-m", "base")
  local base = git(dir, "rev-parse", "HEAD")
  write(dir .. "/a.txt", { "one", "two", "three", "four", "five", "six" })
  git(dir, "commit", "-q", "--no-gpg-sign", "-am", "middle")
  local middle = git(dir, "rev-parse", "HEAD")
  write(dir .. "/a.txt", { "zero", "one", "TWO", "three", "five" })
  write(dir .. "/b.txt", { "B" })
  git(dir, "commit", "-q", "--no-gpg-sign", "-am", "head")
  return { dir = dir, base = base, middle = middle }
end

-- The diff of a.txt from `base` to `HEAD`.
local a_hunks = {
  { kind = "add", base = { start = 0, count = 0 }, head = { start = 1, count = 1 } },
  { kind = "change", base = { start = 2, count = 1 }, head = { start = 3, count = 1 } },
  { kind = "delete", base = { start = 4, count = 1 }, head = { start = 4, count = 0 } },
}

local repo

--- Start the child in the repo, with gitsigns set up, and define the test functions in it.
---@param gitsigns_config table? The config of `require("gitsigns").setup()`.
local function start(gitsigns_config)
  child.fn.chdir(repo.dir)
  if gitsigns_config then
    child.lua("require('gitsigns').setup(...)", { gitsigns_config })
  end
  child.lua(
    [[
    _G.provider = require("didymus.diff.provider.gitsigns")
    _G.results = {}
    local base = ...

    function _G.target(sha)
      return {
        cwd = vim.fn.getcwd(),
        base = { kind = "commit", sha = sha or base },
        head = { kind = "worktree" },
        files = { { path = "a.txt", status = "modified" }, { path = "b.txt", status = "modified" } },
      }
    end

    -- Attach `buf`. Record each call of `cb`, with the hunks at the time of the call.
    function _G.attach(buf, path, sha)
      results[buf] = {}
      provider:attach(buf, { path = path, status = "modified" }, target(sha), function(err)
        table.insert(results[buf], { err = err or vim.NIL, hunks = provider:hunks(buf) or vim.NIL })
      end)
    end

    function _G.render(win, sides)
      results.render = nil
      local buf = vim.api.nvim_win_get_buf(win)
      provider:render({
        layout = "inline",
        sides = sides or "both",
        file = { path = "a.txt", status = "modified" },
        target = target(),
        head_win = win,
        head_buf = buf,
      }, function(err)
        results.render = { err = err or vim.NIL }
      end)
    end

    function _G.render_split(head_win, base_win)
      results.render = nil
      provider:render({
        layout = "split",
        sides = "both",
        file = { path = "a.txt", status = "modified" },
        target = target(),
        head_win = head_win,
        head_buf = vim.api.nvim_win_get_buf(head_win),
        base_win = base_win,
        base_buf = base_win and vim.api.nvim_win_get_buf(base_win),
      }, function(err)
        results.render = { err = err or vim.NIL }
      end)
    end

    -- The number of extmarks of the unified view of `win` in `buf`.
    function _G.view_marks(win, buf)
      local ns = vim.api.nvim_get_namespaces()["gitsigns_unified_" .. win]
      return ns and #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) or 0
    end

    -- The deleted lines that the unified view of `win` shows in `buf`.
    function _G.view_deleted_lines(win, buf)
      local ns = vim.api.nvim_get_namespaces()["gitsigns_unified_" .. win]
      local lines = {}
      for _, mark in ipairs(ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) or {}) do
        for _, virt_line in ipairs(mark[4].virt_lines or {}) do
          local text = {}
          for _, chunk in ipairs(virt_line) do
            table.insert(text, chunk[1])
          end
          table.insert(lines, vim.trim(table.concat(text)))
        end
      end
      return lines
    end
  ]],
    { repo.base }
  )
end

--- Edit `path` in the current window, and wait until gitsigns gives its hunks against the index.
---@param path string
---@return integer buf
local function edit(path)
  child.cmd("edit " .. path)
  local buf = child.api.nvim_get_current_buf()
  wait_for(function()
    return child.lua_get("require('gitsigns').get_hunks(...) ~= nil", { buf })
  end, "gitsigns attaches to " .. path)
  return buf
end

---@param buf integer
---@return table[] The calls of `cb`.
local function wait_for_attach(buf)
  wait_for(function()
    return #child.lua_get("results[...]", { buf }) > 0
  end, "the cb of attach")
  -- `cb` must come only one time.
  child.lua("vim.wait(50)")
  return child.lua_get("results[...]", { buf })
end

---@param buf integer
---@return table[]?
local function gitsigns_hunks(buf)
  return child.lua_get(
    [[vim.tbl_map(function(hunk) return { hunk.removed.start, hunk.added.start } end, require('gitsigns').get_hunks(...) or {})]],
    { buf }
  )
end

--- Wait until gitsigns has the hunks of `buf` against `revision`, then give them. `get_hunks()`
--- gives `{}` also while gitsigns computes the hunks, so the test reads the internal cache.
---@param buf integer
---@param revision string? Nil for the index.
---@return table[]
local function settled_hunks(buf, revision)
  wait_for(function()
    return child.lua_get(
      [[(function(buf, revision)
        local entry = require("gitsigns.cache").cache[buf]
        return entry ~= nil and entry.hunks ~= nil and entry.compare_text ~= nil
          and entry.git_obj.revision == revision
      end)(...)]],
      { buf, revision }
    )
  end, "the hunks of gitsigns")
  return gitsigns_hunks(buf)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo = make_repo()
      helpers.restart(child, { "gitsigns.nvim" })
    end,
    post_case = function()
      vim.fn.delete(repo.dir, "rf")
    end,
    post_once = child.stop,
  },
})

T["attach"] = MiniTest.new_set()

T["attach"]["gives the hunks against the base commit when cb comes"] = function()
  start({})
  local buf = edit("a.txt")
  child.lua("attach(...)", { buf, "a.txt" })
  eq(wait_for_attach(buf), { { err = vim.NIL, hunks = a_hunks } })
end

T["attach"]["waits for the attach of gitsigns after :edit"] = function()
  start({})
  child.cmd("edit a.txt")
  child.lua("attach(vim.api.nvim_get_current_buf(), 'a.txt')")
  eq(wait_for_attach(child.api.nvim_get_current_buf()), { { err = vim.NIL, hunks = a_hunks } })
end

T["attach"]["changes the base of that buffer only, also if it is not the current buffer"] = function()
  start({})
  local a = edit("a.txt")
  child.cmd("vsplit")
  local b = edit("b.txt")
  child.lua("attach(...)", { a, "a.txt" })
  eq(wait_for_attach(a)[1].err, vim.NIL)
  eq(child.api.nvim_get_current_buf(), b)
  eq(#gitsigns_hunks(a), 3)
  eq(gitsigns_hunks(b), {})
end

T["attach"]["gives an error if gitsigns is not set up"] = function()
  start(nil)
  child.cmd("edit a.txt")
  child.lua("attach(vim.api.nvim_get_current_buf(), 'a.txt')")
  eq(wait_for_attach(child.api.nvim_get_current_buf()), {
    { err = 'gitsigns.nvim is not set up. Call require("gitsigns").setup().', hunks = vim.NIL },
  })
end

T["attach"]["gives an error for a base that is not a commit"] = function()
  start({})
  local buf = edit("a.txt")
  child.lua(
    [[
    local buf = ...
    results[buf] = {}
    local target = _G.target()
    target.base = { kind = "index" }
    provider:attach(buf, { path = "a.txt", status = "modified" }, target, function(err)
      table.insert(results[buf], { err = err, hunks = vim.NIL })
    end)
  ]],
    { buf }
  )
  eq(
    wait_for_attach(buf),
    { { err = 'the gitsigns provider does not accept the base "index"', hunks = vim.NIL } }
  )
end

T["attach"]["gives an error after the timeout if gitsigns does not attach"] = function()
  write(repo.dir .. "/untracked.txt", { "new" })
  start({})
  child.lua("provider.timeout = 200")
  child.cmd("edit untracked.txt")
  child.lua("attach(vim.api.nvim_get_current_buf(), 'untracked.txt')")
  eq(wait_for_attach(child.api.nvim_get_current_buf()), {
    { err = "gitsigns did not attach to untracked.txt in 200 ms", hunks = vim.NIL },
  })
end

T["attach"]["gives an error one time if gitsigns never calls back"] = function()
  start({})
  local buf = edit("a.txt")
  child.lua("provider.timeout = 100; require('gitsigns').attach = function() end")
  child.lua("attach(...)", { buf, "a.txt" })
  eq(
    wait_for_attach(buf),
    { { err = "gitsigns did not attach to a.txt in 100 ms", hunks = vim.NIL } }
  )
end

T["detach"] = MiniTest.new_set()

T["detach"]["puts back the base of the gitsigns config"] = function()
  start({ base = repo.middle })
  local buf = edit("a.txt")
  local middle_hunks = settled_hunks(buf, repo.middle)
  MiniTest.expect.no_equality(middle_hunks, {})
  child.lua("attach(...)", { buf, "a.txt" })
  wait_for_attach(buf)
  eq(#gitsigns_hunks(buf), 3)
  child.lua("provider:detach(...)", { buf })
  eq(child.lua_get("provider:hunks(...)", { buf }), vim.NIL)
  eq(settled_hunks(buf, repo.middle), middle_hunks)
end

T["detach"]["during attach gives an error and puts back the base"] = function()
  start({})
  local buf = edit("a.txt")
  child.lua("attach(...)", { buf, "a.txt" })
  child.lua("provider:detach(...)", { buf })
  eq(wait_for_attach(buf), { { err = "the buffer was detached", hunks = vim.NIL } })
  eq(settled_hunks(buf, nil), {})
end

T["detach"]["after the change of the base puts back the base"] = function()
  start({})
  local buf = edit("a.txt")
  -- Delay the `cb` of `change_base()`, so that `detach()` comes before it.
  child.lua([[
    local gitsigns = require("gitsigns")
    local change_base = gitsigns.change_base
    gitsigns.change_base = function(base, global, cb)
      _G.base_changes = (_G.base_changes or 0) + 1
      change_base(base, global, function(...)
        local args = { ... }
        vim.defer_fn(function() cb(unpack(args)) end, 200)
      end)
    end
  ]])
  child.lua("attach(...)", { buf, "a.txt" })
  wait_for(function()
    return child.lua_get("_G.base_changes == 1")
  end, "the change of the base")
  child.lua("provider:detach(...)", { buf })
  eq(wait_for_attach(buf), { { err = "the buffer was detached", hunks = vim.NIL } })
  eq(settled_hunks(buf, nil), {})
end

T["attach"]["gives an error if an internal gitsigns call fails, and keeps the base"] = function()
  start({})
  local buf = edit("a.txt")
  child.lua(
    "_G.real_cache = package.loaded['gitsigns.cache']; package.loaded['gitsigns.cache'] = {}"
  )
  child.lua("attach(...)", { buf, "a.txt" })
  local calls = wait_for_attach(buf)
  eq(#calls, 1)
  MiniTest.expect.no_equality(calls[1].err:find("gitsigns.cache failed", 1, true), nil)
  eq(calls[1].hunks, vim.NIL)
  child.lua("package.loaded['gitsigns.cache'] = _G.real_cache")
  eq(settled_hunks(buf, nil), {})
end

T["render"] = MiniTest.new_set()

---@return integer buf
---@return integer head_win
---@return integer other_win
local function attach_in_two_windows()
  start({})
  local buf = edit("a.txt")
  local head_win = child.api.nvim_get_current_win()
  child.cmd("vsplit")
  local other_win = child.api.nvim_get_current_win()
  child.lua("attach(...)", { buf, "a.txt" })
  eq(wait_for_attach(buf)[1].err, vim.NIL)
  return buf, head_win, other_win
end

local function wait_for_render()
  wait_for(function()
    return child.lua_get("results.render ~= nil")
  end, "the cb of render")
  return child.lua_get("results.render.err")
end

T["render"]["shows the unified view only in the head window, also if it is not current"] = function()
  local buf, head_win, other_win = attach_in_two_windows()
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  wait_for(function()
    return child.lua_get("view_marks(...)", { head_win, buf }) > 0
  end, "the unified view")
  eq(child.lua_get("view_deleted_lines(...)", { head_win, buf }), { "two", "four" })
  eq(child.lua_get("view_marks(...)", { other_win, buf }), 0)
  eq(child.api.nvim_get_current_win(), other_win)
end

T["render"]["a second render keeps the view, and clear removes it"] = function()
  local buf, head_win = attach_in_two_windows()
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  wait_for(function()
    return child.lua_get("view_marks(...)", { head_win, buf }) > 0
  end, "the unified view")
  child.lua("provider:clear(...)", { head_win })
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
  -- A clear of a window with no view does not open a view.
  child.lua("provider:clear(...); vim.wait(100)", { head_win })
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
end

T["render"]["shows the view again after clear in a window with a different buffer"] = function()
  -- The other window keeps the buffer in a window, so gitsigns does not close the view on
  -- `BufWinLeave`.
  local buf, head_win = attach_in_two_windows()
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  child.api.nvim_set_current_win(head_win)
  child.cmd("edit b.txt")
  child.lua("provider:clear(...)", { head_win })
  child.cmd("buffer " .. buf)
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  wait_for(function()
    return child.lua_get("view_marks(...)", { head_win, buf }) > 0
  end, "the unified view")
end

T["render"]["shows no view with the head sides"] = function()
  local buf, head_win = attach_in_two_windows()
  child.lua("render(...)", { head_win, "head" })
  eq(wait_for_render(), vim.NIL)
  child.lua("vim.wait(100)")
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
end

T["render"]["gives an error for the base sides"] = function()
  local _, head_win = attach_in_two_windows()
  child.lua("render(...)", { head_win, "base" })
  eq(wait_for_render(), 'the gitsigns provider does not have the "base" sides yet')
end

T["split"] = MiniTest.new_set()

--- The window options that `:diffthis` changes.
local diff_options = {
  "diff",
  "scrollbind",
  "cursorbind",
  "wrap",
  "foldmethod",
  "foldcolumn",
  "foldenable",
  "foldlevel",
}

---@param win integer
---@return table<string, any>
local function get_options(win)
  local options = {}
  for _, name in ipairs(diff_options) do
    options[name] = child.api.nvim_get_option_value(name, { win = win, scope = "local" })
  end
  return options
end

--- Values that differ from the defaults and from the values of diff mode.
---@param win integer
local function set_options(win)
  child.lua(
    [[
    local win = ...
    vim.wo[win][0].foldmethod = "indent"
    vim.wo[win][0].foldcolumn = "1"
    vim.wo[win][0].foldenable = true
    vim.wo[win][0].foldlevel = 3
    vim.wo[win][0].wrap = false
  ]],
    { win }
  )
end

--- Attach a.txt in the head window, and show its base text in a base window on the left.
---@return integer buf
---@return integer head_win
---@return integer base_win
local function open_split()
  start({})
  local buf = edit("a.txt")
  local head_win = child.api.nvim_get_current_win()
  child.lua("attach(...)", { buf, "a.txt" })
  eq(wait_for_attach(buf)[1].err, vim.NIL)
  local base_win = child.lua(
    [[
    local base_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, { "one", "two", "three", "four", "five" })
    return vim.api.nvim_open_win(base_buf, false, { split = "left", win = ... })
  ]],
    { head_win }
  )
  return buf, head_win, base_win
end

T["split"]["sets 'diff' in both windows, and clear puts back the options"] = function()
  local _, head_win, base_win = open_split()
  set_options(head_win)
  local head_options, base_options = get_options(head_win), get_options(base_win)
  local scrollopt = child.o.scrollopt

  child.lua("render_split(...)", { head_win, base_win })
  eq(wait_for_render(), vim.NIL)
  for _, win in ipairs({ head_win, base_win }) do
    eq(get_options(win).diff, true)
    eq(get_options(win).scrollbind, true)
    eq(get_options(win).cursorbind, true)
    eq(get_options(win).foldmethod, "diff")
  end

  child.lua("provider:clear(...)", { head_win })
  child.lua("provider:clear(...)", { base_win })
  eq(get_options(head_win), head_options)
  eq(get_options(base_win), base_options)
  eq(child.o.scrollopt, scrollopt)
end

T["split"]["closes the unified view of the inline layout first"] = function()
  local buf, head_win, base_win = open_split()
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  wait_for(function()
    return child.lua_get("view_marks(...)", { head_win, buf }) > 0
  end, "the unified view")

  child.lua("render_split(...)", { head_win, base_win })
  eq(wait_for_render(), vim.NIL)
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
  eq(get_options(head_win).diff, true)
end

T["split"]["turns off diff mode when the buffer comes back to the window"] = function()
  -- Neovim keeps the window options of each buffer. So diff mode comes back with the buffer.
  local buf, head_win, base_win = open_split()
  set_options(head_win)
  local head_options = get_options(head_win)
  child.lua("render_split(...)", { head_win, base_win })
  eq(wait_for_render(), vim.NIL)

  child.api.nvim_set_current_win(head_win)
  child.cmd("edit b.txt")
  child.lua("provider:clear(...)", { head_win })
  child.lua("provider:clear(...)", { base_win })
  child.cmd("buffer " .. buf)
  eq(get_options(head_win), head_options)
end

T["split"]["gives an error with no base window"] = function()
  local _, head_win = open_split()
  child.lua("render_split(...)", { head_win, nil })
  eq(wait_for_render(), "the display has no base window")
end

T["detach"]["closes the unified view of the buffer"] = function()
  local buf, head_win = attach_in_two_windows()
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  child.lua("provider:detach(...)", { buf })
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
end

T["detach"]["keeps a unified view that the provider did not open"] = function()
  local buf, head_win, other_win = attach_in_two_windows()
  child.lua("render(...)", { head_win })
  eq(wait_for_render(), vim.NIL)
  -- A view of the user in the other window.
  child.lua("require('gitsigns').diffthis(nil, { unified = true })")
  wait_for(function()
    return child.lua_get("view_marks(...)", { other_win, buf }) > 0
  end, "the view of the user")
  child.lua("provider:detach(...)", { buf })
  eq(child.lua_get("view_marks(...)", { head_win, buf }), 0)
  MiniTest.expect.no_equality(child.lua_get("view_marks(...)", { other_win, buf }), 0)
end

T["health"] = MiniTest.new_set()

---@return string
local function health()
  child.lua("require('didymus').setup({ review = { provider = 'test', picker = 'test' } })")
  child.cmd("checkhealth didymus")
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

T["health"]["gives OK if gitsigns is set up"] = function()
  start({})
  MiniTest.expect.no_equality(
    health():find("OK gitsigns.nvim is available (diff.provider)", 1, true),
    nil
  )
end

T["health"]["gives a warning if an internal gitsigns function is missing"] = function()
  start({})
  child.lua("require('gitsigns.unified').close = nil")
  local report = health()
  MiniTest.expect.no_equality(
    report:find("WARNING gitsigns.nvim has no gitsigns.unified.close (diff.provider)", 1, true),
    nil
  )
end

T["health"]["gives a warning if gitsigns is not set up"] = function()
  start(nil)
  local report = health()
  MiniTest.expect.no_equality(
    report:find("WARNING gitsigns.nvim is not set up (diff.provider)", 1, true),
    nil
  )
end

return T
