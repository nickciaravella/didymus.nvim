# didymus.nvim

Review pull requests in Neovim. Read the real code with full LSP, comment on the PR, and talk to an AI agent in one place.

> [!WARNING]
> **Early development.** Only the agent, the start of a review, the files panel, the review threads, the navigation, new comments, replies, resolve, the submit or the discard of the review, the refresh, the viewed state of files, the inline and split diff, the sides of the diff, the diff navigation, and the diff in the panel preview work now.

## Goals

- Show the real files from the PR, so LSP and normal navigation work.
- Read, write and resolve review comments in Neovim.
- Run an agent CLI of your choice next to the code, and ask it about selected code.
- Let users replace the integrations (code host, agent, diff display) with their own.

## Requirements

- Neovim 0.12+
- `git`
- For the review: [snacks.nvim](https://github.com/folke/snacks.nvim) and the [GitHub CLI](https://cli.github.com/) (`gh`), authenticated with `gh auth login`
- For the diff (optional): [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim), a commit after v2.1.0, because v2.1.0 has no unified view. Without it, the review works with no diff.

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
| `:Didymus review fold [all]` | Fold or unfold the threads at the cursor line. With `all`, fold or unfold all head-line threads. |
| `:Didymus review focus` | Move the cursor into the thread at the cursor line inline (or into an open inline editor). |
| `:Didymus review next [thread\|file\|hunk]`, `:Didymus review prev [thread\|file\|hunk]` | Go to the next or the previous thread, changed file or hunk, also in a different file. The default is `thread`. |
| `:[range]Didymus review comment` | Add a comment on the current line, the selection or the range. Post it at once, or add it to your pending review. |
| `:Didymus review reply` | Reply to the thread at the cursor. Post the reply at once, or add it to your pending review. |
| `:Didymus review resolve` | Resolve the thread at the cursor. On a resolved thread, unresolve it. |
| `:Didymus review submit [approve\|comment\|request_changes]` | Submit your pending review with a verdict and a body. With no verdict, choose one in the picker. |
| `:Didymus review discard` | Delete your pending review and its comments. The picker asks you to confirm. |
| `:Didymus review refresh` | Get the pull request and its threads again. `R` in the files panel does the same. |
| `:Didymus review viewed` | Mark the file of the current window as viewed, or unmark it. `v` in the files panel does the same for the file at the cursor. |

If `HEAD` is not the head of the pull request, `open` checks out the pull request. If there are uncommitted changes, a warning shows the files, and the picker asks you to confirm. didymus does not stash the changes. If git refuses the checkout, the error shows and the review does not open.

Only one review is open at a time. `open` of the same pull request goes to its tabpage. `open` of a different pull request asks to close the open review first.

The files panel opens on the left of the review tabpage. It shows the title, the author and `base ← head` of the pull request. Then it shows a row for each changed file: the status (`A`, `M`, `D` or `R`), the path, and the `+` and `-` counts. `<CR>` on a file opens the real file in the code window, with the cursor on the first change of the pull request, and moves the focus there. The panel stays open. A deleted file is not in your checkout. With the diff shown, `<CR>` on it shows its base. See [Diff](#diff).

`files` in a different tabpage goes to the review tabpage and shows the panel.

Under each file, the panel shows its review threads: an icon for the state (💬 active, ✅ resolved), the author and the first line of the first comment. A resolved thread is dim. An outdated thread has the `[outdated]` tag. `<CR>` on a thread goes to its line in the code window, and unfolds the thread. The file row shows the thread count.

`a` in the panel shows only the active threads, or all threads again. The default is all threads. The third row of the header shows the filter: `All threads` or `Active threads`. The thread count of a file counts only the threads that show.

`v` in the panel marks the file at the cursor as viewed, or unmarks it, as the "Viewed" box on github.com does. On a thread row, it uses the file of the thread. A viewed file is dim and has the `[viewed]` tag. A file with new changes since you viewed it has the `[changed]` tag, and `v` marks it as viewed again. `:Didymus review viewed` uses the file of the current window. If the current window does not show a file of the pull request, it uses the code window. A refresh gets the viewed state again.

In the file, each thread has a sign with its comment count. The thread shows under its line, so it does not cover the code. A thread on a range shows at the last line of the range. The signs and the threads show only in the windows of the review tabpage. In a window outside the review tabpage, the file can have an empty sign column.

```
2 local count = 2
┌──────────────────────────────────────────────────────────┐
│ 💬 @octocat  2026-11-21 14:30                            │
│ Why two?                                                 │
├──────────────────────────────────────────────────────────┤
│ @hubot [pending]  2026-11-21 14:35                       │
│ Because.                                                 │
└──────────────────────────────────────────────────────────┘
  local total = count * 2
✅ @hubot Rename this.
```

A thread is folded or unfolded:

- A folded thread is one line: the icon of the state, the author and the first line of the first comment.
- An unfolded thread shows all its comments in a smooth 4-sided box from the line numbers to the right edge of the window, with a subtle darker background (`DidymusThreadBg`). Each comment starts with a header line (status emoji, bold author, tags and lighter local date and time) followed by rendered markdown (treesitter hides delimiters and highlights code; when `render-markdown.nvim` is installed, its formatting applies too). A long line wraps at the width of the window.
- As on github.com, an active head-side thread starts unfolded, and a resolved, outdated or base-side thread starts folded. A resolve folds the thread, and an unresolve unfolds it.

`fold` folds the threads at the cursor line, or unfolds them. With two threads at the line, it folds both if one of them is unfolded. `fold all` folds all head-line threads if one of them is unfolded. Else, it unfolds them. A refresh keeps the folds.

`focus` opens a read-only rendered markdown view in the exact inline space of the thread, with no float over the code. It keeps markdown rendered under the cursor (`conceallevel = 3`, `concealcursor = "nvc"`, and `anti_conceal = { enabled = false }` when `render-markdown.nvim` is loaded). Inside it, you can move the cursor, select text, yank, follow links and scroll long threads. Press `?` in normal mode to open a shortcuts popup (`r` reply, `x` resolve or unresolve, `z` fold, `q` / `<Esc>` close).

Outdated threads, threads on deleted lines and threads on the file show inline above line 1 of their file. `<CR>` on one of them in the panel opens the file at line 1 and focuses the thread inline. On a deleted file with no buffer, `<CR>` opens a bottom split under the code window.

`next` and `prev` go in the order of the panel, from the cursor. If the current window does not show a file of the pull request, they start at the cursor of the code window.

- `thread` skips the threads that show only in the panel. If the panel shows only the active threads, it also skips the resolved threads. The threads at the same line are one stop. `thread` unfolds the threads of the stop, and scrolls the window so that they show.
- `file` goes to the first change of the file.
- `hunk` goes to the first change of the hunk.
- `file` and `hunk` skip the deleted files.

At the last or the first stop, a message shows, and the cursor does not move. `<C-o>` goes back to the position before the jump. In a different tabpage, `next` and `prev` go to the review tabpage first.

`comment` opens an inline markdown box under the lines, in the same 4-sided frame, so it covers no code. Type the comment, then press a key:

| Key | Action |
| --- | --- |
| `<C-s>` | Comment now: post the comment at once. GitHub does this only if you have no pending review. |
| `<C-y>` | Add to review: add the comment to your pending review. If you have no pending review, didymus starts one. A pending review that you started on github.com also works. |
| `<Esc>`, in normal mode | Leave the box and keep your draft open. |
| `q`, in normal mode | Cancel and discard the draft. |

An open inline editor stays alive if you leave it, scroll away or open another file. While focused, it shows raw markdown source with syntax highlights. While unfocused, it renders the markdown until you enter it again. It hides while off screen and shows again when you return. Only one inline editor can be open at a time.

The new thread shows in the panel and at the line. A comment in your pending review has the `[pending]` tag. It stays pending until you submit the review.

didymus refuses a comment, and shows the reason, in these cases:

- The current window does not show a file of the pull request.
- Another inline comment or reply is already open at a different place.
- `HEAD` is not the head of the pull request, for example after a refresh with a new head, or after a local commit.
- The buffer is modified, or the file is different from the head of the pull request. A comment needs the line numbers of the head.
- The lines are not in a hunk of the pull request. A range must be in one hunk. If the hunks of a file are unknown, for example in a large file, GitHub decides.

If GitHub does not add the comment, the error shows. The next `comment` on the same lines starts with your text.

`reply` and `resolve` use the focused inline thread, else the thread at the cursor line. If more than one thread is at the line, the picker asks which one.

`reply` unfolds the thread and opens an inline markdown box attached to the bottom of the thread box (or a bottom split for a deleted file). It has the keys of `comment`: `<C-s>` (reply now) posts the reply at once, and `<C-y>` (add to review) adds it to your pending review. `<Esc>` in normal mode leaves the box open as a draft, and `q` cancels. GitHub posts a reply at once only if you have no pending review. A reply in your pending review has the `[pending]` tag, until you submit the review. If GitHub does not add the reply, the error shows. The next `reply` to the same thread starts with your text.

After a resolve, the thread is dim in the panel and at its line, and it is folded. If GitHub does not let you do the action, a message shows. For example, GitHub does not let you resolve a thread of your pending review.

`submit` opens a float for the body of the review, with the verdict and the pull request as the title. Type the body, then press `<C-s>` to submit, or `q` in normal mode to cancel. An approval does not need a body. A comment or a request for changes needs a body, or a pending comment. A comment that you posted at once does not count. With no pending review, `submit` gives a review with only the body. GitHub does not let you approve your own pull request or request changes on it. If GitHub does not submit the review, the error shows. The next `submit` starts with your text.

`discard` shows your pending comments in the preview of the picker. After you confirm, didymus deletes the pending review, and its comments go away.

After a submit or a discard, didymus gets the threads again. The review stays open.

`refresh` gets the pull request and its threads again, for example after a comment on github.com. Then the files panel and the threads in the files show the new data. A message shows when the refresh starts and when it ends. If the pull request has a new head, a warning shows, and didymus does not check it out. To check out the new head, close the review and open it again.

The highlight groups are `DidymusThread` (default: `DiagnosticInfo`), `DidymusThreadBorder` (default: `DidymusThread`), `DidymusThreadResolved` (default: `Comment`), `DidymusThreadPending` (default: `DiagnosticHint`) and `DidymusFileViewed` (default: `Comment`).

`close` does not check out the branch from before the review. Its message names that branch. `:tabclose` of the review tabpage also closes the review.

There are no default keymaps. For example:

```lua
vim.keymap.set("n", "<leader>ro", "<Plug>(didymus-review-open)")
vim.keymap.set("n", "<leader>rc", "<Plug>(didymus-review-close)")
vim.keymap.set("n", "<leader>rf", "<Plug>(didymus-review-files)")
vim.keymap.set("n", "<leader>rz", "<Plug>(didymus-review-fold)")
vim.keymap.set("n", "<leader>rZ", "<Plug>(didymus-review-fold-all)")
vim.keymap.set("n", "<leader>ri", "<Plug>(didymus-review-focus)")
vim.keymap.set("n", "<leader>rnt", "<Plug>(didymus-review-next-thread)")
vim.keymap.set("n", "<leader>rpt", "<Plug>(didymus-review-prev-thread)")
vim.keymap.set("n", "<leader>rnf", "<Plug>(didymus-review-next-file)")
vim.keymap.set("n", "<leader>rpf", "<Plug>(didymus-review-prev-file)")
vim.keymap.set("n", "<leader>rnh", "<Plug>(didymus-review-next-hunk)")
vim.keymap.set("n", "<leader>rph", "<Plug>(didymus-review-prev-hunk)")
vim.keymap.set({ "n", "x" }, "<leader>rm", "<Plug>(didymus-review-comment)")
vim.keymap.set("n", "<leader>rr", "<Plug>(didymus-review-reply)")
vim.keymap.set("n", "<leader>rx", "<Plug>(didymus-review-resolve)")
vim.keymap.set("n", "<leader>rs", "<Plug>(didymus-review-submit)")
vim.keymap.set("n", "<leader>rd", "<Plug>(didymus-review-discard)")
vim.keymap.set("n", "<leader>rR", "<Plug>(didymus-review-refresh)")
vim.keymap.set("n", "<leader>rv", "<Plug>(didymus-review-viewed)")
```

| Mapping | Modes |
| --- | --- |
| `<Plug>(didymus-review-open)`, `<Plug>(didymus-review-close)`, `<Plug>(didymus-review-files)`, `<Plug>(didymus-review-fold)`, `<Plug>(didymus-review-fold-all)`, `<Plug>(didymus-review-focus)`, `<Plug>(didymus-review-reply)`, `<Plug>(didymus-review-resolve)`, `<Plug>(didymus-review-submit)`, `<Plug>(didymus-review-discard)`, `<Plug>(didymus-review-refresh)`, `<Plug>(didymus-review-viewed)` | Normal |
| `<Plug>(didymus-review-next-thread)`, `<Plug>(didymus-review-next-file)`, `<Plug>(didymus-review-next-hunk)`, `<Plug>(didymus-review-prev-thread)`, `<Plug>(didymus-review-prev-file)`, `<Plug>(didymus-review-prev-hunk)` | Normal |
| `<Plug>(didymus-review-comment)` | Normal, visual |

To check snacks.nvim and `gh`, run `:checkhealth didymus`.

`review.picker_config` sets the picker options of each kind of list. In each kind, the options of an adapter go under its name, such as `snacks`:

| Kind | List | snacks default |
| --- | --- | --- |
| `changes` | The pull request list. | The `default` preset: a float with the list on the left and the description on the right. |
| `choice` | A question, such as "Uncommitted changes. Check out #12?". | The `select` preset: a small float. It hides the preview. Press `<a-p>` to show it. |
| `files` | The files panel. | The `sidebar` preset, with the preview in the code window. |

For example, show the pull request list at the bottom, and make the files panel wider:

```lua
require("didymus").setup({
  review = {
    picker_config = {
      changes = { snacks = { layout = { preset = "ivy" } } },
      files = { snacks = { layout = { layout = { width = 50, min_width = 50 } } } },
    },
  },
})
```

didymus merges your options over the default of the kind. You cannot change the options that didymus needs, such as `items`, `format` and `confirm`.

The defaults:

```lua
require("didymus").setup({
  review = {
    picker = "snacks", -- "snacks", "test" for tests, or an adapter table
    picker_config = {}, -- the options of each kind of list, for each adapter
    provider = "github", -- "github", "test" for tests, or a provider table
    icons = { active = "💬", resolved = "✅" }, -- the state of a thread. "" shows no icon.
    panel = { keys = { toggle_active = "a", refresh = "R", viewed = "v" } }, -- the files panel. false turns off a key
    input = { -- the inline box of comment and reply, and the float of submit
      width = 60, -- for the submit float: below 1 is a fraction of the window width
      max_height = 10, -- the box grows to this height, then it scrolls
      -- post: comment or reply now, or submit. add: add to the pending review. cancel is in normal mode.
      keys = { post = "<C-s>", add = "<C-y>", cancel = "q" },
    },
    thread = { -- a focused inline thread, or a thread split
      keys = { reply = "r", resolve = "x", fold = "z" }, -- false turns a key off
    },
  },
})
```

## Diff

The review tabpage shows the diff of the pull request on the real file, in the code window. The base is the merge-base of the pull request. The head is the file in your checkout. The default diff provider is [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim). It shows the signs, and the deleted lines in the code window.

| Command | Behavior |
| --- | --- |
| `:Didymus diff toggle` | Show or hide the diff in the review tabpage. |
| `:Didymus diff layout [inline\|split]` | Set the layout of the diff. With no argument, change to the other layout. |
| `:Didymus diff side [both\|base\|head]` | Show both sides, only the base side, or only the head side. With no argument, go to the next sides: `both`, `head`, `base`. |
| `:Didymus diff next`, `:Didymus diff prev` | Go to the next or the previous hunk of the diff, also in a different file. |

The diff shows when the review opens, and follows the code window: after `<CR>` in the files panel, `gd`, `gf` or `:e` to a file of the pull request, the diff shows for that file. Other windows show only the gitsigns signs.

A deleted file always shows its base, with all lines in the `DiffDelete` highlight. The `inline` layout shows the base in the code window. The `split` layout shows the base in the base window, and an empty buffer in the code window. The focus goes to the base. `side` on a deleted file applies to the next file. When the diff hides, the base stays in the code window until it shows a different buffer.

When the cursor moves in the files panel, the preview over the code window shows the file with its diff. The preview is always `inline`, and with the `head` side it shows only the signs. The preview shows the file and its diff at the same time. After the review opens, didymus loads the files of the change in the background, one at a time, in the order of the panel, up to `diff.preload` (30) files. The file under the cursor goes first. If a file is not ready, the preview keeps the last file until it is. The diff goes away when the panel loses the focus. `next` and `prev` do not use the preview.

The preload opens the real files, so their `FileType` autocommands and your LSP servers start for each preloaded file. When the review closes, didymus unloads the files that only the preload opened. A file that you opened stays open. Above `diff.preload`, didymus unloads the file that the preview used last.

In a different tabpage, `toggle`, `layout`, `side`, `next` and `prev` go to the review tabpage first. With no review, a warning shows.

The `inline` layout shows the deleted lines in the code window. The `split` layout shows the base of the file in the base window, on the left of the code window, in the diff mode of Neovim. The base window is read-only. It follows the code window, and closes when the code window shows a file that is not in the pull request. If you close the base window, or open a different buffer in it, the layout changes to `inline`. `layout` of a hidden diff shows the diff.

The `head` side shows only the code window, with the signs of the added and changed lines. The `base` side shows the base of the file in the code window, with the deleted lines in the `DiffDelete` highlight. The base buffer is read-only, and has no LSP and no threads. Both of them ignore the layout, so the base window closes. `both` opens it again. When the side changes, the cursor goes to the matching line of the other side. `side` of a hidden diff shows the diff.

The `base` side is temporary. `next` and `prev` keep it, and show the base of the next file. Any other buffer in the code window ends it, for example `<CR>` in the files panel. Then the side goes back to the value before `base`. A comment needs the head side, so `:Didymus review comment` on the base side shows a warning.

In the `split` layout, Neovim computes the diff of the two windows with your `'diffopt'`. So the diff mode can show a hunk a little differently from the gitsigns signs. When the diff hides or the layout changes, didymus puts back the window options that the diff mode changed, such as `'foldmethod'` and `'wrap'`.

`next` and `prev` move the cursor in the code window. In the base window, they move the cursor of the base window, to the base lines of the hunks. With the `base` side, they use the base lines in the code window. At the last hunk of a file, `next` goes to the first hunk of the next file with hunks, in the order of the files panel. `prev` goes to the last hunk of the previous file. They skip a file with no hunks, such as a binary file. They stop at the first line of a deleted file. The stop of a deletion is the line after the deleted lines. At the last or the first hunk, a message shows, and the cursor does not move. `<C-o>` goes back to the position before the jump. A hidden diff has no hunks, so a message shows.

`:Didymus review next hunk` uses the hunks of GitHub, where you can comment. `:Didymus diff next` uses the hunks of the diff provider, one for each change.

The diff shows your local changes too. If `HEAD` is not the head of the pull request, or a file of the pull request has uncommitted changes, a warning shows one time in each review. Then the diff is not the diff of GitHub.

While the diff shows, gitsigns compares each file that you opened in the review with the merge-base. Its signs show this diff also in other tabpages. When the diff hides, or the review closes, didymus puts back the base of your gitsigns config.

If the diff is not available, a warning tells why, and the review works with no diff. For example, gitsigns.nvim is not installed, or git found no merge-base.

There are no default keymaps. For example:

```lua
vim.keymap.set("n", "<leader>dt", "<Plug>(didymus-diff-toggle)")
vim.keymap.set("n", "<leader>dl", "<Plug>(didymus-diff-layout)")
vim.keymap.set("n", "<leader>ds", "<Plug>(didymus-diff-side)")
vim.keymap.set("n", "<leader>dn", "<Plug>(didymus-diff-next)")
vim.keymap.set("n", "<leader>dp", "<Plug>(didymus-diff-prev)")
```

`<Plug>(didymus-diff-toggle)`, `<Plug>(didymus-diff-layout)`, `<Plug>(didymus-diff-layout-inline)`, `<Plug>(didymus-diff-layout-split)`, `<Plug>(didymus-diff-side)`, `<Plug>(didymus-diff-side-both)`, `<Plug>(didymus-diff-side-base)`, `<Plug>(didymus-diff-side-head)`, `<Plug>(didymus-diff-next)` and `<Plug>(didymus-diff-prev)` are normal mode mappings. `<Plug>(didymus-diff-layout)` changes to the other layout. `<Plug>(didymus-diff-side)` goes to the next sides. To check gitsigns.nvim, run `:checkhealth didymus`.

The defaults:

```lua
require("didymus").setup({
  diff = {
    provider = "gitsigns", -- "gitsigns", "test" for tests, or a provider table
    enabled = true, -- the diff shows when a review opens
    layout = "inline", -- "inline" or "split"
    sides = "both", -- "both" or "head". Only `:Didymus diff side base` shows the base side.
    split = { width = 0.5 }, -- the width of the base window: below 1, a fraction of the code window, else columns
    preload = 30, -- the most files that load in the background for the preview of the files panel
  },
})
```

## Contributing

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE)
