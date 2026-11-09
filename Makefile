NVIM ?= nvim
DEPS := deps
MINI := $(DEPS)/mini.nvim
SNACKS := $(DEPS)/snacks.nvim
# v2.31.0. The integration tests use this commit.
SNACKS_COMMIT := e6fd58c82f2f3fcddd3fe81703d47d6d48fc7b9f
TEST_PATH ?= tests

.PHONY: test test-unit test-e2e test-integration test-file deps snacks fmt fmt-check clean

## Run all *.test.lua files under TEST_PATH (headless).
test: deps
	TEST_PATH=$(TEST_PATH) $(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

test-unit:
	$(MAKE) test TEST_PATH=tests/unit

test-e2e:
	$(MAKE) test TEST_PATH=tests/e2e

test-integration:
	$(MAKE) test TEST_PATH=tests/integration

## Run one test file: make test-file FILE=tests/e2e/startup.test.lua
test-file: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

## Get the test dependencies.
deps: $(MINI) snacks

$(MINI):
	@mkdir -p $(DEPS)
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $@

## Check out SNACKS_COMMIT. Fetch it only if it is not the current commit.
snacks:
	@if [ "$$(git -C $(SNACKS) rev-parse HEAD 2>/dev/null)" != "$(SNACKS_COMMIT)" ]; then \
		mkdir -p $(SNACKS) && \
		git -C $(SNACKS) init -q && \
		git -C $(SNACKS) fetch -q --depth 1 https://github.com/folke/snacks.nvim $(SNACKS_COMMIT) && \
		git -C $(SNACKS) checkout -q --detach FETCH_HEAD; \
	fi

## Format the Lua code.
fmt:
	stylua lua plugin tests

## Check the Lua format. CI uses this target.
fmt-check:
	stylua --check lua plugin tests

## Remove the test dependencies.
clean:
	rm -rf $(DEPS)
