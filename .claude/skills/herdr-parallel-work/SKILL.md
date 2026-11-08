---
name: herdr-parallel-work
description: Work on more than one didymus.nvim issue at the same time in the Herdr app. Each issue gets a git worktree, a Herdr space and a worker agent. Use when the user asks to start parallel work in Herdr, to check the workers, to merge the pull request of a worker, or to clean up after a merge.
---

# Parallel work in Herdr

Use this skill from a Claude session in the Herdr app, in the main checkout. You are the orchestrator. You start the workers, check them, merge their pull requests, and clean up. The user approves the plans, answers the questions, and tells you when to merge.

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

- Start a worker only when the dependencies of its issue are merged. See the `Needs:` line of the issue, and the work plan in the architecture doc of the epic, if it has one.
- Do not answer the questions of a worker. The user does this.
- Merge a pull request only when the user tells you that it is ready. Workers do not merge.
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
Work on issue #<issue> in this worktree, `<worktree>`, on branch `<branch>`. The branch has no upstream, so the first push is `git push -u origin <branch>`. Follow `AGENTS.md`: read the issue and the architecture doc of its epic, if it has one. Then give me a short plan with the decisions that the issue does not make. Wait for my approval before you write code. Another agent works on #<other issue> (<title>) at the same time. You can both change <shared files>. Follow the "Parallel work" rules in `AGENTS.md`. When you finish and give me a summary, start it with a short description of the issue. Do not merge the pull request. Do not start other issues or agents.
```

Write one "Another agent" sentence for each other worker. Find the shared files in the scope of the issues.

## Check the workers

```sh
hc ls --json --label didymus.role=worker            # the workers and their status
hc read <terminal> --lines 40                        # the screen of one worker
gh pr list --head <branch> --state all --json number,state
```

A worker with the status `blocked` or `done` waits for the user. Tell the user the name of its space.

## Merge a pull request

Do these steps when the user tells you that a pull request is ready. If a check fails, do not merge, and tell the user.

1. Make sure that CI passed: `gh pr checks <PR>`.
2. Make sure that the worker is `done`.
3. Make sure that the worktree has no changes, and that all its commits are pushed: `git -C <worktree> status -sb`. The merge deletes the worktree. If a terminal of the user is in the worktree, ask the user before you merge. The Neovim of the test tab is in the worktree, so close the test tab first. See "Close the test tab" in the `herdr-manual-test` skill.
4. Merge: `gh pr merge <PR> --squash --delete-branch`. This deletes the remote branch, the local branch and the worktree.
5. Do the steps in "After a merge".

## After a merge

Do these steps also when the user merges a pull request.

1. If the test tab of the issue is open, close it. See "Close the test tab" in the `herdr-manual-test` skill.
2. Find the space and the tab in the `herdr.space` and `herdr.tab` labels: `hc get <terminal> --json | jq .labels`.
3. Find the terminals of the space with `herdr-app ls`. Check the labels of each one with `hc get`.
4. If the space has only labeled terminals, close it: `herdr-app do space.close --id <space> --confirmed true`. If the user added a terminal, close only the tab of the worker: `herdr-app do tab.close --id <tab> --confirmed true`. Tell the user.
5. End the worker: `hc kill <terminal>; hc rm <terminal>`.
6. If the worktree or the local branch still exists, remove it. Use the commands in `docs/DEVELOPMENT.md`. If `git worktree remove` refuses because of changes, keep the worktree and tell the user. Do not use `--force`.
7. Update the main checkout: `git pull`.
8. Tell each other worker that `main` moved. Skip a `blocked` worker. It gets the notice at the next check.

   ```sh
   notice=$(cat <<'EOF'
   `main` moved: <title> (#<PR>) merged. Follow the "Parallel work" rules in `AGENTS.md`: rebase on `origin/main`, or merge it if your pull request is open. Run `make test`. Then continue your work.
   EOF
   )
   hc send <terminal> "$notice"
   ```
