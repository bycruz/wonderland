-- Glyphs, drawn into the pictures a screen samples: one atlas per face and pixel height, packed
-- when a character is first drawn rather than when the atlas is made.
--
-- The atlas used to be baked whole, from the characters an app said it would draw: a screen of
-- text in one language costs one set of glyphs, and the font's own file is the only thing that
-- knows which characters those are. What that cannot do is draw a string an app did not name in
-- advance -- a file name, a track's title, anything a person typed -- which is most of what an
-- application draws. So a glyph is rasterised into the atlas the first time a line holding it is
-- measured, and the picture the gpu samples is written again for the frame that follows.
--
-- A picture is 512 pixels a side and as many of them are made as a face and a size come to need,
-- rather than one picture that grows: a picture that grew would move every glyph already packed
-- in it, and a line measured against the old positions is a line the gpu draws from the wrong
-- place. What a sheet holds is bounded, a face that runs out of room gets another sheet, and the
-- picture a glyph is in is written into the glyph, so nothing has to be measured again.
local ffi = require("ffi")
local Face = require("wonderland.font.face")
local utf8 = require("wonderland.font.utf8")

local DEFAULT_SIZE = 512

-- How many sheets one face and one size may come to: a sheet is a megabyte of pixels on the gpu
-- and in memory, sixteen of them is every glyph of a language the size of Japanese drawn at one
-- size on one screen, and past that a character is drawn as the advance it takes and no ink.
local MAX_SHEETS = 16

-- How much room is left around a glyph. Sampling is nearest, so a neighbour cannot bleed into a
-- glyph whatever the texture coordinates round to -- this is room for the rounding itself.
local PADDING = 1

--- One character, packed: where its ink is in the sheet it was packed into, and where that ink
--- sits against the pen and the baseline.
---@class wonderland.font.Glyph
---@field codepoint number
---@field texture number # The picture the sheet it is in is, which a quad samples
---@field x number
---@field y number
---@field width number
---@field height number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field advance number # How far the pen moves for it, in whole pixels
---@field left number # Where the ink starts from the pen, in whole pixels
---@field top number # And from the baseline, downwards, in whole pixels

--- One picture of packed glyphs, with room left in it.
---@class wonderland.font.Sheet
---@field image Image
---@field texture number # 0 where there is no gpu to upload it to
---@field pixels ffi.cdata* # The RGBA bytes `image.pixels` is, written in place
---@field width number
---@field height number
---@field dirty boolean # Whether a glyph has been packed since it was last written
---@field private nextX number
---@field private nextY number
---@field private rowHeight number

--- One face at one pixel height, and the glyphs of it that have been drawn.
---@class wonderland.font.Atlas
---@field face wonderland.font.Face
---@field pixelHeight number
---@field ascent number
---@field descent number
---@field lineHeight number
---@field glyphs table<number, wonderland.font.Glyph>
---@field sheets wonderland.font.Sheet[]
---@field pictures TextureManager? # Where a packed sheet is put, where there is one
---@field size number # What a sheet is, a side
local Atlas = {}
Atlas.__index = Atlas

-- Every character a screen is likely to draw, for an app that has not said which ones it draws.
-- Nothing outside it is refused: a character that is not baked here is baked when it is drawn.
Atlas.ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"


---@param face wonderland.font.Face
---@param pixelHeight number
---@param opts { pictures: TextureManager?, characters: string?, size: number? }?
---@return wonderland.font.Atlas
function Atlas.new(face, pixelHeight, opts)
	local ascent, descent = face:metrics(pixelHeight)
	local pictures = opts and opts.pictures

	---@type wonderland.font.Atlas
	local atlas = setmetatable({
		face = face,
		pixelHeight = pixelHeight,
		ascent = ascent,
		descent = descent,
		lineHeight = ascent - descent,
		glyphs = {},
		sheets = {},
		pictures = pictures,
		size = (opts and opts.size) or DEFAULT_SIZE,
	}, Atlas)

	-- What an app said it would draw is baked now rather than on the first line that draws it,
	-- which is a screen of text that draws without a frame of packing. Everything else waits.
	local characters = opts and opts.characters

	if characters ~= nil then
		atlas:sheet()

		for at = 1, #characters do
			atlas:glyph(characters:byte(at))
		end
	end

	return atlas
end

--- A face and a size, from a font file: what a test measuring lines with no screen draws with.
---@param config { pixelHeight: number?, characters: string?, size: number?, pictures: TextureManager? }?
---@param path string
---@param index number?
---@return wonderland.font.Atlas? atlas
---@return string? err
function Atlas.fromPath(config, path, index)
	local face, err = Face.open(path, index)

	if face == nil then
		return nil, err
	end

	local opts = config or {}

	return Atlas.new(face, opts.pixelHeight or 16, {
		pictures = opts.pictures,
		characters = opts.characters,
		size = opts.size,
	})
end

---@param content string
---@return boolean
function Atlas.isValid(content)
	return Face.isValid(content)
end

