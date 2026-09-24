-- A screen with no window behind it, which is how the ui is checked: it is rendered
-- offscreen and the pixels it produced are asserted.
local test = require("lde-test")
local wonderland = require("wonderland")
local Atlas = require("wonderland.font.stbtt")

local div, text = wonderland.div, wonderland.text

local CHARACTERS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

-- Any font will do; the test skips where the machine has none.
local FONT_PATHS = {
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
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

-- Rendering needs a gpu, which a build machine may not have: rather than fail there,
-- say why and skip. The renderer needs no window, only a device.
local gpuErr = nil
if fontPath then
	local ok, err = pcall(function()
		local screen = wonderland.headless.new(function()
			return div()
		end, { width = 8, height = 8, fontPath = assert(fontPath) })

		screen:close()
	end)

	if not ok then
		gpuErr = tostring(err)
		print("headless tests skipped: " .. gpuErr)
	end
end

local canRender = fontPath ~= nil and gpuErr == nil

local WHITE = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 }

---@param pixels string
---@param width number
---@param x number
---@param y number
---@return number r, number g, number b, number a
local function pixelAt(pixels, width, x, y)
	local first = (y * width + x) * 4 + 1
	local r, g, b, a = pixels:byte(first, first + 3)

	return r, g, b, a
end

---@class InkRun
---@field first number # Leftmost column with ink on it
---@field last number # Rightmost one

