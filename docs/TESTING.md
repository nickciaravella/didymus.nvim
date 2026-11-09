# Testing

The tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md). It needs no luarocks. It can run each test in a clean child Neovim, which is good for UI code.

The tests run on the Neovim that is installed on your machine.

## Run the tests

```sh
make test                                        # all tests
make test-unit                                   # unit tests only
make test-e2e                                    # end-to-end tests only
make test-integration                            # integration tests only
make test-file FILE=tests/e2e/startup.test.lua   # one file
make test NVIM=~/neovim/build/bin/nvim           # a different Neovim
```

The first run clones mini.nvim and snacks.nvim into `deps/`. snacks.nvim is at the commit of `SNACKS_COMMIT` in the `Makefile`. If you change `SNACKS_COMMIT`, the next run fetches the new commit.

## Kinds of tests

| Kind | Checks | External dependencies |
| --- | --- | --- |
| Unit | A pure function, or a function that uses only Neovim. | None. |
| End-to-end | One feature as a user sees it, through commands, keys and the public API. | None. The test provider in place of GitHub. The test picker in place of snacks. The test backend or the fake agent in place of an agent. |
| Integration | One provider or external dependency against the real thing. If necessary, more than one module, for a larger functional test. | The real dependency, for example snacks.nvim. |

The unit tests and the end-to-end tests do not use the network.

## Layout

```text
tests/
  minimal_init.lua
  helpers.lua         helpers for all kinds of tests, such as wait_for()
  unit/didymus/       mirrors lua/didymus/
  e2e/                one file (or folder) for each feature
  integration/        one folder for each kind of integration, such as picker/
  fixtures/           files for tests, such as the fake agent and recorded gh output
```

All test files end in `.test.lua`.

### Unit tests

A unit test file has the same path and name as its module. For example, `lua/didymus/foo/bar.lua` has the test file `tests/unit/didymus/foo/bar.test.lua`.

Write unit tests only for modules with real logic, such as parsers and data transforms. Do not unit test glue code. The end-to-end tests cover it.

A unit test has no external dependencies. If the function uses one, such as `git`, `gh` or the agent, mock it. Neovim is not an external dependency. Prefer a real child Neovim to mocks of `vim.api` or `vim.fn`.

Each function goes in one of two places:

| Function | Where it runs | Example |
| --- | --- | --- |
| Pure logic | The test process. Call it directly. | `prompt.to_text()` |
| Logic that uses editor state, such as buffers, windows, the cursor or the mode | A child Neovim | `prompt.context()` |

One test file can have both. See `tests/unit/didymus/agent/prompt.test.lua`.

To test a function in a child Neovim:

1. Restart the child in `pre_case`.
2. Make the state with `child.api`, `child.bo` and `child.o`.
3. If the state needs keys, such as visual mode, type them with `child.type_keys()`.
4. Call the function with `child.lua_get()`. Check the return value.

A call to the child obeys these rules:

- The call runs in the current mode of the child. In visual mode, the function sees the selection, as in a `<Cmd>` mapping.
- The return value goes through RPC, so it must be data. A function gives an error. A metatable does not go through.
- An error in the child is an error in the test. Check it with `MiniTest.expect.error()`.

A unit test calls one function and checks the return value. An end-to-end test uses commands, keys and the public API, and checks what the user sees.

### End-to-end tests

End-to-end tests drive a child Neovim the way a user does, and check the result that a user sees.

- Configure the test provider in place of GitHub, and the test picker in place of snacks. See "The test picker".
- Use one file for each feature, such as `startup.test.lua`. Use a folder if a feature needs more than one file.
- Start each test with `child.restart()`, so that no state goes from one test to the next.
- Drive the plugin with `child.cmd()`, `child.type_keys()` and the public API, such as `require("didymus.agent").start()`.
- Check windows, buffers, the cursor, and messages. Use `MiniTest.expect.reference_screenshot()` to check the screen.

See `tests/e2e/startup.test.lua` for an example.

### The test backend or the fake agent

| Use | To test |
| --- | --- |
| The test backend | Flows that do not need a terminal, such as append and send. |
| The fake agent | The terminal backend: its start, exit, terminal mode and input. |

The test backend starts no process, so its tests do not wait. Set it in `setup()`:

```lua
require("didymus").setup({ agent = { backend = "test" } })
```

It keeps each prompt in `backend.prompts` and shows its text in the buffer. `helpers.prompts(child)` gives the list. `helpers.exit(child, code)` makes the agent exit. See `tests/e2e/agent/test_backend.test.lua`.

### The fake agent

`tests/fixtures/fake_agent.lua` acts like an agent CLI. Use it in place of a real agent in end-to-end tests:

```lua
{ vim.v.progpath, "--clean", "-l", "tests/fixtures/fake_agent.lua", "--name", "test" }
```

| Argument | Behavior |
| --- | --- |
| `--name <name>` | Show `fake agent <name>` as the banner. |
| `--exit <code>` | Exit with `<code>` after the first submit. |

The fake agent reads input in raw mode with bracketed paste. It shows one row for each event:

| Input | Row |
| --- | --- |
| A bracketed paste | `paste: "<text>"` |
| A `\r` or a `\n` outside a paste | `submitted: "<text>"`, with all the input since the last submit |
| Another key | `key: "<byte>"` |

The text goes through `vim.inspect()`. Make the terminal wide, so that each row fits. See `tests/e2e/agent/terminal_input.test.lua`.

The agent starts in a separate process. Do not use a fixed delay. Poll the agent buffer until the text shows. The helpers are in `tests/e2e/agent/helpers.lua`.

### The test picker