--- A sheet with room for a glyph of this size, or a new one: what a full sheet is, and what
--- running out of them is, are both answered here rather than by the caller.
---@param width number
---@param height number
---@return wonderland.font.Sheet? sheet
function Atlas:room(width, height)
	if width + PADDING * 2 > self.size or height + PADDING * 2 > self.size then
		return nil
	end

	local last = self.sheets[#self.sheets]

	if last ~= nil then
		if last.nextX + width + PADDING > last.width then
			last.nextX = PADDING
			last.nextY = last.nextY + last.rowHeight + PADDING
			last.rowHeight = 0
		end

		if last.nextY + height + PADDING <= last.height then
			return last
		end
	end

	if #self.sheets >= MAX_SHEETS then
		return nil
	end

	local sheet = self:sheet()

	if sheet.nextY + height + PADDING > sheet.height then
		return nil
	end

	return sheet
end

--- Makes one more sheet: white with the coverage in alpha, so a glyph drawn with a text colour
--- is that colour where it is drawn and nothing where it is not.
---@return wonderland.font.Sheet
function Atlas:sheet()
	local size = self.size
	local pixels = ffi.new("uint8_t[?]", size * size * 4)

	-- What the shader multiplies by the text colour is white, so the sheet is white everywhere
	-- and the alpha is what says where there is ink: a pixel with no ink is not drawn at all.
	local white = ffi.new("uint8_t[?]", size * 4)

	for index = 0, size - 1 do
		white[index * 4], white[index * 4 + 1], white[index * 4 + 2] = 255, 255, 255
	end

	for row = 0, size - 1 do
		ffi.copy(pixels + row * size * 4, white, size * 4)
	end

	---@type Image
	local image = { width = size, height = size, channels = 4, pixels = pixels }

	---@type wonderland.font.Sheet
	local sheet = {
		image = image,
		texture = self.pictures ~= nil and self.pictures:upload(image) or 0,
		pixels = pixels,
		width = size,
		height = size,
		dirty = false,
		nextX = PADDING,
		nextY = PADDING,
		rowHeight = 0,
	}

	self.sheets[#self.sheets + 1] = sheet

	return sheet
end

--- Whether this face draws the character at all.
---@param codepoint number
---@return boolean
function Atlas:hasGlyph(codepoint)
	return self.face:hasGlyph(codepoint)
end

--- Where a character's ink goes: packed into a sheet now if this is the first line that draws it,
--- which is what makes a font atlas something an app can hand any text to.
---@param codepoint number
---@return wonderland.font.Glyph
function Atlas:glyph(codepoint)
	local known = self.glyphs[codepoint]

	if known ~= nil then
		return known
	end

	local advance = math.floor(self.face:advance(codepoint, self.pixelHeight) + 0.5)
	local ink = self.face:ink(codepoint, self.pixelHeight)
	local sheet = ink.width > 0 and ink.height > 0 and self:room(ink.width, ink.height) or nil

	---@type wonderland.font.Glyph
	local glyph = {
		codepoint = codepoint,
		texture = 0,
		x = 0,
		y = 0,
		width = 0,
		height = 0,
		u0 = 0,
		v0 = 0,
		u1 = 0,
		v1 = 0,
		advance = advance,
		left = ink.left,
		top = ink.top,
	}

	if sheet ~= nil then
		local x, y = sheet.nextX, sheet.nextY
		local width, height = ink.width, ink.height

		-- Only the alpha is written: the sheet is white already, and it is the coverage that
		-- says where the glyph is -- see the fragment shader, which multiplies the two.
		for row = 0, height - 1 do
			local from = ink.pixels + row * width
			local into = sheet.pixels + ((y + row) * sheet.width + x) * 4 + 3

			for column = 0, width - 1 do
				into[column * 4] = from[column]
			end
		end

		sheet.nextX = sheet.nextX + width + PADDING

		if height > sheet.rowHeight then
			sheet.rowHeight = height
		end

		sheet.dirty = true

		glyph.texture = sheet.texture
		glyph.x, glyph.y, glyph.width, glyph.height = x, y, width, height
		glyph.u0, glyph.v0 = x / sheet.width, y / sheet.height
		glyph.u1, glyph.v1 = (x + width) / sheet.width, (y + height) / sheet.height
	end

	self.face:freeInk(ink)

	self.glyphs[codepoint] = glyph

	return glyph
end

--- The quad a character draws, as the atlas holds it: where its ink is in its sheet and where
--- that ink sits against the pen and the baseline. The character is packed by this call if it is
--- the first time anything has drawn it.
---@param char string
---@return wonderland.font.Glyph
function Atlas:getCharUVs(char)
	local codepoint = utf8.one(char)

	return self:glyph(codepoint)
end

--- What has been packed since the last frame, written into the pictures the screen samples. A
--- sheet is written whole because a texture is written in bands here, and a patch of one is not
--- what that call takes: a sheet that gained a glyph is a megabyte of copy, on the frame after
--- the glyph was packed and no frame at all after it.
function Atlas:flush()
	if self.pictures == nil then
		return
	end

	for _, sheet in ipairs(self.sheets) do
		if sheet.dirty then
			self.pictures:writeLayer(sheet.texture, sheet.image)
			sheet.dirty = false
		end
	end
end

return Atlas
