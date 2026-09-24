-- Glyph atlases rasterised by stb_truetype.
--
-- This replaces the pre-baked bitmap font: glyphs are rasterised from a font file
-- when the atlas is built, so any font and any size works and no image decoder is
-- involved. The atlas is white with the coverage in alpha, which is what a tinted
-- glyph quad wants.
local ffi = require("ffi")
local buffer = require("string.buffer")
local stbtt = require("wonderland.stbtt")

-- A glyph of a run, as the array of them is: eight numbers, whole ones as whole ones.
-- A run of a line is measured once and drawn every frame, so it is read far more often
-- than it is written -- and 32 bytes a glyph in one array is a tenth of what a table a
-- glyph costs, which a screen of text pays for every line it shows.
ffi.cdef [[
	typedef struct {
		int32_t x, y, width, height;  // where the ink is drawn, in whole pixels
		float u0, v0, u1, v1;         // and where it is in the atlas
		int32_t advance;              // how far the pen moves for it, which is where the next one
		                              // starts -- and where a caret before it sits, which is the
		                              // one place the ink's own edge is not the answer
	} wl_glyph;

	// One line of a run: the range of the run's glyphs that are its own, and how wide it came
	// out, which is what a line that is not left-aligned is placed by.
	typedef struct {
		int32_t first, count;
		double width;
	} wl_line;

	// Where one character sits in the atlas, measured when the atlas is built: nine floats,
	// because that is what stb writes them as, and read one struct at a time when a line is
	// measured rather than built as a table per character per line.
	typedef struct {
		float x, y, width, height;
		float u0, v0, u1, v1;
		float advance;
	} wl_quad;
]]

local library = stbtt

local DEFAULT_PIXEL_HEIGHT = 16
local DEFAULT_WIDTH = 512
local DEFAULT_HEIGHT = 512
local FIRST_CHAR = 32

---@class wonderland.ffi.alignedQuad: ffi.cdata*
---@field x0 number
---@field y0 number
---@field x1 number
---@field y1 number
---@field s0 number
---@field t0 number
---@field s1 number
---@field t1 number

---@class wonderland.font.Config
---@field characters string
---@field pixelHeight number?
---@field width number?
---@field height number?

---@class wonderland.font.Quad
---@field x number # Where the glyph sits in the atlas, in pixels
---@field y number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field width number # How large the glyph draws
---@field height number
---@field advance number # How far the cursor moves

--- One glyph of a run, placed from the run's top left corner. The array of them is what
--- a run holds, so a glyph is a struct rather than a table: the language server cannot see
--- an ffi.cdef, so the fields are spelled out here.
---@class wonderland.font.Glyph: ffi.cdata*
---@field x number # Where the ink starts, from the run's left edge
---@field y number # And from its top edge
---@field width number
---@field height number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field advance number # How far the pen moved for it, which is where a caret in front of it sits
--- The ink's own left edge is not that: ink sits inside the advance by its side bearing, so a
--- caret drawn at it would sit inside the character rather than in front of it.

--- A line of text: what it measures, and where each glyph goes inside it. This is the
--- whole of what drawing text needs, so a text element can stay one element instead of
--- becoming one element per character.
---@class wonderland.font.Line
---@field first number # Where this line's glyphs start in the run's array
---@field count number # How many of them there are
---@field width number # And how far the pen moved over it, which is what it is aligned by

--- What a string measures to, and where each of its glyphs goes. This is the whole of what
--- drawing text needs, so a text element can stay one element instead of becoming one element
--- per character. A string with newlines in it is a run of several lines: one array of glyphs
--- with each line's own range in it, and each line's glyphs placed a line lower than the last.
---@class wonderland.font.Run
---@field width number # How far the pen moves over the widest of its lines
---@field height number # The line box: the font's line height, times how many lines there are
---@field lines ffi.cdata*? # `wl_line`, one per line, from the top
---@field lineCount number # How many lines, since the array is not a Lua one
---@field glyphs ffi.cdata*? # `wl_glyph`, one per character from nought, nothing for an empty line
---@field count number # How many, since the array is not a Lua one
---@field id number # Stable for the life of the run: what a frame compares to tell whether a line changed

--- Runs are pure functions of the font and the string, so they are kept: a screen of
--- labels asks for the same handful of strings over and over. The cache is bounded
--- because an app can invent strings forever, as a clock does.
-- A screen of text measures a line per line it shows, and a screen showing more lines than the
-- cache holds would miss on all of them: an entry is under a kilobyte, so the cache is sized for
-- a screen rather than for a handful of labels, and the ones it drops when it is full are the
-- oldest, which is what keeps an app that invents strings forever from growing it.
local RUN_CACHE_LIMIT = 2048

-- How many of the oldest lines are dropped when the cache is full: dropping one at a time would
-- leave it evicting on every line measured after that.
local RUN_EVICT = RUN_CACHE_LIMIT / 2

-- Handed out one per measured line and never reused, so two lines are the same line only
-- if they are the same run.
local nextRunId = 0

