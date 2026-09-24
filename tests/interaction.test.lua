-- What the pointer and the keyboard do to a screen: the wheel and a scroll bar, the buttons that
-- are not the left one, the keyboard going from one thing to the next, and the two things a style
-- says about text -- how tall it is, and what it does when it does not fit.
--
-- These need a screen, so they need a gpu and a font on the machine: they skip where either is
-- missing, the way the rendering tests do.
--
-- A screen is a gpu device of its own, and a machine hands a process a few dozen of them and no
-- more: these tests draw one screen each and ask it everything they have to ask, rather than one
-- screen an assertion.
local test = require("lde-test")
local elementModule = require("wonderland.element")
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local FONT_PATHS = {
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/Library/Fonts/Arial.ttf",
	"C:/Windows/Fonts/arial.ttf",
}

local fontPath = nil
for _, path in ipairs(FONT_PATHS) do
	local file = io.open(path, "rb")

	if file then
		file:close()
		fontPath = path
		break
	end
end

local gpuErr = nil

if fontPath then
	local ok, err = pcall(function()
		local screen = wonderland.headless.new(function()
			return div():children(text("x"))
		end, { width = 8, height = 8, fontPath = assert(fontPath) })

		screen:close()
	end)

	if not ok then
		gpuErr = tostring(err)
		print("interaction tests skipped: " .. gpuErr)
	end
end

local canRender = fontPath ~= nil and gpuErr == nil

local WIDTH, HEIGHT = 200, 140

--- A screen of the view, drawn once so that a press has boxes to land on.
---@param view fun(): wonderland.Element
---@param onMessage fun(message: any)?
---@return wonderland.Headless
local function aScreen(view, onMessage)
	local screen = wonderland.headless.new(view, {
		width = WIDTH,
		height = HEIGHT,
		fontPath = assert(fontPath),
		onMessage = onMessage,
	})

	screen:draw()

	return screen
end

--- An event into the screen, with the window it happened in filled in: what a loop hands over.
---@param screen wonderland.Headless
---@param event winit.Event
---@return any? message
local function send(screen, event)
	event.window = screen.window

	return screen:event(event)
end

--- The rows of a band that have ink on them.
---@param pixels string
---@param top number
---@param bottom number
---@return number first
---@return number last
local function inkRows(pixels, top, bottom)
	local first, last = nil, nil

	for y = top, bottom do
		for x = 0, WIDTH - 1 do
			local at = (y * WIDTH + x) * 4 + 1
			local r, g, b = pixels:byte(at, at + 2)

			if (r or 0) + (g or 0) + (b or 0) > 30 then
				first = first or y
				last = y
				break
			end
		end
	end

	return first or 0, last or 0
end

