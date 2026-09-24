-- Geometry: what a screen solves to. Every test lays an element tree out and reads the
-- nodes it produced, which is the same path a frame takes.
local test = require("lde-test")
local layout = require("wonderland.layout")
local wonderlandElement = require("wonderland.element")
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@param element wonderland.Element
---@param width number
---@param height number
---@return wonderland.Layout.Screen
local function solve(element, width, height)
	local screen = layout.new()
	screen:fromElement(element)
	screen:solve(width, height)

	return screen
end

---@param screen wonderland.Layout.Screen
---@param index number
---@param at number?
---@return wonderland.Node
local function child(screen, index, at)
	local node = screen:node(index)

	-- childIndices is a plain array, so the run that starts at firstChild begins one
	-- before it.
	return screen:node(screen.childIndices[node.firstChild + (at or 1) - 2])
end

-- A style kept for the pointer stands in for the base one and says only what it names: one
-- that names a background and nothing else must leave the size, the padding and the direction
-- alone, or hovering a button would make it take the whole screen.
test.it("a style kept for the pointer says only what it names", function()
	local button = div():style(sty():size(200, 44):bg("#426bd9")):hover(sty():bg("#ff0000"))

	wonderlandElement.hovering(button, true)

	local node = solve(button, 400, 300):node(1)
	test.equal(node.width, 200, "the size is what the style it stood in for said")
	test.equal(node.height, 44)
	test.equal(node.bgR, 1.0, "and the background is what it said itself")
	test.equal(node.bgG, 0.0)
	test.equal(node.bgB, 0.0)
end)

-- Brightness is how a hover or active style usually says what it wants: the colours an element
-- already has, lit differently, rather than a second set of them to keep in step.
test.it("a bright style lights the colours the element already has", function()
	local button = div():style(sty():size(200, 44):bg("#404040")):hover(sty():bright(2))

	wonderlandElement.hovering(button, true)

	local node = solve(button, 400, 300):node(1)
	test.equal(node.width, 200, "the size is what the style it stood in for said")
	test.equal(node.height, 44)
	test.equal(node.bgR, 128 / 255, "and the background is twice as bright")
	test.equal(node.fgA, 0, "with nothing said about a colour it did not have")
end)

test.it("brightness stops at white and leaves transparency alone", function()
	local lit = solve(div():style(sty():bg("#808080"):fg("#404040"):bright(4)), 400, 300):node(1)

	test.equal(lit.bgR, 1.0, "four times a half is white, and not more than white")
	test.equal(lit.bgA, 1.0, "alpha is not a colour")
	test.equal(lit.fgR, 255, "a text colour stops at white too")
end)

-- Where the corners are round is what a box says about itself, so a style that stands in for it
-- and says nothing about them leaves them alone: a card that lights up under the pointer is still
-- a card with round corners.
test.it("a style that stands in for another keeps the corners it did not name", function()
	local card = div():style(sty():size(200, 44):bg("#426bd9"):radius(8)):hover(sty():bright(1.25))

	wonderlandElement.hovering(card, true)
	test.equal(solve(card, 400, 300):node(1).radius, 8, "the corners are what the style it stood in for said")

	local squared = div():style(sty():size(200, 44):bg("#426bd9"):radius(8)):hover(sty():radius(0))

	wonderlandElement.hovering(squared, true)
	test.equal(solve(squared, 400, 300):node(1).radius, 0, "and one that does name them is what is used")
end)

test.it("a bright style is not a size", function()
	local button = div():style(sty():size(200, 44)):active(sty():bright(0.5))

	wonderlandElement.hovering(button, true)
	wonderlandElement.pressing(button, true)

	local node = solve(button, 400, 300):node(1)
	test.equal(node.width, 200, "held down, a button stays the size it was")
	test.equal(node.height, 44)
end)

test.it("a pressed style is used in place of a hovered one", function()
	local button = div():style(sty():size(200, 44)):hover(sty():bg("#ff0000")):active(sty():bg("#0000ff"))

	wonderlandElement.hovering(button, true)
	wonderlandElement.pressing(button, true)

	local node = solve(button, 400, 300):node(1)
	test.equal(node.width, 200)
	test.equal(node.bgB, 1.0, "held down, the active style is the one used")
	test.equal(node.bgR, 0.0)
end)

-- ────────────────────────────────────────────────────────────────
-- defaults
-- ────────────────────────────────────────────────────────────────

test.it("a screen fills the space it is given by default", function()
	local screen = solve(div(), 400, 300)

	test.equal(screen:node(1).width, 400)
	test.equal(screen:node(1).height, 300)
end)

test.it("the default direction is a row", function()
	local screen = solve(div():children(div():style(sty():w(150)), div():style(sty():w(150))), 400, 300)

	test.equal(screen:node(1).direction, 0)
	test.equal(child(screen, 1, 1).x, 0)
	test.equal(child(screen, 1, 2).x, 150, "the second is placed after the first")
end)

