# gh

Facts about the GitHub CLI (`gh`) and the GitHub API. See [`README.md`](README.md) for the rules.

## `gh api`

### `--paginate` merges REST array pages, but writes GraphQL pages one after the other

The raw output of a REST array endpoint with `--paginate` is one JSON array. But `--jq` runs on each page. With GraphQL, the pages are JSON objects one after the other, which is not valid JSON. Use `--paginate --slurp` for both. Then the output is an array of pages.

- Proof:
  - `gh api --paginate 'repos/nickciaravella/didymus.nvim/pulls/57/files?per_page=3' | jq -s length` gives `1` (one array of 8 files). With `--jq length`, it gives `3 3 2`.
  - `gh api graphql --paginate` with `files(first: 4, after: $endCursor)` on the same PR gives `…}}}}}{"data"…`.
- Checked: gh 2.103.2

### `--paginate` of GraphQL reads the first `pageInfo` in the reply

`gh` takes `hasNextPage` and `endCursor` from the first `pageInfo` object in the JSON reply. With a nested connection, such as the comments of each review thread, put the `pageInfo` of the outer connection before `nodes`. Else `gh` reads the `pageInfo` of the first nested connection. Then it can stop after page 1 with no error, or use a wrong cursor.

- Proof: on neovim/neovim#42726 (3 threads), the query `reviewThreads(first: 2, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { id comments(first: 5) { pageInfo { hasNextPage endCursor } } } }` gives 2 pages. With the `pageInfo` of the threads after `nodes`, it gives only 1 page, and exit code 0.
- Checked: gh 2.103.2

### A GraphQL error exits with 1, and puts `gh: <message>` on stderr

stdout still has the JSON body, with `errors` and a `null` in `data`. Show the message from stderr. An error of a REST call also gives `gh: <message>` on stderr, such as `gh: Not Found (HTTP 404)`.

- Proof: `gh api graphql -F owner='{owner}' -F repo='{repo}' -F number=99999 -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id}}}'` gives `gh: Could not resolve to a PullRequest with the number of 99999.` on stderr, and exit code 1.
- Checked: gh 2.103.2

## PR files

### The REST files of a PR have no `patch` for a large file or a pure rename

The `patch` field is `null`. The other fields, such as `status` and `changes`, are present. So a file with no `patch` is not always a binary file.

- Proof:
  - `gh api repos/neovim/neovim/pulls/20607/files --jq '.[] | select(.filename == "runtime/neovim.ico") | {status, changes, patch}'` gives `{"changes":0,"patch":null,"status":"renamed"}`.
  - The same for `src/unicode/EastAsianWidth.txt` in neovim/neovim#27317 gives `{"changes":5170,"patch":null,"status":"modified"}`.
- Checked: gh 2.103.2

## `gh pr checkout`

### The fetch lines of git can come before the error on stderr

If `gh` fetches a new branch, stderr starts with the lines of `git fetch`, such as `From github.com:owner/repo`. The error of git comes after them, and `failed to run git: exit status <n>` is the last line. So the first line of stderr is not always the error. Keep all lines.

- Proof: in a new clone of this repo, change `lua/didymus/config.lua`, then run `gh pr checkout 57`. stderr is `From github.com:nickciaravella/didymus.nvim`, ` * [new branch] …`, `error: Your local changes to the following files would be overwritten by checkout:`, the file, `Aborting` and `failed to run git: exit status 1`.
- Checked: gh 2.103.2

### It fails in a single-branch clone, such as a clone with `--depth`

The fetch refspec of a single-branch clone has only one branch. So the fetched PR branch is not a remote-tracking branch, and git cannot set up the tracking. A full clone works.

- Proof: `git clone --depth 1 git@github.com:nickciaravella/didymus.nvim.git d && cd d && gh pr checkout 57` gives `fatal: cannot set up tracking information; starting point 'origin/feat/review-provider' is not a branch`.
- Checked: gh 2.103.2, git 2.55.0
