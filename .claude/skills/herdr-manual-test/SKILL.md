---
name: herdr-manual-test
description: Open the manual test of a didymus.nvim change in a new Herdr tab, and close that tab later. Use when you prepare a manual test and HC_TERMINAL_ID is set, or when you close the test tab of an issue, for example after a merge.
---

# Manual tests in Herdr

Use this skill after you write `.manual-test/setup.lua` and check the start command. See "Manual tests" in `AGENTS.md`.

## Settings

| Setting | Value |
| --- | --- |
| Tab | `Manual test`, in the space of your terminal. |
| Socket | `${XDG_RUNTIME_DIR:-/tmp}/didymus-manual-test-<issue>.sock`. It is outside the worktree, so that the cleanup works after the worktree is removed. |
| Labels | `didymus.role=manual-test didymus.issue=<issue> didymus.branch=<branch>` on the terminal of the tab. |

## Open the test tab

1. Find the space of your terminal:

   ```sh
   space=$(hc get "$HC_TERMINAL_ID" --json | jq -r '.labels["herdr.space"] // empty')
   ```

   If `space` is empty, you are not in the Herdr app. Give the user the command, as outside Herdr.
2. If a test tab of the issue is open, close it. See "Close the test tab".
3. Open the tab. The `argv` is the start command with `--listen`. A tab does not use a shell, so set `DIDYMUS_DIR` with `env`:

   ```sh
   sock="${XDG_RUNTIME_DIR:-/tmp}/didymus-manual-test-<issue>.sock"
   herdr-app do tab.new "$(jq -n --arg space "$space" --arg dir "$PWD" --arg sock "$sock" \
     --argjson files '["lua/didymus/agent/init.lua", "+42"]' \
     '{name: "Manual test", space: $space, folder: $dir,
       argv: (["env", "DIDYMUS_DIR=" + $dir, "nvim", "--listen", $sock, "-S", ".manual-test/setup.lua"] + $files)}')"
   ```

   The output gives the `terminal`.
4. Label the terminal: `hc label <terminal> didymus.role=manual-test didymus.issue=<issue> didymus.branch=<branch>`.
5. Make sure that Neovim started. `nvim --server "$sock" --remote-expr 'v:servername'` must print the socket. `hc read <terminal> --lines 10` shows the screen.
6. Tell the user the name of the tab. Then give the checklist.

## Close the test tab

Warning: the user can have unsaved changes in the test Neovim. Check before you close it.

1. Find the terminal: `hc ls --json --label didymus.role=manual-test --label didymus.issue=<issue> | jq -r '.terminals[].address'`. If there is none, stop.
2. Find the buffers with unsaved changes. Empty output means none:

   ```sh
   timeout 5 nvim --server "${XDG_RUNTIME_DIR:-/tmp}/didymus-manual-test-<issue>.sock" --remote-expr 'execute("ls +")'
   ```

3. If there are unsaved changes, tell the user the buffers. Close the tab only when the user agrees.
4. Find the tab in the `herdr.tab` label: `hc get <terminal> --json | jq -r '.labels["herdr.tab"]'`.
5. If the tab has only the test terminal, close it: `herdr-app do tab.close --id <tab> --confirmed true`. If the user added a terminal to the tab, keep the tab.
6. End the terminal: `hc kill <terminal>; hc rm <terminal>`.
