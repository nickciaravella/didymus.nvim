# AGENTS.md

Rules and references for AI agents that work on didymus.nvim.

## Documents

| Document | Contents |
| --- | --- |
| [`README.md`](README.md) | The user view. |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Decisions, open questions, code structure. |
| [`docs/TESTING.md`](docs/TESTING.md) | How to run and write tests. |
| [`docs/TASK_TRACKING.md`](docs/TASK_TRACKING.md) | Epics, labels and issues. |
| [`docs/GLOSSARY.md`](docs/GLOSSARY.md) | Key terms. |
| [`docs/architecture/agent.md`](docs/architecture/agent.md) | The design and work plan of the `agent` epic. |
| [`docs/reference/design-prompt.md`](docs/reference/design-prompt.md) | The reference file. See below. |
| [`agents/expertise/`](agents/expertise/README.md) | The notebooks: facts about the technologies of the project. See "Notebooks" below. |

### The reference file

The reference file is a first pass at the design. It is not a spec.

- Use it to learn about the goals and the problems of the project.
- Do not implement a detail from it before the user agrees to that detail.
- Record each decision in `docs/DEVELOPMENT.md`.

## Project rules

1. Neovim 0.12 is the minimum version. If a feature needs a later version, tell the user and record it.
2. Do not use deprecated Neovim APIs.
3. Do not block the UI.
4. Examine external APIs against the live schema or the installed source. Do not trust memory for API shapes.
5. Update the docs in the same change as the code.
6. Add end-to-end tests for each feature. Add unit tests only for real logic. See `docs/TESTING.md`.
7. Do infrastructure work only when an epic needs it. See `docs/TASK_TRACKING.md`.

## Notebooks

Each notebook in `agents/expertise/` keeps the tricky facts about one technology, such as `neovim.md`.

1. When you work with a technology, scan the headings of its notebook: `grep -n '^##' agents/expertise/neovim.md`.
2. Read each entry whose heading applies to your work.
3. When a tricky fact about a technology took effort to find, add an entry. See [`agents/expertise/README.md`](agents/expertise/README.md).

Do not keep these facts in a local memory, such as the Claude Code auto memory. A local memory is only for the preferences of one user.

## Commands

| Task | Command |
| --- | --- |
| Run all tests | `make test` |
| Run unit or end-to-end tests | `make test-unit`, `make test-e2e` |
| Run one test file | `make test-file FILE=tests/e2e/startup.test.lua` |
| Format | `make fmt` |
| Check the format | `make fmt-check` |

## Writing rules (STE100)

Use **ASD-STE100 Simplified Technical English** for all text: docs, comments, names, user messages, commit messages, pull requests, and messages to the user.

### General

Be concise and simple. Only write code, comments or documentation that is useful. Do not over-explain when a simpler solution will be as effective.

### Words

1. Use simple, common words. Use each word with one meaning only. Write "start", not "launch". Write "use", not "utilize".
2. Use the same word for the same thing. Use the terms in `docs/GLOSSARY.md`.
3. Technical names and verbs are permitted: `extmark`, `worktree`, `fetch`, `parse`.
4. Do not use slang, idioms or contractions.
5. Do not use noun clusters of more than three words.

### Sentences

1. Write instructions in the imperative, with one instruction in each sentence.
2. Use the active voice and simple tenses (present, past, future).
3. Do not use the "-ing" form of a verb, except in technical names.
4. Keep instructions to 20 words or fewer, and descriptions to 25 words or fewer.
5. Put a warning before the instruction that it applies to.

### Paragraphs

1. Start with the topic sentence. Use six sentences or fewer.
2. Use numbered lists for steps, bullet lists for items, and tables for data that you compare.

### Code

1. Use full words in names: `commentable_ranges`, not `cmt_rngs`. Common Neovim short forms are permitted: `buf`, `win`, `opts`, `cb`, `err`.
2. Start function names with a verb.
3. Write a comment only to tell why. The code tells what.

## Before you start

1. Read the issue and the architecture doc of its epic, if the epic has one. See `docs/TASK_TRACKING.md`.
2. Scan the notebooks of the technologies that the task uses. See "Notebooks".
3. Give the user a short plan. List the decisions that the issue does not make.
4. If the issue and the architecture doc do not agree, ask the user.
5. If a decision changes the scope of another open issue, update that issue.

## Before you finish

1. Run `make test` and `make fmt-check`.
2. Prepare the manual test for each change that a person can see. See "Manual tests" below.
3. Use the `submit-pr` skill (`.claude/skills/submit-pr/SKILL.md`) to open a pull request.
4. Merge a pull request only when the user asks. Use a squash merge after CI passes.

### Manual tests

Do as much of the setup as you can, so that the user only does the test. See [`docs/TESTING.md`](docs/TESTING.md#manual-tests).

1. Write the setup in `.manual-test/setup.lua`: the options and the keys for the test.
2. Use the fake agent. Use the real agent only if a step needs it.
3. Make sure that Neovim loads didymus.nvim from your worktree.
4. If `HC_TERMINAL_ID` is set, open the test tab with the `herdr-manual-test` skill.
5. Else, give the user the command that starts Neovim, with the files and lines of the test.
6. Give the user the checklist: each step and its expected result.

## Parallel work

Agents can work on different issues at the same time. Each agent works in its own worktree. See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md#work-in-a-worktree).

1. Change only the files in your worktree.
2. Before you open a pull request, rebase on `origin/main`. Then run `make test` and `make fmt-check`.
3. If `main` changes after you open the pull request, merge `origin/main` into your branch. Do not force push.
