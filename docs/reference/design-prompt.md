> **Reference file. Not a spec. It will be deprecated.**
> Use it to learn about the project. Do not implement its details before we decide on them.
> The decisions are in [`docs/DEVELOPMENT.md`](../DEVELOPMENT.md).

# didymus.nvim — design prompt for Claude Code

Nov 7, 2026 · @Nick

## How to work on this

You are building didymus.nvim, a Neovim plugin for reviewing pull requests against the real checked-out code, with an AI agent in a side panel. Treat this doc as the spec, but challenge anything that looks wrong.

1. Read the whole doc before writing any code.
2. Ask me the open questions at the end, plus any of your own, in one batch.
3. Propose the module layout and the exact interface signatures as Lua files containing only LuaCATS annotations. Wait for my approval.
4. Build in the phases listed below. Each phase ends with passing tests and a short manual checklist I can run against a real PR.
5. Verify every `gh` command, GraphQL query, mutation and gitsigns function against the live schema or installed source before relying on it. Do not trust memory for API shapes.
6. Keep adapters swappable: core code never `require`s a concrete adapter module. Only the registry does.

## What it must do

One command opens a PR review in its own tabpage: files and threads on the left, the real file in the middle, an agent CLI on the right. The user reads code with full LSP, comments on GitHub, and talks to an agent in one continuous thread.

1. **Pick a PR.** `:Didymus` lists open PRs for the current repo through `vim.ui.select`, so any picker plugin works. `:Didymus open 123` or a PR URL skips the picker.
2. **Side panel.** The left window shows a PR header (title, author, base ← head, state), then the changed files with status, +/− counts, viewed state and thread count. Files expand to show their threads. A separate section lists general PR comments.
3. **Real file at the first hunk.** Selecting a file opens the actual file from the PR workspace, not a scratch buffer of a revision. Hunks against the merge-base are shown on it and the cursor lands on the first one. LSP, `gd`, references and `gf` work normally. Reaching another changed file by any route (LSP, `gf`, `:e`) still shows its hunks.
4. **Comments.** Threads render inline at their lines. The user can add a line or range comment, reply, resolve or unresolve, and submit the review as approve, comment or request changes. New comments go into a pending review.
5. **Agent panel.** The right window runs an agent (Claude Code, Codex, Copilot CLI, pi, or any configured command) with the PR workspace as its working directory. It lives for the whole review session.
6. **Ask about a selection.** Visual-select code, run `:Didymus ask`, type a question. The question plus the path, line range and code goes to the same agent session, and focus moves to the agent panel.
7. **Links back.** File references in the agent panel (`path:line`, `path:line:col`, `path:start-end`, `path#L10-L20`) jump the main window to that location on `<CR>` or `gf`.

## Architecture

A host-agnostic core owns state, layout and UI. Everything else plugs in through three extension points, and every concrete integration is an adapter behind one of them.

| Extension point | Responsibility | v1 adapters | Adapters others could add |
| --- | --- | --- | --- |
| `review` | Change data and review actions: changes, files, threads, comments, verdicts | `github` (via `gh`), `delegate` | `local` (git diff, comments stored on disk), `gitlab`, `gerrit` |
| `agent` | Running an agent and carrying the conversation | `terminal`, `delegate` | `acp`, `tmux` |
| `diff` | Showing hunks on the real buffer and navigating them | `gitsigns`, `delegate` | `extmarks` (own renderer), `mini.diff` |

Ownership boundaries:

- **Core owns** the session state, the event bus, the tabpage layout and window placement, the files panel, inline thread rendering, the comment composer, the local git workspace, prompt construction, and navigation (`core.navigate(location)`).
- **Adapters own** only their external system. They never create windows, never read session state directly, and never call each other.
- **Agent adapters may own a buffer, never a window.** Core places the buffer in the right-hand window. Link parsing lives in the adapter, since only it knows its output format, but jumps go through `ctx.navigate`.
- **Commentable lines come from the review adapter, not the diff adapter.** The host's own patch decides which lines accept comments. The diff adapter is display-only.
- **The local workspace is core.** The review adapter says where the code comes from (`source`: fetch a ref, or use the local checkout), and core does the git work.
- **Shared utilities are fine.** Adapters may use pure helpers such as `didymus.patch`, `didymus.prompt` and `didymus.async`. They may not reach into session or UI modules.

