# Neovim

Facts about Neovim that are tricky and not well documented. For the rules, see [`README.md`](README.md).

## Terminal jobs

### A terminal job in a hidden buffer gets a pty with 5 rows

`jobstart()` with `term = true` uses the size of the current window by default. In `nvim_buf_call()` on a hidden buffer, the current window is a temporary window with 5 rows. Give `width` and `height` to `jobstart()`.

- Proof: this command prints `5 80`.

  ```sh
  nvim --clean --headless -n -c 'lua local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_call(b, function() vim.fn.jobstart({ "stty", "size" }, { term = true }) end)
  vim.wait(500) io.write(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "\n")' -c qa
  ```

- Checked: Neovim 0.12.5

### A paste into a terminal buffer has `\n` between the lines

`p` or `nvim_put()` in a terminal buffer sends a bracketed paste to the job. On Unix, the lines have `\n` between them. A paste from a linewise register has no `\n` at the end.

- Proof: run this command in the repo root. The fake agent prints `paste: "one\ntwo"`.

  ```sh
  nvim --clean --headless -n -c 'lua vim.fn.jobstart({ vim.v.progpath, "--clean", "-l", "tests/fixtures/fake_agent.lua" }, { term = true, width = 120 })
  vim.wait(1000) vim.fn.setreg("a", { "one", "two" }, "l") vim.cmd([[normal! "ap]]) vim.wait(500)
  io.write(vim.api.nvim_buf_get_lines(0, 0, -1, false)[2], "\n")' -c qa
  ```

- Checked: Neovim 0.12.5

## Messages

### A progress message of `nvim_echo()` needs `source`, and shows as `<title>: <text>`

`:h nvim_echo` gives `source` as optional, but `kind = "progress"` gives an error with no `source`. The default UI shows the `title`, a colon and the text. So `title = "didymus"` and the text `get #12` show `didymus: get #12`. A later call with the same `id` updates the message.

- Proof: this command prints `{ false, "Required: 'opts.source'" }`. A screenshot of a child Neovim in mini.test shows `didymus: get #12`.

  ```sh
  nvim --clean --headless -c 'lua io.write(vim.inspect({ pcall(vim.api.nvim_echo, { { "x" } }, false,
  { kind = "progress", status = "running" }) }), "\n")' -c qa
  ```

- Checked: Neovim 0.12.5

### The error of `vim.cmd()` has a long prefix, but the error of `nvim_cmd()` is `Vim:E37: …`

An error of `vim.cmd("edit x")` starts with the Lua location and `nvim_exec2()`, then `Vim(edit):`. This text is too long for a message to the user. `vim.api.nvim_cmd()` gives only `Vim:` and the Vim error. So run the command with `nvim_cmd()`, and remove `Vim:` before you show the error.

- Proof: this command prints `[string "vim/_core/editor"]:353: command line..script nvim_exec2() called at command line:0, line 1: Vim(edit):E37: No write since last change (add ! to override)`, then `Vim:E37: No write since last change (add ! to override)`.

  ```sh
  nvim --clean --headless -c 'set nohidden' -c 'lua vim.cmd("normal! ix") io.write(select(2, pcall(vim.cmd, "edit other")), "\n",
  select(2, pcall(vim.api.nvim_cmd, { cmd = "edit", args = { "other" } }, {})), "\n")' -c 'qa!'
  ```

- Checked: Neovim 0.12.5

## Extmarks

### Only the experimental `nvim__ns_set()` scopes a namespace to windows, and it has traps

Neovim 0.12 has no `nvim_win_add_ns()`. `nvim__ns_set(ns, { wins = { … } })` shows the extmarks of `ns` only in `wins`, also signs and `virt_lines`. `:h nvim__ns_set()` marks it as experimental. These are the traps:

- `wins = {}` turns the scope off. Then the extmarks show in all windows.
- If a window of the list closes, the scope stays on. The extmarks then show in no window.
- `<C-w>T` gives the window a new id. The new window is not in the scope.
- An invalid window id gives the error `Invalid window id`.
- With `signcolumn=auto`, a window outside the scope still gets an empty sign column, because the sign column counts the signs of the buffer.

- Proof: run this command in the repo root after `make deps`. It prints the first screen row: the sign shows only in the right window, then in both, then in no window, with an empty sign column.

  ```sh
  nvim --clean --headless -n -c 'set rtp+=deps/mini.nvim' -c 'lua local c = require("mini.test").new_child_neovim() c.start({ "--clean", "-n" }) c.o.columns = 30
  c.lua([[_G.ns = vim.api.nvim_create_namespace("x") vim.api.nvim_buf_set_lines(0, 0, -1, true, { "a" })
  vim.api.nvim_buf_set_extmark(0, _G.ns, 0, 0, { sign_text = "S" }) _G.w = vim.api.nvim_get_current_win() vim.cmd("vsplit")]])
  local function row(label) io.write(label, ": ", table.concat(c.get_screenshot().text[1]), "\n") end
  c.lua("vim.api.nvim__ns_set(_G.ns, { wins = { _G.w } })") row("wins = { right }")
  c.lua("vim.api.nvim__ns_set(_G.ns, { wins = {} })") row("wins = {}")
  c.lua("vim.api.nvim__ns_set(_G.ns, { wins = { _G.w } }) vim.api.nvim_win_close(_G.w, true)") row("right closed")
  c.stop()' -c qa
  ```

