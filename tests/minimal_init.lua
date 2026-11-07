vim.opt.runtimepath:append(vim.fn.getcwd())

-- Only the main test process loads mini.test. Child processes have a UI, so they skip it.
if #vim.api.nvim_list_uis() == 0 then
  vim.opt.runtimepath:append(vim.fn.getcwd() .. "/deps/mini.nvim")
  require("mini.test").setup({
    collect = {
      find_files = function()
        return vim.fn.globpath(vim.env.TEST_PATH or "tests", "**/*.test.lua", true, true)
      end,
    },
  })
end
