local Bitmap = require("wonderland.font.stbtt")

---@alias Font number

---@class FontManager
---@field textureManager TextureManager
---@field bitmaps table<Font, wonderland.font.Atlas>
---@field defaultFont Font
local FontManager = {}
FontManager.__index = FontManager

---@param textureManager TextureManager
---@param fontPath string? # A ttf or otf to rasterise the default font from, if the app has one
function FontManager.new(textureManager, fontPath)
	local self = setmetatable({ textureManager = textureManager, bitmaps = {} }, FontManager)

	local characters =
	" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

	if fontPath ~= nil then
		local defaultBitmap = assert(
			Bitmap.fromPath({ pixelHeight = 18, characters = characters }, fontPath),
			"Failed to rasterise the font"
		)
		self.defaultFont = self:upload(defaultBitmap)
	end

	return self
end

---@param bitmap wonderland.font.Atlas
---@return Font
function FontManager:upload(bitmap)
	local id = self.textureManager:upload(bitmap.image)
	self.bitmaps[id] = bitmap
	return id
end

function FontManager:getDefault()
	return self.defaultFont
end

--- The font text elements draw with when they do not name one themselves.
---@param font Font
function FontManager:setDefault(font)
	self.defaultFont = font
end

---@param font Font
---@return wonderland.font.Atlas
function FontManager:getBitmap(font)
	return self.bitmaps[font]
end

return FontManager