The test picker has no UI. It records each call, so that a test can act as the user. Set it in `setup()`:

```lua
require("didymus").setup({ review = { picker = "test" } })
```

Then drive it in the child with `require("didymus.ui.picker.test")`:

| Function | Behavior |
| --- | --- |
| `calls` | One record for each `select()` and `panel()`: `kind`, `opts`, `items`, `cursor`, `open` and `focus_count`. |
| `choose(target)` | Choose an item in the last open picker. A select closes first. A panel stays open. |
| `cancel()` | Close the last open picker with no choice. |
| `press(key, target)` | Call the action of `key` in the last open panel, with the item under the cursor. |

`target` is the index or the text of an item. Nil is the item under the cursor. The calls are synchronous, so the test does not wait.

### The test provider

The test provider keeps its changes in memory. Set it in `setup()`:

```lua
require("didymus").setup({ review = { provider = "test" } })
```

The helpers in `tests/e2e/review/helpers.lua` run in the test process:

| Function | Behavior |
| --- | --- |
| `make_repo(opts)` | Make a temporary git repo with a base commit on `main` and a head commit on `feature`. `HEAD` is on `main`. Return the `dir` and a `change` that points to the two commits. |
| `set_changes(child, changes)` | Give the changes to the test provider in the child. |
| `call(child, method, ...)` | Call a method of the configured provider in the child. Wait for its `cb`, and return `{ err, result }`. |
| `git(dir, args)`, `write(dir, files)` | Run git, or write files, in the repo. |

The `files` of the change come from `git diff`, with the patch as GitHub gives it. The helpers do not use the git config of the user. Before you call `checkout`, set the directory of the child to the repo with `child.fn.chdir(repo.dir)`. See `tests/e2e/review/provider.test.lua`.

### The GitHub provider

The unit tests of the GitHub provider replace `vim.system` with a mock. The mock gives recorded `gh` output from `tests/fixtures/github/`, and calls `on_exit` in a fast event, as the real `vim.system` does. See `tests/unit/didymus/review/provider/github.test.lua`.

| Fixture | Recorded from | Changes by hand |
| --- | --- | --- |
| `list.json` | `gh pr list` on neovim/neovim: one PR and one draft. | None. |
| `fork_*.json` | neovim/neovim#38540: a fork head, renamed files, 2 pages of 2 files. | None. |
| `no_patch_*.json` | neovim/neovim#27317: a large file with no `patch`. | Only 2 of the files. |
| `pending_*.json` | nickciaravella/didymus.nvim#57. | Only 1 file, the first line of the body, and 2 pending reviews. |

The REST fixtures (`*_files.json`) do not have the URL fields. To record again, run the query of `lua/didymus/review/provider/github/graphql.lua` and the REST call with `--paginate --slurp`. A smaller page size, such as `first: 2` and `per_page=2`, gives more than one page.

The health tests in `tests/e2e/health.test.lua` set the `$PATH` of the child to a new directory, with a fake `gh` script or with no `gh`. So they do not use the network.

### Integration tests

Integration tests check one provider or external dependency against the real thing. For example, a test checks the GitHub provider with the real `gh`. If necessary, a test can use more than one module, for a larger functional test.

`tests/integration/picker/snacks.test.lua` checks the snacks picker adapter with the real snacks.nvim:

- Start each test with `helpers.restart(child)` from `tests/integration/helpers.lua`. It puts `deps/snacks.nvim` on the `'runtimepath'` of the child. The end-to-end children do not have snacks.nvim.
- snacks draws its windows in scheduled callbacks. Poll with `wait_for()` until the text shows.
- To check that a thing does not happen, such as an auto close, let the child run its callbacks first. Call `vim.wait(50)` in the child.

In the MVP, people test the GitHub provider with the real `gh` by hand. See [#50](https://github.com/nickciaravella/didymus.nvim/issues/50).

## Manual tests

Do manual tests on a throwaway PR, not on a PR that other persons use.

### Load the plugin from a worktree

Make your config load didymus.nvim from `$DIDYMUS_DIR` when it is set. For example, with lazy.nvim:

```lua
{ dir = vim.env.DIDYMUS_DIR or "~/Work/didymus.nvim", main = "didymus" }
```

lazy.nvim resets `'runtimepath'`, so `--cmd "set rtp^=$PWD"` has no effect.

Make sure that didymus.nvim loads from the worktree. This command prints the path of its `init.lua`:

```sh
DIDYMUS_DIR="$PWD" nvim --headless -c 'lua io.write(debug.getinfo(require("didymus").setup, "S").source)' -c qa
```

If your config does not read `DIDYMUS_DIR`, use `nvim --clean -u tests/minimal_init.lua` in place of `DIDYMUS_DIR="$PWD" nvim`.

### The setup file

Agents write the setup of a manual test in `.manual-test/setup.lua`. Git ignores `.manual-test/`. Load the setup after your config with `-S`, and give the files and the line of the test:

```sh
DIDYMUS_DIR="$PWD" nvim -S .manual-test/setup.lua lua/didymus/agent/init.lua +42
```

The setup adds its options to the options of your config. For example, this setup uses the fake agent:

```lua
local didymus = require("didymus")
local fake_agent = vim.fn.getcwd() .. "/tests/fixtures/fake_agent.lua"
didymus.setup(vim.tbl_deep_extend("force", didymus.config, {
  agent = { cmd = { vim.v.progpath, "--clean", "-l", fake_agent, "--name", "manual test" } },
}))
```

## CI

`.github/workflows/ci.yml` runs `make test` on Neovim stable, and checks the format. `make test` runs the unit, end-to-end and integration tests.
