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

The `sidebar` preset has `preview = "main"`. The preview is a float over the code window, and each move of the cursor in the list changes it. The explorer sets `layout = { preset = "sidebar", preview = false }` to stop it. To hide the preview for some items, call `picker:toggle("preview", { enable = false })` in `on_change`.

- Proof: [`layouts.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/config/layouts.lua#L22-L23) and [`sources.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/config/sources.lua#L65) at v2.31.0.
- Checked: snacks.nvim v2.31.0

### The main preview does not come back when the focus goes back to the list of a sidebar

With `auto_close = false`, snacks hides the main preview when the focus goes to a window outside the picker. Its `WinEnter` handler shows the preview again, but it returns early if the current window is a float. The list of a `sidebar` layout is a float in the root split. Add a handler on the list: `picker.list.win:on("WinEnter", cb, { buf = true })`.

- Proof: the test `the preview hides while the focus is in the code window` in `tests/integration/picker/snacks.test.lua`. It fails without the `WinEnter` handler in `lua/didymus/ui/picker/snacks.lua`. See also [`picker.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/core/picker.lua#L286-L298) at v2.31.0.
- Checked: snacks.nvim v2.31.0

### The file previewer shows a copy of a file that is not loaded, unless the item has `buf`

`Snacks.picker.preview.file()` reads a file into its scratch buffer if `item.buf` is not a loaded buffer. Marks, such as the gitsigns diff, cannot go on that copy. Set `item.buf` to a loaded buffer before the call, and the preview shows the real buffer. snacks deletes a buffer only if it loaded the buffer itself (`vim.b.snacks_picker_loaded`), and only when the preview window closes. So unload your own buffers.

- Proof: the test `with on_preview, the preview shows the real buffer, and unloads it after` in `tests/integration/picker/snacks.test.lua`. See also [`preview.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/preview.lua#L80-L114) and [`core/preview.lua`](https://github.com/folke/snacks.nvim/blob/v2.31.0/lua/snacks/picker/core/preview.lua#L103-L120) at v2.31.0.
- Checked: snacks.nvim v2.31.0

### The `WinClosed` of the main preview does not fire when the focus leaves a sidebar

snacks hides the main preview in its `WinEnter` handler. That handler is not `nested`, so the close of the preview window gives no `WinClosed`, also for `picker.preview.win:on("WinClosed", …)`. To know that the preview hid, check `picker.preview.win:valid()` in a scheduled callback of a global `WinEnter` autocmd.

- Proof: the test `with on_preview, the preview shows the real buffer, and unloads it after` in `tests/integration/picker/snacks.test.lua`. It fails with a `WinClosed` handler on the preview window in place of the `WinEnter` check in `lua/didymus/ui/picker/snacks.lua`.
- Checked: snacks.nvim v2.31.0