---@class wonderland.font.Atlas
---@field config wonderland.font.Config
---@field image Image
---@field ascent number # Pixels above the baseline at this pixel height
---@field descent number # Pixels below it, negative
---@field lineHeight number # ascent - descent, the height of one line of text
---@field private chardata ffi.cdata*
---@field private width number
---@field private height number
---@field runs table<string, wonderland.font.Run> # Measured lines, kept
---@field runCount number # How many are in it, since # cannot count string keys
---@field quads ffi.cdata* # `wl_quad`, where each character of the set sits, by its place in it
---@field byByte ffi.cdata* # `uint16_t`: which place a byte is, one based, for measuring a line
---@field index table<string, number> # And the same by character, for asking for one by name
---@field recent table<number, string> # The last lines measured, oldest first, for what to drop
---@field recentAt number # Where the next of those goes
local Atlas = {}
Atlas.__index = Atlas

-- Every character a screen is likely to draw, for an app that has not said which ones it
-- draws: baking a glyph is what the atlas costs, so a screen of digits can bake twenty.
Atlas.ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

-- Where the machines this gets tried on keep a font.
local FONT_PATHS = {
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/Library/Fonts/Arial.ttf",
	"C:\\Windows\\Fonts\\segoeui.ttf",
	"C:\\Windows\\Fonts\\arial.ttf",
}

--- The first ttf this machine is likely to have, so an app that does not care which font it
--- is drawn in does not have to name one. `FONT=` in the environment wins, which is how a
--- machine with something else in mind says so.
---@return string? path
function Atlas.find()
	local named = os.getenv("FONT")
	if named then
		return named
	end

	for _, path in ipairs(FONT_PATHS) do
		local file = io.open(path, "rb")

		if file then
			file:close()
			return path
		end
	end
end

---@param config wonderland.font.Config
---@param content string
---@return wonderland.font.Atlas? atlas
---@return string? err
function Atlas.fromData(config, content)
	local width = config.width or DEFAULT_WIDTH
	local height = config.height or DEFAULT_HEIGHT
	local pixelHeight = config.pixelHeight or DEFAULT_PIXEL_HEIGHT
	local count = #config.characters

	local data = buffer.new()
	data:put(content)

	local pixels = ffi.new("unsigned char[?]", width * height)
	local chardata = ffi.new("stbtt_bakedchar[?]", count)

	local baked = library.bakeFontBitmap(
		ffi.cast("const unsigned char*", data:ref()),
		0,
		pixelHeight,
		pixels,
		width,
		height,
		FIRST_CHAR,
		count,
		chardata
	)

	if baked <= 0 then
		return nil, string.format("The font does not fit in a %dx%d atlas", width, height)
	end

	local rgba = ffi.new("uint8_t[?]", width * height * 4)
	for index = 0, width * height - 1 do
		rgba[index * 4] = 255
		rgba[index * 4 + 1] = 255
		rgba[index * 4 + 2] = 255
		rgba[index * 4 + 3] = pixels[index]
	end

	-- The baked quads are placed against the baseline, so text needs to know where
	-- it sits at this pixel height to put a line of glyphs on it.
	local ascent = ffi.new("float[1]")
	local descent = ffi.new("float[1]")
	local lineGap = ffi.new("float[1]")
	library.getScaledFontVMetrics(
		ffi.cast("const unsigned char*", data:ref()),
		0,
		pixelHeight,
		ascent,
		descent,
		lineGap
	)

	---@type wonderland.font.Atlas
	local atlas = setmetatable({
		config = config,
		chardata = chardata,
		quads = ffi.new("wl_quad[?]", count),
		byByte = ffi.new("uint16_t[?]", 256),
		index = {},
		width = width,
		height = height,
		ascent = ascent[0],
		descent = descent[0],
		lineHeight = ascent[0] - descent[0],
		runs = {},
		runCount = 0,
		image = {
			width = width,
			height = height,
			channels = 4,
			pixels = rgba,
			buffer = ffi.string(rgba, width * height * 4)
		},
	}, Atlas)

	-- Every character is measured once, here, and kept as the struct a line is measured from.
	-- Measuring a line then reads these and allocates nothing, which is what a screen of text
	-- pays for on every repaint.
	for at = 1, count do
		local char = config.characters:sub(at, at)
		local quad = atlas:getCharUVs(char)
		local into = atlas.quads[at - 1]

		into.x, into.y = quad.x, quad.y
		into.width, into.height = quad.width, quad.height
		into.u0, into.v0, into.u1, into.v1 = quad.u0, quad.v0, quad.u1, quad.v1
		into.advance = quad.advance

		atlas.index[char] = at - 1
		atlas.byByte[char:byte()] = at
	end

	return atlas
end

---@param config wonderland.font.Config
---@param path string
---@return wonderland.font.Atlas? atlas
---@return string? err
function Atlas.fromPath(config, path)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, "Failed to open font file: " .. tostring(err)
	end

	local content = file:read("*all")
	file:close()

	return Atlas.fromData(config, content)
end

