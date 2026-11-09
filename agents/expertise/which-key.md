# which-key.nvim

Facts about which-key.nvim that are tricky and not well documented. For the rules, see [`README.md`](README.md).

## Visual mode

### A key that comes with the start of visual mode stops the triggers

In visual and operator-pending mode, which-key starts on `ModeChanged`. If a key is in the typeahead at that time, which-key suspends its triggers until the next event loop. Neovim reads that key before the triggers come back. So if `<leader>` comes in the same input as `V`, Neovim waits `'timeoutlen'`, and after a longer pause `<leader>` runs alone. The mapping of the user does not run, and a plugin cannot fix it. In manual tests, start visual mode first, then press `<leader>`.

- Proof: `M.safe()` in [`lua/which-key/state.lua`](https://github.com/folke/which-key.nvim/blob/3aab2147e74890957785941f0c1ad87d0a44c15a/lua/which-key/state.lua#L24-L38) calls `getcharstr(1)`, and the `ModeChanged` callback then suspends the triggers. A check with a real TUI is in [didymus.nvim#12](https://github.com/nickciaravella/didymus.nvim/issues/12#issuecomment-6729013542).
- Checked: which-key.nvim `3aab214`, Neovim 0.12.5
