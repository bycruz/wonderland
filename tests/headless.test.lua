-- A screen with no window behind it, which is how the ui is checked: it is rendered
-- offscreen and the pixels it produced are asserted.
local test = require("lde-test")
local image = require("image")
local wonderland = require("wonderland")
local Atlas = require("wonderland.font.atlas")

local div, text = wonderland.div, wonderland.text

-- The fixtures are found beside this file rather than by the working directory a test is run from.
local HERE = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".")
local SPINNER = HERE .. "/fixtures/spinner.gif"

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
local BLACK = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 }

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
	local glyph = atlas:getCharUVs("w")
	test.equal(drawnWidth, math.ceil(glyph.width), "and it is as wide as the atlas says")
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
	test.greater(ctx.quads, 4096, "the frame is past what the buffers start with")

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

-- The first frame of a window is the one frame that is built whether anything is owed it or not:
-- a window that has just been made has nothing to show, and nothing asking for a frame is what a
-- loop does before anything has happened in it.
test.skipIf(not canRender)("draws the first frame a loop asks for", function()
	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 20 }, height = { abs = 20 },
			bg = { r = 1, g = 0, b = 0, a = 1 } })
	end, { width = 20, height = 20, fontPath = assert(fontPath) })

	-- The frame a window loop asks for, rather than a screen drawn by hand.
	screen.window.frameAsked = true
	screen.plugins.ui:frame(screen.window)

	local r, g = pixelAt(assert(screen:getPixels()), 20, 10, 10)

	test.equal(r, 255, "the first frame of a window is drawn")
	test.equal(g, 0)

	screen:close()
end)

-- A caret is drawn by the library, in the field that has the keyboard: where it is comes from the
-- value -- the run of it is what has the advances -- and how tall it is comes from the font, so a
-- field that says nothing about its caret still has one.
test.skipIf(not canRender)("draws a caret where the typing is", function()
	local value = ""

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 60 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 60 },
				bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = value, oninput = function(typed)
					return { type = "typed", value = typed }
				end })
		)
	end, { width = 100, height = 60, fontPath = assert(fontPath), onMessage = function(message)
		if message.type == "typed" then
			value = message.value
		end
	end })

	-- The caret is the only ink in the field, so anything of the field's own colour is it.
	---@param row number
	---@return number # Where it starts, or nought less where there is none on that row
	local function caretLeft(row)
		screen.plugins.ui:frame(screen.window)

		local pixels = assert(screen:getPixels())

		for x = 0, 99 do
			local r, g, b = pixelAt(pixels, 100, x, row)

			if r > 200 and g > 200 and b > 200 then
				return x
			end
		end

		return -1
	end

	local blink = screen.plugins.ui.caretBlink

	screen.plugins.ui.caretBlink = 0
	test.equal(caretLeft(10), -1, "a field nothing has clicked in has no caret")

	screen:click(50, 10)
	test.equal(screen.plugins.layout:getFocusedId(screen.window), "field", "clicking it takes the keyboard")
	test.equal(caretLeft(10), 0, "and the caret is at the start of what is typed")

	screen:event({ name = "keyPress", window = screen.window, key = "a", modifiers = {} })
	test.equal(value, "a", "what is typed is the app's")

	local typed = caretLeft(10)
	test.greater(typed, 0, "so the caret is drawn after it")

	screen:event({ name = "keyPress", window = screen.window, key = "home", modifiers = {} })
	test.equal(caretLeft(10), 0, "and home takes it back to the start of the line")

	-- A paragraph: the caret of the second line is a line's height down, which is the line it is on
	-- rather than the box it is in.
	value = "a\nb"

	-- Drawn first, because the key is handled against the field the last frame built: what the app
	-- hands back is what is in the field from the frame after it. This is a screen drawn by hand
	-- rather than a frame the state asked for, which is what an app changing its own state is.
	screen:draw()
	screen:event({ name = "keyPress", window = screen.window, key = "down", modifiers = {} })
	test.equal(caretLeft(30), 0, "the caret of a paragraph is on the line the typing is on")
	test.equal(caretLeft(10), -1, "and not on the line above it")

	screen:event({ name = "keyPress", window = screen.window, key = "end", modifiers = {} })
	test.greater(caretLeft(30), 0, "which is a line of its own, placed in that line")

	screen.plugins.ui.caretBlink = blink
	screen:close()
end)

