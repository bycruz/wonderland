-- Glyphs, drawn into the pictures a screen samples: one atlas per face and pixel height, packed
-- when a character is first drawn rather than when the atlas is made, so any string an app hands
-- over is drawable.
--
-- A picture is 512 pixels a side and more of them are made as a face and a size come to need, rather
-- than one picture that grows: growing one would move every glyph already packed in it, and a line
-- measured against the old positions is drawn from the wrong place. Which sheet a glyph is in is
-- written into the glyph, so nothing is measured twice.
local ffi = require("ffi")
local reader = require("wonderland.font.reader")
local utf8 = require("wonderland.font.utf8")

local DEFAULT_SIZE = 512

-- How many sheets one face and one size may come to: a sheet is a megabyte of pixels on the gpu
-- and in memory, sixteen of them is every glyph of a language the size of Japanese drawn at one
-- size on one screen, and past that a character is drawn as the advance it takes and no ink.
local MAX_SHEETS = 16

-- How much room is left around a glyph. Sampling is nearest, so a neighbour cannot bleed into a
-- glyph whatever the texture coordinates round to -- this is room for the rounding itself.
local PADDING = 1

--- One glyph, packed: where its ink is in its sheet and where that ink sits against the pen and
--- the baseline.
---@class wonderland.font.Glyph
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
---@field colour boolean? # Whether the picture is its own colours rather than a shape to draw in one

--- One picture of packed glyphs, with room left in it.
---@class wonderland.font.Sheet
---@field image Image
---@field texture number # 0 where there is no gpu to upload it to
---@field pixels ffi.cdata* # The RGBA bytes `image.pixels` is, written in place
---@field width number
---@field height number
---@field dirty boolean # Whether a glyph has been packed since it was last written
---@field colour boolean # Whether what it holds is a picture's own colours rather than coverage
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
---@field glyphIds table<number, wonderland.font.Glyph> # The same, by the glyph's own number
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
		glyphIds = {},
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
	local face, err = reader.open(path, index)

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
	return reader.isValid(content)
end

--- A sheet with room for a glyph of this size, or a new one: what a full sheet is, and what
--- running out of them is, are both answered here rather than by the caller.
---@param width number
---@param height number
---@param colour boolean? # Whether the glyph is a picture rather than a shape
---@return wonderland.font.Sheet? sheet
function Atlas:room(width, height, colour)
	if width + PADDING * 2 > self.size or height + PADDING * 2 > self.size then
		return nil
	end

	local last = self.sheets[#self.sheets]

	-- A sheet of one kind is not room for a glyph of the other: what holds a shape is white where
	-- nothing is packed, and what holds a picture is nothing.
	if last ~= nil and last.colour ~= (colour == true) then
		last = nil
	end

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

	local sheet = self:sheet(colour)

	if sheet.nextY + height + PADDING > sheet.height then
		return nil
	end

	return sheet
end

--- Makes one more sheet.
---
--- A sheet of a shape is white everywhere with the coverage in alpha, so what is drawn is the text
--- colour where there is ink and nothing where there is not. A glyph a font draws as a picture of its
--- own -- an emoji -- goes in a sheet of the other kind: nothing where there is no ink and the
--- picture's own colours where there is. The two kinds cannot share a sheet.
---@param colour boolean? # Whether the sheet is for pictures rather than for shapes
---@return wonderland.font.Sheet
function Atlas:sheet(colour)
	local size = self.size
	local pixels = ffi.new("uint8_t[?]", size * size * 4)

	if not colour then
		-- What the shader multiplies by the text colour is white, so the sheet is white everywhere
		-- and the alpha is what says where there is ink: a pixel with no ink is not drawn at all.
		local white = ffi.new("uint8_t[?]", size * 4)

		for index = 0, size - 1 do
			white[index * 4], white[index * 4 + 1], white[index * 4 + 2] = 255, 255, 255
		end

		for row = 0, size - 1 do
			ffi.copy(pixels + row * size * 4, white, size * 4)
		end
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
		colour = colour == true,
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

--- Where a character's ink goes, packed into a sheet now if this is the first line that draws it.
---@param codepoint number
---@return wonderland.font.Glyph
function Atlas:glyph(codepoint)
	local known = self.glyphs[codepoint]

	if known ~= nil then
		return known
	end

	local advance = math.floor(self.face:advance(codepoint, self.pixelHeight) + 0.5)
	local ink = self.face:ink(codepoint, self.pixelHeight)
	local glyph = self:pack(ink, advance)

	self.glyphs[codepoint] = glyph

	return glyph
end

--- Where one glyph of a font goes, by the number the font gave it rather than by the character it was
--- asked for: a shaper answers with glyphs -- of a letter, a ligature, a mark -- and what is packed is
--- what it named. The advance is the one it was first packed with: a shaped run moves its pen by the
--- advance the shaper gave for that occurrence, which differs across a kerned pair.
---@param glyph number # Which glyph of the face it is
---@param advance number # How far the pen moved for it, in whole pixels
---@return wonderland.font.Glyph
function Atlas:byGlyph(glyph, advance)
	local known = self.glyphIds[glyph]

	if known ~= nil then
		return known
	end

	local packed = self:pack(reader.ink(self.face, glyph, self.pixelHeight), advance)

	self.glyphIds[glyph] = packed

	return packed
end

--- One glyph of a font, packed into a sheet, which is what a character of one comes to.
---@param ink wonderland.font.Ink
---@param advance number
---@return wonderland.font.Glyph
function Atlas:pack(ink, advance)
	local sheet = ink.width > 0 and ink.height > 0 and self:room(ink.width, ink.height, ink.colour) or nil

	---@type wonderland.font.Glyph
	local glyph = {
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
		colour = ink.colour or nil,
	}

	if sheet ~= nil then
		local x, y = sheet.nextX, sheet.nextY
		local width, height = ink.width, ink.height

		-- A shape writes one channel: the sheet is white already and the coverage is what says where
		-- the glyph is -- the shader multiplies the two.
		--
		-- A picture -- an emoji -- writes all four: the platform's order, each byte already
		-- multiplied by the alpha, which is divided back out here because the shader blends by it.
		if ink.colour then
			for row = 0, height - 1 do
				local from = ink.pixels + row * width * 4
				local into = sheet.pixels + ((y + row) * sheet.width + x) * 4

				for column = 0, width - 1 do
					local at = column * 4
					local alpha = from[at + 3]

					if alpha == 0 then
						into[at], into[at + 1], into[at + 2], into[at + 3] = 0, 0, 0, 0
					else
						local scale = 255 / alpha

						-- What a face hands over is blue, green, red and alpha, and what a sheet is
						-- holds red, green, blue and the alpha of it.
						into[at] = math.min(255, math.floor(from[at + 2] * scale + 0.5))
						into[at + 1] = math.min(255, math.floor(from[at + 1] * scale + 0.5))
						into[at + 2] = math.min(255, math.floor(from[at] * scale + 0.5))
						into[at + 3] = alpha
					end
				end
			end
		else
			for row = 0, height - 1 do
				local from = ink.pixels + row * width
				local into = sheet.pixels + ((y + row) * sheet.width + x) * 4 + 3

				for column = 0, width - 1 do
					into[column * 4] = from[column]
				end
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
