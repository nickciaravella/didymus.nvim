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
