# Testing

The tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md). It needs no luarocks. It can run each test in a clean child Neovim, which is good for UI code.

## Run the tests

```sh
make test                                              # all tests
make test-unit                                         # unit tests only
make test-integration                                  # integration tests only
make test-file FILE=tests/integration/startup.test.lua # one file
make test NVIM=~/neovim/build/bin/nvim                 # a different Neovim
```

The first run clones mini.nvim into `deps/`.

## Layout

```text
tests/
  minimal_init.lua
  unit/didymus/       mirrors lua/didymus/
  integration/        one file (or folder) for each feature
```

All test files end in `.test.lua`.

### Unit tests

A unit test file has the same path and name as its module. For example, `lua/didymus/foo/bar.lua` has the test file `tests/unit/didymus/foo/bar.test.lua`.

Write unit tests only for modules with real logic, such as parsers and data transforms. Do not unit test glue code. The integration tests cover it.

### Integration tests

Integration tests are end to end. They drive a child Neovim the way a user does, and check the result that a user sees.

- Use one file for each feature, such as `startup.test.lua`. Use a folder if a feature needs more than one file.
- Start each test with `child.restart()`, so that no state goes from one test to the next.
- Drive the plugin with `child.cmd()` and `child.type_keys()`.
- Check windows, buffers, the cursor, and messages. Use `MiniTest.expect.reference_screenshot()` to check the screen.

See `tests/integration/startup.test.lua` for an example.

## Manual tests

Load the local plugin:

```sh
nvim --cmd "set rtp^=$PWD"
```

Do manual tests on a throwaway PR, not on a PR that other persons use.

## CI

`.github/workflows/ci.yml` runs the tests on Neovim v0.12.0, stable and nightly, and checks the format. Keep v0.12.0 in the matrix. It is the minimum version.