-- A field that puts the text it draws somewhere of its own -- centred, as the todo example's field
-- is -- is one whose caret follows the text rather than the box: a caret at the top of a box whose
-- text is in the middle is a caret in the wrong place.
test.skipIf(not canRender)("draws a caret beside the text a field draws, wherever it put it", function()
	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 40 } }):children(
			div():style({ direction = "row", align = "center", width = { abs = 100 }, height = { abs = 40 },
				bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = "a" })
				:children(text("a"):style({ fg = { r = 0.5, g = 0.5, b = 0.5, a = 1 } }))
		)
	end, { width = 100, height = 40, fontPath = assert(fontPath) })

	screen.plugins.ui.caretBlink = 0
	screen:click(50, 20)

	---@param find fun(r: number, g: number, b: number): boolean
	---@return number? first
	---@return number? last # The rows that colour is drawn on
	local function rows(find)
		screen.plugins.ui:frame(screen.window)

		local pixels = assert(screen:getPixels())
		local first, last = nil, nil

		for y = 0, 39 do
			for x = 0, 99 do
				local r, g, b = pixelAt(pixels, 100, x, y)

				if find(r, g, b) then
					first = first or y
					last = y
					break
				end
			end
		end

		return first, last
	end

	-- The caret is the field's own colour, and the text is the colour the line was given: two
	-- different greys, so which rows are whose is plain.
	local caretFirst, caretLast = rows(function(r) return r > 200 end)
	local textFirst, textLast = rows(function(r) return r > 100 and r < 200 end)

	-- Compared by the end and the middle of each rather than by their first row: the top of a
	-- glyph is the faintest part of it, so where the ink starts is not where the pixels start.
	test.truthy(caretFirst, "the caret is drawn")
	test.truthy(textFirst, "and so is the text")
	test.truthy((caretLast or 0) >= (textLast or 0) - 2, "the caret ends where the line of text does")
	test.truthy(((caretFirst or 0) + (caretLast or 0)) / 2 >= ((textFirst or 0) + (textLast or 0)) / 2 - 4,
		"and is beside it rather than at the top of the box")

	screen:close()
end)

-- A blink is a frame half a second away, and the loop has no timer: what a screen with something
-- to do on its own asks for is the end of its wait, and the frame that comes with it.
test.skipIf(not canRender)("asks the loop for the time a blinking caret is due", function()
	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 30 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 30 },
				bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = "typed" })
		)
	end, { width = 100, height = 30, fontPath = assert(fontPath) })

	local ui = screen.plugins.ui
	local ctx = assert(screen.plugins.layout.contexts[screen.window])
	local asked, seconds = 0, nil

	-- Only the deadline is looked at: what a screen asks a loop for is when to come back, and this
	-- is a loop that does nothing else.
	---@diagnostic disable-next-line: missing-fields
	local handler = {
		setTimeout = function(_, value)
			asked, seconds = asked + 1, value
		end,
	}

	ui.caretBlink = 0.5
	screen:click(50, 15)

	ui:tick(screen.window, handler)
	test.equal(asked, 1, "the loop is told when to come back")
	test.truthy(seconds ~= nil and seconds > 0 and seconds <= 0.5,
		"which is within the half second the caret blinks for")

	screen.window.shouldRedraw = false
	ctx.caretAt = 0
	ui:tick(screen.window, handler)
	test.truthy(screen.window.shouldRedraw, "and a caret that is due asks for a frame")
	test.equal(asked, 2, "with the one after it asked for as well")

	screen:close()
end)

-- A key arrives with the keys before it still not drawn, and each of them is applied to what the one
-- before it left rather than to the field the last frame drew. Applied to the field the last frame
-- drew, the letters would each be typed into the same empty line with the caret walking along it:
-- what is typed is the app's, and the app hands it back a frame later.
--
-- A key that is *held*, and a key pressed again while the clock is repeating it, are repeats, and a
-- repeat is the clock's to take: see the test below about the rate a held key repeats at.
test.skipIf(not canRender)("applies every key before the next frame to what the one before it left", function()
	local value = ""

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 30 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 30 }, bg = { r = 0, g = 0, b = 0, a = 1 },
				fg = WHITE })
				:input({ name = "field", value = value, oninput = function(typed)
					return { type = "typed", value = typed }
				end })
		)
	end, { width = 100, height = 30, fontPath = assert(fontPath), onMessage = function(message)
		if message.type == "typed" then
			value = message.value
		end
	end })

	--- A tap of a key: it goes down and comes back up, which is what a key that is pressed rather
	--- than held does.
	---@param key string
	---@return nil
	local function tap(key)
		screen:event({ name = "keyPress", window = screen.window, key = key, modifiers = {} })
		screen:event({ name = "keyRelease", window = screen.window, key = key })
	end

	-- Clicking takes the keyboard and puts the caret at the end of what is in the field.
	screen:click(50, 15)

	tap("a")
	test.equal(value, "a", "a key tapped types its letter")

	-- Two more before the frame that would show the first: what they are applied to is what the key
	-- before them left, which is not what is on screen.
	tap("b")
	test.equal(value, "ab", "and the next one types into what that one left")
	tap("c")
	test.equal(value, "abc", "and the one after it into what that one left")

	screen:close()