--- The columns that have ink on them, as one run per group of touching glyphs.
---@param pixels string
---@param width number
---@param height number
---@return InkRun[] runs
local function inkRuns(pixels, width, height)
	local runs = {}
	local current = nil

	for x = 0, width - 1 do
		local covered = false
		for y = 0, height - 1 do
			local r, g, b = pixelAt(pixels, width, x, y)
			if (r or 0) + (g or 0) + (b or 0) > 30 then
				covered = true
				break
			end
		end

		if covered then
			if current then
				current.last = x
			else
				current = { first = x, last = x }
			end
		elseif current then
			runs[#runs + 1] = current
			current = nil
		end
	end

	if current then
		runs[#runs + 1] = current
	end

	return runs
end

---@param width number
---@param height number
---@param value string
---@param align "start" | "center"
---@return string pixels
---@return number screenWidth
local function renderText(width, height, value, align)
	local screen = wonderland.headless.new(function()
		return div():style({
			direction = "column",
			justify = "center",
			align = align,
			bg = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
		}):children({
			text(value):style({ fg = WHITE }),
		})
	end, { width = width, height = height, fontPath = assert(fontPath) })

	screen:draw()
	local pixels = assert(screen:getPixels())
	screen:close()

	return pixels, width
end

test.skipIf(not canRender)("draws the background it was asked for", function()
	local screen = wonderland.headless.new(function()
		return div():style({ width = { rel = 1.0 }, height = { rel = 1.0 }, bg = { r = 0.25, g = 0.5, b = 0.75, a = 1.0 } })
	end, { width = 4, height = 4, fontPath = assert(fontPath) })

	screen:draw()
	local pixels = assert(screen:getPixels())
	screen:close()

	local r, g, b, a = pixelAt(pixels, 4, 2, 2)

	-- The colour is written as a float and read back as a byte, so allow the one the
	-- conversion can differ by.
	local function near(value, expected)
		return value ~= nil and math.abs(value - expected) <= 1
	end

	test.truthy(near(r, 64), "a quarter of the way to white")
	test.truthy(near(g, 127))
	test.truthy(near(b, 191))
	test.equal(a, 255)
end)

test.skipIf(not canRender)("draws text where the layout put it", function()
	local pixels, width = renderText(40, 30, "abc", "start")

	-- Being laid out from the left, the ink starts at the left edge and stops well
	-- short of the right one.
	local inked = inkRuns(pixels, width, 30)
	test.equal(#inked, 3, "three letters, three runs of ink")
	test.truthy(inked[1].first <= 2, "the first starts at the left edge")
	test.truthy(inked[3].last < 34, "and the last does not reach the right edge")
end)

-- A glyph quad is exactly as wide as its ink, so a quad that starts halfway across a
-- pixel loses its last column: the fragment at its right edge falls outside it. The
-- same letter centred is therefore the case that used to come out clipped.
test.skipIf(not canRender)("draws a glyph the same width wherever it lands", function()
	local left, leftWidth = renderText(40, 30, "w", "start")
	local centred, centredWidth = renderText(101, 30, "w", "center")

	local leftRuns = inkRuns(left, leftWidth, 30)
	local centredRuns = inkRuns(centred, centredWidth, 30)

	test.equal(#leftRuns, 1, "one letter, one run of ink")
	test.equal(#centredRuns, 1)

	local drawnWidth = leftRuns[1].last - leftRuns[1].first + 1
	local centredDrawn = centredRuns[1].last - centredRuns[1].first + 1
	test.equal(centredDrawn, drawnWidth, "a centred glyph keeps every column")

	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))
	local quad = atlas:getCharUVs("w")
	test.equal(drawnWidth, math.ceil(quad.width), "and it is as wide as the atlas says")
end)

-- The frame buffers start at a screenful and grow, and writing past the end of one used
-- to be a hard error, which a long enough list reached.
test.skipIf(not canRender)("draws a screen bigger than the buffers it started with", function()
	local ROWS = 300

	local screen = wonderland.headless.new(function()
		local rows = {}

		for index = 1, ROWS do
			rows[index] = div():style({
				direction = "row",
				width = { rel = 1.0 },
				height = { abs = 20 },
			}):children({
				text(string.format("Row %d of the list", index)):style({ fg = WHITE }),
			})
		end

		return div():style({
			direction = "column",
			bg = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
		}):children(rows)
	-- The window is the clip a frame starts with, so a screen whose frame is meant to be enormous
	-- has to be enormous: what is outside it is not drawn.
	end, { width = 400, height = 6200, fontPath = assert(fontPath) })

	screen:draw()

	local ctx = assert(screen.plugins.render:getContext(screen.window))
	test.greater(ctx.nIndices, 4096 * 6, "the frame is past what the buffers start with")

	local pixels = assert(screen:getPixels())
	screen:close()

	local runs = inkRuns(pixels, 400, 6200)
	test.greater(#runs, 0, "and it drew the first rows of it")
end)

-- The frame is written into one buffer that is kept, rather than a table of numbers
-- built and thrown away per repaint.
test.skipIf(not canRender)("writes a repaint into the buffer it already has", function()
	local screen = wonderland.headless.new(function()
		return div():style({
			direction = "column",
			bg = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
		}):children({
			text("a line of text"):style({ fg = WHITE }),
		})
	end, { width = 200, height = 60, fontPath = assert(fontPath) })

	local batch = screen.plugins.ui.batch

	screen:draw()
	local vertices, capacity, quads = batch.vertices, batch.capacity, batch.quads

	screen:draw()
	test.truthy(batch.vertices == vertices, "the same memory is written into again")
	test.equal(batch.capacity, capacity, "and a frame the same size does not grow it")
	test.equal(batch.quads, quads, "and the same screen makes the same quads")

	screen:close()
end)

-- The layout is one flat array of plain data, so a repaint that comes out the same as the
-- frame the gpu already has rebuilds nothing.
test.skipIf(not canRender)("a repaint that comes out the same is not built again", function()
	local screen = wonderland.headless.new(function()
		return div():style({ bg = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 } }):children(
			text("a line of text"):style({ fg = WHITE })
		)
	end, { width = 200, height = 60, fontPath = assert(fontPath) })

	local ui = screen.plugins.ui
	local ctx = assert(screen.plugins.layout.contexts[screen.window])

	screen:draw()
	local quads = ui.batch.quads
	test.greater(quads, 0, "the first frame is always built")

	ui:refreshView(screen.window)
	test.falsy(ctx.screen.changed, "the second came out the same")
	test.equal(ui.batch.quads, quads, "so nothing was built")

	screen:close()
end)

-- Which is only safe because a line carries the id of the run it measured into: two lines
-- of the same width are still two different lines. Tabular digits make that case exactly.
test.skipIf(not canRender)("a line that changed is noticed even at the same width", function()
	local value = "12"
	local screen = wonderland.headless.new(function()
		return div():style({ bg = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 } }):children(
			text(value):style({ fg = WHITE })
		)
	end, { width = 200, height = 60, fontPath = assert(fontPath) })

	local ui = screen.plugins.ui
	local ctx = assert(screen.plugins.layout.contexts[screen.window])

	screen:draw()
	local before = ctx.screen:node(1).width

	value = "21"
	ui:refreshView(screen.window)

	test.equal(ctx.screen:node(1).width, before, "the two lines are the same width")
	test.truthy(ctx.screen.changed, "and still a change")

	screen:close()
end)

test.skipIf(not canRender)("hands a click to the screen and gives back its message", function()
	local message = nil
	local screen = wonderland.headless.new(function()
		return div():style({
			direction = "row",
			justify = "center",
			align = "center",
			width = { rel = 1.0 },
			height = { rel = 1.0 },
			bg = { r = 0, g = 0, b = 0, a = 1 },
		}):children({
			div():style({
				width = { abs = 20 },
				height = { abs = 20 },
				bg = { r = 1, g = 1, b = 1, a = 1 },
			}):onClick({ type = "clicked" }),
		})
	end, {
		width = 40,
		height = 40,
		fontPath = assert(fontPath),
		onMessage = function(received)
			message = received
		end,
	})

	screen:draw()
	screen:click(20, 20)
	screen:close()

	test.truthy(message, "the click produced a message")
	test.equal(message and message.type, "clicked")
end)

-- The colour a box is drawn in, at a point in it, so what the pointer does to it can be read.
---@param screen wonderland.Headless
---@return number, number, number, number
local function centrePixel(screen)
	local pixels = assert(screen:getPixels())

	return pixelAt(pixels, 200, 100, 60)
end

--- A screen with one button in it, which is what the pointer tests point at.
---@return wonderland.Headless
local function withButton()
	return wonderland.headless.new(function()
		return div():style({ width = { rel = 1.0 }, height = { rel = 1.0 } }):children(
			div()
				:style({ width = { abs = 200 }, height = { abs = 120 }, bg = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 } })
				:hover({ bg = { r = 1.0, g = 0.0, b = 0.0, a = 1.0 } })
				:active({ bg = { r = 0.0, g = 0.0, b = 1.0, a = 1.0 } })
		)
	end, { width = 200, height = 200, fontPath = assert(fontPath) })
end

test.skipIf(not canRender)("a hover style is used while the pointer is over the element", function()
	local screen = withButton()

	screen:draw()

	local r, g, b = centrePixel(screen)
	test.equal(r, 0, "the box is drawn with the style it was given")
	test.equal(g, 0)
	test.equal(b, 0)

	-- Nothing is hovered until the pointer moves: a window does not know where it is.
	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 60 })

	-- A window asks for the frame itself once the pointer has changed something; a screen with
	-- no window is drawn by hand, which is what a redraw would come to.
	screen:draw()

	local overR, overG, overB = centrePixel(screen)
	test.equal(overR, 255, "and with the hover style while the pointer is on it")
	test.equal(overG, 0)
	test.equal(overB, 0)

	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 190 })
	screen:draw()

	local offR = centrePixel(screen)
	test.equal(offR, 0, "and back to it when the pointer leaves again")

	screen:close()