- Checked: Neovim 0.12.5

### `nvim_win_text_height()` counts the `virt_lines` under a line as a part of the next line

The `virt_lines` under row `r` count as the filler lines of row `r + 1`. The filler lines above `start_row` count too, unless you give `start_vcol`. So to count the rows from the top line to the last `virt_lines` of row `r`, give `start_vcol = 0`, use `end_row = r + 1`, and subtract the height of row `r + 1` alone. For the last row of the buffer, do not give `end_row`. Then the filler lines under it count.

- Proof: this command prints `row 0: 1/0, row 1: 3/2, row 1 with start_vcol: 1/0` (`all`/`fill`).

  ```sh
  nvim --clean --headless -n -c 'lua vim.api.nvim_buf_set_lines(0, 0, -1, true, { "a", "b" })
  vim.api.nvim_buf_set_extmark(0, vim.api.nvim_create_namespace("x"), 0, 0, { virt_lines = { { { "v1" } }, { { "v2" } } } })
  local function height(opts) local h = vim.api.nvim_win_text_height(0, opts) return h.all .. "/" .. h.fill end
  io.write("row 0: ", height({ start_row = 0, end_row = 0 }), ", row 1: ", height({ start_row = 1, end_row = 1 }),
  ", row 1 with start_vcol: ", height({ start_row = 1, start_vcol = 0, end_row = 1 }), "\n")' -c 'qa!'
  ```

- Checked: Neovim 0.12.5

## Windows

### The `textoff` of a window changes only at the next redraw after a new sign column

With `signcolumn=auto`, the first sign of a buffer makes the sign column show. But `getwininfo().textoff` keeps the old value until the next redraw. A `vim.schedule()` callback can run before that redraw, and `on_win` of a decoration provider also gets the old value. `on_end` of a decoration provider gets the new value, and so do `:redraw` and `nvim__redraw()`. So to fit `virt_lines` to the text width, check the width in `on_end`, and draw again in `vim.schedule()`.

- Proof: run this command in the repo root after `make deps`. It prints `now 0, on_win 0, on_end 2, …`. See also `Session:check_text_widths()` in `lua/didymus/review/session.lua`. The test "a long comment wraps at the text width, and again after a resize" in `tests/e2e/review/threads.test.lua` fails without it.

  ```sh
  nvim --clean --headless -n -c 'set rtp+=deps/mini.nvim' -c 'lua local c = require("mini.test").new_child_neovim() c.start({ "--clean", "-n" })
  c.lua([[_G.seen = {} vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("p"), {
  on_win = function(_, win) table.insert(_G.seen, "on_win " .. vim.fn.getwininfo(win)[1].textoff) return false end,
  on_end = function() table.insert(_G.seen, "on_end " .. vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff) end })]])
  c.get_screenshot() c.lua([[_G.seen = {} vim.api.nvim_buf_set_extmark(0, vim.api.nvim_create_namespace("s"), 0, 0, { sign_text = "S" })
  table.insert(_G.seen, "now " .. vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff)]])
  c.get_screenshot() io.write(table.concat(c.lua_get("_G.seen"), ", "), "\n") c.stop()' -c qa
  ```

- Checked: Neovim 0.12.5

### `nvim_win_set_buf()` adds the old position to the jumplist, but `:keepjumps buffer` does not

`:h nvim_win_set_buf()` does not tell it. To show a buffer with no jumplist entry, run `:buffer` with the `keepjumps` and `keepalt` modifiers in the window, for example `nvim_cmd({ cmd = "buffer", count = buf, mods = { keepjumps = true, keepalt = true } }, {})`. `:keepjumps edit` also adds no entry. The diff navigation uses both, so that a jump that opens files to get their hunks adds only the start position.

- Proof: the test "the jumplist gets only the start position, also when the jump checks a file with no hunks" in `tests/e2e/diff/navigation.test.lua`. This command prints `{ "a.txt:1" }`:

  ```sh
  cd "$(mktemp -d)" && echo a > a.txt && echo b > b.txt && nvim --clean --headless -c 'edit a.txt' -c 'clearjumps' -c 'lua vim.api.nvim_win_set_buf(0, vim.fn.bufadd("b.txt"))' -c 'lua print(vim.inspect(vim.tbl_map(function(j) return vim.fn.bufname(j.bufnr) .. ":" .. j.lnum end, vim.fn.getjumplist()[1])))' -c qa
  ```

- Checked: Neovim 0.12.6

### `:diffoff` does not put back 'foldenable' if 'foldmethod' goes back to "manual"

`:diffoff` puts back most window options from before `:diffthis`. But if 'foldmethod' was "manual", which is the default, `:diffoff` sets 'foldenable' to off. `:h :diffoff` tells it only as "most-likely". `:diffthis` also adds "hor" to the global 'scrollopt'. So save the options before `:diffthis`, and set them again after `:diffoff`. The gitsigns diff provider does this.