end)

-- What a caret costs is one quad: a blink is the last quad of the frame the gpu already has, going
-- out and coming back, and a frame the window asks for with nothing behind it is a frame of what is
-- already there. Neither of them looks at the view, the measure or the solve.
test.skipIf(not canRender)("a blink is one quad and no screen is built for it", function()
	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 30 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 30 },
				bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = "typed" })
		)
	end, { width = 100, height = 30, fontPath = assert(fontPath) })

	local ui = screen.plugins.ui
	local layout = screen.plugins.layout
	local ctx = assert(layout.contexts[screen.window])

	ui.frameInterval = 0
	ui.caretBlink = 0

	screen:click(50, 15)
	screen:draw()

	local refreshes = 0
	local refresh = layout.refreshView

	layout.refreshView = function(plugin, window)
		refreshes = refreshes + 1

		return refresh(plugin, window)
	end

	-- A frame the window asked for, with nothing behind it: what is already built is what it gets.
	screen.window.frameAsked = true
	ui:frame(screen.window)
	test.equal(refreshes, 0, "an ask with nothing behind it does not solve the screen")

	local quads = ui.batch.quads

	ui.caretBlink = 0.5
	ctx.caretAt = 0
	ui:frame(screen.window)
	test.equal(ui.batch.quads, quads - 1, "a blink takes the caret's quad out of the frame")
	test.equal(refreshes, 0, "and nothing is solved or walked for it")

	ctx.caretAt = 0
	ui:frame(screen.window)
	test.equal(ui.batch.quads, quads, "and the next one puts it back")
	test.equal(refreshes, 0, "which is the same frame with one more quad in it")

	-- A frame that is owed is still a frame a caret can blink in: the clock it blinks on is its own,
	-- and what a screen with something to do asks for is the end of the loop's wait, which is a
	-- frame it asked for itself.
	ctx.caretAt = 0
	ui:requestRedraw(screen.window, true)
	ui:frame(screen.window)
	test.equal(ui.batch.quads, quads - 1, "and a blink in a frame that was owed is the same one quad")

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

-- A paragraph grows downwards as it is typed into, which is a box the app would have to size for
-- everything it might hold: `maxLines` is how many lines it holds before a break stops doing
-- anything, and `grow` is the box being as tall as what is in it rather than as tall as a guess.
test.skipIf(not canRender)("holds a paragraph to the lines it was given", function()
	local draft = "one"

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "column", width = { abs = 120 }, height = { abs = 120 },
			bg = { r = 0, g = 0, b = 0, a = 1 } }):children(
			div():style({ direction = "row", width = { abs = 120 }, height = { abs = 6 }, fg = WHITE })
				:input({
					name = "notes",
					value = draft,
					multiline = true,
					maxLines = 2,
					grow = true,
					oninput = function(value) return { type = "typed", value = value } end,
				})
				:children(text(draft):style({ fg = { r = 0.5, g = 0.5, b = 0.5, a = 1 } }))
		)
	end, {
		width = 120,
		height = 120,
		fontPath = assert(fontPath),
		onMessage = function(message)
			if message.type == "typed" then
				draft = message.value
			end
		end,
	})

	local layout = screen.plugins.layout
	local ctx = assert(layout.contexts[screen.window])

	--- The field as the last solve left it, which is what a box that grows is measured by.
	---@return wonderland.Node
	local function field()
		return assert(assert(ctx.screen):child(assert(ctx.root), 1))
	end

	--- A key, and the frame the app would draw to take the message it produced.
	---@param key string
	local function press(key)
		screen:event({ name = "keyPress", window = screen.window, key = key, modifiers = {} })
		screen:draw()
	end

	screen:draw()
	screen:click(60, 3)

	local oneLine = field().height

	test.greater(oneLine, 6, "the box is as tall as what is typed into it rather than as its style says")

	press("return")
	press("t")
	press("w")
	press("o")

	test.equal(draft, "one\ntwo", "a break makes a second line")
	test.equal(field().height, oneLine * 2, "and the box is as tall as the two of them")

	-- Two lines is what it holds, so a break at the end of the last of them is a key that does
	-- nothing rather than a line that is drawn past the box it was given.
	press("return")
	test.equal(draft, "one\ntwo", "while a break past the last line it holds is not taken")
	test.equal(field().height, oneLine * 2, "and the box does not grow for one either")

	screen:close()
end)

