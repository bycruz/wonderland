-- Fonts: what a face is read as, how a glyph gets into an atlas, how a line is measured through a
-- chain of faces, and how one is cut to a width.
--
-- Almost everything here is made rather than installed: a face is a table with the four things an
-- atlas asks of one -- whether it draws a character, how tall its lines are, how far a pen moves
-- for one, and the ink itself -- so a chain of two faces, one that draws a character and one that
-- does not, is a test with no font file anywhere in it. The tests that read a real font file skip
-- on a machine that has none, the way the rendering tests do.
local ffi = require("ffi")
local test = require("lde-test")
local Atlas = require("wonderland.font.atlas")
local Face = require("wonderland.font.face")
local Font = require("wonderland.font.font")
local utf8 = require("wonderland.font.utf8")

-- Any font will do for the tests that need one; they skip where the machine has none.
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

--- A face that draws the characters it was told it draws, and nothing else: what an atlas asks a
--- face, with no font file behind it. Its glyphs are two pixels of ink each, so that the packing
--- itself is what the tests below are about.
---@param codepoints table<number, boolean>
---@param advance number
---@param inkSize number?
---@return wonderland.font.Face
local function aFace(codepoints, advance, inkSize)
	local size = inkSize or 2
	local ink = ffi.new("uint8_t[?]", size * size)

	ffi.fill(ink, size * size, 255)

	---@type any
	return {
		hasGlyph = function(_, codepoint)
			return codepoints[codepoint] == true
		end,
		metrics = function()
			return 12, -4, 0
		end,
		advance = function()
			return advance
		end,
		ink = function()
			return { width = size, height = size, left = 0, top = 0, pixels = ink }
		end,
		freeInk = function() end,
	}
end

---@param codepoints number[]
---@param advance number
---@return wonderland.font.Face
local function aFaceOf(codepoints, advance)
	local set = {}

	for _, codepoint in ipairs(codepoints) do
		set[codepoint] = true
	end

	return aFace(set, advance)
end

test.it("reads one character of a string, and where the next one starts", function()
	local codepoint, after = utf8.decode("a", 1)

	test.equal(codepoint, 0x61)
	test.equal(after, 2)

	codepoint, after = utf8.decode("ö", 1)
	test.equal(codepoint, 0xF6, "two bytes are one character")
	test.equal(after, 3)

	codepoint, after = utf8.decode("日", 1)
	test.equal(codepoint, 0x65E5, "and three are one")
	test.equal(after, 4)

	codepoint, after = utf8.decode("😀", 1)
	test.equal(codepoint, 0x1F600, "and four are one")
	test.equal(after, 5)
end)

test.it("reads a byte that starts nothing as the character that says so", function()
	local codepoint, after = utf8.decode("\128a", 1)

	test.equal(codepoint, 0xFFFD, "a stray continuation byte is not text")
	test.equal(after, 2, "and takes one byte with it, so the next character is not lost")

	local truncated = utf8.decode("\228\184", 1)
	test.equal(truncated, 0xFFFD, "a sequence the string ends in the middle of is not text either")
end)