The registry is generic. Each extension point is a spec (required methods, optional methods, known capability keys), so adding a fourth extension point later means writing a spec, not changing the registry. Built-in adapters register through the same public `register()` call as third-party ones, and core has no private path to them.

## Data model

All adapters speak these types. A change is whatever the review adapter reviews: a GitHub PR, a GitLab MR, or a local branch diff. Host IDs are opaque strings, and lines are 1-based on the head version unless `side` says otherwise.

```lua
---@alias didymus.Side "head"|"base"
---@alias didymus.Callback fun(err: string?, result: any)

---@class didymus.ChangeRef
---@field adapter string          -- review adapter name, e.g. "github"
---@field repo string?            -- "owner/name"; nil for local
---@field id string               -- PR number, MR iid, or a local range like "main...HEAD"

---@class didymus.ChangeSummary
---@field ref didymus.ChangeRef
---@field title string
---@field author string?
---@field updated_at string?
---@field is_draft boolean?

---@class didymus.Source            -- where core gets the code under review
---@field kind "fetch"|"local"
---@field remote_url string?      -- fetch: remote to fetch from
---@field ref string?             -- fetch: e.g. "refs/pull/123/head"

---@class didymus.Change : didymus.ChangeSummary
---@field body string
---@field url string?
---@field state "open"|"closed"|"merged"|"local"
---@field base_label string       -- e.g. base branch name
---@field head_label string
---@field base_sha string
---@field head_sha string?        -- nil = include the working tree (local review)
---@field source didymus.Source
---@field files didymus.ChangedFile[]
---@field pending_review_id string?

---@class didymus.ChangedFile
---@field path string
---@field old_path string?        -- renames
---@field status "added"|"modified"|"deleted"|"renamed"
---@field additions integer
---@field deletions integer
---@field viewed boolean?
---@field commentable didymus.Range[]?       -- head lines the host accepts; nil = unknown
---@field commentable_base didymus.Range[]?  -- base lines the host accepts

---@class didymus.Range
---@field start integer           -- inclusive
---@field finish integer          -- inclusive

---@class didymus.Location
---@field path string             -- relative to workspace root
---@field line integer
---@field end_line integer?
---@field col integer?

---@class didymus.Comment
---@field id string
---@field author string
---@field body string             -- markdown
---@field created_at string
---@field pending boolean

---@class didymus.Thread
---@field id string
---@field path string
---@field side didymus.Side
---@field line integer?           -- nil when outdated
---@field start_line integer?
---@field original_line integer?
---@field resolved boolean
---@field outdated boolean
---@field comments didymus.Comment[]

---@class didymus.CommentDraft
---@field path string
---@field side didymus.Side
---@field line integer
---@field start_line integer?
---@field body string
---@field file_level boolean?     -- comment on the file, not a line

---@class didymus.Hunk
---@field start integer           -- buffer line of first added/changed line
---@field count integer           -- 0 for pure deletions
---@field base_start integer
---@field base_count integer

---@class didymus.Attachment
---@field kind "code"|"thread"|"hunk"
---@field location didymus.Location
---@field content string
---@field filetype string?

---@class didymus.AgentPrompt
---@field text string
---@field attachments didymus.Attachment[]
```

## Extension point: review

A review adapter lists changes, reads their files and threads, and performs review actions. Every async method takes a final `cb(err, result)` and never blocks the UI. Methods marked `?` are optional.