-- A key held down is one key arriving over and over, and how fast it arrives is not the screen's to
-- choose: a keyboard's own repeat is half a second away and then slow enough to watch, which is a
-- backspace that reads as a character at a time rather than as deleting. So the library repeats the
-- keys a hold keeps doing itself -- a rate of its own, and the same rate for a letter as for a
-- backspace -- and the app hears every one of them the way it hears a key.
--
-- The keyboard repeats a held key as well, and what its repeats are is not something that arrives
-- with them: a press of a key it is repeating is a press of it like any other. So the library is
-- told which they are -- see the keyboard in winit -- and takes the rest itself. A key that the
-- keyboard says is a repeat of a key the clock is repeating is left to the clock; a key that is
-- pressed again by hand is a key of its own, and what it does, it does at once.
test.skipIf(not canRender)("repeats a held key at a rate of its own", function()
	local value = "abc"

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 30 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 30 },
				bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = value, oninput = function(typed)
					return { type = "typed", value = typed }
				end })
		)
	end, { width = 100, height = 30, fontPath = assert(fontPath), onMessage = function(message)
		if message.type == "typed" then
			value = message.value
		end
	end })

	local ui = screen.plugins.ui
	local layout = screen.plugins.layout
	local ctx = assert(layout.contexts[screen.window])
	local asked, seconds = 0, nil

	---@diagnostic disable-next-line: missing-fields
	local handler = {
		setTimeout = function(_, value2)
			asked, seconds = asked + 1, value2
		end,
	}

	--- A key, as the keyboard sends one.
	---@param name string
	---@param pressed string # The key itself
	---@param repeated boolean? # Whether the keyboard said this press was one of its own repeats
	---@param modifiers table? # And what was held with it
	---@return any?
	local function key(name, pressed, repeated, modifiers)
		local message = screen:event({
			name = name,
			window = screen.window,
			key = pressed,
			modifiers = modifiers or {},
			repeated = repeated,
		})

		if message and screen.onMessage then
			screen.onMessage(message)
		end

		return message
	end

	--- A tick of the loop, with what is due made due: the clock is the loop's, and what the screen
	--- does with it is what is being checked -- so the wait is forced rather than sat through.
	---@param due boolean?
	---@return any? message
	local function tick(due)
		if due then
			ctx.repeatAt = 0
		end

		local message = ui:tick(screen.window, handler)

		if message and screen.onMessage then
			screen.onMessage(message)
		end

		return message
	end

	-- The caret is a clock of its own, and this is a test about the other one. Frames are not held
	-- back either: what is being asked about is what asks for one, not how often one may go out --
	-- and a test fires its events closer together than any display has frames.
	ui.caretBlink = 0
	ui.frameInterval = 0

	screen:click(50, 15)

	key("keyPress", "backspace")
	test.equal(value, "ab", "the key itself takes the character before the caret")
	test.equal(ctx.repeatKey, "backspace", "and a key that does something again and again is held down")

	-- Nothing yet: what comes first is the wait before a key repeats at all, and the loop is told
	-- when that is over.
	tick()
	test.equal(value, "ab", "and takes nothing more until the wait is over")
	test.truthy(seconds ~= nil and seconds > 0 and seconds <= layout.keyRepeatDelay,
		"which is the wait the loop is asked to come back after")

	test.equal(assert(tick(true)).type, "typed", "the wait over, the key is the app's again")
	test.equal(value, "a", "and it took the character before the caret")
	test.truthy(screen.window.shouldRedraw, "with a frame asked for, which is what shows it")

	-- The keyboard repeating the key itself is that key arriving again, and the clock is what is
	-- repeating it: its press is taken by nothing, and the one the clock has next is where it was --
	-- which is what says a hold is one rate rather than the keyboard's and the clock's added up.
	local due = ctx.repeatAt

	screen.window.shouldRedraw = false
	key("keyPress", "backspace", true)
	test.equal(value, "a", "a press the keyboard says is its own repeat is not taken as a key")
	test.falsy(screen.window.shouldRedraw, "so it asks for no frame of its own")
	test.equal(ctx.repeatAt, due, "and the repeat the clock has next is not moved by it")

	-- A release the keyboard says is one of its own repeats is not a key coming up: the key is still
	-- held, and the hold goes on through it.
	key("keyRelease", "backspace", true)
	test.equal(ctx.repeatKey, "backspace", "a release the keyboard says is its own repeat does not let go")

	ctx.repeatAt = 0
	test.equal(assert(tick(true)).type, "typed", "and the clock goes on repeating the key it holds")
	test.equal(value, "", "which took the character it was due to take")

	-- What the hand does is a release of its own, and a key that is let go of is not held any more:
	-- what was repeating stops with it, and it does not repeat once more on the way out.
	screen:draw()
	ctx.owed = false
	screen.window.shouldRedraw = false
	ctx.repeatAt = 0

	key("keyRelease", "backspace")
	test.falsy(ctx.repeatKey, "a key that is let go of is not held down any more")
	test.falsy(tick(true), "and nothing repeats after it")
	test.falsy(screen.window.shouldRedraw, "so no frame is asked for either")

	-- A key pressed again is a key of its own, whatever the clock was doing: it does what it does at
	-- once rather than waiting out the wait a hold begins with, and the wait starts again from it.
	-- Typed into an empty field, so that what the press does is plain.
	key("keyPress", "i")
	test.equal(value, "i", "a letter typed is a letter in the field")

	screen.window.shouldRedraw = false
	test.equal(assert(key("keyPress", "backspace")).type, "typed",
		"and a backspace pressed again is a key of its own")
	test.equal(value, "", "which took the character it was pressed to take")
	test.truthy(screen.window.shouldRedraw, "and asked for the frame that shows it")
	test.falsy(ctx.repeatAt, "with the wait before it repeats starting again")

	-- Holding a key that types types it, by the same clock and at the same rate: a letter held down
	-- is letters at a fixed rate rather than a burst whenever the keyboard feels like one.
	key("keyPress", "x")
	test.equal(ctx.repeatKey, "x", "a letter is held down like anything else")
	test.equal(value, "x", "which is the letter the press typed")

	ctx.repeatAt = 0
	test.equal(assert(tick(true)).type, "typed", "and the clock is what types it again")
	test.equal(value, "xx", "one letter a repeat, at the rate it was given")

	ctx.repeatAt = 0
	key("keyPress", "x", true)
	test.equal(value, "xx", "while the keyboard's own repeat of it types nothing")

	-- A key that happens once is not one of those: return sends what is in the field rather than
	-- filling it in, and a chord with control is a command.
	key("keyRelease", "x")
	key("keyPress", "f5")
	key("keyPress", "return")
	key("keyPress", "a", nil, { ctrl = true })
	test.falsy(ctx.repeatKey, "and none of those is repeated by the library")

	-- With the library's repeat turned off, the keyboard's own is what a held key does: it is the
	-- presses that do the work, and there is nothing to say any of them is a repeat.
	layout.keyRepeatInterval = 0

	key("keyPress", "backspace")
	test.equal(value, "x", "which takes a character")
	key("keyPress", "backspace", true)
	test.equal(value, "", "and the keyboard's own repeat of it takes the next")

	screen:close()
