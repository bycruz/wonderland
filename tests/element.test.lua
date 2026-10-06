-- The elements a frame is built from: what a view may do with one, and what it is told when it does
-- something it may not. It is a file of its own because the screen it makes wants a gpu device, and
-- a device is a thing a machine hands out a few dozen of: see `headless.test.lua`, which is where
-- most of the screens in this suite are made and which the runner reaches long after this one.
local test = require("lde-test")
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

-- A font is what a screen needs; the test skips where the machine has none.
local FONT_PATHS = {
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"Library/Fonts/Arial.ttf",
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

local canRender = fontPath ~= nil

if canRender then
	local ok = pcall(function()
		local screen = wonderland.headless.new(function() return div() end, { width = 8, height = 8 })
		screen:close()
	end)

	canRender = ok
end

-- An element is built by the view and used in the repaint it was built for. One kept from an earlier
-- frame is a pointer into memory that has been handed out again, so it points at whatever the slot
-- it was in holds now -- which is an element of the frame being built, and linking it in again makes
-- a tree that holds itself. The walk over one of those does not end, and it used to end in a stack
-- overflow in the middle of shaping a line: what a window does with that is stop answering, with
-- nothing on it to say why.
--
-- Which of the two things that notice says so depends on the slot: an element whose slot has not been
-- handed out again still carries the frame it was made in, and is told off for that; one whose slot
-- is an element of this frame's again cannot be told from it, and is caught by the walk, which counts
-- what it visits. Either is the library saying what is wrong rather than a stack overflow saying
-- nothing, which is what this is about -- which of the two it is is where the arena happened to be.
test.skipIf(not canRender)("says so when an element of an earlier frame is put in a tree", function()
	local kept = div():style(sty():size(10, 10))

	local ok, err = pcall(function()
		local screen = wonderland.headless.new(function()
			return div():style(sty():fill()):children({ kept })
		end, { width = 20, height = 20, fontPath = assert(fontPath) })

		screen:draw()
		screen:close()
	end)

	local said = tostring(err)

	test.falsy(ok, "the frame is not built")
	test.truthy(said:find("earlier frame") ~= nil or said:find("holds itself") ~= nil,
		"and the tree the element made is what is named")
	test.truthy(said:find("view") ~= nil, "with what to do about it: an element belongs to its view")
end)

-- A style is written once and kept, which is what the whole of a screen being built again every
-- repaint is paid for with. The same style two frames running is the same slot, so nothing about the
-- frame after it is a copy of the one before.
test.skipIf(not canRender)("draws a screen from a style kept between frames", function()
	local kept = sty():size(20, 20):bg("#426bd9")
	local frames = 0

	local screen = wonderland.headless.new(function()
		frames = frames + 1

		return div():style(sty():fill()):children({ div():style(kept) })
	end, { width = 40, height = 40, fontPath = assert(fontPath) })

	screen:draw()

	local first = assert(screen:getPixels())

	screen:draw()

	local second = assert(screen:getPixels())
	screen:close()

	test.greater(frames, 1, "the screen was built again")
	test.equal(second, first, "and a style kept from an earlier frame draws the same screen")
end)