```lua
---@class didymus.ReviewAdapter
---@field name string
---@field capabilities table<string, boolean>  -- e.g. { file_comments = true, multiline = true, suggestions = true }
---@field detect fun(self, root: string): boolean   -- can this adapter handle the repo at root?
---@field list_changes fun(self, root: string, opts: { state: string?, query: string? }, cb: didymus.Callback)  -- result: didymus.ChangeSummary[]
---@field get_change fun(self, ref: didymus.ChangeRef, cb: didymus.Callback)         -- result: didymus.Change (files + commentable ranges)
---@field get_threads fun(self, change: didymus.Change, cb: didymus.Callback)        -- result: didymus.Thread[]
---@field add_comment fun(self, change: didymus.Change, draft: didymus.CommentDraft, cb: didymus.Callback)  -- result: didymus.Thread
---@field reply fun(self, change: didymus.Change, thread_id: string, body: string, cb: didymus.Callback) -- result: didymus.Comment
---@field get_general_comments? fun(self, change: didymus.Change, cb: didymus.Callback)  -- result: didymus.Comment[]
---@field begin_review? fun(self, change: didymus.Change, cb: didymus.Callback)      -- create or resume a pending review; result: id
---@field set_resolved? fun(self, change: didymus.Change, thread_id: string, resolved: boolean, cb: didymus.Callback)
---@field submit_review? fun(self, change: didymus.Change, verdict: "approve"|"comment"|"request_changes", body: string?, cb: didymus.Callback)
---@field discard_review? fun(self, change: didymus.Change, cb: didymus.Callback)
---@field set_viewed? fun(self, change: didymus.Change, path: string, viewed: boolean, cb: didymus.Callback)
---@field health? fun(self): table                                              -- checks for :checkhealth
```

- Optional methods mark what an adapter can do, and core hides the commands whose method is absent. `capabilities` covers finer behavior inside required methods, such as file-level or multi-line comments.
- If `begin_review` exists, core calls it before the first draft comment, and later comments land in that pending review. Without it, comments post or save immediately.
- Verdict names are host-neutral. The adapter maps them to the host's terms.
- Errors carry the host's message plus a short summary. Core surfaces them with `vim.notify`.
- A `local` adapter is the design check for this interface. It reviews `main...HEAD` or the working tree, returns `source = { kind = "local" }`, keeps threads under `.git/didymus/`, and has no `submit_review`. If the interface can't support that cleanly, change the interface.

## Extension point: agent

An agent adapter starts one session per review and carries every prompt to it. It may render the conversation into a buffer for the right-hand window, or drive an agent that lives outside Neovim.

```lua
---@class didymus.AgentContext
---@field cwd string                       -- workspace root
---@field primer string                    -- session-opening context built by core
---@field navigate fun(loc: didymus.Location) -- jump the main window
---@field on_exit fun(code: integer)?

---@class didymus.AgentAdapter
---@field name string
---@field capabilities table<string, boolean>  -- e.g. { structured_locations = false, resume = false }
---@field start fun(self, ctx: didymus.AgentContext, opts: table): didymus.AgentSession
---@field health? fun(self): table

---@class didymus.AgentSession
---@field send fun(self, prompt: didymus.AgentPrompt)
---@field buf? fun(self): integer           -- buffer for the agent window; absent = agent lives outside Neovim
---@field focus? fun(self, win: integer)     -- after core shows the buffer, e.g. enter terminal mode
---@field alive fun(self): boolean
---@field stop fun(self)
```

- One session per review session. Every `send` goes to it, so the thread is continuous.
- If the session has no `buf`, core skips the agent window, and `:Didymus ask` confirms with a notification instead. That lets an adapter target a tmux pane or a separate terminal.
- The adapter decides how to deliver `ctx.primer`. The terminal adapter sends it as the first message; an agent with a system-prompt flag could use that.
- `send` receives structured attachments. `didymus.prompt.to_text(prompt)` gives the standard text rendering; an ACP adapter would send resource blocks instead.
- The choice of CLI is configuration on the terminal adapter, not separate adapters:

```lua
agent = {
  adapter = "terminal",
  default = "claude",
  presets = {
    claude  = { cmd = { "claude" } },
    codex   = { cmd = { "codex" } },
    copilot = { cmd = { "copilot" } },
    pi      = { cmd = { "pi" } },
  },
}
```