end)

-- A key is not what it types: shift and 1 is the key 1 held, and "!" is what the keyboard made of
-- it. A field that typed the key itself would type "1" for shift and 1 -- and a key its release
-- cannot be matched to is a hold nothing lets go of, because the release of a key is named after
-- the key and not after what it typed.
test.skipIf(not canRender)("types what a key types, and repeats that while it is held", function()
	local value = ""

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 100 }, height = { abs = 30 } }):children(
			div():style({ width = { abs = 100 }, height = { abs = 30 },
				bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = value, oninput = function(typed)
					return { type = "typed", value = typed }
				end })
		)
	end, { width = 100, height = 30, fontPath = assert(fontPath), onMessage = function(message)
		if message.type == "typed" then
			value = message.value
		end
	end })

	local ui = screen.plugins.ui
	local layout = screen.plugins.layout
	local ctx = assert(layout.contexts[screen.window])

	---@diagnostic disable-next-line: missing-fields
	local handler = { setTimeout = function() end }

	--- A key, as the keyboard sends one: what it is, what it types, and what was held with it.
	---@param name string
	---@param pressed string
	---@param typed string?
	---@param modifiers table?
	---@param repeated boolean?
	---@return any?
	local function key(name, pressed, typed, modifiers, repeated)
		local message = screen:event({
			name = name,
			window = screen.window,
			key = pressed,
			text = typed,
			modifiers = modifiers or {},
			repeated = repeated,
		})

		if message and screen.onMessage then
			screen.onMessage(message)
		end

		return message
	end

	---@return any? message
	local function beat()
		ctx.repeatAt = 0

		local message = ui:tick(screen.window, handler)

		if message and screen.onMessage then
			screen.onMessage(message)
		end

		return message
	end

	ui.caretBlink = 0
	screen:click(50, 15)

	-- Shift and 1: the key is 1, and what it types is "!".
	key("keyPress", "1", "!", { shift = true })
	test.equal(value, "!", "a key types what the keyboard made of it rather than the key itself")
	test.equal(ctx.repeatKey, "1", "and what is held down is the key, which is what it is named")
	test.equal(ctx.repeatTyped, "!", "with what it types kept as what it repeats")

	-- The keyboard repeating the key is that key over and over, which is nothing: the clock is what
	-- is repeating it, and what it repeats is what the press typed.
	key("keyPress", "1", "!", { shift = true }, true)
	test.equal(value, "!", "a press the keyboard says is its own repeat types nothing")

	test.equal(assert(beat()).type, "typed", "and the clock repeats the key it holds")
	test.equal(value, "!!", "as what that key typed rather than as the key")

	-- The release is named after the key, and a shift that changed what it types does not change
	-- that: a hold that could not be matched to its own release would never be let go of.
	key("keyRelease", "1")

	test.falsy(ctx.repeatKey, "a release of the key let go of lets the hold go")
	test.falsy(beat(), "and the clock takes nothing after it")

	-- And a 1 of its own, with no shift, types 1.
	key("keyPress", "1", "1")
	test.equal(value, "!!1", "a key pressed again types what the keyboard makes of it now")

	screen:close()
