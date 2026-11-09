# snacks.nvim

Facts about snacks.nvim that are tricky and not well documented. For the rules, see [`README.md`](README.md).

## Picker

### `Snacks.picker.pick()` with a `source` closes an open picker of that source

If a picker with the same `source` is open, `pick()` closes it and returns nil. It does not open a second picker. Do not set `source` on a picker that can open more than one time, such as a panel.

- Proof: run this command in the repo root after `make deps`. It prints `second: nil, first closed: true`.

  ```sh
  nvim --clean --headless -c 'set rtp+=deps/snacks.nvim' -c 'lua local function opts() return { source = "x", items = { { text = "a" } } } end
  local first = require("snacks").picker.pick(opts()) local second = require("snacks").picker.pick(opts())
  io.write(("second: %s, first closed: %s\n"):format(tostring(second), tostring(first.closed)))' -c qa
  ```

- Checked: snacks.nvim v2.31.0

### `picker:refresh()` keeps the cursor on the same index, not on the same item

`refresh()` calls `list:set_target()`, which keeps the cursor index. If the new items have a new item above the cursor, the cursor goes to a different item. To keep the item, call `picker:find({ on_done = ... })`. In `on_done`, find the index of the item and call `picker.list:view(index)`.

- Proof: the test `update() shows the new items, and the cursor stays on the same item` in `tests/integration/picker/snacks.test.lua`. It fails without the `list:view()` call in `lua/didymus/ui/picker/snacks.lua`.
- Checked: snacks.nvim v2.31.0

### A picker with no items closes, unless `show_empty = true`

When the finder gives no items, the picker shows a "No results" warning and closes. `on_close` runs. A panel must set `show_empty = true`.

- Proof: the test `stays open with no items, and an action gets no item` in `tests/integration/picker/snacks.test.lua`. It fails without `show_empty = true`.
- Checked: snacks.nvim v2.31.0

### The `sidebar` layout shows the preview in the main window

The `sidebar` preset has `preview = "main"`. Each move of the cursor in the list then shows the item in the code window. The explorer sets `layout = { preset = "sidebar", preview = false }` to stop it.

- Proof: [`layouts.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/config/layouts.lua#L22-L23) and [`sources.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/config/sources.lua#L65) at v2.31.0.
- Checked: snacks.nvim v2.31.0