end)

test.skipIf(not canRender)("an active style is used while the pointer is held down on the element", function()
	local screen = withButton()

	screen:draw()
	screen:event({ name = "mousePress", window = screen.window, x = 100, y = 60, button = 1 })
	screen:draw()

	local r, g, b = centrePixel(screen)
	test.equal(r, 0, "held down, the active style is the one used")
	test.equal(g, 0)
	test.equal(b, 255)

	screen:event({ name = "mouseRelease", window = screen.window, x = 100, y = 60, button = 1 })
	screen:draw()

	local overR = centrePixel(screen)
	test.equal(overR, 255, "and letting go leaves it hovered, not pressed")
	test.equal(select(3, centrePixel(screen)), 0)

	screen:event({ name = "focusOut", window = screen.window })
	screen:draw()

	local awayR, awayG, awayB = centrePixel(screen)
	test.equal(awayR, 0, "and a window the pointer is no longer in has nothing under it")
	test.equal(awayG, 0)
	test.equal(awayB, 0)

	screen:close()
end)

-- A frame is only asked for when the screen solves to something the gpu does not have. Every
-- repaint goes through here: a pointer moving across the same element, a window resized back to
-- the size it was, a message that changed nothing on screen. Asking for a frame for those spends
-- one on nothing, and spends it waiting for the display, with the next event queued behind it.
-- A box that scrolls shows only what is inside it. Without that, a list would draw over whatever
-- is below it, and the row that is half out of the pane would be half a row too many.
test.skipIf(not canRender)("a box that scrolls draws only what is inside it", function()
	local screen = wonderland.headless.new(function()
		local pane = div():style({ direction = "column", width = { abs = 200 }, height = { abs = 100 } })
			:scroll(50)

		pane:children(
			div():style({ width = { abs = 200 }, height = { abs = 100 }, bg = { r = 1.0, g = 0.0, b = 0.0, a = 1.0 } }),
			div():style({ width = { abs = 200 }, height = { abs = 100 }, bg = { r = 0.0, g = 0.0, b = 1.0, a = 1.0 } })
		)

		return pane
	end, { width = 200, height = 200, fontPath = assert(fontPath) })

	screen:draw()

	local pixels = assert(screen:getPixels())
	local r, _, b = pixelAt(pixels, 200, 100, 25)
	test.equal(r, 255, "the row scrolled up shows the part of it that is left")
	test.equal(b, 0)

	local overR, _, overB = pixelAt(pixels, 200, 100, 75)
	test.equal(overR, 0, "and the next one is below it")
	test.equal(overB, 255)

	local outsideR, _, outsideB = pixelAt(pixels, 200, 100, 150)
	test.equal(outsideR, 0, "and below the pane there is nothing at all")
	test.equal(outsideB, 0)
	test.equal(select(2, pixelAt(pixels, 200, 100, 150)), 0, "not even a colour of its own")

	screen:close()
end)