end)

-- A click in a field is at a character rather than at the end of what it holds: which line and which
-- character of it a point is at comes from the text the field draws -- the run of it, and where the
-- walk put it -- so a click in the middle of a word puts the caret in the middle of it.
test.skipIf(not canRender)("puts the caret where in a field it was clicked", function()
	local value = "abcd\nef"

	local screen = wonderland.headless.new(function()
		return div():style({ direction = "row", width = { abs = 200 }, height = { abs = 60 } }):children(
			div():style({ direction = "column", width = { abs = 200 }, height = { abs = 60 },
				padding = { left = 20 }, bg = { r = 0, g = 0, b = 0, a = 1 }, fg = WHITE })
				:input({ name = "field", value = value, multiline = true })
				:children(text(value):style({ fg = { r = 0.5, g = 0.5, b = 0.5, a = 1 } }))
		)
	end, { width = 200, height = 60, fontPath = assert(fontPath) })

	local layout = screen.plugins.layout

	screen.plugins.ui.caretBlink = 0

	-- How far into a line of the text a character boundary is, which is where a caret of that column
	-- is drawn: read from the same run the screen draws, so a click and the caret it comes to are
	-- measured against one thing rather than two.
	local fontManager = assert(screen.plugins.render.sharedResources).fontManager
	local run = assert(fontManager:getDefault()):getRun(value)

	---@param line number
	---@param column number
	---@return number
	local function pen(line, column)
		local line_ = run.lines[line]
		local total = 0

		for at = 0, math.min(column, line_.count) - 1 do
			total = total + run.glyphs[line_.first + at].advance
		end

		return total
	end

	local PAD = 20
	local LINE = run.height / run.lineCount

	--- A click, and the byte of the value the caret came to be at.
	---@param x number
	---@param y number
	---@return number
	local function clickAt(x, y)
		screen:click(x, y)

		return layout:getCursorPos(screen.window)
	end

	test.equal(clickAt(2, 5), 0, "a click before the first character is at the start of the line")
	test.equal(clickAt(PAD + pen(0, 2) - 1, 5), 2, "one just before a character boundary is that boundary")
	test.equal(clickAt(PAD + pen(0, 2) + 1, 5), 2, "and one just after it is the same one")
	test.equal(clickAt(PAD + pen(0, 4) + 40, 5), 4, "a click past the end of the line is the end of it")

	-- The line is the one the point is down from the top of the text, so a paragraph is one the
	-- caret can be put on any line of -- and a point below the last line is the last line.
	test.equal(clickAt(PAD + pen(1, 1) - 1, LINE + 5), 6, "a click on the second line is on the second line")
	test.equal(clickAt(2, LINE * 2 + 3), 5, "as is a click below the last one")

	-- And the caret is drawn where that is: the click above was at a boundary of the first line.
	clickAt(PAD + pen(0, 2) - 1, 5)

	local pixels = assert(screen:getPixels())
	local caretX = nil

	for x = 0, 199 do
		for y = 0, 59 do
			local r, g, b = pixelAt(pixels, 200, x, y)

			if r > 200 and g > 200 and b > 200 then
				caretX = caretX or x
				break
			end
		end

		if caretX then
			break
		end
	end

	test.truthy(caretX ~= nil, "and the caret is drawn at all")
	test.truthy(caretX ~= nil and math.abs(caretX - (PAD + pen(0, 2))) <= 1,
		"at the boundary that was clicked rather than at the end of the value")

	screen:close()
end)

-- ────────────────────────────────────────────────────────────────
-- pictures
-- ────────────────────────────────────────────────────────────────

--- A picture of four pixels, one colour each in the order a file holds them -- red, green, blue and
--- white, across and then down. Three channels, so what is drawn is a picture the upload had to
--- widen as well as place: a texture holds rgba and nothing else.
---@param path string
local function writePicture(path)
	local picture = image.new(2, 2, 3)

	picture:setPixel(0, 0, 255, 0, 0)
	picture:setPixel(1, 0, 0, 255, 0)
	picture:setPixel(0, 1, 0, 0, 255)
	picture:setPixel(1, 1, 255, 255, 255)

	assert(picture:save(path))
