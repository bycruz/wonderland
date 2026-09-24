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

test.skipIf(not canRender)("a repaint that comes out the same asks for no frame", function()
	local screen = withButton()

	screen:draw()
	screen.window.shouldRedraw = false

	screen.plugins.ui:refreshView(screen.window)
	test.falsy(screen.window.shouldRedraw, "a screen that came out the same is not drawn again")

	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 60 })
	test.truthy(screen.window.shouldRedraw, "the pointer arriving on the button is a frame")

	screen.window.shouldRedraw = false
	screen:event({ name = "mouseMove", window = screen.window, x = 110, y = 62 })
	test.falsy(screen.window.shouldRedraw, "and moving about on it is not")

	screen:event({ name = "mouseMove", window = screen.window, x = 100, y = 190 })
	test.truthy(screen.window.shouldRedraw, "while leaving it is")

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