-- A box scrolled past either end shows the end, not a hole and not a bar walking out of it. An
-- app that keeps its own offset can go below zero -- a bounce, a wheel turned the other way -- and
-- the box it is in is the only thing that can put it back.
test.skipIf(not canRender)("a box scrolled past its start draws as if it were at the start", function()
	local function at(offset)
		local screen = wonderland.headless.new(function()
			local pane = div():style({ direction = "column", width = { abs = 200 }, height = { abs = 100 },
				bar = { width = 8, least = 20, color = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 } } }):scroll(offset)

			pane:children(
				div():style({ width = { abs = 200 }, height = { abs = 100 }, bg = { r = 1.0, g = 0.0, b = 0.0, a = 1.0 } }),
				div():style({ width = { abs = 200 }, height = { abs = 100 }, bg = { r = 0.0, g = 0.0, b = 1.0, a = 1.0 } })
			)

			return pane
		end, { width = 200, height = 100, fontPath = assert(fontPath) })

		screen:draw()
		local pixels = assert(screen:getPixels())

		local bar = pixelAt(pixels, 200, 196, 5)
		screen:close()

		return bar
	end

	local above, atStart = at(-500), at(0)

	test.equal(above, atStart, "an offset above the start is the start")
end)

-- A box with round corners is drawn as the box it is and cut in the shader, which is why it
-- costs one quad: what is left is the box, with the corners taken off it and the middle of every
-- side where it was.
test.skipIf(not canRender)("draws a box with round corners", function()
	local screen = wonderland.headless.new(function()
		return div():style({ width = { abs = 40 }, height = { abs = 40 }, bg = WHITE, radius = 12 })
	end, { width = 40, height = 40, fontPath = assert(fontPath) })

	screen:draw()

	local pixels = assert(screen:getPixels())
	screen:close()

	test.equal(select(1, pixelAt(pixels, 40, 20, 20)), 255, "the middle of the box is the box")
	test.equal(select(1, pixelAt(pixels, 40, 20, 0)), 255, "and so is the middle of a side")
	test.equal(select(1, pixelAt(pixels, 40, 0, 20)), 255)

	local r, g, b = pixelAt(pixels, 40, 0, 0)
	test.equal(r, 0, "while the corner is drawn as what is behind it")
	test.equal(g, 0)
	test.equal(b, 0)
end)

