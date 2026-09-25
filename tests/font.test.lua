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
local Font = require("wonderland.font.font")
local Registry = require("wonderland.font.registry")
local reader = require("wonderland.font.reader")
local utf8 = require("wonderland.font.utf8")

-- Any font will do for the tests that need one; they skip where the machine has none.
local FONT_PATHS = {
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/Library/Fonts/Arial.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
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

-- A font that draws emoji, which is what a machine draws a check mark with: one that states a glyph
-- as a *graph* of shapes and colours rather than as an outline, which is most of them now.
local EMOJI_PATHS = {
	"/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"C:/Windows/Fonts/seguiemj.ttf",
}

local emojiPath = nil
for _, path in ipairs(EMOJI_PATHS) do
	local file = io.open(path, "rb")

	if file then
		file:close()
		emojiPath = path
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

--- A shaper that draws a line in the order it is read rather than the order it is typed, one glyph a
--- character, with the character itself as the glyph number: what a line of arabic is and a line of
--- latin is not, with no dependence on this machine's fonts.
---@param face wonderland.font.Face
---@param text string
---@param pixelHeight number
---@return wonderland.font.Shaped
local function mirrored(face, text, pixelHeight)
	local characters, count, at = {}, 0, 1

	while at <= #text do
		local codepoint, after = utf8.decode(text, at)

		count = count + 1
		characters[count] = { codepoint = codepoint, cluster = at - 1 }
		at = after
	end

	local glyphs, pen = {}, 0.0

	for index = count, 1, -1 do
		local character = characters[index]
		local advance = face:advance(character.codepoint, pixelHeight)

		glyphs[#glyphs + 1] = {
			glyph = character.codepoint,
			cluster = character.cluster,
			x = pen,
			y = 0,
			advance = advance,
		}

		pen = pen + advance
	end

	return { glyphs = glyphs, width = pen, rtl = true, text = text }
end

-- A test that changes the reader puts it back: see the `afterEach` below.
local realProvider = reader.get()

--- A reader of a test's own: the face is a table and a line comes to what `shape` says.
---@param face wonderland.font.Face
---@param shape fun(face: wonderland.font.Face, text: string, pixelHeight: number): wonderland.font.Shaped
local function aShapedReader(face, shape)
	reader.set({
		open = function()
			return face
		end,
		shape = shape,
		ink = function(_, glyph, pixelHeight)
			return face:ink(glyph, pixelHeight)
		end,
	})
end

test.afterEach(function()
	reader.set(realProvider)
end)

--- The font this machine draws with, built the way the font manager builds one: the machine's own
--- sans and the faces the registry asks for after it.
---@param pixelHeight number
---@return wonderland.font.Font?
local function machineFont(pixelHeight)
	local paths = Registry.new():fallbacks("sans-serif")

	if #paths == 0 then
		return nil
	end

	local primary = Atlas.fromPath({ pixelHeight = pixelHeight }, paths[1])

	if primary == nil then
		return nil
	end

	local fallbacks = {}

	for index = 2, #paths do
		fallbacks[#fallbacks + 1] = { paths[index], 0 }
	end

	return Font.new(primary, {
		spec = { pixelHeight = pixelHeight },
		fallbacks = fallbacks,
		load = function(path, index)
			return reader.open(path, index)
		end,
	})
end

-- Whether this machine draws arabic at all: a machine with nothing of the sort skips the tests below,
-- the way a machine with no font skips the ones that read one.
local arabicFont = machineFont(24)

---@param font wonderland.font.Font
---@param char string
---@return boolean
local function draws(font, char)
	font:getRun(char)

	local codepoint = utf8.decode(char, 1)

	for _, atlas in ipairs(font.atlases) do
		if atlas:hasGlyph(codepoint) then
			return true
		end
	end

	return false
end

local drawsArabic = arabicFont ~= nil and draws(arabicFont, "\u{645}")

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

test.it("draws a line in the order it is shaped in, and keeps the byte of every glyph", function()
	local face = aFaceOf({ 0x61, 0x62, 0x63, 0x64 }, 8)

	aShapedReader(face, mirrored)

	local atlas = Atlas.new(assert(reader.open("a face of this test's own")), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })
	local run = font:getRun("abcd")
	local line = run.lines[0]

	test.equal(run.count, 4, "one glyph a character")
	test.equal(line.rtl, 1, "a line that reads right to left says so")
	test.equal(assert(run.glyphs)[line.first].cluster, 3,
		"and the first glyph of it is drawn from the last byte of the string")

	for at = 0, line.count - 1 do
		local glyph = assert(run.glyphs)[line.first + at]

		test.equal(glyph.cluster, 3 - at, "every glyph keeps the byte it came from")
		test.equal(glyph.pen, at * 8, "and says where the pen was when it was placed")
	end
end)

test.it("shapes each piece of a line with the face that draws it", function()
	local latin = aFaceOf({ 0x61, 0x62 }, 8)
	local arabic = aFaceOf({ 0x620, 0x621 }, 5)

	reader.set({
		open = function(path)
			return path == "latin" and latin or arabic
		end,
		shape = mirrored,
		ink = function(face, glyph, pixelHeight)
			return face:ink(glyph, pixelHeight)
		end,
	})

	local atlas = Atlas.new(assert(reader.open("latin")), 16)
	local loaded = 0
	local font = Font.new(atlas, {
		spec = { pixelHeight = 16 },
		fallbacks = { { "arabic", 0 } },
		load = function(path, index)
			loaded = loaded + 1

			return assert(reader.open(path, index))
		end,
	})

	local run = font:getRun("ab\u{620}\u{621}")

	test.equal(loaded, 1, "the face that draws the rest of the line is read once")
	test.equal(#font.atlases, 2)
	test.equal(run.count, 4, "a glyph a character, whichever face drew it")

	-- Each piece is one shaper's line, so the second is placed after the first rather than shaped
	-- together with it.
	local glyphs = assert(run.glyphs)

	test.equal(glyphs[0].cluster, 1, "the first piece is drawn the way it reads, in its own face")
	test.equal(glyphs[1].cluster, 0)
	test.equal(glyphs[2].cluster, 4, "and the second piece comes after it, with the bytes it has")
	test.equal(glyphs[3].cluster, 2)
	test.equal(glyphs[2].pen, 16, "placed where the first piece left the pen")
	test.equal(glyphs[2].advance, 5, "and moved by the advance of the face that draws it")
	test.equal(run.lines[0].rtl, 1, "a line most of which reads right to left reads right to left")
end)

test.it("cuts a line that reads right to left at its end, which is its left", function()
	local face = aFaceOf({ 0x61, 0x62, 0x63, 0x64, 0x2026 }, 8)

	aShapedReader(face, mirrored)

	local atlas = Atlas.new(assert(reader.open("a face of this test's own")), 16)
	local font = Font.new(atlas, { spec = { pixelHeight = 16 }, load = function() end })
	local run = font:getRun("abcd", 24)
	local line = run.lines[0]
	local glyphs = assert(run.glyphs)

	test.equal(run.count, 3, "the last two characters and an ellipsis")
	test.equal(run.width, 24, "which is the width it was cut to and no more")
	test.equal(glyphs[line.first].advance, 8, "the ellipsis is the first glyph of the line")
	test.equal(glyphs[line.first].cluster, 0, "and stands for the start of the string, which was dropped")
	test.equal(glyphs[line.first].pen, 0, "which is the left end of the line, where its reading ends")
	test.equal(glyphs[line.first + 1].cluster, 1, "what was kept is the start of what was written")
	test.equal(glyphs[line.first + 1].pen, 8, "sitting against the right of the ellipsis")
	test.equal(glyphs[line.first + line.count - 1].pen + glyphs[line.first + line.count - 1].advance, 24,
		"and running to the right end of the room")
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
	local face = assert(reader.open(assert(fontPath), 0))

	test.truthy(face:hasGlyph(0x41), "a font has the letters it has")
	test.falsy(face:hasGlyph(0xE000), "and not every character there is")
	test.greater(select(1, face:metrics(18)), 0, "and says how tall a line of it is")
	test.greater(face:advance(0x41, 18), 0, "and how far the pen moves for a letter")

	local ink = face:ink(0x41, 18)

	test.greater(ink.width, 0, "and what the ink of one is")
	test.greater(ink.height, 0)
	face:freeInk(ink)
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

test.it("recognises a font file by its signature", function()
	test.truthy(reader.isValid("\0\1\0\0" .. string.rep("\0", 8)))
	test.truthy(reader.isValid("OTTO" .. string.rep("\0", 8)))
	test.falsy(reader.isValid("not a font at all"))
end)

test.skipIf(emojiPath == nil)("packs an emoji a font draws as a picture of its own", function()
	local atlas = assert(Atlas.fromPath({ pixelHeight = 24 }, assert(emojiPath)))
	local glyph = atlas:glyph(0x2705)

	test.greater(glyph.width, 0, "a check mark has ink")
	test.greater(glyph.height, 0)
	test.greater(glyph.advance, 0, "and moves the pen along")

	-- What is packed of a picture is how bright it is where it is drawn -- a sheet holds one
	-- channel and it is multiplied by the text's colour -- so what a picture comes to is a range of
	-- brightness rather than one value: a square with a check on it is not a square.
	local sheet = atlas.sheets[1]
	local most, least = 0, 255

	for row = 0, glyph.height - 1 do
		for column = 0, glyph.width - 1 do
			local at = ((glyph.y + row) * sheet.width + glyph.x + column) * 4 + 3
			local light = sheet.pixels[at]

			if light > most then
				most = light
			end

			if light < least then
				least = light
			end
		end
	end

	test.greater(most - least, 40,
		string.format("and it is a picture rather than a block: %d to %d", least, most))
end)

test.skipIf(not drawsArabic)("draws a line of arabic as the letters it is written with", function()
	local font = assert(arabicFont)
	local run = font:getRun("\u{645}\u{631}\u{62D}\u{628}\u{627}")
	local line = run.lines[0]
	local glyphs = assert(run.glyphs)

	test.equal(line.rtl, 1, "a line of arabic reads right to left")
	test.equal(glyphs[line.first].cluster, 8, "and is drawn from its last letter, which is the leftmost")
	test.equal(glyphs[line.first + line.count - 1].cluster, 0, "ending at its first, which is the rightmost")
	test.equal(glyphs[line.first].pen, 0, "placed from the left end of the line")

	-- A mark sits on a letter and moves nothing of its own, so the pen never goes backwards rather
	-- than always moving. Where a glyph's *ink* lands is not something a run promises: a letter leans
	-- over the one beside it and the last glyph of a word is drawn a little past the line's room.
	local widest = 0

	for at = 0, line.count - 1 do
		local glyph = glyphs[line.first + at]

		test.equal(glyph.pen >= (at > 0 and glyphs[line.first + at - 1].pen or 0), true,
			"every glyph of it starts where the pen the one before left it is")

		if glyph.pen + glyph.advance > widest then
			widest = glyph.pen + glyph.advance
		end
	end

	-- Within a fraction of a pixel: a run keeps advances as floats and the width is the shaper's own
	-- answer.
	test.less(math.abs(widest - run.width), 0.05, "as wide as its glyphs move the pen between them")

	-- Whether the letters are the shapes they take in the word is checked where the shaper is, by the
	-- glyphs a font named: a run keeps ink and not glyph numbers, and two forms of one letter can come
	-- to the same ink and the same advance. What a run has to get right is the order and the bytes.
	local pair = font:getRun("\u{645}\u{645}")
	local pairLine = pair.lines[0]

	test.equal(pair.count, 2, "two letters of a word are two glyphs")
	test.equal(assert(pair.glyphs)[pairLine.first].cluster, 2, "drawn from the second of them first")
	test.equal(assert(pair.glyphs)[pairLine.first + 1].cluster, 0, "and the first of them last")
end)
