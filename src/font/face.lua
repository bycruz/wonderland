-- One font file, open: the bytes stb_truetype reads, and what it says about the glyphs in it.
--
-- A face is the file rather than a size. Everything that depends on a size -- how much the font's
-- own units scale by, how tall a line is, where a glyph's ink sits -- is worked out from the face
-- and a pixel height, which is what one face at several sizes is: the file is read once, and a
-- size costs the glyphs it draws and nothing else.
local ffi = require("ffi")
local buffer = require("string.buffer")
local stbtt = require("wonderland.stbtt")

--- The ink of a character at a size: how large it is, where it sits against the pen and the
--- baseline, and one byte a pixel of coverage. The pixels are stb's own buffer, which whoever
--- read them gives back with `Face:freeInk`.
---@class wonderland.font.Ink
---@field width number
---@field height number
---@field left number
---@field top number
---@field pixels ffi.cdata*

--- A font file that stays where it was read from: stb_truetype reads the bytes for the life of
--- the face, so they are kept with it.
---@class wonderland.font.Face
---@field path string?
---@field index number # Which font of a collection it is, nought for a file that holds one
---@field data string.buffer
---@field info stbtt.ffi.FontInfo
---@field private scales table<number, number> # What each pixel height scales by, kept
local Face = {}
Face.__index = Face

---@param content string
---@param at number
---@return number
local function u16(content, at)
	local a, b = content:byte(at, at + 1)

	return (a or 0) * 256 + (b or 0)
end

---@param content string
---@param at number
---@return number
local function u32(content, at)
	local a, b, c, d = content:byte(at, at + 3)

	return ((a or 0) * 256 + (b or 0)) * 256 * 256 + ((c or 0) * 256 + (d or 0))
end

--- Where a font of a file starts, as the table directory it keeps its tables in.
---@param content string
---@param index number
---@return number? at
local function directoryAt(content, index)
	if content:sub(1, 4) ~= "ttcf" then
		return index == 0 and 1 or nil
	end

	-- A collection is a header and the offsets of the fonts in it: the one asked for is where its
	-- own table directory is, and a font that is not in the collection is nothing.
	if index >= u32(content, 9) then
		return nil
	end

	return u32(content, 13 + index * 4) + 1
end

-- What stb_truetype reads a character map in, and nothing else: a subtable of another format --
-- format 2 and 8 are the ones fonts in the wild still carry -- is one it asserts on, and an assert
-- is an abort rather than an answer, so a font with one is a font that takes the process with it.
local CHARACTER_MAPS = { [0] = true, [4] = true, [6] = true, [12] = true, [13] = true }

--- The character map stb_truetype would read this font's codepoints with, and whether it is one it
--- knows: what is looked for here is what it looks for, so that a face this accepts is one it
--- answers for rather than one it aborts on.
---@param content string
---@param at number # The font's table directory
---@return boolean readable
---@return string? why
local function characterMap(content, at)
	local cmap = nil

	for table = 0, u16(content, at + 4) - 1 do
		local record = at + 12 + table * 16

		if content:sub(record, record + 3) == "cmap" then
			cmap = u32(content, record + 8) + 1
		end
	end

	if cmap == nil or cmap + 4 > #content then
		return false, "it holds no character map"
	end

	-- The two platforms it reads, and of the second the two encodings: the last one that matches
	-- is the one it keeps, which is what this keeps as well.
	local chosen = nil

	for record = 0, u16(content, cmap + 2) - 1 do
		local platform = u16(content, cmap + 4 + record * 8)
		local encoding = u16(content, cmap + 6 + record * 8)

		if platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10)) then
			chosen = cmap + u32(content, cmap + 8 + record * 8)
		end
	end

	if chosen == nil or chosen + 2 > #content then
		return false, "its character map is not one stb_truetype reads"
	end

	local format = u16(content, chosen)

	if not CHARACTER_MAPS[format] then
		return false, string.format("its character map is format %d, which stb_truetype aborts on", format)
	end

	return true
end

--- Whether a font is one this can draw: stb_truetype rasterises the outlines of a TrueType font,
--- and an OpenType font whose outlines are CFF -- which is how most CJK fonts are shipped -- has
--- none of them, so it is not a font that comes out of here at all.
---
--- It is answered from the table directory rather than by trying, because trying means reading
--- the whole file first: a collection of CJK fonts is thirty megabytes, and reading one to find
--- out it cannot be drawn is a second of an app's start for nothing.
---@param content string
---@param index number
---@return boolean readable
---@return string? why
local function drawable(content, index)
	local at = directoryAt(content, index)

	if at == nil or at > #content - 12 then
		return false, "there is no font " .. index .. " in it"
	end

	local tables = u16(content, at + 4)
	local hasOutlines, hasCFF = false, false

	for table = 0, tables - 1 do
		local tag = content:sub(at + 12 + table * 16, at + 15 + table * 16)

		if tag == "glyf" then
			hasOutlines = true
		elseif tag == "CFF " or tag == "CFF2" then
			hasCFF = true
		end
	end

	if not hasOutlines then
		return false, hasCFF and "its outlines are CFF, which stb_truetype cannot draw" or "it holds no glyphs"
	end

	return characterMap(content, at)
end