- Proof: the test "sets 'diff' in both windows, and clear puts back the options" in `tests/integration/diff/gitsigns.test.lua`. This command prints `false manual`, but 'foldenable' was on before:

  ```sh
  nvim --clean --headless -c 'vnew' -c 'windo diffthis' -c 'windo diffoff' -c 'lua print(vim.wo.foldenable, vim.wo.foldmethod)' -c qa
  ```

- Checked: Neovim 0.12.6

### Diff mode comes back when its buffer comes back to the window

Neovim keeps the window options of each buffer in each window. If the window shows a different buffer, `:diffoff` changes the options of that buffer only. When the old buffer comes back to the window, 'diff', 'scrollbind', 'cursorbind' and 'foldmethod=diff' come back too. A new buffer in the window gets no diff options. So turn off diff mode before the buffer leaves, or in `BufWinEnter` when it comes back. The gitsigns diff provider does it in `BufWinEnter`.

- Proof: the test "turns off diff mode when the buffer comes back to the window" in `tests/integration/diff/gitsigns.test.lua`. This command prints `true true diff`:

  ```sh
  cd "$(mktemp -d)" && echo a > a.txt && echo b > b.txt && nvim --clean --headless -c 'edit a.txt' -c 'vsplit b.txt' -c 'windo diffthis' -c 'wincmd l' -c 'enew' -c 'diffoff' -c 'buffer a.txt' -c 'lua print(vim.wo.diff, vim.wo.scrollbind, vim.wo.foldmethod)' -c qa
  ```

- Checked: Neovim 0.12.6

## Floats

### The float of `open_floating_preview()` closes when you leave its source buffer, also for a picker

The float has a `BufLeave` autocmd on the buffer where it opened. A picker, such as snacks, opens its own windows, so the float closes. Then a second call with the same `focus_id` cannot focus the float, and opens a new float with no focus. So when the float is open, do not open a picker before the second call.

- Proof: this command prints `before: 1, after :new: 0`. See also `close_preview_autocmd()` in `runtime/lua/vim/lsp/util.lua`.

  ```sh
  nvim --clean --headless -c 'lua vim.lsp.util.open_floating_preview({ "a" }, "", {}) local function count() return #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins()) end io.write("before: ", count()) vim.cmd("new") vim.wait(50) io.write(", after :new: ", count(), "\n")' -c qa
  ```

- Checked: Neovim 0.12.5

## Lua scripts (`nvim -l`)

### A script that blocks in `io.read` does not exit on SIGTERM or SIGHUP

`io.read` blocks the event loop. The script exits on the signal only after the read returns. For this reason, `jobstop()` on a job without a pty waits for its timeout (2 seconds), then sends SIGKILL. Read stdin with `vim.uv` and `read_start()`, and wait with `vim.wait()`. For raw keys, use `vim.uv.new_tty(0, true)` and `set_mode("raw")`. For an example, see `tests/fixtures/fake_agent.lua`.

- Proof: this command prints `still runs`.

  ```sh
  sleep 5 | nvim --clean -l <(echo 'io.read()') & sleep 0.5; kill $!; sleep 1; kill -0 $! && echo "still runs"
  ```

- Checked: Neovim 0.12.5

## Tests with a child Neovim

### A Neovim with a UI stops at the swap prompt, and RPC calls hang

If a file has a swap file from a Neovim that crashed, `:edit` shows the E325 prompt. With a UI attached, Neovim waits for a key, so an RPC call such as `child.lua()` hangs. Without a UI, Neovim does not wait. The swap file of a running Neovim gives no prompt (`:h W325`). mini.test adds `-n` to its child. Add `-n` to each Neovim that you start yourself.

- Proof: do these steps.
  1. In a Neovim, change a file, run `:preserve`, and stop that Neovim with `kill -9`.
  2. Start `nvim --clean --headless --listen <address>`. Call `nvim_ui_attach()`, then send `:edit <file>`.
  3. `nvim_get_mode()` gives `{ blocking = true, mode = "rm" }`. With `-n`, it gives `mode = "n"`.
- Proof for mini.test: `child.start()` in `deps/mini.nvim/lua/mini/test.lua` adds `--clean -n`.
- Checked: Neovim 0.12.5

### `child.type_keys()` fails the test on an error message, also from a later callback

mini.test reads `v:errmsg` after each key. An error message from the key fails the test with that message. This also applies to the error of a `vim.schedule()` callback, if it runs before mini.test reads `v:errmsg`. To test an async error, send the last key with `child.api.nvim_input()`. Then poll the messages.

- Proof: in the test "after an error, the next comment at the same lines starts with the text" of `tests/e2e/review/comment.test.lua`, use `child.type_keys("<C-s>")` in place of `child.api.nvim_input("<C-s>")`. The test fails with the error message of didymus. See `type_keys()` in `deps/mini.nvim/lua/mini/test.lua`.
- Checked: Neovim 0.12.5, mini.nvim f9ac12d
