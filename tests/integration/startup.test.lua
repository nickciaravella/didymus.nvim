local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
    end,
    post_once = child.stop,
  },
})

T[":Didymus command exists"] = function()
  eq(child.fn.exists(":Didymus"), 2)
end

T["setup() keeps the configuration"] = function()
  child.lua('require("didymus").setup({ foo = 1 })')
  eq(child.lua_get('require("didymus").config.foo'), 1)
end

T[":checkhealth didymus reports no errors"] = function()
  child.cmd("checkhealth didymus")
  local report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  MiniTest.expect.no_equality(report:find("OK Neovim"), nil)
  eq(report:find("ERROR"), nil)
end

return T