test.it("packs a glyph the first time it is asked for", function()
	local atlas = Atlas.new(aFaceOf({ 0x41 }, 8), 16)

	test.equal(#atlas.sheets, 0, "an atlas with nothing baked in it has no picture yet")

	local glyph = atlas:glyph(0x41)

	test.equal(glyph.width, 2, "the ink of the character")
	test.equal(glyph.height, 2)
	test.equal(glyph.advance, 8, "and how far the pen moves for it")
	test.equal(#atlas.sheets, 1, "the picture is made when a glyph is packed into it")
	test.truthy(glyph.u0 >= 0 and glyph.u1 <= 1, "the texture coordinates stay in range")
	test.equal(atlas:glyph(0x41), glyph, "and the glyph is packed once")
end)

test.it("bakes the characters it was made with, and packs the rest as they are drawn", function()
	local atlas = Atlas.new(aFaceOf({ 0x41, 0x42, 0x43 }, 8), 16, { characters = "AB" })

	test.equal(#atlas.sheets, 1, "what an app said it draws is baked now")
	test.truthy(atlas.glyphs[0x41] ~= nil and atlas.glyphs[0x42] ~= nil)
	test.equal(atlas.glyphs[0x43], nil, "and everything else waits")

	atlas:glyph(0x43)

	test.truthy(atlas.glyphs[0x43] ~= nil, "until a line holding it is measured")
end)

test.it("makes another picture when one fills up", function()
	local codepoints = {}

	for codepoint = 0x100, 0x180 do
		codepoints[#codepoints + 1] = codepoint
	end

	local atlas = Atlas.new(aFaceOf(codepoints, 8), 16, { size = 32 })

	for _, codepoint in ipairs(codepoints) do
		atlas:glyph(codepoint)
	end

	test.greater(#atlas.sheets, 1, "a sheet that is full is added to rather than grown")
	test.truthy(#atlas.sheets <= 16, "and there is an end to how many a face and size may come to")
end)

test.it("draws a character too large for a picture as the room it takes", function()
	local atlas = Atlas.new(aFace({ [0x41] = true }, 8, 40), 16, { size = 16 })
	local glyph = atlas:glyph(0x41)

	test.equal(glyph.width, 0, "there is no ink")
	test.equal(glyph.advance, 8, "and the line still flows")
end)

test.it("measures a line as one run of glyphs", function()
	local atlas = Atlas.new(aFaceOf({ 0x41, 0x42, 0x43 }, 8), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })
	local run = font:getRun("ABC")

	test.equal(run.count, 3, "one glyph a character")
	test.equal(run.width, 24, "as wide as the advances put together")
	test.equal(run.height, 16, "and one line tall")
	test.equal(run.lines[0].count, 3)

	for index = 0, run.count - 1 do
		local glyph = assert(run.glyphs)[index]

		test.equal(glyph.x, index * 8, "placed along the line, on whole pixels")
		test.equal(glyph.advance, 8)
	end
end)

test.it("measures a line with the face that draws each of its characters", function()
	local primary = Atlas.new(aFaceOf({ 0x41 }, 8), 16)
	local loaded = 0
	local font = Font.new(primary, {
		spec = { pixelHeight = 16 },
		fallbacks = { { "a file that is not read yet", 0 } },
		load = function()
			loaded = loaded + 1

			return aFaceOf({ 0x2603 }, 5)
		end,
	})

	local run = font:getRun("A\u{2603}")

	test.equal(run.count, 2)
	test.equal(assert(run.glyphs)[0].advance, 8, "the character the first face draws is drawn by it")
	test.equal(assert(run.glyphs)[1].advance, 5, "and the one it does not is drawn by the face after it")
	test.equal(#font.atlases, 2, "which is read once")
	test.equal(loaded, 1)

	font:getRun("A\u{2603}B")

	test.equal(loaded, 1, "and a second line reads nothing again")
end)

test.it("draws a character no face has with the face the font is named by", function()
	local font = Font.new(Atlas.new(aFaceOf({ 0x41 }, 8), 16), {
		spec = { pixelHeight = 16 },
		load = function()
			return nil
		end,
	})

	local run = font:getRun("\u{2603}")

	test.equal(run.count, 1, "a character nobody draws is still a character")
	test.equal(assert(run.glyphs)[0].advance, 8, "drawn as the face it was measured in draws it")
end)

test.it("cuts a line to a width, with an ellipsis where it was cut", function()
	local atlas = Atlas.new(aFaceOf({ 0x41, 0x2026 }, 8), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })

	local run = font:getRun("AAAA", 24)

	test.equal(run.count, 3, "two characters and an ellipsis")
	test.equal(run.width, 24, "which is the width it was cut to and no more")
	test.equal(assert(run.glyphs)[2].advance, 8, "and the last of them is the ellipsis")
end)

test.it("leaves a line that fits as it is", function()
	local atlas = Atlas.new(aFaceOf({ 0x41, 0x2026 }, 8), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })

	local run = font:getRun("AAA", 24)

	test.equal(run.count, 3, "nothing was cut off it")
	test.equal(run, font:getRun("AAA"), "and it is the same run as the line with no width at all")
end)

test.it("keeps a line by the width it was cut to as well", function()
	local atlas = Atlas.new(aFaceOf({ 0x41, 0x2026 }, 8), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })

	local wide = font:getRun("AAAAAAA", 40)
	local narrow = font:getRun("AAAAAAA", 24)

	test.equal(font:getRun("AAAAAAA", 40), wide, "the same string and width is the same line")
	test.equal(font:getRun("AAAAAAA", 24), narrow)
	test.truthy(wide ~= narrow, "and another width is another line")
	test.truthy(narrow.width < wide.width)
end)

test.it("measures a paragraph as lines of one run", function()
	local atlas = Atlas.new(aFaceOf({ 0x41 }, 8), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })
	local paragraph = font:getRun("AA\nA")

	test.equal(paragraph.lineCount, 2, "a break makes a second line")
	test.equal(paragraph.count, 3, "and is not a glyph itself")
	test.equal(paragraph.width, 16, "so it is as wide as its widest line")
	test.equal(paragraph.lines[0].count, 2)
	test.equal(paragraph.lines[1].count, 1, "and the second holds what came after the break")
	test.equal(assert(paragraph.glyphs)[2].y - assert(paragraph.glyphs)[0].y, 16, "a line lower")
	test.equal(font:getRun("").lineCount, 1, "and a line of nothing is still a line")
end)

test.it("keeps a screen's worth of lines and drops the oldest", function()
	local atlas = Atlas.new(aFaceOf({ 0x41 }, 8), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })

	for index = 1, 300 do
		font:getRun(string.format("line %d", index))
	end

	test.equal(font:getRun("line 1"), font:getRun("line 1"), "a line a screen shows stays measured")
	test.equal(font.runCount, 300, "and nothing was dropped for a screen this size")

	for index = 301, 2400 do
		font:getRun(string.format("line %d", index))
	end

	test.truthy(font.runCount <= 2048, string.format("the cache stayed bounded, at %d lines", font.runCount))
	test.falsy(font.runs["line 1"], "and the oldest lines are the ones that went")
end)

test.skipIf(fontPath == nil)("reads a font file, and says what it draws", function()
	local face = assert(Face.open(assert(fontPath), 0))

	test.truthy(face:hasGlyph(0x41), "a font has the letters it has")
	test.falsy(face:hasGlyph(0x65E5), "and not every character there is")
	test.greater(face:scale(18), 0, "and scales by something at a pixel height")
	test.greater(select(1, face:metrics(18)), 0, "as tall as it says it is")
end)

test.skipIf(fontPath == nil)("packs a glyph of a real font, and draws it", function()
	local atlas = assert(Atlas.fromPath({ pixelHeight = 18, characters = "A" }, assert(fontPath)))
	local glyph = atlas:getCharUVs("A")

	test.greater(glyph.width, 0, "the ink of a letter is real")
	test.greater(glyph.height, 0)
	test.greater(glyph.advance, 0, "and moves the pen along")
	test.equal(atlas.sheets[1].image.width, 512, "in a picture of the size an atlas is")
	test.equal(atlas.sheets[1].image.channels, 4, "with the coverage in its alpha")
end)

test.skipIf(fontPath == nil)("packs a character the atlas was never told about", function()
	local atlas = assert(Atlas.fromPath({ pixelHeight = 18, characters = " " }, assert(fontPath)))
	local box = atlas:glyph(0x41)

	test.greater(box.width, 0, "a character drawn for the first time is packed then")
	test.truthy(box.u1 > box.u0, "and has a place in the picture")
end)

-- What a font is refused for is read out of its tables rather than found by trying, because trying
-- is an abort in the rasteriser rather than an error here: the two below are the whole of what a
-- font file has to be to say so.

---@param value number
---@return string
local function be16(value)
	return string.char((value >> 8) & 0xFF, value & 0xFF)
end

---@param value number
---@return string
local function be32(value)
	return string.char((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
end

--- A font file of the tables it is given: an offset table, a record a table, and the tables
--- themselves after the records, which is where a record points.
---@param tables { tag: string, content: string }[]
---@return string
local function aFontFile(tables)
	local records, contents = {}, {}
	local at = 12 + #tables * 16

	for _, table in ipairs(tables) do
		records[#records + 1] = table.tag .. string.rep("\0", 4) .. be32(at) .. be32(#table.content)
		contents[#contents + 1] = table.content
		at = at + #table.content + #table.content % 4
	end

	return be32(0x00010000) .. be16(#tables) .. string.rep("\0", 6) .. table.concat(records)
		.. table.concat(contents)
end

--- A character map of one subtable, which is the format a font is refused for being of.
---@param format number
---@return string
local function aCharacterMap(format)
	-- The header, one record pointing past it, and the subtable itself, which is what the format
	-- of is read: nothing else of a character map is looked at here.
	return be16(0) .. be16(1) .. be16(3) .. be16(1) .. be32(12) .. be16(format) .. string.rep("\0", 6)
end

test.it("refuses a font whose outlines it cannot draw", function()
	local face, err = Face.fromData(aFontFile({ { tag = "CFF ", content = string.rep("\0", 8) } }), "a font")

	test.equal(face, nil)
	test.truthy(tostring(err):find("CFF", 1, true) ~= nil, "and says why: " .. tostring(err))
end)

test.it("refuses a font whose character map it would abort on", function()
	local font = aFontFile({
		{ tag = "glyf", content = string.rep("\0", 4) },
		{ tag = "cmap", content = aCharacterMap(2) },
	})
	local face, err = Face.fromData(font, "a font")

	test.equal(face, nil, "a character map of a format the rasteriser asserts on is not read")
	test.truthy(tostring(err):find("character map", 1, true) ~= nil, "and says which: " .. tostring(err))
end)

test.it("does not refuse a font for a character map it does read", function()
	local font = aFontFile({
		{ tag = "glyf", content = string.rep("\0", 4) },
		{ tag = "cmap", content = aCharacterMap(4) },
	})
	local face, err = Face.fromData(font, "a font")

	-- What is left of the font is not a font -- there is no head, no hmtx and no glyphs -- so what
	-- this is about is that the character map was not what refused it.
	test.equal(face, nil)
	test.falsy(tostring(err):find("character map", 1, true) ~= nil, tostring(err))
end)

test.it("recognises a font file by its signature", function()
	test.truthy(Face.isValid("\0\1\0\0" .. string.rep("\0", 8)))
	test.truthy(Face.isValid("OTTO" .. string.rep("\0", 8)))
	test.falsy(Face.isValid("not a font at all"))
end)
