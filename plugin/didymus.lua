if vim.g.loaded_didymus then
  return
end
vim.g.loaded_didymus = true

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify("didymus.nvim needs Neovim 0.12 or later", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Didymus", function(cmd)
  require("didymus").command(cmd.fargs)
end, { nargs = "*", desc = "didymus.nvim" })
