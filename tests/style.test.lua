-- The style surface: what a screen says it looks like, and the rule that keeps it
-- readable by the engine.
local test = require("lde-test")
local element = require("wonderland.element")
local style = require("wonderland.style")
local sty = style.new

local div, text = element.div, element.text

--- The children of an element, in the order they were added: they are one chain of
--- indices, so reading them back is a walk.
---@param el wonderland.Element
---@return wonderland.Element[]
local function children(el)
	local list = {}
	local at = el.childFirst

	while at ~= 0 do
		local child = element.at(at)

		list[#list + 1] = child
		at = child.nextSibling
	end

	return list
end

---@param screen wonderland.Layout.Screen
---@param index number
---@param at number?
---@return wonderland.Node
local function child(screen, index, at)
	local node = screen:node(index)

	return screen:node(screen.childIndices[node.firstChild + (at or 1) - 2])
end

-- What an element holds is a slot in the style arena rather than a table: the layout
-- reads the struct that slot is, so a style costs one array index per element and a
-- comparison of two styles is a comparison of two numbers.
test.it("what an element holds is a slot in the style arena", function()
	local written = sty():bg("red"):w(8)
	local el = div():style(written)
	local slot = style.at(el.baseStyle)

	test.equal(el.baseStyle, style.intern(written), "the slot is the style it was given")
	test.equal(slot.bgR, 1.0, "and what was set is in it")
	test.equal(slot.wantWidth, 8)
	test.equal(slot.widthUnit, style.ABS, "in pixels")
	test.equal(slot.paint, 1, "a background is painted")
	test.equal(slot.fgA, 0, "while a colour that was not set reads as nothing")
	test.equal(slot.font, 0)
end)

test.it("a style can also be written out as a table by hand", function()
	local el = div():style({ bg = { r = 0.25, g = 0.5, b = 0.75, a = 1.0 }, width = { abs = 4 } })
	local slot = style.at(el.baseStyle)

	test.equal(slot.bgG, 0.5)
	test.equal(slot.wantWidth, 4)
	test.equal(slot.widthUnit, style.ABS)
end)

test.it("colours are taken by name, by hex, or as the channels", function()
	test.match(sty():bg("red").values.bg, { r = 1.0, g = 0.0, b = 0.0, a = 1.0 })
	test.equal(sty():fg("#00ff00").values.fg.g, 1.0)
	test.equal(sty():bg("#0000ff80").values.bg.a, 128 / 255)
	test.equal(sty():bg({ r = 0.25, g = 0.5, b = 0.75, a = 1.0 }).values.bg.g, 0.5)

	local ok, err = pcall(function()
		return sty():bg("chartreuse")
	end)
	test.falsy(ok, "a colour nobody knows is refused")
	test.truthy(tostring(err):match("Not a colour"), "and says so")
end)

test.it("a style is a value, so one can be handed to many elements", function()
	local shared = sty():bg("#123456")
	local first, second = div():style(shared), div():style(shared)

	test.equal(first.baseStyle, second.baseStyle, "both elements hold the same slot")
	test.equal(style.at(second.baseStyle).bgR, 0x12 / 255)
end)

-- Two styles that say the same thing are one slot, which is what lets a screen that
-- writes an identical style every repaint add nothing to the arena.
test.it("a style written twice interns to one slot", function()
	local first = sty():bg("#262b38"):pad(12):column():fg("#e6e6e6")
	local second = sty():bg("#262b38"):pad(12):column():fg("#e6e6e6")
	local other = sty():bg("#262b38"):pad(12):column():fg("#ffffff")

	test.equal(style.intern(first), style.intern(second))
	test.greater(other and style.intern(other) or 0, 0, "a different style is somewhere of its own")
	test.falsy(style.intern(other) == style.intern(first))
end)

-- A radius is a field of the style like any other, so a style that differs only in how round
-- its corners are is a style of its own: interning compares the whole struct.
test.it("how round the corners are is part of what a style says", function()
	local round = sty():bg("red"):radius(8)
	local square = sty():bg("red")

	test.equal(style.at(style.intern(round)).radius, 8, "what it names is in the slot")
	test.equal(style.at(style.intern(square)).radius, 0, "and a style that names none is square")
	test.falsy(style.intern(round) == style.intern(square), "so they are two slots, not one")
end)

test.it("hover, active and focus are kept on the element", function()
	local el = div():hover(sty():fg("red")):active(sty():bg("blue")):focus(sty():bg("green"))

	test.greater(el.hoverStyle, 0, "the hover style is there")
	test.equal(style.at(el.hoverStyle).fgR, 255)
	test.equal(style.at(el.activeStyle).bgB, 1.0)
	test.greater(el.focusStyle, 0)
	test.equal(el.baseStyle, 0, "and an element that named no style of its own is the empty one")
end)

test.it("sizes are pixels, shares of the space, or automatic", function()
	test.equal(sty():w(8).values.width, 8)
	test.match(sty():wrel(0.25).values.width, { rel = 0.25 })
	test.equal(sty():h("auto").values.height, "auto")
	test.match(sty():fill().values.width, { rel = 1.0 })
	test.match(sty():fill().values.height, { rel = 1.0 })
	test.equal(sty():size(4, 6).values.height, 6)
end)

test.it("padding and margins take one, two or four numbers", function()
	test.match(sty():pad(8).values.padding, { top = 8, bottom = 8, left = 8, right = 8 })
	test.match(sty():pad(8, 16).values.padding, { top = 8, bottom = 8, left = 16, right = 16 })
	test.match(sty():pad(1, 2, 3, 4).values.padding, { top = 1, right = 2, bottom = 3, left = 4 })
	test.match(sty():margin(4).values.margin, { top = 4, bottom = 4, left = 4, right = 4 })
end)

test.it("a border is one line on every side", function()
	local border = assert(sty():border(2, "red").values.border)
	local top, bottom = assert(border.top), assert(border.bottom)
	local left, right = assert(border.left), assert(border.right)

	test.equal(top.width, 2)
	test.equal(bottom.width, 2)
	test.equal(assert(left.color).r, 1.0)
	test.equal(assert(right.color).r, 1.0)
end)

test.it("a direction is said as a row, a column, or the axis itself", function()
	test.equal(sty():row().values.direction, "row")
	test.equal(sty():column().values.direction, "column")
	test.equal(sty():flex("row").values.direction, "row")
end)

test.it("elements are built by calling, and children take elements or strings", function()
	local el = div():style(sty():row()):children(text("one"), "two"):children({ div(), "three" })
	local nodes = children(el)

	test.equal(#nodes, 4, "two from the first call, two from the second")
	test.equal(el.childCount, 4, "and the count says so without a walk")
	test.equal(element.textOf(nodes[1]), "one")
	test.equal(element.textOf(nodes[2]), "two", "a string becomes an element that draws it")
	test.equal(element.textOf(nodes[3]), nil, "and an element with children draws nothing itself")
	test.equal(element.textOf(nodes[4]), "three")
end)

-- A string is a child like any other, and there is no separate kind of element for it:
-- it is an element with a line on it and no children, and it draws whatever the elements
-- above it say text looks like.
test.it("a string child is an element that draws a line", function()
	local el = div():children("hello")
	local only = children(el)[1]

	test.equal(#children(el), 1)
	test.equal(element.textOf(only), "hello")
	test.equal(only.childCount, 0, "and it has nothing inside it")
end)

test.it("a line is drawn in what its parents say, unless it says otherwise", function()
	local UIBuilder = require("wonderland.util.font_manager")
	test.truthy(UIBuilder, "the font manager is where a font comes from")

	local red = sty():fg("red")
	local blue = sty():fg("blue")

	-- The nearest element that says wins.
	local layout = require("wonderland.layout")
	local tree = div():style(red):children(
		div():style(blue):children("inner"),
		"outer"
	)

	local screen = layout.new()
	screen:fromElement(tree)
	screen:solve(100, 100)

	local first, second = child(screen, 1, 1), child(screen, 1, 2)
	test.equal(screen:node(1).fgR, 255, "the box takes what it was given")
	test.equal(first.fgB, 255, "a child that says its own colour keeps it")
	test.equal(second.fgR, 255, "and one that says nothing takes the nearest above")
end)

test.it("what is not text is not inherited", function()
	local layout = require("wonderland.layout")

	local screen = layout.new()
	screen:fromElement(div():style(sty():bg("red")):children(div():style(sty():w(4))))
	screen:solve(100, 100)

	local inner = child(screen, 1)
	test.equal(inner.paint, 0, "a background belongs to the box that has it")
	test.equal(inner.width, 4, "while what it does say about itself is kept")
end)

test.it("an element with no style at all draws nothing and does not fall over", function()
	local layout = require("wonderland.layout")

	local screen = layout.new()
	screen:fromElement(div():children(div()))
	screen:solve(100, 100)

	test.equal(screen:node(1).paint, 0, "there is nothing to paint")
	test.truthy(child(screen, 1), "and its child is still laid out")
end)

test.it("an element can be named, for input focus", function()
	local el = div():named("field")

	test.equal(element.nameOf(el), "field")
	test.equal(element.nameOf(div()), nil, "and an element with no name has none")
end)

test.it("text is drawn in the family and at the size a style names", function()
	local named = sty():font("Inter"):text("lg")
	local counted = sty():font("Inter"):text(18)

	test.equal(style.intern(named), style.intern(counted), "a size from the scale is the pixels it is")

	local other = sty():font("A Family Nobody Has"):text("lg")
	test.truthy(style.intern(other) ~= style.intern(named), "and another family is another style")

	local slot = style.intern(named)
	local handle = style.at(slot).fontFamily

	test.equal(style.familyAt(handle), "Inter", "which holds the name rather than a font: a style is bytes")
	test.equal(style.at(slot).fontSize, 18, "at eighteen pixels")
end)

test.it("a size that is not on the scale is not a size", function()
	local ok, err = pcall(function()
		return sty():text("enormous")
	end)

	test.falsy(ok, "a name that is not a size is refused")
	test.truthy(tostring(err):match("Not a text scale"), "and says so")

	local badWeight, weightErr = pcall(function()
		return sty():font("Inter", { weight = "heavyish" })
	end)

	test.falsy(badWeight, "and so is a weight that is not one")
	test.truthy(tostring(weightErr):match("Not a font weight"), "and says so")
end)

test.it("a weight is taken by name or by number", function()
	local byName = sty():font("Inter", { weight = "semibold" })
	local byNumber = sty():font("Inter", { weight = 600 })

	test.equal(style.intern(byName), style.intern(byNumber), "semibold is six hundred")

	local slot = style.intern(byName)
	test.equal(style.at(slot).fontWeight, 600)
	test.equal(style.at(slot).fontItalic, 0, "and a style that says nothing about a slant is upright")
end)

test.it("says whether a line too wide for its box is cut", function()
	local cut = sty():ellipsis()

	test.equal(style.at(style.intern(cut)).ellipsis, 1, "a box that asked for it is cut")
	test.falsy(style.at(style.intern(sty())) and style.at(style.intern(sty())).ellipsis ~= 0,
		"and one that said nothing is not")
end)
