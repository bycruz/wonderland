-- What reads a font file and shapes a line of text: the machine's own text stack, through `texter`.
-- FreeType and HarfBuzz on linux and android, Uniscribe and GDI on windows, CoreText on macOS.
--
-- A provider is whatever table is set here -- see `wonderland.font.Provider` -- so a test can set one
-- of its own rather than needing a font file.
local texter = require("texter")

--- Whether some bytes look like a font, by their signature: a ttf, an otf, a collection or a dfont.
---@param content string
---@return boolean
local function looksLikeAFont(content)
	local magic = content:sub(1, 4)

	return magic == "\0\1\0\0" or magic == "OTTO" or magic == "true" or magic == "ttcf"
end

--- What reads fonts, in the shape this library asks for one.
---
--- A face is asked five questions by the atlas that packs it: whether it draws a character, how tall
--- its lines are, how far the pen moves for one, what its ink is, and whether it can give that ink
--- back. `shape` and `ink` are for drawing a line as glyphs rather than characters, and a provider
--- may have neither: what cannot shape is measured a character at a time.
---@class wonderland.font.Provider
---@field open fun(path: string, index: number?): wonderland.font.Face?, string?
---@field shape fun(face: wonderland.font.Face, text: string, pixelHeight: number): wonderland.font.Shaped?
---@field ink fun(face: wonderland.font.Face, glyph: number, pixelHeight: number): wonderland.font.Ink?

--- A face: a font file read, as the atlas asks for one.
---@class wonderland.font.Face
---@field path string?
---@field index number?
---@field family string?
---@field style string?

--- The ink of one glyph, in the reader's own buffer, valid until the next glyph is asked for.
---@class wonderland.font.Ink
---@field width number
---@field height number
---@field left number
---@field top number
---@field pixels ffi.cdata*?
---@field colour boolean? # Four bytes a pixel rather than one of coverage

--- A string, shaped: its glyphs in the order they are drawn, left to right whatever way the text
--- reads, each with where it goes and which byte of the string it came from.
---@class wonderland.font.Shaped
---@field glyphs wonderland.font.ShapedGlyph[]
---@field width number
---@field rtl boolean
---@field text string

--- One glyph of a shaped line. `cluster` is the byte of the string it came from, from nought: a
--- glyph is not a character -- a ligature is one glyph of two, an emoji one glyph of four bytes --
--- so the byte is what a caret and a click count in.
---@class wonderland.font.ShapedGlyph
---@field glyph number # Which glyph of the font it is
---@field cluster number
---@field x number # Where it goes, from the start of the line
---@field y number
---@field advance number

--- What a reader answers, which is `texter`'s where nothing else has been set.
---@type wonderland.font.Provider
local provider = texter.provider

-- Which reader handed each face out, held weakly. A face from a reader that is not in place now --
-- a test's own, or one of a reader since replaced -- is one nothing here shapes.
---@type table<wonderland.font.Face, wonderland.font.Provider>
local opened = setmetatable({}, { __mode = "k" })

local reader = {}

--- What reads font files now.
---@return wonderland.font.Provider
function reader.get()
	return provider
end

--- Makes something else the reader of font files, for every font read from then on.
---@param replacement wonderland.font.Provider
function reader.set(replacement)
	provider = replacement
end

--- Whether this machine has what text is read with, and what a machine without it says instead.
---@return boolean
function reader.available()
	return texter.available()
end

--- Whether a line of text can be shaped through this face. It is a face this reader handed out and
--- the provider still in place that opened it; anything else is measured a character at a time.
---@param face wonderland.font.Face
---@return boolean
function reader.shapes(face)
	return provider.shape ~= nil and opened[face] == provider
end

--- A line of text, shaped. The text is the whole of what one face draws of it: `wonderland.font.Font`
--- cuts a line into those pieces and shapes each with the face that draws it.
---@param face wonderland.font.Face
---@param text string
---@param pixelHeight number
---@return wonderland.font.Shaped
function reader.shape(face, text, pixelHeight)
	assert(provider.shape ~= nil, "This reader does not shape text: measure it a character at a time")

	return provider.shape(face, text, pixelHeight)
end

--- The ink of one glyph of a font, at a size.
---@param face wonderland.font.Face
---@param glyph number
---@param pixelHeight number
---@return wonderland.font.Ink
function reader.ink(face, glyph, pixelHeight)
	return assert(provider.ink)(face, glyph, pixelHeight)
end

--- What is missing, where something is.
---@return string?
function reader.why()
	return texter.why()
end

--- A face, from a font file.
---@param path string
---@param index number?
---@return wonderland.font.Face? face
---@return string? err
function reader.open(path, index)
	assert(texter.available(), texter.why())

	local face, err = provider.open(path, index)

	if face ~= nil then
		opened[face] = provider
	end

	return face, err
end

--- Whether some bytes look like a font this can be opened from.
---@param content string
---@return boolean
function reader.isValid(content)
	return looksLikeAFont(content)
end

return reader