--- The runs of columns with ink on them in a band of rows, which is one run per thing drawn a few
--- pixels apart: the letters of a word are pixels apart, and two things in a row are the gap
--- between them apart.
---@param pixels string
---@param top number
---@param bottom number
---@return { first: number, last: number }[]
local function inkRuns(pixels, top, bottom)
	local runs, current = {}, nil
	local blank = 0

	for x = 0, WIDTH - 1 do
		local inked = false

		for y = top, bottom do
			local at = (y * WIDTH + x) * 4 + 1
			local r, g, b = pixels:byte(at, at + 2)

			if (r or 0) + (g or 0) + (b or 0) > 30 then
				inked = true
				break
			end
		end

		if inked then
			if current ~= nil and blank <= 4 then
				current.last = x
			else
				current = { first = x, last = x }
				runs[#runs + 1] = current
			end

			blank = 0
		else
			blank = blank + 1
		end
	end

	return runs
end

--- The name an element was given, which is how the layout knows which field has the keyboard.
---@param screen wonderland.Headless
---@return string? name
local function focusedName(screen)
	local element = screen.plugins.layout:getCaret(screen.window)

	return element ~= nil and elementModule.nameOf(element) or nil
end

--- The screen as it was solved, and the node it was built from: where the size text came out to and
--- how wide a line that was cut is are read from the nodes.
---@param screen wonderland.Headless
---@return wonderland.Layout.Screen
---@return number root
local function solved(screen)
	local ctx = assert(screen.plugins.layout.contexts[screen.window])

	return assert(ctx.screen), assert(ctx.root)
end

-- A pane of twenty rows of twenty pixels in a box a hundred tall: three hundred pixels of content
-- past what the box shows, which is what its bar is drawn from.
---@param onScroll fun(by: number?, to: number?): any
---@return wonderland.Element
local function aPane(onScroll)
	local rows = {}

	for index = 1, 20 do
		rows[index] = div():style(sty():wrel(1.0):h(20)):children(text(string.format("Row %d", index)))
	end

	return div():style(sty():w(200):h(100):column():bar(8, 20, "#ffffff"))
		:children(rows)
		:scroll(0)
		:onScroll(onScroll)
end

test.skipIf(not canRender)("sends a wheel to the box under the pointer that scrolls", function()
	local said = {}

	local screen = aScreen(function()
		return div():style(sty():fill():column()):children({
			aPane(function(by, to)
				local message = { type = "scroll", by = by, to = to }

				said[#said + 1] = message

				return message
			end),
			div():style(sty():w(50):h(20)),
		})
	end)

	-- Over the pane: the box under the pointer hears about it, and is told how far it turned.
	send(screen, { name = "mouseMove", x = 20, y = 20 })

	local message = send(screen, { name = "mouseScroll", dy = 1 })

	test.truthy(message ~= nil, "the box under the pointer hears the wheel")
	test.equal(assert(message).by, 1)
	test.equal(#said, 1)

	-- Below it: nothing scrolls there, so the event is left for the app, which is what a screen
	-- with no box for it wants.
	send(screen, { name = "mouseMove", x = 20, y = 115 })

	test.falsy(send(screen, { name = "mouseScroll", dy = 1 }), "and a wheel elsewhere is nobody's here")
	test.equal(#said, 1)

	screen:close()
end)

test.skipIf(not canRender)("drags the bar of a box that scrolls, and only its bar", function()
	local said = {}

	local screen = aScreen(function()
		return div():style(sty():fill()):children(aPane(function(by, to)
			local message = { type = "scroll", by = by, to = to }

			said[#said + 1] = message

			return message
		end))
	end)

	-- A press on a row of the pane is a press on the row, and not on the bar down the side of it.
	send(screen, { name = "mousePress", x = 100, y = 50, button = 1 })

	test.equal(#said, 0, "a press on the content is not a press on the bar")

	-- The bar is the strip down the right hand side of the pane, eight pixels wide, and the thumb
	-- is the share of the content the box shows: a press below it is a press on the track.
	local pressed = assert(send(screen, { name = "mousePress", x = 196, y = 50, button = 1 }))

	test.equal(pressed.to, 152, "a press on the track says where in the content the thumb was put")

	local dragged = assert(send(screen, { name = "mouseMove", x = 196, y = 100 }))

	test.greater(dragged.to, pressed.to, "and a drag goes on moving it")

	send(screen, { name = "mouseRelease", x = 196, y = 100, button = 1 })

	test.falsy(send(screen, { name = "mouseMove", x = 196, y = 60 }), "until it is let go of")

	screen:close()
end)

test.skipIf(not canRender)("gives a press of the right button to the context menu alone", function()
	local seen = {}
	local held = nil

	local screen = aScreen(function()
		return div():style(sty():fill():column()):children({
			div():style(sty():w(100):h(60)):children(text("a row"))
				:onClick({ type = "click" })
				:onContextMenu(function(x, y)
					return { type = "menu", x = x, y = y }
				end),
			div():style(sty():w(100):h(60)):onMouseDown(function(_, _, _, _, modifiers)
				held = modifiers

				return { type = "pressed" }
			end),
		})
	end, function(message)
		seen[#seen + 1] = message
	end)

	local message = send(screen, { name = "mousePress", x = 20, y = 20, button = 3 })

	test.equal(assert(message).type, "menu", "the right button opens a menu")
	test.equal(assert(message).x, 20, "where in the box it was pressed")

	send(screen, { name = "mouseRelease", x = 20, y = 20, button = 3 })

	test.equal(#seen, 1, "and neither the press nor the release is a click")

	screen:click(20, 20)

	test.equal(#seen, 2, "the left button is a click, and only a click")
	test.equal(seen[2].type, "click")

	-- A mouse event carries no modifiers, so what is held is what the keyboard last said: a person
	-- holds shift down before pressing the pointer. What a press is told about is a box that is not
	-- a click: a click answers first, and a press after it is never reached.
	send(screen, { name = "keyPress", key = "left-shift", modifiers = { shift = true } })
	send(screen, { name = "mousePress", x = 20, y = 100, button = 1 })

	test.truthy(held ~= nil, "and a press is told what was held")
	test.equal(assert(held).shift, true)

	screen:close()
end)

--- A field that reports what is typed into it.
---@param name string
---@return wonderland.Element
local function aField(name)
	return div():style(sty():w(100):h(20)):input({
		name = name,
		value = "",
		oninput = function(value)
			return { type = "typed", value = value }
		end,
	})
end

test.skipIf(not canRender)("moves the keyboard with tab, and works what it lands on", function()
	local seen = {}

	local screen = aScreen(function()
		return div():style(sty():fill():column()):children({
			aField("first"),
			aField("second"),
			div():style(sty():w(100):h(20)):focus(sty():bg("#333333")):named("button"):onClick({
				type = "pressed",
			}),
		})
	end, function(message)
		seen[#seen + 1] = message
	end)

	---@return number
	local function presses()
		local count = 0

		for _, message in ipairs(seen) do
			if message.type == "pressed" then
				count = count + 1
			end
		end

		return count
	end

	test.equal(focusedName(screen), nil, "nothing has the keyboard to begin with")

	screen:click(10, 10)

	test.equal(focusedName(screen), "first", "a click puts the keyboard in the field it landed in")

	send(screen, { name = "keyPress", key = "tab", modifiers = {} })

	test.equal(focusedName(screen), "second", "tab goes to the field after it")

	send(screen, { name = "keyPress", key = "tab", modifiers = { shift = true } })

	test.equal(focusedName(screen), "first", "and shift with it goes back")

	send(screen, { name = "keyPress", key = "tab", modifiers = { shift = true } })
	screen:draw()

	test.equal(focusedName(screen), nil, "and back past the first is the last thing on the screen")
	test.equal(screen.plugins.layout.contexts[screen.window].focusedName, "button",
		"which is the thing that answers a click, and has no caret")

	send(screen, { name = "keyPress", key = "tab", modifiers = {} })

	test.equal(focusedName(screen), "first", "tab carries on around the screen")

	-- On to the second field and then to the thing that answers a click, which is what the work
	-- below is about.
	send(screen, { name = "keyPress", key = "tab", modifiers = {} })
	send(screen, { name = "keyPress", key = "tab", modifiers = {} })
	screen:draw()

	test.equal(focusedName(screen), nil, "the thing after the last field has no caret")
	test.falsy(screen.plugins.ui:caretFor(screen.window),
		"and nothing for a screen to blink every half second: a caret is what a field has")

	send(screen, { name = "keyPress", key = "return", modifiers = {} })

	test.equal(presses(), 1, "and return works it")

	send(screen, { name = "keyPress", key = "space", modifiers = {} })

	test.equal(presses(), 2, "and so does space")

	screen:close()
end)

test.skipIf(not canRender)("draws text at the size and in the family a style names", function()
	local screen = aScreen(function()
		return div():style(sty():fill():column():gap(4):bg("#000000")):children({
			text("Hxg"):style(sty():fg("#ffffff")),
			text("Hxg"):style(sty():fg("#ffffff"):text("xs")),
			text("Hxg"):style(sty():fg("#ffffff"):text(30)),
			text("Hxg"):style(sty():fg("#ffffff"):text("3xl")),
			text("Hxg"):style(sty():fg("#ffffff"):font("A Family Nobody Has")),
		})
	end)

	local nodes, root = solved(screen)
	local base = nodes:node(root + 1).height
	local small = nodes:node(root + 2).height
	local counted = nodes:node(root + 3).height
	local named = nodes:node(root + 4).height
	local unknown = nodes:node(root + 5).height

	test.greater(base, small, "a size below the one an app starts at is shorter than it")
	test.greater(counted, base, "and one above it is taller")
	test.equal(named, counted, "a size from the scale is the pixels it names")
	test.greater(unknown, 0, "and a family this machine does not have is drawn in one it has")

	screen:close()
end)

test.skipIf(not canRender)("cuts a line that does not fit to the room it has", function()
	local screen = aScreen(function()
		local title = "a title far too long for its box"

		return div():style(sty():fill():column():bg("#000000")):children({
			div():style(sty():w(40):h(20)):children(
				text(title):style(sty():fg("#ffffff"):ellipsis())
			),
			div():style(sty():w(40):h(20)):children(text(title):style(sty():fg("#ffffff"))),
			div():style(sty():w(100):h(20):row():gap(8)):children({
				text(title):style(sty():fg("#ffffff"):ellipsis()),
				text("3:21"):style(sty():fg("#ffffff")),
			}),
		})
	end)

	local pixels = assert(screen:getPixels())
	local cut = inkRuns(pixels, 0, 19)
	local whole = inkRuns(pixels, 20, 39)
	local row = inkRuns(pixels, 40, 59)

	screen:close()

	test.equal(#cut, 1, "a line asked to be cut is drawn once")
	test.truthy(cut[1].last <= 39, string.format("and stops at its box, at %d", cut[1].last))
	test.greater(whole[#whole].last, 40, "while one that was not draws past the box it is in")
	test.greater(whole[#whole].last, cut[1].last, "which is shorter than what it would have been")

	test.equal(#row, 2, "a title beside a duration in a row is two things drawn")
	test.truthy(row[1].last < row[2].first, "and the title stops before the time beside it starts")
	test.greater(row[2].last, 60, "which is where the row put it")
end)

test.skipIf(not canRender)("lays a cut line out as wide as it was cut to", function()
	local screen = aScreen(function()
		return div():style(sty():fill():column():bg("#000000")):children(
			div():style(sty():w(60):h(20)):children(
				text("a title far too long for its box"):style(sty():fg("#ffffff"):ellipsis())
			)
		)
	end)

	local nodes, root = solved(screen)
	local line = nodes:node(root + 2)

	screen:close()

	test.truthy(line.width < 60, string.format("the line is as wide as it was cut to, at %f", line.width))
	test.greater(line.width, 0, "and something of it is left")
end)
