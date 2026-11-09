# didymus.nvim

Review pull requests in Neovim. Read the real code with full LSP, comment on the PR, and talk to an AI agent in one place.

> [!WARNING]
> **Early development.** Only the agent works now.

## Goals

- Show the real files from the PR, so LSP and normal navigation work.
- Read, write and resolve review comments in Neovim.
- Run an agent CLI of your choice next to the code, and ask it about selected code.
- Let users replace the integrations (code host, agent, diff display) with their own.

## Requirements

- Neovim 0.12+
- `git`

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
| `:[range]Didymus agent send [text]` | Open a float for a prompt about the current line or the range. On submit, send the prompt and the code. The agent stays hidden. |

`toggle float` shows or hides the float. If the split is visible, it closes, and the same agent shows in the float. `toggle split` does the same for the split. `toggle` with no view uses the last view, then `agent.view`.

The float hides when you go to a different window. The agent continues. The inside of the float has the `DidymusAgentFloat` highlight, which links to `Normal`.

**Append** puts the location and the code in the agent input, and does not submit. You type the rest of the prompt in the agent.

**Send** opens a float above the code. Type the prompt, then press `<C-y>` to send it. `<CR>` adds a line. `q` or `<Esc>` in normal mode cancels. With `[text]`, send submits at once, with no float. To read the answer, show the agent.

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
      keys = { submit = "<C-y>", cancel = "q" },
    },
    terminal = {
      ready_delay = 500, -- ms to wait after the first output of the agent, before input
      submit_delay = 50, -- ms to wait after the prompt text, before the Enter key
    },
  },
})
```

## Contributing

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE)
