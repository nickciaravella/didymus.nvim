if vim.g.loaded_didymus then
  return
end
vim.g.loaded_didymus = true

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify("didymus.nvim needs Neovim 0.12 or later", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Didymus", function(cmd)
  local range = cmd.range > 0 and { cmd.line1, cmd.line2 } or nil
  require("didymus.command").run(cmd.args, range)
end, {
  nargs = "*",
  range = true,
  desc = "didymus.nvim",
  complete = function(arglead, cmdline, cursorpos)
    return require("didymus.command").complete(arglead, cmdline, cursorpos)
  end,
})

for _, action in ipairs({ "start", "toggle", "focus", "stop" }) do
  vim.keymap.set({ "n", "t" }, ("<Plug>(didymus-agent-%s)"):format(action), function()
    require("didymus.agent")[action]()
  end, { desc = "didymus: agent " .. action })
end

-- A Lua function sees the selection. A `:` mapping gives only full lines.
for _, action in ipairs({ "append", "send" }) do
  vim.keymap.set({ "n", "x" }, ("<Plug>(didymus-agent-%s)"):format(action), function()
    require("didymus.agent")[action]()
  end, { desc = "didymus: agent " .. action })
end

for _, action in ipairs({
  "open",
  "close",
  "files",
  "reply",
  "submit",
  "discard",
  "refresh",
}) do
  vim.keymap.set("n", ("<Plug>(didymus-review-%s)"):format(action), function()
    require("didymus.review")[action]()
  end, { desc = "didymus: review " .. action })
end

for _, action in ipairs({ "next", "prev" }) do
  for _, kind in ipairs({ "thread", "file", "hunk" }) do
    vim.keymap.set("n", ("<Plug>(didymus-review-%s-%s)"):format(action, kind), function()
      require("didymus.review")[action]({ kind = kind })
    end, { desc = ("didymus: review %s %s"):format(action, kind) })
  end
end

vim.keymap.set("n", "<Plug>(didymus-review-fold)", function()
  require("didymus.review").fold()
end, { desc = "didymus: review fold or unfold the thread" })

vim.keymap.set("n", "<Plug>(didymus-review-fold-all)", function()
  require("didymus.review").fold({ all = true })
end, { desc = "didymus: review fold or unfold all threads" })

vim.keymap.set("n", "<Plug>(didymus-review-resolve)", function()
  require("didymus.review").resolve()
end, { desc = "didymus: review resolve or unresolve" })

vim.keymap.set({ "n", "x" }, "<Plug>(didymus-review-comment)", function()
  require("didymus.review").comment()
end, { desc = "didymus: review comment" })

vim.keymap.set("n", "<Plug>(didymus-review-comment-file)", function()
  require("didymus.review").comment({ kind = "file" })
end, { desc = "didymus: review comment on the file" })

vim.keymap.set("n", "<Plug>(didymus-review-comment-change)", function()
  require("didymus.review").comment({ kind = "change" })
end, { desc = "didymus: review comment on the change" })

for _, action in ipairs({ "toggle", "next", "prev" }) do
  vim.keymap.set("n", ("<Plug>(didymus-diff-%s)"):format(action), function()
    require("didymus.diff")[action]()
  end, { desc = "didymus: diff " .. action })
end

vim.keymap.set("n", "<Plug>(didymus-diff-layout)", function()
  require("didymus.diff").layout()
end, { desc = "didymus: diff change the layout" })

for _, layout in ipairs({ "inline", "split" }) do
  vim.keymap.set("n", ("<Plug>(didymus-diff-layout-%s)"):format(layout), function()
    require("didymus.diff").layout({ layout = layout })
  end, { desc = "didymus: diff layout " .. layout })
end

vim.keymap.set("n", "<Plug>(didymus-diff-side)", function()
  require("didymus.diff").side()
end, { desc = "didymus: diff go to the next sides" })

for _, side in ipairs({ "both", "base", "head" }) do
  vim.keymap.set("n", ("<Plug>(didymus-diff-side-%s)"):format(side), function()
    require("didymus.diff").side({ side = side })
  end, { desc = "didymus: diff side " .. side })
end
