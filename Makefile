NVIM ?= nvim
DEPS := deps
MINI := $(DEPS)/mini.nvim
SNACKS := $(DEPS)/snacks.nvim
# v2.31.0. The integration tests use this commit.
SNACKS_COMMIT := e6fd58c82f2f3fcddd3fe81703d47d6d48fc7b9f
GITSIGNS := $(DEPS)/gitsigns.nvim
# No tag has the unified view of diffthis(). The integration tests use this commit.
GITSIGNS_COMMIT := fd780920613e541cbdfac41bf711583ed49f9249
TEST_PATH ?= tests

.PHONY: test test-unit test-e2e test-integration test-file deps snacks gitsigns fmt fmt-check clean

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
deps: $(MINI) snacks gitsigns

$(MINI):
	@mkdir -p $(DEPS)
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $@

## Check out commit $(2) of the repo $(3) in $(1). Fetch it only if it is not the current commit.
define checkout
	@if [ "$$(git -C $(1) rev-parse HEAD 2>/dev/null)" != "$(2)" ]; then \
		mkdir -p $(1) && \
		git -C $(1) init -q && \
		git -C $(1) fetch -q --depth 1 $(3) $(2) && \
		git -C $(1) checkout -q --detach FETCH_HEAD; \
	fi
endef

snacks:
	$(call checkout,$(SNACKS),$(SNACKS_COMMIT),https://github.com/folke/snacks.nvim)

gitsigns:
	$(call checkout,$(GITSIGNS),$(GITSIGNS_COMMIT),https://github.com/lewis6991/gitsigns.nvim)

## Format the Lua code.
fmt:
	stylua lua plugin tests

## Check the Lua format. CI uses this target.
fmt-check:
	stylua --check lua plugin tests

## Remove the test dependencies.
clean:
	rm -rf $(DEPS)
