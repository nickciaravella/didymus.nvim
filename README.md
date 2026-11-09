# didymus.nvim

Review pull requests in Neovim. Read the real code with full LSP, comment on the PR, and talk to an AI agent in one place.

> [!WARNING]
> **Early development.** Only the agent, the start of a review, the files panel, the review threads (with navigation), new comments, replies, resolve, and the submit or the discard of the review work now.

## Goals

- Show the real files from the PR, so LSP and normal navigation work.
- Read, write and resolve review comments in Neovim.
- Run an agent CLI of your choice next to the code, and ask it about selected code.
- Let users replace the integrations (code host, agent, diff display) with their own.

## Requirements

- Neovim 0.12+
- `git`
- For the review: [snacks.nvim](https://github.com/folke/snacks.nvim) and the [GitHub CLI](https://cli.github.com/) (`gh`), authenticated with `gh auth login`

## Installation

```lua
-- vim.pack (Neovim 0.12+)
vim.pack.add({ "https://github.com/nickciaravella/didymus.nvim" })

-- lazy.nvim
{ "nickciaravella/didymus.nvim" }
```

## Agent

Run an agent CLI, such as Claude Code or Codex, in a split on the right or in a float.

| Command | Behavior |
| --- | --- |
| `:Didymus agent toggle [float\|split] [cmd]` | Show the agent, or hide it. Start it if it does not run. |
| `:Didymus agent focus [float\|split] [cmd]` | Show the agent and focus it. Start it if it does not run. |
| `:Didymus agent start [cmd]` | Start the agent, but do not show it. |
| `:Didymus agent stop` | End the agent and close its view. |
| `:[range]Didymus agent append` | Put the current line or the range in the agent input. Then show and focus the agent. |
| `:[range]Didymus agent send [text]` | Open a float for a prompt about the current line or the range. Then send the prompt and the code, or append them. |

`toggle float` shows or hides the float. If the split is visible, it closes, and the same agent shows in the float. `toggle split` does the same for the split. `toggle` with no view uses the last view, then `agent.view`.

The float hides when you go to a different window. The agent continues. The inside of the float has the `DidymusAgentFloat` highlight, which links to `Normal`.

**Append** puts the location and the code in the agent input, and does not submit. You type the rest of the prompt in the agent.

**Send** opens a float above the code. Type the prompt, then press a key:

| Key | Behavior |
| --- | --- |
| `<C-s>` | Send the prompt and the code. The agent stays hidden. To read the answer, show the agent. |
| `<C-y>` | Append the code and the prompt to the agent input, as append does. Then add to the prompt in the agent. |
| `<CR>` | Add a line. |
| `q` or `<Esc>` in normal mode | Cancel. |

With `[text]`, send submits at once, with no float.

In visual mode, the mappings use the selection. `:'<,'>Didymus agent append` uses the full lines. Append and send start the agent if it does not run.

`[cmd]` overrides `agent.cmd`. If the agent runs, didymus does not use `[cmd]`. To change the agent, stop it first.

There are no default keymaps. For example:

```lua
vim.keymap.set({ "n", "t" }, "<M-a>", "<Plug>(didymus-agent-toggle)")
vim.keymap.set({ "n", "x" }, "<leader>aa", "<Plug>(didymus-agent-append)")
vim.keymap.set({ "n", "x" }, "<leader>as", "<Plug>(didymus-agent-send)")
```

| Mapping | Modes |
| --- | --- |
| `<Plug>(didymus-agent-toggle)`, `<Plug>(didymus-agent-focus)`, `<Plug>(didymus-agent-start)`, `<Plug>(didymus-agent-stop)` | Normal and terminal |
| `<Plug>(didymus-agent-append)`, `<Plug>(didymus-agent-send)` | Normal and visual |

`agent.keys` sets a key to go to the agent and a key to go back to the code. For example, `<C-a>` for both:

```lua
require("didymus").setup({ agent = { keys = { focus = "<C-a>", leave = "<C-a>" } } })
```

- `focus` is a normal-mode key. It shows the agent and focuses it.
- `leave` is a key in the agent buffer, in terminal and normal mode. It goes back to the code. The agent does not get this key.

To check that the program of `agent.cmd` is on `$PATH`, run `:checkhealth didymus`.

The defaults:

```lua
require("didymus").setup({
  agent = {
    cmd = "claude", -- a string runs through 'shell'
    view = "split", -- "split" or "float"
    backend = "terminal", -- "terminal", or "test" for tests
    split = { width = 0.4 }, -- below 1 is a fraction of the editor width
    float = { width = 0.85, height = 0.85 }, -- below 1 is a fraction of the editor size
    keys = { focus = false, leave = false }, -- a key, or false for no key
    input = { -- the float of send
      width = 60, -- below 1 is a fraction of the window width
      max_height = 10, -- the float grows to this height, then it scrolls
      keys = { send = "<C-s>", append = "<C-y>", cancel = "q" }, -- false turns off a key
    },
    terminal = {
      ready_delay = 500, -- ms to wait after the first output of the agent, before input
      submit_delay = 50, -- ms to wait after the prompt text, before the Enter key
    },
  },
})
```

## Review

Review a GitHub pull request in the current checkout. The picker is [snacks.nvim](https://github.com/folke/snacks.nvim). didymus gets the pull requests with `gh`.

| Command | Behavior |
| --- | --- |
| `:Didymus review open [n\|url]` | Open a pull request in the review tabpage. With no argument, choose a pull request in the picker. The preview shows its description. |
| `:Didymus review close` | Close the files panel and the review tabpage. |
| `:Didymus review files` | Show the files panel, or hide it. |
| `:Didymus review thread` | Open the thread at the cursor in a float, with all its comments. |
| `:Didymus review next`, `:Didymus review prev` | Go to the next or the previous thread, also in a different file. |
| `:[range]Didymus review comment` | Add a comment on the current line, the selection or the range. The comment goes into your pending review. |
| `:Didymus review reply` | Reply to the thread at the cursor. The reply goes into your pending review. |
| `:Didymus review resolve` | Resolve the thread at the cursor. On a resolved thread, unresolve it. |
| `:Didymus review submit [approve\|comment\|request_changes]` | Submit your pending review with a verdict and a body. With no verdict, choose one in the picker. |
| `:Didymus review discard` | Delete your pending review and its comments. The picker asks you to confirm. |

If `HEAD` is not the head of the pull request, `open` checks out the pull request. If there are uncommitted changes, a warning shows the files, and the picker asks you to confirm. didymus does not stash the changes. If git refuses the checkout, the error shows and the review does not open.

Only one review is open at a time. `open` of the same pull request goes to its tabpage. `open` of a different pull request asks to close the open review first.

The files panel opens on the left of the review tabpage. It shows the title, the author and `base ← head` of the pull request. Then it shows a row for each changed file: the status (`A`, `M`, `D` or `R`), the path, and the `+` and `-` counts. `<CR>` on a file opens the real file in the code window, with the cursor on the first change of the pull request, and moves the focus there. The panel stays open. A deleted file does not open.

`files` in a different tabpage goes to the review tabpage and shows the panel.

Under each file, the panel shows its review threads: the author, the first line of the first comment, and the state. A resolved thread is dim. An outdated thread has the `[outdated]` tag. `<CR>` on a thread goes to its line in the code window. The file row shows the thread count.

In the file, each thread has a sign with its comment count, and a summary under its line. A thread on a range shows at the last line of the range. The signs and the summaries show only in the windows of the review tabpage. In a window outside the review tabpage, the file can have an empty sign column.

Outdated threads, threads on deleted lines and threads on the file show only in the panel. `<CR>` on one of them opens its float next to the panel.

`thread` opens a float next to the cursor. The float closes when the cursor moves. A second `thread` moves the focus into the float, and `q` closes it. If more than one thread is at the line, the picker asks which one to open.

`next` and `prev` go through the threads in the order of the panel, from the cursor. If the current window does not show a file of the pull request, they start at the cursor of the code window. They skip the threads that show only in the panel, and the threads at the same line are one stop. At the last or the first thread, a message shows, and the cursor does not move. `<C-o>` goes back to the position before the jump. In a different tabpage, `next` and `prev` go to the review tabpage first.

`comment` opens a float above the lines, with the location as the title. Type the comment, then press `<C-s>` to add it, or `q` in normal mode to cancel. The comment goes into your pending review. If you have no pending review, didymus starts one. A pending review that you started on github.com also works. The new thread shows in the panel and at the line, with the `[pending]` tag. It stays pending until you submit the review.

didymus refuses a comment, and shows the reason, in these cases:

- The current window does not show a file of the pull request.
- The buffer is modified, or the file is different from the head of the pull request. A comment needs the line numbers of the head.
- The lines are not in a hunk of the pull request. A range must be in one hunk. If the hunks of a file are unknown, for example in a large file, GitHub decides.

If GitHub does not add the comment, the error shows. The next `comment` on the same lines starts with your text.

`reply` and `resolve` use the thread at the cursor line. In the thread float, they use the thread of the float. If more than one thread is at the line, the picker asks which one. In the thread float, `r` replies and `x` resolves or unresolves. The footer of the float shows these keys if it is wide enough. For a thread that shows only in the panel, press `<CR>` two times on its row, then use the keys.

`reply` opens a float at the cursor line. Type the reply, then press `<C-s>` to add it, or `q` in normal mode to cancel. The reply goes into your pending review, as a comment does. It stays pending until you submit the review. If GitHub does not add the reply, the error shows. The next `reply` to the same thread starts with your text.

After a resolve, the thread is dim in the panel and at its line. If GitHub does not let you do the action, a message shows. For example, GitHub does not let you resolve a thread of your pending review.

`submit` opens a float for the body of the review, with the verdict and the pull request as the title. Type the body, then press `<C-s>` to submit, or `q` in normal mode to cancel. An approval does not need a body. A comment or a request for changes needs a body, or a pending comment. With no pending review, `submit` gives a review with only the body. GitHub does not let you approve your own pull request or request changes on it. If GitHub does not submit the review, the error shows. The next `submit` starts with your text.

`discard` shows your pending comments in the preview of the picker. After you confirm, didymus deletes the pending review, and its comments go away.

After a submit or a discard, didymus gets the threads again. The review stays open.

The highlight groups are `DidymusThread` (default: `DiagnosticInfo`), `DidymusThreadResolved` (default: `Comment`) and `DidymusThreadPending` (default: `DiagnosticHint`).

`close` does not check out the branch from before the review. Its message names that branch. `:tabclose` of the review tabpage also closes the review.

There are no default keymaps. For example:

```lua
vim.keymap.set("n", "<leader>ro", "<Plug>(didymus-review-open)")
vim.keymap.set("n", "<leader>rc", "<Plug>(didymus-review-close)")
vim.keymap.set("n", "<leader>rf", "<Plug>(didymus-review-files)")
vim.keymap.set("n", "<leader>rt", "<Plug>(didymus-review-thread)")
vim.keymap.set("n", "<leader>rn", "<Plug>(didymus-review-next)")
vim.keymap.set("n", "<leader>rp", "<Plug>(didymus-review-prev)")
vim.keymap.set({ "n", "x" }, "<leader>rm", "<Plug>(didymus-review-comment)")
vim.keymap.set("n", "<leader>rr", "<Plug>(didymus-review-reply)")
vim.keymap.set("n", "<leader>rx", "<Plug>(didymus-review-resolve)")
vim.keymap.set("n", "<leader>rs", "<Plug>(didymus-review-submit)")
vim.keymap.set("n", "<leader>rd", "<Plug>(didymus-review-discard)")
```

| Mapping | Modes |
| --- | --- |
| `<Plug>(didymus-review-open)`, `<Plug>(didymus-review-close)`, `<Plug>(didymus-review-files)`, `<Plug>(didymus-review-thread)`, `<Plug>(didymus-review-next)`, `<Plug>(didymus-review-prev)`, `<Plug>(didymus-review-reply)`, `<Plug>(didymus-review-resolve)`, `<Plug>(didymus-review-submit)`, `<Plug>(didymus-review-discard)` | Normal |
| `<Plug>(didymus-review-comment)` | Normal, visual |

To check snacks.nvim and `gh`, run `:checkhealth didymus`.

The defaults:

```lua
require("didymus").setup({
  review = {
    picker = "snacks", -- "snacks", "test" for tests, or an adapter table
    provider = "github", -- "github", "test" for tests, or a provider table
    input = { -- the float of comment, reply and submit
      width = 60, -- below 1 is a fraction of the window width
      max_height = 10, -- the float grows to this height, then it scrolls
      keys = { comment = "<C-s>", cancel = "q" }, -- comment also adds a reply and submits. cancel is in normal mode
    },
    thread = { -- the thread float
      keys = { reply = "r", resolve = "x" }, -- false turns a key off
    },
  },
})
```

## Contributing

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE)
