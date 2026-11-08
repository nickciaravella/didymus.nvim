---
name: herdr-parallel-work
description: Work on more than one didymus.nvim issue at the same time in the Herdr app. Each issue gets a git worktree, a Herdr space and a worker agent. Use when the user asks to start parallel work in Herdr, to check the workers, or to clean up after a worker's pull request merges.
---

# Parallel work in Herdr

Use this skill from a Claude session in the Herdr app, in the main checkout. You start the workers, check them, and clean up after each merge. The user approves their plans and answers their questions.

Use `herdr-app` for spaces and tabs. Use `hc` to read, label and send text to terminals. For the full manuals, run `herdr-app --skill` and `hc --skill`.

## Settings

| Setting | Value |
| --- | --- |
| Worktree | `../didymus.nvim-worktrees/<issue>-<slug>`. The slug is two or three words from the issue title. |
| Branch | `<type>/<slug>`, for example `feat/input-float`. |
| Space | `#<issue> <slug words>`, with one tab, `Implement`. |
| Worker | `claude --model claude-opus-5-5 --effort high --permission-mode <mode>`. Use the permission mode of this session. |
| Labels | `didymus.role=worker didymus.issue=<issue> didymus.branch=<branch>` on the worker terminal. |

## Rules

- Start a worker only when the dependencies of its issue are merged. See the work plan in the architecture doc of the epic.
- Do not answer the questions of a worker. The user does this. Merge only when the user asks.
- Close only the spaces and terminals that have the `didymus.role` label.

## Start a worker

1. Make the worktree. Use the commands in `docs/DEVELOPMENT.md` ("Work in a worktree").
2. Write the task from the template below. Put it in a quoted heredoc, because in double quotes the backticks run as commands.
3. Start the space. Give the arguments as one JSON object, so that the task needs no more shell quotes:

   ```sh
   herdr-app do space.new "$(jq -n --arg name "#6 input float" --arg folder "$worktree" --arg task "$task" \
     '{name: $name, folder: $folder, tab: "Implement", task: $task,
       argv: ["claude", "--model", "claude-opus-5-5", "--effort", "high", "--permission-mode", "auto"]}')"
   ```

   The output gives the `space`, the `tab` and the `terminal`.
4. Label the terminal: `hc label <terminal> didymus.role=worker didymus.issue=<issue> didymus.branch=<branch>`.
5. Make sure that the agent started. `hc get <terminal> --json` must show `claude-code` and the worktree as `cwd`.

The task template:

```text
Work on issue #<issue> in this worktree, `<worktree>`, on branch `<branch>`. The branch has no upstream, so the first push is `git push -u origin <branch>`. Follow `AGENTS.md`: read the issue and the architecture doc, then give me a short plan with the decisions that the issue does not make. Wait for my approval before you write code. Another agent works on #<other issue> (<title>) at the same time. You can both change <shared files>. Follow the "Parallel work" rules in `AGENTS.md`. Do not merge the pull request. Do not start other issues or agents.
```

Write one "Another agent" sentence for each other worker. Find the shared files in the scope of the issues.

## Check the workers

```sh
hc ls --json --label didymus.role=worker            # the workers and their status
hc read <terminal> --lines 40                        # the screen of one worker
gh pr list --head <branch> --state all --json number,state
```

A worker with the status `blocked` or `done` waits for the user. Tell the user the name of its space.

## After a merge

1. Find the space in the `herdr.space` label: `hc get <terminal> --json | jq .labels`.
2. Make sure that the space has only labeled terminals. List them with `herdr-app ls`. Check the labels of each one with `hc get`. If the user added a terminal, do not close the space, and tell the user.
3. Close the space: `herdr-app do space.close --id <space> --confirmed true`. Then end the worker: `hc kill <terminal>; hc rm <terminal>`.
4. Remove the worktree and the branch. Use the commands in `docs/DEVELOPMENT.md`. If `git worktree remove` refuses because of changes, keep the worktree and tell the user. Do not use `--force`.
5. Update the main checkout: `git pull`.
6. Tell each other worker that `main` moved. Skip a `blocked` worker. It gets the notice at the next check.

   ```sh
   notice=$(cat <<'EOF'
   `main` moved: <title> (#<PR>) merged. Follow the "Parallel work" rules in `AGENTS.md`: rebase on `origin/main`, or merge it if your pull request is open. Run `make test`. Then continue your work.
   EOF
   )
   hc send <terminal> "$notice"
   ```