end

--- A picture of one colour, written where the asset manager can read it back.
---@param path string
---@param width number
---@param height number
---@param color number[]
local function writeColor(path, width, height, color)
	local picture = image.new(width, height, 4)

	picture:fill(color[1], color[2], color[3], color[4])
	assert(picture:save(path))
end

test.skipIf(not canRender)("draws pictures of any size, each with the picture it was given", function()
	local wide = os.tmpname() .. ".png"
	local dot = os.tmpname() .. ".png"

	-- One past what the texture array this used to be would have held at its widest, and one that
	-- is nothing: what a screen of pictures costs is what the pictures are.
	writeColor(wide, 640, 360, { 200, 40, 40, 255 })
	writeColor(dot, 8, 8, { 40, 200, 40, 255 })

	local screen = wonderland.headless.new(function(_, assets)
		local big = assets:image(wide)
		local small = assets:image(dot)

		return div():style({ direction = "row", width = { rel = 1.0 }, height = { rel = 1.0 }, bg = BLACK })
			:children({
				div():style({ width = big.width, height = big.height, bgImage = big.texture, bgImageUV = big.uv }),
				div():style({ width = small.width, height = small.height, bgImage = small.texture, bgImageUV = small.uv }),
			})
	end, { width = 660, height = 360, fontPath = assert(fontPath) })

	screen:draw()
	local pixels = assert(screen:getPixels())
	local ctx = assert(screen.plugins.render:getContext(screen.window))
	screen:close()

	local r, g = pixelAt(pixels, 660, 320, 180)
	test.equal(r, 200, "the large picture is drawn where the layout put it")
	test.equal(g, 40)

	local dr, dg = pixelAt(pixels, 660, 644, 4)
	test.equal(dg, 200, "and the small one is beside it, with a draw call of its own")
	test.equal(dr, 40)

	local er, eg, eb = pixelAt(pixels, 660, 652, 300)
	test.equal(er, 0, "and what neither of them covers is what was behind them")
	test.equal(eg, 0)
	test.equal(eb, 0)

	test.greater(ctx.runCount, 2, "which is two runs of quads, one texture bound for each")

	os.remove(wide)
	os.remove(dot)
end)

-- A picture past what one upload holds is uploaded in bands, which are layers of one texture: the
-- pixels have to come back out where they went in, across the seam between two of them.
test.skipIf(not canRender)("draws a picture larger than one upload is, in bands", function()
	local side = 2048
	local path = os.tmpname() .. ".png"

	-- A picture of four million pixels, which is two bands, and a ramp down it so that a row that
	-- came back out at the wrong height reads as the wrong colour.
	local picture = image.new(side, side, 4)

	for row = 0, side - 1 do
		local shade = math.floor(row / 8)
		local pixels = picture.pixels

		for column = 0, side - 1 do
			local at = (row * side + column) * 4

			pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] = shade, shade, shade, 255
		end
	end

	assert(picture:save(path))

	local screen = wonderland.headless.new(function(_, assets)
		local big = assets:image(path)

		return div():style({ width = { rel = 1.0 }, height = { rel = 1.0 }, bg = BLACK }):children({
			div():style({ width = big.width, height = big.height, bgImage = big.texture, bgImageUV = big.uv }),
		})
	end, { width = side, height = side, fontPath = assert(fontPath) })

	screen:draw()
	local pixels = assert(screen:getPixels())
	screen:close()

	---@param row number
	---@return number
	local function shadeAt(row)
		return (pixelAt(pixels, side, 40, row))
	end

	test.equal(shadeAt(0), 0, "the first row of the picture is the first row of the frame")
	test.equal(shadeAt(1000), 125, "and a row of the first band is where it was")
	test.equal(shadeAt(1024), 128, "the row the second band starts at is where it was as well")
	test.equal(shadeAt(2047), 255, "and so is the last row of the picture")

	os.remove(path)
end)