-- A slider is a box that reports where in itself it was pressed and dragged, as the value that
-- sits there: pressing in it goes straight to that value, dragging follows the pointer even past
-- the ends of the box, and letting go is the end of the drag rather than the end of the slider.
test.skipIf(not canRender)("a slider reports where it was pressed and dragged", function()
	local slid = {}

	local screen = wonderland.headless.new(function()
		return div():style({ width = { abs = 100 }, height = { abs = 40 },
			bg = { r = 0, g = 0, b = 0, a = 1 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 40 } })
				:slider({
					value = 0,
					min = 0,
					max = 100,
					onchange = function(value) return { type = "slid", value = value } end,
				})
		)
	end, {
		width = 100,
		height = 40,
		fontPath = assert(fontPath),
		onMessage = function(message)
			slid[#slid + 1] = message.value
		end,
	})

	---@param name string
	---@param x number
	local function send(name, x)
		screen:event({ name = name, window = screen.window, x = x, y = 20, button = 1 })
	end

	---@return number
	local function last()
		return slid[#slid]
	end

	screen:draw()
	send("mousePress", 75)
	test.equal(last(), 75, "pressing three quarters along is three quarters of the way")

	send("mouseMove", 140)
	test.equal(last(), 100, "dragging past the right end stops at it")

	send("mouseMove", 50)
	test.equal(last(), 50, "and back in the middle is the middle")

	send("mouseMove", -20)
	test.equal(last(), 0, "while past the left end stops at that")

	send("mouseRelease", 25)
	test.equal(last(), 25, "letting go leaves it where it was let go")

	send("mouseMove", 90)
	test.equal(last(), 25, "and moving after that is not dragging it")

	test.equal(#slid, 5, "which is the press, the three drags and letting go, and nothing else")

	screen:close()
end)

-- The nub of a slider is a child of it that the layout puts where the value is, because how wide
-- the box a slider was given came out is the one thing an app cannot work out for itself. It
-- travels across the box less the nub, so the ends of the box are the ends of the slider.
test.skipIf(not canRender)("puts a slider's nub where the value is", function()
	local value = 0

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 10 },
			bg = { r = 0, g = 0, b = 0, a = 1 } }):children(
			div():style({ direction = "row", width = { abs = 100 }, height = { abs = 10 } })
				:slider({ value = value, min = 0, max = 100, onchange = function() end })
				:children({
					div():style({ width = { abs = 20 }, height = { abs = 10 },
						bg = { r = 1, g = 1, b = 1, a = 1 } }):thumb(),
				})
		)
	end, { width = 100, height = 10, fontPath = assert(fontPath) })

	---@return number # The first column the nub of the frame is drawn at
	local function nubLeft()
		screen:draw()

		local pixels = assert(screen:getPixels())

		for x = 0, 99 do
			if select(1, pixelAt(pixels, 100, x, 5)) == 255 then
				return x
			end
		end

		return 100
	end

	value = 50
	test.equal(nubLeft(), 40, "half way is the box less the nub, halved")

	value = 0
	test.equal(nubLeft(), 0, "at the low end it starts at the start of the box")

	value = 100
	test.equal(nubLeft(), 80, "and at the high end it ends at the end of it")

	value = 25
	test.equal(nubLeft(), 20, "while a quarter of the way is a quarter of the space it has")

	screen:close()
end)

