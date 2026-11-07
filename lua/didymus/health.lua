local M = {}

function M.check()
  vim.health.start("didymus")

  if vim.fn.has("nvim-0.12") == 1 then
    local version = vim.version()
    vim.health.ok(("Neovim %d.%d.%d"):format(version.major, version.minor, version.patch))
  else
    vim.health.error("Neovim 0.12 or later is necessary")
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("`git` is available")
  else
    vim.health.error("`git` is not on $PATH")
  end
end

return M
