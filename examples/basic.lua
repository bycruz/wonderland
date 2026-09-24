-- A screen laid out without a window, so it runs on its own:
--
--   lde ./examples/basic.lua
--
-- A share of the space is a fraction of what the parent has, so a page is built out of
-- shares that add up: a title bar and a body, then the body split in two.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty
local Layout = wonderland.Layout

local page = div():style(sty():column()):children(
	div():style(sty():hrel(0.15)),                                -- a title bar
	div():style(sty():row():hrel(0.85)):children(                 -- and a body holding
		div():style(sty():wrel(0.25):hrel(1.0)),                  -- a sidebar and
		div():style(sty():wrel(0.75):hrel(1.0))                   -- the content beside it
	)
)

---@param screen wonderland.Layout.Screen
---@param index number
---@param depth number
local function show(screen, index, depth)
	local node = screen:node(index)

	print(string.format("%s%4gx%-4g at (%4g, %4g)", string.rep("  ", depth), node.width, node.height, node.x, node.y))

	for at = 0, node.childCount - 1 do
		show(screen, screen.childIndices[node.firstChild + at - 1], depth + 1)
	end
end

print("an 800x600 screen")
show(Layout.screen(page, 800, 600), 1, 0)
