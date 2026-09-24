local test = require("lde-test")
local ffi = require("ffi")
local Atlas = require("wonderland.font.stbtt")

local CHARACTERS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

-- Any font will do; the test skips where the machine has none.
local FONT_PATHS = {
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/adwaita-sans-fonts/AdwaitaSans-Regular.ttf",
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

test.skipIf(fontPath == nil)("rasterises glyphs into an atlas", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))

	test.equal(atlas.image.width, 512)
	test.equal(atlas.image.height, 512)
	test.equal(#atlas.image.buffer, 512 * 512 * 4, "the atlas is RGBA")

	-- The upload path hands image.pixels straight to writeTexture, so it has to be
	-- the real RGBA buffer and not just the string copy.
	test.equal(atlas.image.channels, 4)
	test.equal(ffi.sizeof(atlas.image.pixels), 512 * 512 * 4, "the atlas pixels are uploadable")

	-- Something has to have been drawn, and the alpha is where coverage lives.
	local hasCoverage = false
	for index = 4, #atlas.image.buffer, 4 * 97 do
		if atlas.image.buffer:byte(index) ~= 0 then
			hasCoverage = true
			break
		end
	end

	test.truthy(hasCoverage, "the atlas has glyphs in it")
end)

test.skipIf(fontPath == nil)("reports a quad for a glyph", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))

	local quad = atlas:getCharUVs("A")

	test.greater(quad.width, 0, "the glyph draws at a real size")
	test.greater(quad.height, 0)
	test.truthy(quad.u0 >= 0 and quad.u1 <= 1, "the texture coordinates stay in range")
	test.truthy(quad.v0 >= 0 and quad.v1 <= 1)
	test.greater(quad.advance, 0, "and moves the cursor along")
end)

test.skipIf(fontPath == nil)("measures a line as one run of glyphs", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))
	local run = atlas:getRun("Hello")

	test.equal(run.count, 5, "one glyph per character")
	test.equal(run.height, math.ceil(atlas.lineHeight), "the run is one line tall")
	test.greater(run.width, 0, "and as wide as its advances")

	-- A line flows left to right, and every glyph sits on the same baseline.
	local previous = -1
	for index = 0, run.count - 1 do
		local glyph = run.glyphs[index]

		test.truthy(glyph.x >= previous, "glyphs go left to right")
		previous = glyph.x
		test.equal(glyph.x, math.floor(glyph.x), "on whole pixels")
		test.equal(glyph.y, math.floor(glyph.y))
	end
end)

test.skipIf(fontPath == nil)("measures a paragraph as lines of one run", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))
	local line = atlas:getRun("Hello")
	local paragraph = atlas:getRun("Hello\nHi")

	test.equal(paragraph.lineCount, 2, "a break makes a second line")
	test.equal(paragraph.count, 7, "and is not a glyph itself")
	test.equal(paragraph.width, line.width, "so it is as wide as its widest line, which is the first")
	test.equal(paragraph.height, 2 * math.ceil(atlas.lineHeight), "and two lines tall")

	-- The lines are read by index like the glyphs are, so the first is nought.
	test.equal(paragraph.lines[0].count, 5, "the first line holds what came before the break")
	test.equal(paragraph.lines[0].width, line.width)
	test.equal(paragraph.lines[0].first, 0)
	test.equal(paragraph.lines[1].count, 2, "and the second what came after")
	test.equal(paragraph.lines[1].first, 5)
	test.greater(paragraph.lines[1].width, 0)

	local above, below = paragraph.glyphs[0], paragraph.glyphs[5]
	test.equal(below.y - above.y, math.ceil(atlas.lineHeight), "which is drawn a line lower than the first")
	test.equal(atlas:getRun("").lineCount, 1, "and a line of nothing is still a line")
end)

test.skipIf(fontPath == nil)("keeps the run it measured for the next frame", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))

	test.equal(atlas:getRun("same string"), atlas:getRun("same string"), "the same line is measured once")
end)

-- An app can invent strings forever, as a clock does, so the cache is bounded and the oldest
-- lines go when it is full. Counting the entries needs its own number: the keys are strings, so
-- # is 0. It is sized for a screen, because a screen showing more lines than the cache holds
-- would miss on every one of them on every repaint.
test.skipIf(fontPath == nil)("an empty line measures to nothing, rather than failing", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))
	local run = atlas:getRun("")

	test.equal(run.count, 0, "there are no glyphs in a line with no characters")
	test.equal(run.width, 0)
	test.equal(run.glyphs, nil, "and no array to put them in")
end)

test.skipIf(fontPath == nil)("keeps a screen's worth of lines and drops the oldest", function()
	local atlas = assert(Atlas.fromPath({ characters = CHARACTERS, pixelHeight = 18 }, assert(fontPath)))

	for index = 1, 300 do
		atlas:getRun(string.format("line %d", index))
	end

	test.equal(atlas:getRun("line 1"), atlas:getRun("line 1"), "a line a screen shows stays measured")
	test.equal(atlas.runCount, 300, "and nothing was dropped for a screen this size")

	for index = 301, 2400 do
		atlas:getRun(string.format("line %d", index))
	end

	test.truthy(atlas.runCount <= 2048, string.format("the cache stayed bounded, at %d lines", atlas.runCount))
	test.falsy(atlas.runs["line 1"], "and the oldest lines are the ones that went")
end)

test.it("recognises a font file", function()
	test.truthy(Atlas.isValid("\0\1\0\0" .. string.rep("\0", 8)))
	test.falsy(Atlas.isValid("not a font at all"))
end)