test.skipIf(not canRender)("draws a picture where the box it was given is, the right way up", function()
	local path = os.tmpname() .. ".png"

	writePicture(path)

	local screen = wonderland.headless.new(function(_, assets)
		local logo = assets:image(path)

		return div():style({ width = { rel = 1.0 }, height = { rel = 1.0 }, bg = BLACK }):children({
			div():style({ width = logo.width, height = logo.height, bgImage = logo.texture, bgImageUV = logo.uv }),
		})
	end, { width = 3, height = 3, fontPath = assert(fontPath) })

	screen:draw()
	local pixels = assert(screen:getPixels())
	screen:close()

	local r, g, b, a = pixelAt(pixels, 3, 0, 0)
	test.equal(r, 255, "the pixel the file holds first is drawn at the corner the layout put it in")
	test.equal(g, 0)
	test.equal(b, 0)
	test.equal(a, 255, "and is opaque, whatever the file said about alpha")

	local tr, tg, tb = pixelAt(pixels, 3, 1, 0)
	test.equal(tr, 0, "the one the file holds beside it is drawn beside it")
	test.equal(tg, 255)
	test.equal(tb, 0)

	local bl, bg, bb = pixelAt(pixels, 3, 0, 1)
	test.equal(bl, 0, "and the row below it is the row below it, not the one above")
	test.equal(bg, 0)
	test.equal(bb, 255)

	local br, brg, brb = pixelAt(pixels, 3, 1, 1)
	test.equal(br, 255, "the last one the file holds is the bottom right corner")
	test.equal(brg, 255)
	test.equal(brb, 255)

	local er, eg, eb = pixelAt(pixels, 3, 2, 2)
	test.equal(er, 0, "and it is two pixels wide, so the rest is what was behind it")
	test.equal(eg, 0)
	test.equal(eb, 0)

	os.remove(path)
end)

test.skipIf(not canRender)("draws the frame of a gif the clock is on", function()
	local dance = nil

	local screen = wonderland.headless.new(function(_, assets)
		dance = dance or assets:gif(SPINNER)
		local frame = dance:current()

		return div():style({ width = { rel = 1.0 }, height = { rel = 1.0 }, bg = BLACK }):children({
			div():style({ width = frame.width, height = frame.height, bgImage = frame.texture,
				bgImageUV = frame.uv }),
		})
	end, { width = 4, height = 4, fontPath = assert(fontPath) })

	--- The colour of the pixel the first frame's picture covers.
	---@return number r, number g, number b, number a
	local function drawn()
		screen:draw()

		return pixelAt(assert(screen:getPixels()), 4, 1, 1)
	end

	local r, g, b = drawn()
	test.equal(r, 255, "the first frame of the gif is red")
	test.equal(g, 0)

	-- The clock is the test's, and the frames are played from the delay each one came with: the
	-- first frame is a tenth of a second, the third two of them. See `wonderland.util.assets`.
	local assets = screen.assets

	assets:advance(0)
	assets:advance(0.1)

	local secondR, secondG = drawn()
	test.equal(secondR, 0, "the second frame is green")
	test.equal(secondG, 255)

	assets:advance(0.2)

	local thirdB = select(3, drawn())
	test.equal(thirdB, 255, "and the third is blue")

	assets:advance(0.4)

	local wrappedR = select(1, drawn())
	test.equal(wrappedR, 255, "and then it is red again")

	test.truthy(dance ~= nil, "the screen is drawn from a gif at all")
	screen:close()
end)

test.skipIf(not canRender)("asks the loop for the time the next frame of a gif is due", function()
	local dance = nil

	local screen = wonderland.headless.new(function(_, assets)
		dance = dance or assets:gif(SPINNER)
		local frame = dance:current()

		return div():style({ width = { rel = 1.0 }, height = { rel = 1.0 }, bg = BLACK }):children({
			div():style({ width = frame.width, height = frame.height, bgImage = frame.texture,
				bgImageUV = frame.uv }),
		})
	end, { width = 4, height = 4, fontPath = assert(fontPath) })

	screen:draw()

	local waited = nil
	local handler = {
		setMode = function() end,
		setTimeout = function(_, seconds) waited = seconds end,
		close = function() end,
		exit = function() end,
	}

	-- What the ui reads is the wall clock, and a gif that started before the beginning of it is one
	-- whose next frame is due now: the frame it is on was started a very long time ago.
	---@cast dance wonderland.Gif
	dance.at = 0

	local was = dance.index
	local ctx = assert(screen.plugins.layout.contexts[screen.window])

	screen.plugins.ui:tick(screen.window, handler)

	test.equal(dance.index, was + 1, "the tick moved it on to its next frame")
	test.truthy(ctx.owed, "and left the screen it is on owed a frame")
	test.truthy(waited ~= nil and waited > 0, "and told the loop when to come back")

	-- The frame it owes is drawn as the display's time allows, and once it has been the loop is
	-- woken for the gif's own next frame rather than for a frame that is already there.
	ctx.owed = false
	waited = nil

	screen.plugins.ui:tick(screen.window, handler)

	test.equal(dance.index, was + 1, "which is not due yet")
	test.truthy(waited ~= nil, "so the loop is told when it is")
	test.greater(waited or 0, 0.05, "which is most of the tenth of a second the frame is shown for")
	test.lessEqual(waited or 0, 0.1)

	screen:close()
end)
