local layout = require("didymus.ui.layout")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["resolve_size()"] = function()
  eq(layout.resolve_size(0.5, 81), 40)
  eq(layout.resolve_size(30, 80), 30)
  eq(layout.resolve_size(200, 80), 80)
  eq(layout.resolve_size(0.001, 80), 1)
end

T["border_size()"] = function()
  eq({ layout.border_size("none") }, { 0, 0 })
  eq({ layout.border_size({ "╭", "─", "╮", "│", "╯", "─", "╰", "│" }) }, { 2, 2 })
  -- The "shadow" border is only on the right and the bottom.
  local shadow =
    { "", "", { " ", "A" }, { " ", "B" }, { " ", "B" }, { " ", "B" }, { " ", "A" }, "" }
  eq({ layout.border_size(shadow) }, { 1, 1 })
end

T["center_offset()"] = function()
  eq(layout.center_offset(20, 80), 30)
  eq(layout.center_offset(21, 80), 29)
  eq(layout.center_offset(80, 80), 0)
end

T["center()"] = function()
  local area = { row = 2, col = 10, width = 40, height = 20 }
  eq(layout.center(area, 20, 10, "none"), { row = 7, col = 20, width = 20, height = 10 })
  eq(
    layout.center(area, 20, 10, { "+", "-", "+", "|", "+", "-", "+", "|" }),
    { row = 6, col = 19, width = 20, height = 10 }
  )
  -- The float and its border fit in the area.
  eq(
    layout.center(area, 100, 100, { "+", "-", "+", "|", "+", "-", "+", "|" }),
    { row = 2, col = 10, width = 38, height = 18 }
  )
end

return T
