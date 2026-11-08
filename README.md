# didymus.nvim

Review pull requests in Neovim. Read the real code with full LSP, comment on the PR, and talk to an AI agent in one place.

> [!WARNING]
> **Early development.** Only the agent split works now.

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

Run an agent CLI, such as Claude Code or Codex, in a split on the right.

| Command | Behavior |
| --- | --- |
| `:Didymus agent toggle [split] [cmd]` | Show the agent, or hide it. Start it if it does not run. |
| `:Didymus agent start [cmd]` | Start the agent, but do not show it. |
| `:Didymus agent stop` | End the agent and close its split. |

`[cmd]` overrides `agent.cmd`. If the agent runs, didymus does not use `[cmd]`. To change the agent, stop it first.

There are no default keymaps. For example:

```lua
vim.keymap.set({ "n", "t" }, "<M-a>", "<Plug>(didymus-agent-toggle)")
```

The mappings are `<Plug>(didymus-agent-toggle)`, `<Plug>(didymus-agent-start)` and `<Plug>(didymus-agent-stop)`.

The defaults:

```lua
require("didymus").setup({
  agent = {
    cmd = "claude", -- a string runs through 'shell'
    backend = "terminal", -- "terminal", or "test" for tests
    split = { width = 0.4 }, -- below 1 is a fraction of the editor width
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