-- What a pointer grabs when it drags a slider is the nub, so where it is pressed is measured to
-- the middle of the nub: a nub that is a fifth of the box has a tenth of it either side of the
-- pointer at either of its ends.
test.skipIf(not canRender)("a slider is dragged by the middle of its nub", function()
	local slid = {}

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 40 },
			bg = { r = 0, g = 0, b = 0, a = 1 } }):children(
			div():style({ direction = "row", width = { abs = 100 }, height = { abs = 40 } })
				:slider({
					value = 0,
					min = 0,
					max = 100,
					onchange = function(value) return { type = "slid", value = value } end,
				})
				:children({
					div():style({ width = { abs = 20 }, height = { abs = 40 },
						bg = { r = 1, g = 1, b = 1, a = 1 } }):thumb(),
				})
		)
	end, {
		width = 100,
		height = 40,
		fontPath = assert(fontPath),
		onMessage = function(message)
			slid[#slid + 1] = message.value
		end,
	})

	---@param name string
	---@param x number
	local function send(name, x)
		screen:event({ name = name, window = screen.window, x = x, y = 20, button = 1 })
	end

	---@return number
	local function last()
		return slid[#slid]
	end

	screen:draw()
	send("mousePress", 50)
	test.equal(last(), 50, "pressing half way along is half way, nub and all")

	send("mouseMove", 10)
	test.equal(last(), 0, "and the left end of it is where the nub's middle is, so the pointer is")

	send("mouseMove", 90)
	test.equal(last(), 100, "which is the same at the right end")

	send("mouseMove", 30)
	test.equal(last(), 25, "so a quarter of the way along what the nub travels is a quarter of it")

	screen:close()
end)

