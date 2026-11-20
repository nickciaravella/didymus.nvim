# gitsigns.nvim

Facts about gitsigns.nvim that are tricky and not well documented. For the rules, see [`README.md`](README.md).

The tests are in `tests/integration/diff/gitsigns.test.lua`. The source links are at the pinned commit `fd78092`, `GITSIGNS_COMMIT` in the `Makefile`.

## Setup

### `plugin/gitsigns.lua` calls `setup()`, and only `setup()` makes the `:Gitsigns` command

A plugin manager that sources `plugin/` sets up gitsigns with no config. A child Neovim that only appends gitsigns to the `'runtimepath'` does not source `plugin/`, so gitsigns is not set up. With no setup, `attach()` does nothing. To tell if gitsigns is set up, check `vim.fn.exists(":Gitsigns") == 2`.

- Proof: the test `attach gives an error if gitsigns is not set up`, and [`gitsigns.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns.lua#L236-L258).
- Checked: gitsigns.nvim `fd78092`

## Base and hunks

### `change_base()` acts on the current buffer, and reads it before it yields

`change_base(base, global, cb)` has no buffer argument. Call it in `nvim_buf_call(buf, …)`. The async task starts at once and reads the current buffer before its first yield, so `nvim_buf_call()` is enough.

- Proof: the test `attach changes the base of that buffer only, also if it is not the current buffer`.
- Checked: gitsigns.nvim `fd78092`

### `change_base(nil)` sets the index, not the `base` of the gitsigns config

The doc says that `change_base()` with no base "uses the original base". In the code, a nil base is the index. `attach` uses `config.base`. To put back the base of the config, call `change_base(require("gitsigns.config").config.base)`. A base that the user set with `:Gitsigns change_base` is lost, because no public function reads it.

- Proof: the test `detach puts back the base of the gitsigns config`, and [`attach.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/attach.lua#L326).
- Checked: gitsigns.nvim `fd78092`

### The `cb` of `change_base()` can come before the hunks against the new base

`change_base()` sets the hunks to nil and calls the throttled `manager.update()`. If an update already runs, for example the first update after `:edit`, the call returns at once and `cb` comes. `get_hunks()` gives `{}` for nil hunks, so it cannot tell "not ready" from "no hunks". `User GitSignsUpdate` has `data.buffer`, but it fires only when the status changes. To wait, poll `require("gitsigns.cache").cache[buf]` until `hunks`, `compare_text` and `git_obj.revision == sha` are set.

- Proof: the test `attach gives the hunks against the base commit when cb comes`. It fails in some runs without the wait for `internal.has_hunks()` in `lua/didymus/diff/provider/gitsigns.lua`. See also [`manager.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/manager.lua#L151) and [`actions.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/actions.lua#L693).
- Checked: gitsigns.nvim `fd78092`

### An update that reads the base text during `change_base()` keeps the text of the old base

An update reads the base text with `git show` when `compare_text` is nil. If `change_base()` ends while that read runs, the update stores the text of the old base after the new revision is set. The next updates reuse it. Then `git_obj.revision` is the new base, but the hunks are against the old base. Before `change_base()`, wait until `cache[buf].hunks` and `compare_text` are set. Do not call `change_base()` two times at the same time for one buffer, because the last call to end sets the base.

- Proof: the tests `detach during attach gives an error and puts back the base` and `detach after the change of the base puts back the base`. They fail in some runs without the wait for `internal.is_idle()` in `lua/didymus/diff/provider/gitsigns.lua`. See also [`manager.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/manager.lua#L171).
- Checked: gitsigns.nvim `fd78092`

### gitsigns computes the hunks only for a buffer in a window of the current tabpage

`manager.update()` checks the windows of the current tabpage only. For a buffer that is not there, it keeps the old hunks and updates later. So attach only a buffer in a window of the current tabpage.

- Proof: [`manager.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/manager.lua#L125-L132).
- Checked: gitsigns.nvim `fd78092`

## Unified view

### No tag has the unified view of `diffthis()`

`diffthis(base, { unified = true })` came after v2.1.0 (2026-03-26). So pin a commit, not a tag.

- Proof: `git show v2.1.0:lua/gitsigns/unified.lua` fails in a clone of gitsigns.nvim.
- Checked: gitsigns.nvim v2.1.0 and `fd78092`

### `diffthis()` reads the current window before it returns, if the base is the base of the buffer

`diffthis()` reads the current window after it makes the revision buffer, so a yield before that read would use the wrong window. With the base of the buffer, gitsigns reuses its base text, and the test shows that the read comes before `diffthis()` returns. So `nvim_win_call(win, …)` opens the view in `win`. Use the same base for `change_base()` and `diffthis()`.

- Proof: the test `render shows the unified view only in the head window, also if it is not current`, and [`diffthis.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/actions/diffthis.lua#L223).
- Checked: gitsigns.nvim `fd78092`

### The public API cannot tell if a unified view is open, and cannot close it after the window changes its buffer

A second `diffthis(…, { unified = true })` closes the view, but only if the current window shows the buffer of the view now. The view closes on `WinClosed`, and on `BufWinLeave` only when no other window shows the buffer. An update can close it later, with no event. So a state that the caller keeps can be wrong, and a toggle can open a view in place of closing it. Use `require("gitsigns.unified").get_view(win)` and `.close(win)`.

- Proof: the test `render shows the view again after clear in a window with a different buffer`, and [`unified.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/unified.lua#L255-L272).
- Checked: gitsigns.nvim `fd78092`

### The unified view blocks the event loop while it copies the highlights of the deleted lines

The update of a unified view calls `capture_removed_hunks_from_source()` with no yield. It copies the treesitter highlights of each deleted hunk from the base buffer. A redraw can come between `diffthis()` and that update, so a window that shows the buffer shows the signs first, and the deleted lines after the block. To show both together, hide the window until the `cb` of `diffthis()`. That `cb` comes after the update.

- Proof: a timer of 2 ms in a Neovim with lua_ls and treesitter. For a Lua file with 76 hunks, the capture took 411 ms, and the loop was blocked for 433 ms. For 15 hunks, it was blocked for 42 ms. See [`unified.lua`](https://github.com/lewis6991/gitsigns.nvim/blob/fd780920613e541cbdfac41bf711583ed49f9249/lua/gitsigns/unified.lua#L116-L170). The test `the preview of the snacks files panel shows the unified view, until the panel loses the focus` checks each redraw of the preview.
- Checked: gitsigns.nvim `fd78092`
