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

The unit tests and the end-to-end tests do not use the network.

| Kind | Checks | External dependencies |
| --- | --- | --- |
| Unit | One module with real logic. | Mocks. |
| End-to-end | One feature, as a user sees it. | The local provider in place of GitHub. |
| Integration | One provider, against the provider interface. | The real dependency of that provider, for example `gh`. |

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

Mock all external dependencies, such as `git`, `gh` and the agent.

### End-to-end tests

End-to-end tests drive a child Neovim the way a user does, and check the result that a user sees.

- Configure the local provider in place of GitHub.
- Use one file for each feature, such as `startup.test.lua`. Use a folder if a feature needs more than one file.
- Start each test with `child.restart()`, so that no state goes from one test to the next.
- Drive the plugin with `child.cmd()` and `child.type_keys()`.
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

Integration tests check that a provider, such as the GitHub provider, follows the provider interface. Keep them small. Test only the behavior that the interface needs.

We add the first integration tests with the first provider.

## Manual tests

Load the local plugin:

```sh
nvim --cmd "set rtp^=$PWD"
```

Do manual tests on a throwaway PR, not on a PR that other persons use.

## CI

`.github/workflows/ci.yml` runs the tests on Neovim stable, and checks the format.
