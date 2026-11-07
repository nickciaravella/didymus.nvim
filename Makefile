NVIM ?= nvim
DEPS := deps
MINI := $(DEPS)/mini.nvim
TEST_PATH ?= tests

.PHONY: test test-unit test-e2e test-file deps fmt fmt-check clean

## Run all *.test.lua files under TEST_PATH (headless).
test: deps
	TEST_PATH=$(TEST_PATH) $(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

test-unit:
	$(MAKE) test TEST_PATH=tests/unit

test-e2e:
	$(MAKE) test TEST_PATH=tests/e2e

## Run one test file: make test-file FILE=tests/e2e/startup.test.lua
test-file: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

## Get the test dependencies.
deps: $(MINI)

$(MINI):
	@mkdir -p $(DEPS)
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $@

## Format the Lua code.
fmt:
	stylua lua plugin tests

## Check the Lua format. CI uses this target.
fmt-check:
	stylua --check lua plugin tests

## Remove the test dependencies.
clean:
	rm -rf $(DEPS)