test.it("the default position is static", function()
	local screen = solve(div():style(sty():w(10):h(10)), 400, 300)

	test.equal(screen:node(1).x, 0)
	test.equal(screen:node(1).y, 0)
	test.equal(screen:node(1).position, 0)
end)

test.it("zIndex starts at zero", function()
	test.equal(solve(div(), 400, 300):node(1).zIndex, 0)
	test.equal(solve(div():style(sty():z(5)), 400, 300):node(1).zIndex, 5)
end)

-- ────────────────────────────────────────────────────────────────
-- sizes
-- ────────────────────────────────────────────────────────────────

test.it("a share of the space is that share of the parent", function()
	test.equal(solve(div():style(sty():wrel(1.0):hrel(1.0)), 400, 300):node(1).width, 400)
	test.equal(solve(div():style(sty():wrel(0.5):hrel(0.5)), 400, 300):node(1).width, 200)
	test.equal(solve(div():style(sty():wrel(0.5):hrel(0.5)), 400, 300):node(1).height, 150)
end)

test.it("an absolute size does not depend on the parent", function()
	local node = solve(div():style(sty():size(120, 80)), 400, 300):node(1)

	test.equal(node.width, 120)
	test.equal(node.height, 80)
end)

test.it("an automatic size takes what is available", function()
	test.equal(solve(div():style(sty():w("auto")), 400, 300):node(1).width, 400)
end)

test.it("a line of text is the size of the line it measured", function()
	local line = text("hello")
	wonderlandElement.setRun(line, { width = 84, height = 18, glyphs = nil, count = 0, id = 1 })

	local node = solve(line, 400, 300):node(1)
	test.equal(node.width, 84)
	test.equal(node.height, 18)
end)

test.it("a hidden element takes no room and its children are left alone", function()
	local screen = solve(div():style(sty():hidden()):children(div():style(sty():w(10))), 400, 300)
	local node = screen:node(1)

	test.equal(node.width, 0)
	test.equal(node.height, 0)
	test.equal(node.visible, 0)
	test.falsy(child(screen, 1).width > 0, "nothing inside it was laid out")
end)

-- ────────────────────────────────────────────────────────────────
-- margins, padding, borders
-- ────────────────────────────────────────────────────────────────

test.it("margins move the element and take room from its children", function()
	test.equal(solve(div():style(sty():margin(0, 0, 0, 20):wrel(1.0)), 400, 300):node(1).x, 20)
	test.equal(solve(div():style(sty():margin(15, 0, 0, 0):hrel(1.0)), 400, 300):node(1).y, 15)

	local inset = solve(div():style(sty():margin(0, 10, 0, 10)):children(div():style(sty():wrel(1.0))), 400, 300)
	test.equal(child(inset, 1).width, 380, "the child gets what is left")

	local short = solve(div():style(sty():margin(25, 0, 25, 0)):children(div():style(sty():hrel(1.0))), 400, 300)
	test.equal(child(short, 1).height, 250)
end)

test.it("padding moves the children in and takes room from them", function()
	local padded = solve(div():style(sty():pad(0, 0, 0, 10)):children(div():style(sty():w(50))), 400, 300)
	test.equal(child(padded, 1).x, 10)

	local dropped = solve(div():style(sty():pad(8, 0, 0, 0)):children(div():style(sty():h(50))), 400, 300)
	test.equal(child(dropped, 1).y, 8)

	local shrunk = solve(div():style(sty():pad(10, 20)):children(div():style(sty():fill())), 400, 300)
	test.equal(child(shrunk, 1).width, 360)
	test.equal(child(shrunk, 1).height, 280)
end)

test.it("a border takes room from the children", function()
	local bordered = solve(div():style(sty():border(3, "red")):children(div():style(sty():fill())), 400, 300)

	test.equal(child(bordered, 1).width, 394)
	test.equal(child(bordered, 1).height, 294)
end)

-- ────────────────────────────────────────────────────────────────
-- placing children
-- ────────────────────────────────────────────────────────────────

test.it("a row places children side by side, a column stacks them", function()
	local row = solve(div():style(sty():row()):children(div():style(sty():w(150)), div():style(sty():w(150))),
		400, 300)
	test.equal(child(row, 1, 1).x, 0)
	test.equal(child(row, 1, 2).x, 150)

	local column = solve(div():style(sty():column()):children(div():style(sty():h(120)),
		div():style(sty():h(120))), 400, 300)
	test.equal(child(column, 1, 1).y, 0)
	test.equal(child(column, 1, 2).y, 120)
end)

test.it("children take the whole cross axis and start at its beginning", function()
	local row = solve(div():style(sty():row()):children(div(), div()), 400, 300)

	test.equal(child(row, 1, 1).height, 300)
	test.equal(child(row, 1, 2).height, 300)
	test.equal(child(row, 1, 1).y, 0)

	local column = solve(div():style(sty():column()):children(div(), div()), 400, 300)

	test.equal(child(column, 1, 1).width, 400)
	test.equal(child(column, 1, 2).width, 400)
	test.equal(child(column, 1, 2).x, 0)
end)

