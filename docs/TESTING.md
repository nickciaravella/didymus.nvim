# Testing

The tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md). It needs no luarocks. It can run each test in a clean child Neovim, which is good for UI code.

The tests run on the Neovim that is installed on your machine.

## Run the tests

```sh
make test                                        # all tests
make test-unit                                   # unit tests only
make test-e2e                                    # end-to-end tests only
make test-file FILE=tests/e2e/startup.test.lua   # one file
make test NVIM=~/neovim/build/bin/nvim           # a different Neovim
```

The first run clones mini.nvim into `deps/`.

## Kinds of tests

| Kind | Checks | External dependencies |
| --- | --- | --- |
| Unit | A pure function, or a function that uses only Neovim. | None. |
| End-to-end | One feature as a user sees it, through commands, keys and the public API. | None. The local provider in place of GitHub. The fake agent in place of an agent. |
| Integration | One provider or external dependency against the real thing. If necessary, more than one module, for a larger functional test. | The real dependency, for example `gh`. |

The unit tests and the end-to-end tests do not use the network.

## Layout

```text
tests/
  minimal_init.lua
  unit/didymus/       mirrors lua/didymus/
  e2e/                one file (or folder) for each feature
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

- Configure the local provider in place of GitHub.
- Use one file for each feature, such as `startup.test.lua`. Use a folder if a feature needs more than one file.
- Start each test with `child.restart()`, so that no state goes from one test to the next.
- Drive the plugin with `child.cmd()`, `child.type_keys()` and the public API, such as `require("didymus.agent").start()`.
- Check windows, buffers, the cursor, and messages. Use `MiniTest.expect.reference_screenshot()` to check the screen.

See `tests/e2e/startup.test.lua` for an example.

### The fake agent

`tests/fixtures/fake_agent.lua` acts like an agent CLI. Use it in place of a real agent in end-to-end tests:

```lua
{ vim.v.progpath, "--clean", "-l", "tests/fixtures/fake_agent.lua", "--name", "test" }
```

| Argument | Behavior |
| --- | --- |
| `--name <name>` | Show `fake agent <name>` as the banner. |
| `--exit <code>` | Exit with `<code>` after the first line of input. |

The agent starts in a separate process. Do not use a fixed delay. Poll the agent buffer until the text shows. See `tests/e2e/agent/session.test.lua`.

### Integration tests

Integration tests check one provider or external dependency against the real thing. For example, a test checks the GitHub provider with the real `gh`. If necessary, a test can use more than one module, for a larger functional test.

We add the first integration tests with the first provider.

## Manual tests

Load the local plugin:

```sh
nvim --cmd "set rtp^=$PWD"
```

Do manual tests on a throwaway PR, not on a PR that other persons use.

## CI

`.github/workflows/ci.yml` runs the tests on Neovim stable, and checks the format.