-- A field that takes more than one line: return breaks the line rather than sending it,
-- control with return sends it, and the caret moves between the lines and the ends of them. What
-- is typed is the app's to keep, as it is in a field of one line: the message comes back and the
-- screen is built again with it.
test.skipIf(not canRender)("types into a field that takes more than one line", function()
	local draft = ""
	local sent = {}

	local screen = wonderland.headless.new(function()
		return div():style({ width = { abs = 100 }, height = { abs = 60 },
			bg = { r = 0, g = 0, b = 0, a = 1 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 60 } })
				:input({
					name = "notes",
					value = draft,
					multiline = true,
					oninput = function(value) return { type = "typed", value = value } end,
					onsubmit = function(value) return { type = "sent", value = value } end,
				})
		)
	end, {
		width = 100,
		height = 60,
		fontPath = assert(fontPath),
		onMessage = function(message)
			sent[#sent + 1] = message

			if message.type == "typed" then
				draft = message.value
			end
		end,
	})

	--- A key, and the frame the app would draw to take the message it produced.
	---@param key string
	---@param ctrl boolean? # Whether the key was held with control
	local function press(key, ctrl)
		screen:event({
			name = "keyPress",
			window = screen.window,
			key = key,
			modifiers = { shift = false, lock = false, ctrl = ctrl or false, alt = false, super = false },
		})
		screen:draw()
	end

	screen:draw()
	screen:click(50, 30)

	press("a")
	press("b")
	press("return")
	press("c")

	test.equal(draft, "ab\nc", "return breaks the line rather than sending what is in it")

	-- Up keeps how far into its line the caret was, counted from the start of it: it was at the
	-- end of a line of one character, which is one byte in, so it lands one byte into the line
	-- above, which is after the "a".
	press("up")
	press("X")
	test.equal(draft, "aXb\nc", "and the caret moves between lines")

	press("end")
	press("Y")
	test.equal(draft, "aXbY\nc", "end goes to the end of the line the caret is on")

	press("home")
	press("Z")
	test.equal(draft, "ZaXbY\nc", "and home to its start")

	press("return", true)
	test.equal(sent[#sent].type, "sent", "control with return is what sends it")
	test.equal(sent[#sent].value, "ZaXbY\nc", "with the whole paragraph")

	screen:close()
end)

-- A shadow is the box it belongs to, moved and drawn with its edge spread out: it is drawn
-- behind the box, so what shows of it is what the box does not cover, and it is soft, so what
-- shows fades with the distance from the box rather than stopping at it.
test.skipIf(not canRender)("draws a shadow behind the box", function()
	local screen = wonderland.headless.new(function()
		return div():style({ width = { abs = 60 }, height = { abs = 60 },
			bg = { r = 0.5, g = 0.5, b = 0.5, a = 1.0 } }):children(
			div():style({
				width = { abs = 20 },
				height = { abs = 20 },
				top = 10,
				left = 20,
				position = "relative",
				bg = WHITE,
				radius = 4,
				shadow = { x = 0, y = 8, blur = 6, color = { r = 0.0, g = 0.0, b = 0.0, a = 0.4 } },
			})
		)
	end, { width = 60, height = 60, fontPath = assert(fontPath) })

	screen:draw()

	local pixels = assert(screen:getPixels())
	screen:close()

	-- The box is where it was put, and the side the shadow was not moved towards has nothing
	-- on it but the screen.
	test.equal(select(1, pixelAt(pixels, 60, 30, 20)), 255, "the box is the box")
	test.equal(select(1, pixelAt(pixels, 60, 30, 4)), 127, "and above it there is nothing but the screen")

	-- Below it the shadow is: darker than the screen, lighter than the box, and lighter the
	-- further from the box it gets, which is what spreading its edge over six pixels means.
	local near = select(1, pixelAt(pixels, 60, 30, 31))
	local far = select(1, pixelAt(pixels, 60, 30, 41))

	test.truthy(near < 100, "the shadow darkens what is under it")
	test.truthy(near > 0, "and is not the box")
	test.truthy(far > near, "while fading out with the distance")
	test.truthy(far < 127, "and is still there eleven pixels past the box")
	test.equal(select(1, pixelAt(pixels, 60, 30, 50)), 127, "and is gone further down than it was blurred")
end)

-- What is not asked to fade has an edge where the box does: the same shadow with no blur is a
-- band the width of the offset below it, and nothing at all past that.
test.skipIf(not canRender)("a shadow with no blur has a hard edge", function()
	local screen = wonderland.headless.new(function()
		return div():style({ width = { abs = 60 }, height = { abs = 60 },
			bg = { r = 0.5, g = 0.5, b = 0.5, a = 1.0 } }):children(
			div():style({
				width = { abs = 20 },
				height = { abs = 20 },
				top = 10,
				left = 20,
				position = "relative",
				bg = WHITE,
				shadow = { x = 0, y = 8, blur = 0, color = { r = 0.0, g = 0.0, b = 0.0, a = 0.4 } },
			})
		)
	end, { width = 60, height = 60, fontPath = assert(fontPath) })

	screen:draw()

	local pixels = assert(screen:getPixels())
	screen:close()

	test.truthy(select(1, pixelAt(pixels, 60, 30, 34)) < 90, "the band under the box is the shadow")
	test.equal(select(1, pixelAt(pixels, 60, 30, 40)), 127, "and past the offset there is none of it")
	test.equal(select(1, pixelAt(pixels, 60, 30, 28)), 255, "and the box is still the box")
end)

-- A box cut down by the pane it is in is still a box with round corners: only what is left of it
-- is drawn, and where it was cut it is cut square, because those are not its own corners. The
-- corners it does have are still round, which is what a box scrolled to the middle of its list
-- has at both ends.
test.skipIf(not canRender)("a rounded box cut by a pane keeps only the corners it has", function()
	local screen = wonderland.headless.new(function()
		local pane = div():style({ direction = "column", width = { abs = 100 }, height = { abs = 60 } }):scroll(30)

		pane:children(
			div():style({ width = { abs = 100 }, height = { abs = 60 }, bg = WHITE, radius = 20 }),
			div():style({ width = { abs = 100 }, height = { abs = 20 } }),
			div():style({ width = { abs = 100 }, height = { abs = 60 }, bg = WHITE, radius = 20 })
		)

		return pane
	end, { width = 100, height = 60, fontPath = assert(fontPath) })

	screen:draw()

	local pixels = assert(screen:getPixels())
	screen:close()

	-- The first box is scrolled 30 up, so its own top is above the pane and the pane cuts it: at
	-- the pane's first row the box is at its left edge, square. Its last row is 30 down, inside
	-- the pane, and there its own round corner is.
	test.equal(select(1, pixelAt(pixels, 100, 0, 0)), 255, "where it was cut it is still the box")
	test.equal(select(1, pixelAt(pixels, 100, 20, 20)), 255, "and so is the middle of it")
	test.equal(select(1, pixelAt(pixels, 100, 0, 29)), 0, "while its own corner is cut off")

	-- The second box starts 50 down, so the pane does not cut it: its own top corner is, and it is
	-- drawn where it landed.
	test.equal(select(1, pixelAt(pixels, 100, 0, 50)), 0, "the box below is round at the top too")
	test.equal(select(1, pixelAt(pixels, 100, 50, 58)), 255, "and it is drawn where it lands")
end)

-- A frame is built once for the frame rather than once for every event behind it, so what an
-- event asks for is a frame and not a screen: the frame itself is what comes out the same as the
-- one already drawn. A frame the *window* asks for -- what an expose is -- is drawn whatever it
-- comes out to, because what it is for is a window that lost what it was showing.
test.skipIf(not canRender)("a frame that comes out the same is not drawn", function()
	local screen = withButton()

	-- A frame is asked for at most once a frame's time, which is what a display shows: this is
	-- about which frame is drawn, so the test asks for them as often as it likes.
	screen.plugins.ui.frameInterval = 0

	screen:draw()
	screen.window.shouldRedraw = false

	screen.plugins.ui:refreshView(screen.window)
	test.falsy(screen.window.shouldRedraw, "a screen that came out the same asks for no frame")

	local drawn = 0
	local draw = screen.plugins.render.draw

	screen.plugins.render.draw = function(plugin, ctx)
		drawn = drawn + 1
		return draw(plugin, ctx)
	end

	--- What the loop does for a frame it was asked for.
	local function frame()
		screen:event({ name = "redraw", window = screen.window })
	end

	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 60 })
	test.truthy(screen.window.shouldRedraw, "the pointer arriving on the button asks for one")
	frame()
	test.equal(drawn, 1, "and it is drawn, because the button under the pointer changed")

	screen.window.shouldRedraw = false
	screen:event({ name = "mouseMove", window = screen.window, x = 110, y = 62 })
	test.truthy(screen.window.shouldRedraw, "moving about on it asks for one too")
	frame()
	test.equal(drawn, 1, "which comes out the same, so it is not drawn")

	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 190 })
	frame()
	test.equal(drawn, 2, "while leaving it is")

	screen.window.shouldRedraw = false
	frame()
	test.equal(drawn, 3, "and a frame the window asks for is drawn whatever it solves to")

	-- A frame that came too soon to be shown waits for the display, and what the window manager
	-- asks for is the display: the frame that was held back is the one that goes out.
	screen.plugins.ui.frameInterval = 1 / 60
	screen.window.shouldRedraw = false
	-- As if no frame had gone out yet: the frames above were drawn as fast as they were asked for.
	screen.plugins.layout.contexts[screen.window].framedAt = nil
	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 60 })
	test.truthy(screen.window.shouldRedraw, "a frame asks for the one after it")

	screen.window.shouldRedraw = false
	screen:event({ name = "mouseMove", window = screen.window, x = 90, y = 58 })
	test.falsy(screen.window.shouldRedraw, "while one that comes too soon waits for the display")

	screen.window.frameAsked = true
	screen:event({ name = "mouseMove", window = screen.window, x = 80, y = 56 })
	test.truthy(screen.window.shouldRedraw, "and is drawn when the window manager asks for it")

	-- A resize is the window's own, so it is not held back: a window left at the size before the
	-- last one is a window that looks frozen.
	screen.window.shouldRedraw = false
	screen:event({ name = "resize", window = screen.window })
	test.truthy(screen.window.shouldRedraw, "and a window that changed size is drawn at once")
	screen.window.shouldRedraw = false
	screen.plugins.ui.frameInterval = 0

	screen:close()
end)

test.skipIf(not canRender)("hands back nothing when a click misses", function()
	local message = nil
	local screen = wonderland.headless.new(function()
		return div():style({
			direction = "row",
			width = { rel = 1.0 },
			height = { rel = 1.0 },
			bg = { r = 0, g = 0, b = 0, a = 1 },
		}):children({
			div():style({
				width = { abs = 10 },
				height = { abs = 10 },
				bg = { r = 1, g = 1, b = 1, a = 1 },
			}):onClick({ type = "clicked" }),
		})
	end, {
		width = 40,
		height = 40,
		fontPath = assert(fontPath),
		onMessage = function(received)
			message = received
		end,
	})

	screen:draw()
	screen:click(35, 35)
	screen:close()

	test.falsy(message, "the click was nowhere near the button")
end)