test.it("a gap goes between children and not after the last one", function()
	local row = solve(div():style(sty():row():gap(20)):children(div():style(sty():w(100)),
		div():style(sty():w(100))), 400, 300)
	test.equal(child(row, 1, 1).x, 0)
	test.equal(child(row, 1, 2).x, 120)

	local column = solve(div():style(sty():column():gap(15)):children(div():style(sty():h(50)),
		div():style(sty():h(50))), 400, 300)
	test.equal(child(column, 1, 2).y, 65)
end)

test.it("justify says where the children sit along the axis", function()
	local function placed(justify)
		local screen = solve(div():style(sty():row():justify(justify)):children(
			div():style(sty():w(100)),
			div():style(sty():w(100))
		), 400, 300)

		return child(screen, 1, 1).x, child(screen, 1, 2).x
	end

	local start, startSecond = placed("start")
	test.equal(start, 0)
	test.equal(startSecond, 100)

	local centre, centreSecond = placed("center")
	test.equal(centre, 100)
	test.equal(centreSecond, 200)

	local finish, finishSecond = placed("end")
	test.equal(finish, 200)
	test.equal(finishSecond, 300)
end)

test.it("space-between and space-around spread the children out", function()
	local between = solve(div():style(sty():row():justify("space-between")):children(
		div():style(sty():w(100)),
		div():style(sty():w(100))
	), 400, 300)
	test.equal(child(between, 1, 1).x, 0)
	test.equal(child(between, 1, 2).x, 300)

	local around = solve(div():style(sty():row():justify("space-around")):children(
		div():style(sty():w(100)),
		div():style(sty():w(100))
	), 400, 300)
	test.equal(child(around, 1, 1).x, 50)
	test.equal(child(around, 1, 2).x, 250)
end)

test.it("align says where they sit across the axis", function()
	local function placed(align)
		local screen = solve(div():style(sty():row():align(align)):children(div():style(sty():h(50))), 400, 300)

		return child(screen, 1, 1).y
	end

	test.equal(placed("start"), 0)
	test.equal(placed("center"), 125)
	test.equal(placed("end"), 250)

	local column = solve(div():style(sty():column():align("center")):children(div():style(sty():w(60))), 400, 300)
	test.equal(child(column, 1, 1).x, 170)
end)

test.it("an automatic child takes what the others leave", function()
	local one = solve(div():style(sty():row()):children(div():style(sty():w(100)), div():style(sty():w("auto"))),
		400, 300)
	test.equal(child(one, 1, 2).width, 300, "what the fixed one left")
	test.equal(child(one, 1, 2).x, 100)

	local two = solve(div():style(sty():row()):children(div():style(sty():w(100)), div():style(sty():w("auto")),
		div():style(sty():w("auto"))), 400, 300)
	test.equal(child(two, 1, 2).width, 150)
	test.equal(child(two, 1, 3).width, 150)

	local down = solve(div():style(sty():column()):children(div():style(sty():h(80)), div():style(sty():h("auto"))),
		400, 300)
	test.equal(child(down, 1, 2).height, 220, "what the fixed one left")
end)

test.it("a child can be placed by hand, without taking room in the flow", function()
	local offset = solve(div():style(sty():offset(30, 25):size(10, 10)), 400, 300):node(1)
	test.equal(offset.x, 30, "offset from where the layout would have put it")
	test.equal(offset.y, 25)

	local reversed = solve(div():style({ position = "relative", right = 20, bottom = 10, width = 10, height = 10 }),
		400, 300):node(1)
	test.equal(reversed.x, -20, "and from the far edge when that is what it names")
	test.equal(reversed.y, -10)

	local screen = solve(div():style(sty():row()):children(
		div():style(sty():offset(50, 0):size(10, 10)),
		div():style(sty():w(40))
	), 400, 300)
	test.equal(child(screen, 1, 2).x, 0, "the one placed by hand pushed nothing along")
end)

test.it("a nested child is placed inside its parent's content", function()
	local screen = solve(div():style(sty():pad(0, 0, 0, 10)):children(
		div():style(sty():w(50)):children(div():style(sty():w(20)))
	), 400, 300)
	local outer = child(screen, 1)

	test.equal(outer.x, 10)
	test.equal(outer.width, 50)
	test.equal(child(screen, 2, 1).width, 20, "and it starts at its parent's content")
end)

test.it("a nested row gets the parent's content width", function()
	local screen = solve(div():style(sty():column():pad(20)):children(div():style(sty():wrel(1.0))), 400, 300)

	test.equal(child(screen, 1).width, 360)
end)

test.it("a text property is inherited and a background is not", function()
	local screen = solve(div():style(sty():fg("red")):children(
		div():style(sty():bg("blue")):children("inner"),
		"outer"
	), 400, 300)
	local inner, outer = child(screen, 1, 1), child(screen, 1, 2)

	test.equal(inner.fgR, 255, "the colour is taken from above")
	test.equal(outer.fgR, 255)
	test.equal(inner.bgB, 1.0, "and a background belongs to the box that has it")
	test.equal(outer.paint, 0, "so the one that has none paints nothing")
end)