---@param content string
---@param path string?
---@param index number?
---@return wonderland.font.Face? face
---@return string? err
function Face.fromData(content, path, index)
	local readable, why = drawable(content, index or 0)

	if not readable then
		return nil, string.format("%s is not a font stb_truetype can read: %s", path or "The font data", why)
	end

	local data = buffer.new()
	data:put(content)

	local at = ffi.cast("const unsigned char *", data:ref())
	local offset = stbtt.getFontOffsetForIndex(at, index or 0)

	if offset < 0 then
		return nil, string.format("%s holds no font %d", path or "The font data", index or 0)
	end

	local info = ffi.new("stbtt_fontinfo")

	if not stbtt.initFont(info, at, offset) then
		return nil, string.format("%s is not a font stb_truetype can read", path or "The font data")
	end

	return setmetatable({
		path = path,
		index = index or 0,
		data = data,
		info = info,
		scales = {},
	}, Face)
end

-- How much of a file is read before it is known whether it can be drawn: a table directory sits
-- at the start of a font, and past a collection's header -- a few offsets -- at the start of the
-- font itself, so this is generous for either.
local HEADER_SIZE = 8192

--- A font, read from a file. What it is read through first is the table directory, so a file that
--- turns out to have no outlines stb_truetype can draw costs a header rather than the whole of it:
--- a collection of CJK fonts is thirty megabytes, and reading one to be refused is a second of an
--- app's start for nothing.
---@param path string
---@param index number?
---@return wonderland.font.Face? face
---@return string? err
function Face.open(path, index)
	local file, err = io.open(path, "rb")

	if not file then
		return nil, string.format("Could not read %s: %s", path, tostring(err))
	end

	local header = file:read(HEADER_SIZE) or ""
	local content = header
	local readable, why = drawable(content, index or 0)

	if not readable and #header == HEADER_SIZE then
		-- A directory that is not in the header is a file read through, so that what this refuses
		-- is never a font it could have drawn.
		content = header .. (file:read("*all") or "")
		readable, why = drawable(content, index or 0)
	end

	file:close()

	if not readable then
		return nil, string.format("%s is not a font stb_truetype can read: %s", path, why)
	end

	return Face.fromData(content, path, index)
end

--- Whether this face draws the character at all. A character no face in a chain has is the one
--- a replacement is drawn for, so this is what picking a face for a character is asked.
---@param codepoint number
---@return boolean
function Face:hasGlyph(codepoint)
	return stbtt.findGlyphIndex(self.info, codepoint) ~= 0
end

--- What a pixel height scales this font's own units by: every measurement here is a product of
--- it, and asking for it walks the font's tables, so each height is worked out once.
---@param pixelHeight number
---@return number
function Face:scale(pixelHeight)
	local known = self.scales[pixelHeight]

	if known then
		return known
	end

	local scale = stbtt.scaleForPixelHeight(self.info, pixelHeight)
	self.scales[pixelHeight] = scale

	return scale
end

--- How tall a line of this face is at a size: what it reaches above the baseline, what it goes
--- below it, and the gap the font asks for between two lines of itself.
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function Face:metrics(pixelHeight)
	local ascent, descent, lineGap = ffi.new("float[1]"), ffi.new("float[1]"), ffi.new("float[1]")

	stbtt.getScaledFontVMetrics(ffi.cast("const unsigned char *", self.data:ref()), self.index, pixelHeight,
		ascent, descent, lineGap)

	return ascent[0], descent[0], lineGap[0]
end

--- How far the pen moves for a character, in pixels at this size. It is not the width of the ink:
--- a glyph sits inside its advance by a side bearing, which is what keeps the spacing of a line
--- the font's own.
---@param codepoint number
---@param pixelHeight number
---@return number
function Face:advance(codepoint, pixelHeight)
	local advanceWidth, sideBearing = ffi.new("int[1]"), ffi.new("int[1]")

	stbtt.getCodepointHMetrics(self.info, codepoint, advanceWidth, sideBearing)

	return advanceWidth[0] * self:scale(pixelHeight)
end

--- The ink of a character at this size, rasterised here and now: what an atlas packs is this,
--- and a character no screen has drawn yet costs nothing until one does.
---
--- What comes back is stb's buffer, which the reader gives back with `Face:freeInk`: a face is
--- shared by every size of itself and every screen drawing it, so the buffer cannot be kept here.
---@param codepoint number
---@param pixelHeight number
---@return wonderland.font.Ink
function Face:ink(codepoint, pixelHeight)
	local scale = self:scale(pixelHeight)
	local width, height = ffi.new("int[1]"), ffi.new("int[1]")
	local left, top = ffi.new("int[1]"), ffi.new("int[1]")
	local pixels = stbtt.getCodepointBitmap(self.info, scale, scale, codepoint, width, height, left, top)

	return { width = width[0], height = height[0], left = left[0], top = top[0], pixels = pixels }
end

--- Gives back the buffer `ink` came in, which is the face's to give back: what it hands out is
--- stb_truetype's own memory, and a face that is not one -- a test's stand-in -- answers with
--- whatever it made.
---@param ink wonderland.font.Ink
function Face:freeInk(ink)
	if ink.pixels ~= nil then
		stbtt.freeBitmap(ink.pixels, nil)
	end
end

--- Whether some bytes look like a font this can be opened from, by their signature rather than
--- by their name: a ttf, an otf, a collection of either, or a dfont.
---@param content string
---@return boolean
function Face.isValid(content)
	local magic = content:sub(1, 4)

	return magic == "\0\1\0\0" or magic == "OTTO" or magic == "true" or magic == "ttcf"
end

return Face