- If the agent process exits, the panel shows the exit code and offers a restart. A restart is a new thread, and the UI says so.

## Extension point: diff

A diff adapter shows hunks against the merge-base on the real file buffer and moves between them. It is display and navigation only.

```lua
---@class didymus.DiffAttachOpts
---@field root string        -- workspace root
---@field base_rev string    -- merge-base SHA
---@field on_ready fun()?    -- called once hunks are computed

---@class didymus.DiffAdapter
---@field name string
---@field capabilities table<string, boolean>  -- e.g. { inline_deletions = true, word_diff = true }
---@field attach fun(self, bufnr: integer, opts: didymus.DiffAttachOpts)
---@field detach fun(self, bufnr: integer)
---@field hunks fun(self, bufnr: integer): didymus.Hunk[]   -- buffer-relative, current state
---@field goto_hunk fun(self, bufnr: integer, which: "first"|"next"|"prev"|"last")
---@field toggle_deletions? fun(self, bufnr: integer)     -- show removed lines inline
---@field health? fun(self): table
```

- Never used to decide whether a line is commentable.
- Strictly per buffer. Attaching in the review tab must not change diff state for buffers outside it.
- `attach` may compute asynchronously. Core waits for `on_ready` before jumping to the first hunk.
- Core attaches on `BufEnter` for any file under the workspace root that is in `change.files`. That keeps hunks visible after LSP jumps, `gf` and `:e`.

## Extending

Users extend didymus without touching this repo, in three tiers: hooks on core events, a `delegate` adapter configured with functions, or a full adapter module.

**Full adapters.** Any plugin or config can register an adapter for an extension point, then select it:

```lua
require("didymus").register("review", "gitlab", require("didymus-gitlab"))
require("didymus").setup({ review = { adapter = "gitlab" } })
```

`register` validates the module against the extension point's spec and fails at registration, not mid-review. The types ship in `didymus.types` so third-party adapters get LuaLS completion. `didymus.testing` exposes the contract suites so any adapter can check itself.

**Delegate adapters.** Every extension point ships a `delegate` adapter that forwards each interface call to a handler function from config. A handler takes the method's arguments minus `self`, plus a trailing `api` table of core helpers: `navigate`, `notify`, `change` and `fallback`.

```lua
require("didymus").setup({
  agent = {
    adapter = "delegate",
    handlers = {
      -- send prompts to an agent already running in a tmux pane named "agent"
      send = function(prompt, api)
        local text = require("didymus.prompt").to_text(prompt)
        vim.system({ "tmux", "load-buffer", "-b", "didymus", "-" }, { stdin = text }):wait()
        vim.system({ "tmux", "paste-buffer", "-p", "-d", "-b", "didymus", "-t", "agent" }):wait()
        vim.system({ "tmux", "send-keys", "-t", "agent", "Enter" })
      end,
    },
  },
})
```

- Each handler fills the method of the same name. For `agent`, handlers fill the session methods plus an optional `start`; `send` is the only required one, `alive` defaults to true and `stop` to a no-op.
- An absent handler leaves that method absent, so optional features drop out of the UI. A missing required handler is a setup error unless `fallback` is set.
- `fallback = "github"` (any registered adapter) turns the delegate into a wrapper: handlers override single methods and everything else goes to the fallback. A handler can call `api.fallback.add_comment(...)` to decorate a method instead of replacing it.
- A handler for an async method either calls `cb` or returns a non-nil value (or `nil, err`), and the delegate calls `cb` with it.
- Every handler runs under `pcall`. A failing handler reports the error and never tears down the session.

**Hooks.** Core fires `User` autocmds for its events (`DidymusChangeLoaded`, `DidymusThreadsChanged`, `DidymusFileOpened`, `DidymusCommentAdded`, `DidymusReviewSubmitted`) with the payload in `ev.data`. Hooks observe and add behavior; they can't change what an adapter returns.

Test fakes are delegate adapters with canned handlers, so the suite exercises the delegate path and the interfaces at the same time.

## Core behavior

