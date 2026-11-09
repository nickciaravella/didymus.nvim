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

for _, action in ipairs({ "open", "close", "files", "thread", "next", "prev" }) do
  vim.keymap.set("n", ("<Plug>(didymus-review-%s)"):format(action), function()
    require("didymus.review")[action]()
  end, { desc = "didymus: review " .. action })
end

vim.keymap.set({ "n", "x" }, "<Plug>(didymus-review-comment)", function()
  require("didymus.review").comment()
end, { desc = "didymus: review comment" })
