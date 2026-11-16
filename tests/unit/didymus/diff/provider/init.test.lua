local eq = MiniTest.expect.equality
local provider = require("didymus.diff.provider")

local T = MiniTest.new_set()

T["get()"] = MiniTest.new_set()

T["get()"]["gives the built-in provider of a name"] = function()
  eq(provider.get("gitsigns") == require("didymus.diff.provider.gitsigns"), true)
  eq(provider.get("test") == require("didymus.diff.provider.test"), true)
end

T["get()"]["gives a provider table back"] = function()
  local custom = { capabilities = {} }
  eq(provider.get(custom) == custom, true)
end

T["get()"]["gives an error for an unknown name"] = function()
  eq(
    { provider.get("unknown") },
    { nil, 'unknown provider "unknown". Use "gitsigns", "test" or a provider table.' }
  )
end

return T