Core keeps one session object as the source of truth and renders every UI piece from it.

- **Session.** One `didymus.Session` per open review holds `change`, `threads`, the workspace (root, merge-base), adapter instances, the agent session and window IDs. Mutations go through session methods that emit events (`change_loaded`, `threads_changed`, `file_opened`, `comment_added`, `review_submitted`), mirrored as `User` autocmds. UI modules subscribe and re-render; they hold no state of their own.
- **Async.** A small `didymus.async` helper wraps `vim.system` and callbacks in coroutines so core reads top to bottom. No plenary.
- **Layout.** `:Didymus open` creates a tabpage, runs `:tcd` to the workspace root, and opens three windows: files panel (left, about 36 columns), main (center), agent (right, about 40% width). Each side panel toggles independently. `:Didymus close` closes the tab and stops the agent but leaves the worktree on disk.
- **Files panel.** A plain scratch buffer rendered from session state, so `/` search works. Keys: `<CR>` opens a file or jumps to a thread, `za` expands, `v` toggles viewed, `R` refreshes, `]f`/`[f` move between files (also mapped in the main window). Resolved threads are dimmed. Outdated threads are tagged and listed only here.
- **Inline threads.** Extmarks in a dedicated namespace: a sign with the comment count and a one-line `virt_lines` summary that expands to the full thread on toggle. A float shows the thread with reply and resolve keys. Head-side threads map to their `line`. Base-side threads anchor at the hunk containing that base line.
- **Composer.** A markdown scratch buffer in a float. `:w` or `<C-s>` submits, `q` cancels. Opened from visual mode, it becomes a range comment. One key inserts a ```` ```suggestion ```` block pre-filled with the selected lines.
- **Commentability.** Before opening the composer, core checks the cursor line against `file.commentable`. Outside those ranges, it offers a file-level comment instead. If `commentable` is nil, it allows the comment and lets the host reject it. If the buffer has unsaved or uncommitted edits, it refuses, because line numbers no longer match head.
- **Ask flow.** `:Didymus ask` from visual mode opens an input float for the question. `didymus.prompt` builds an `AgentPrompt` with a `code` attachment (path, range, content, filetype), calls `agent:send`, and focuses the agent panel when there is one. Variants ask about the thread or the hunk under the cursor.
- **Navigation.** `core.navigate(loc)` resolves `loc.path` against the workspace root, opens it in the main window (never the panel or agent window), sets the cursor and centers it.
- **Commands.** One `:Didymus` command with subcommand completion: `open [n|url]`, `files`, `agent [preset]`, `ask`, `comment`, `reply`, `resolve`, `submit`, `discard`, `refresh`, `close`. Every action is also a `<Plug>(didymus-…)` mapping. Default keymaps are buffer-local and configurable.
- **Health.** `:checkhealth didymus` checks the Neovim version and `git` worktree support, then runs each active adapter's `health()`: `github` checks that `gh` is installed and authenticated, `gitsigns` that gitsigns is present, and `terminal` that each preset command is on `$PATH`.

## v1 adapters

Each extension point ships two adapters: a real default (`github`, `terminal`, `gitsigns`) and `delegate`. The local workspace is core, but it is specified here because the defaults depend on it.

### review: github

- All calls go through `gh` via `vim.system`. No direct HTTP.
- `list_changes`: `gh pr list --json number,title,author,updatedAt,isDraft`.
- `get_change`: GraphQL for metadata, including `baseRefOid`, `headRefOid`, `isCrossRepository` and the viewer's pending review. REST `repos/{owner}/{repo}/pulls/{n}/files` (paginated) supplies each file's `patch`, which `didymus.patch` turns into `commentable` ranges. Return `source = { kind = "fetch", ref = "refs/pull/<n>/head", remote_url = <base repo URL> }` so fork PRs work.
- `get_threads`: GraphQL `reviewThreads` with `path`, `line`, `startLine`, `originalLine`, `diffSide`, `isResolved`, `isOutdated` and comments. Paginate.
- `get_general_comments`: the PR's issue comments.
- Writes, all GraphQL: `addPullRequestReview` without an event (creates a pending review), `addPullRequestReviewThread` (`subjectType: FILE` for file-level comments), `addPullRequestReviewThreadReply`, `resolveReviewThread` / `unresolveReviewThread`, `submitPullRequestReview`, `deletePullRequestReview`, `markFileAsViewed` / `unmarkFileAsViewed`. Check each against the schema first.
- Keep all GraphQL documents as string constants in one module so they are easy to review.
- `health()`: `gh` is installed, authenticated, and can see the repo.

### Workspace (core)

- Default mode: a git worktree at `stdpath("cache")/didymus/worktrees/<owner>__<repo>__<n>`, detached at `head_sha`. First fetch `source.ref` from the remote matching source.`remote_url`. Reuse the worktree on reopen. On refresh, fetch and move it to the new head if it is clean; otherwise warn.
- `merge_base = git merge-base <base_sha> <head_sha>`, not the base branch tip, so hunks match GitHub's three-dot diff.
- Alternative mode `workspace = "in_place"`: use the current checkout only if `HEAD` already equals `head_sha`. Otherwise refuse with a message. Never switch branches silently.

When the review adapter returns `source = { kind = "local" }`, core skips fetching and uses the current checkout in place. `head_sha = nil` means hunks include uncommitted changes.

### agent: terminal

- Start with `vim.fn.jobstart(cmd, { term = true, cwd = ctx.cwd })` in a scratch buffer (the Neovim 0.11+ replacement for `termopen`).
- Send the output of `didymus.prompt.to_text` wrapped in bracketed paste (`\27[200~` … `\27[201~`), then `\r` after a short configurable delay, since some TUIs drop an immediate Enter. Queue sends until the TUI is ready (first output or a configurable delay).
- `to_text` renders the question, then for each attachment a header line `path:start-end` and a fenced code block tagged with the filetype. It lives in core so delegates and other adapters reuse it.
- Send the primer (below) as the first message.
- Links: buffer-local `<CR>` and `gf` in terminal-normal mode. Parse the line under the cursor for `path:line[:col]`, `path:start-end` and `path#Lx[-Ly]`. If nothing matches, retry with the next line joined on, to catch wrapped paths. Resolve relative to cwd and skip paths that don't exist. Optionally highlight matches with extmarks once output settles.
- Phase 5: expose `require("didymus").api` with `goto(path, line)` and `draft_comment(path, line, body)`. An agent can call it through `nvim --server "$NVIM" --remote-expr`, because Neovim sets `$NVIM` in terminal jobs.
- `health()`: each preset command is on `$PATH`.

Primer template:

```text
You are helping me review {change_kind} {id} in {repo}: "{title}".
Base {base_label} <- head {head_label}. The working directory is the change head.
See the full change with: git diff {merge_base}...HEAD

Description:
{body}

When you reference code, always write the location as relative/path:line
or relative/path:start-end. Don't modify files unless I ask.
```

### diff: gitsigns

- Per buffer, after gitsigns attaches, call `change_base(merge_base)` without the global flag.
- Fire `on_ready` from the `User GitSignsUpdate` autocmd for that buffer.
- Build `hunks` from `get_hunks(bufnr)`, `goto_hunk` from `nav_hunk`, and `toggle_deletions` from gitsigns' inline deleted-lines feature. Check the installed version's API; some of these names have changed across releases.
- `health()`: gitsigns is installed. It is required only when this adapter is selected.

### delegate (all three)

- One generic factory builds a delegate for any extension point from its spec, `handlers` and optional `fallback`. The agent delegate adds the session mapping on top.
- Behavior is as described under Extending: absent handlers leave methods absent, `fallback` wraps another adapter, handlers run under `pcall`, and returned values are passed to `cb`.
- The registry validates a delegate at setup like any other adapter, after handlers and fallback are merged.

## Pitfalls and constraints

These are the problems most likely to cause bugs. Design for them from phase 0.

- **Commentable lines.** GitHub rejects line comments outside the PR's diff hunks; context lines count as inside. Large or binary files may come back with no `patch`, so treat their commentability as unknown.
- **One pending review per user per PR.** `begin_review` must find and resume an existing one, including one started on github.com.
- **Merge-base, not base tip.** Diffing against the base branch tip pulls in unrelated changes merged since the branch point.
- **Fork PRs.** The head branch may not exist on any local remote. Always fetch `refs/pull/<n>/head`.
- **Edited buffers.** Local edits shift line numbers away from head. Refuse new comments from modified buffers; let existing thread extmarks move with the text.
- **Base-side threads.** Comments on deleted lines have no head line. Anchor them to their hunk and say so in the float.
- **Worktree LSP cost.** Language servers index a new worktree from scratch, so the first open in a large repo is slow. Document `in_place` mode as the alternative.
- **Global state.** Never change gitsigns, LSP or option state outside the review tab.
- **Terminal input.** Multi-line text sent without bracketed paste submits line by line.
- **Never block.** Every `gh` and `git` call is async, and slow calls show progress.

## Layout, tests and phases

Start from this module layout and adjust it in your plan if something fits better.

```text
plugin/didymus.lua                  -- :Didymus command, <Plug> mappings
lua/didymus/
  init.lua                       -- setup(), register(), public api
  config.lua
  types.lua                      -- LuaCATS only, no runtime code
  specs.lua                      -- extension point specs: methods, capability keys
  registry.lua                   -- adapter registration + validation
  session.lua                    -- review state + mutations
  events.lua                     -- internal bus + User autocmds
  async.lua
  workspace.lua                  -- worktree, fetch, merge-base, local source
  patch.lua                      -- unified diff parsing, commentable ranges
  links.lua                      -- location parsing + resolution
  prompt.lua                     -- AgentPrompt, primer, to_text
  navigate.lua
  ui/{layout,panel,threads,composer,picker,input}.lua
  adapters/
    delegate.lua                 -- generic delegate built from a spec
    review/github.lua
    agent/terminal.lua
    diff/gitsigns.lua
  testing/                       -- contract suites, usable by any adapter
  health.lua
tests/
  fakes/                         -- delegate handler sets
  fixtures/                      -- recorded gh JSON, sample patches
```

Testing:

- Choose the framework in your plan (mini.test or busted through nlua) and tell me the trade-off.
- Unit-test the pure modules hardest: `patch`, `links`, `prompt` and line mapping.
- Write one contract suite per extension point in `didymus.testing`. Every built-in adapter runs it, and third-party adapters can too.
- Run core flows headless against fakes, which are delegate adapters with canned handlers.
- Test the `github` adapter against recorded JSON fixtures, with `gh` stubbed at the `vim.system` boundary.
- End each phase with a manual checklist against a real throwaway PR.

Phases:

1. **Scaffold.** Types, extension point specs, registry with validation, the generic delegate adapter, events and `User` autocmds, async helper, contract suites, fakes, test harness, health check stub.
2. **Read-only review.** `github` reads, workspace, layout, files panel, opening a file at its first hunk with `gitsigns`, hunks surviving LSP jumps.
3. **Comments.** Patch parsing, inline threads, composer, pending review, reply, resolve, submit, discard, refresh.
4. **Agent.** `terminal` adapter with presets, primer, `:Didymus ask` and its variants, link jumping.
5. **Polish.** Viewed state, outdated threads, suggestion blocks, the `$NVIM` callback API, `doc/didymus.txt`, full health check.

## Non-goals and open questions

v1 leaves these out: merging PRs, CI and check status, editing or deleting comments, review adapters beyond github and delegate (such as local or gitlab), an ACP agent adapter, session persistence across Neovim restarts, and multiple concurrent reviews. The interfaces must not rule any of them out.

Ask me these before starting:

- Should the default workspace mode be worktree or in-place?
- Is Neovim 0.11 an acceptable minimum version?
- Which test framework: mini.test or busted?
- Should the agent panel also support a floating layout, or only the right-hand split?