--- The quad a glyph draws, in atlas pixels and in texture coordinates.
---@param char string
---@return wonderland.font.Quad
function Atlas:getCharUVs(char)
	local index = assert(
		self.config.characters:find(char, 1, true),
		"Character '" .. char .. "' is not in the atlas."
	) - 1

	local xpos = ffi.new("float[1]")
	local ypos = ffi.new("float[1]")
	local quad = ffi.new("stbtt_aligned_quad")
	---@cast quad wonderland.ffi.alignedQuad

	library.getBakedQuad(self.chardata, self.width, self.height, index, xpos, ypos, quad, 1)

	return {
		x = quad.x0,
		y = quad.y0,
		u0 = quad.s0,
		v0 = quad.t0,
		u1 = quad.s1,
		v1 = quad.t1,
		width = quad.x1 - quad.x0,
		height = quad.y1 - quad.y0,
		advance = xpos[0],
	}
end

--- Where every glyph of a line goes, measured once and kept.
---
--- Each glyph is placed against the baseline inside a box as wide as its advance, so a
--- line flows with the font's own spacing, and the positions are whole pixels because a
--- quad that starts halfway across one loses its last column.
---@param text string
---@return wonderland.font.Run
function Atlas:getRun(text)
	local cached = self.runs[text]
	if cached then
		return cached
	end

	if self.runCount >= RUN_CACHE_LIMIT then
		-- The oldest lines are dropped rather than all of them. Clearing the whole cache meant
		-- that a screen with more lines than the cache holds measured every one of them again
		-- on every repaint, which is the difference between nothing per frame and megabytes of
		-- it. The ring holds the last lines measured in the order they were measured, so the
		-- ones it is about to overwrite are the oldest there are.
		local recent = self.recent
		local at = self.recentAt

		for _ = 1, RUN_EVICT do
			local oldest = recent[at]

			if oldest ~= nil then
				recent[at] = nil
				self.runs[oldest] = nil
				self.runCount = self.runCount - 1
			end

			at = at % RUN_CACHE_LIMIT + 1
		end

		self.recentAt = at
	end

	-- How many lines the string is, and how many glyphs they hold between them: a newline is a
	-- break with nothing drawn at it, so it is not a glyph. Counted before anything is placed,
	-- because both arrays are made once and filled in place.
	local lineCount = 1
	local glyphCount = 0
	local scan = 1

	while true do
		local newline = text:find("\n", scan, true)

		if not newline then
			glyphCount = glyphCount + #text - scan + 1
			break
		end

		glyphCount = glyphCount + newline - scan
		lineCount = lineCount + 1
		scan = newline + 1
	end

	---@type ffi.cdata*?
	local glyphs = glyphCount > 0 and ffi.new("wl_glyph[?]", glyphCount) or nil
	local lines = ffi.new("wl_line[?]", lineCount)

	local quads = self.quads
	local byByte = self.byByte
	local array = glyphs
	local lineStep = math.floor(self.lineHeight + 0.5)
	local widest = 0
	local placed = 0
	local start = 1

	-- A line of nothing is a line of nothing: no glyphs to place, and no array to place them in.
	-- By byte, not by taking a one-character string out of the line: a string per character per
	-- line is what measuring cost before the quads were structs, and it is most of what was left.
	for line = 0, lineCount - 1 do
		local newline = text:find("\n", start, true)
		local last = (newline or #text + 1) - 1
		local baseline = math.floor(self.ascent + 0.5) + line * lineStep
		local pen = 0
		local first = placed

		for at = start, last do
			local place = byByte[text:byte(at)]

			if place == 0 then
				error("Character '" .. text:sub(at, at) .. "' is not in the atlas.", 2)
			end

			local quad = quads[place - 1]
			local glyph = assert(array)[placed]

			glyph.x = math.floor(pen + quad.x + 0.5)
			glyph.y = math.floor(baseline + quad.y + 0.5)
			glyph.width = math.ceil(quad.width)
			glyph.height = math.ceil(quad.height)
			glyph.u0, glyph.v0 = quad.u0, quad.v0
			glyph.u1, glyph.v1 = quad.u1, quad.v1
			glyph.advance = math.floor(quad.advance + 0.5)

			pen = pen + glyph.advance
			placed = placed + 1
		end

		lines[line].first, lines[line].count, lines[line].width = first, placed - first, pen

		if pen > widest then
			widest = pen
		end

		start = last + 2
	end

	nextRunId = nextRunId + 1

	---@type wonderland.font.Run
	local run = {
		width = widest,
		height = lineStep * lineCount,
		lines = lines,
		lineCount = lineCount,
		glyphs = glyphs,
		count = placed,
		id = nextRunId,
	}
	self.runs[text] = run
	self.runCount = self.runCount + 1

	local recent = self.recent

	if recent == nil then
		recent = {}
		self.recent, self.recentAt = recent, 1
	end

	recent[self.recentAt] = text
	self.recentAt = self.recentAt % RUN_CACHE_LIMIT + 1

	return run
end

---@param content string
function Atlas.isValid(content)
	local magic = content:sub(1, 4)

	return magic == "\0\1\0\0" or magic == "OTTO" or magic == "true" or magic == "ttcf"
end

return Atlas
