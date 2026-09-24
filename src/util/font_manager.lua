-- The fonts a screen draws with: what a style asks for, and what a machine has.
--
--   local fonts = self.assets.textureManager ... -- see `wonderland.plugin.Render.SharedResources`
--   sty():font("Inter"):text("lg")
--
-- What a style names is a family and a size, and what a screen needs is a face at that size with
-- a picture of its glyphs: this is where the two are put together. A face is read once however
-- many sizes ask for it, an atlas is made per face and size the first time something is drawn in
-- it, and a name that is not on this machine is answered with the machine's own sans rather than
-- with nothing -- see `wonderland.font.Registry`, which is what knows the names.
--
-- The fonts themselves are kept and handed out by number, because a number is what a style can
-- hold: a style is interned as bytes and compared as bytes, so a family name in it is a handle
-- into a table of names rather than a string -- see `wonderland.style`.
local Face = require("wonderland.font.face")
local Font = require("wonderland.font.font")
local Atlas = require("wonderland.font.atlas")
local Registry = require("wonderland.font.registry")

--- What an app or a style asks for. Everything but the family is what the element above it said
--- where the style says nothing, so an app names a family once and a size where it differs.
---@class wonderland.FontSpec
---@field family string? # A family name, or a font file to read instead of one
---@field pixelHeight number? # How tall the font is baked, in pixels
---@field weight number? # As CSS counts it: 100 to 900, 400 for a regular
---@field italic boolean?
---@field characters string? # What is baked when the atlas is made, where an app knows what it draws

--- A font, as a number: 1 based, and 0 is no font at all, which is what an element holds of one
--- it was not given.
---@alias Font number

local DEFAULT_PIXEL_HEIGHT = 16
local DEFAULT_WEIGHT = 400

-- What fonts a machine has is a question about the machine, not about an app: what one scan finds
-- is kept here and shared by every manager in the process, so that two windows -- or a test that
-- makes a screen an assertion -- do not read the same thousand font files over again.
local shared = nil

---@return Registry
local function registryOf()
	if shared == nil then
		shared = Registry.new()
	end

	return shared
end

-- What a name has to look like to be a file rather than a family: a font file's own extension, or
-- a path with a separator in it. A family name never has either, because a family is a name and
-- not a place.
local FILE_EXTENSIONS = { "%.ttf$", "%.otf$", "%.ttc$", "%.otc$", "%.dfont$", "%.TTF$", "%.OTF$" }

---@param name string
---@return boolean
local function isFilePath(name)
	if name:find("[/\\]") ~= nil then
		return true
	end

	for _, extension in ipairs(FILE_EXTENSIONS) do
		if name:find(extension) ~= nil then
			return true
		end
	end

	return false
end

---@class FontManager
---@field textureManager TextureManager
---@field registry Registry
---@field fonts wonderland.font.Font[] # By the number an element holds, from one
---@field defaultFont wonderland.font.Font?
---@field defaultSpec wonderland.FontSpec? # What it was resolved from, for a style to change one part of
---@field private byKey table<string, wonderland.font.Font> # A spec, resolved once
---@field private faces table<string, wonderland.font.Face | false> # Files read, by where they are
local FontManager = {}
FontManager.__index = FontManager

---@param textureManager TextureManager
---@param registry Registry?
---@return FontManager
function FontManager.new(textureManager, registry)
	return setmetatable({
		textureManager = textureManager,
		registry = registry or registryOf(),
		fonts = {},
		byKey = {},
		faces = {},
	}, FontManager)
end

---@param spec wonderland.FontSpec
---@return string
local function keyOf(spec)
	return string.format("%s\0%g\0%d\0%d\0%s", spec.family or "", spec.pixelHeight or DEFAULT_PIXEL_HEIGHT,
		spec.weight or DEFAULT_WEIGHT, spec.italic and 1 or 0, spec.characters or "")
end

--- A font file that is read once however many fonts are made from it: a face holds the whole of a
--- font's bytes, so two sizes of one font are two atlases and one file.
---@param path string
---@param index number?
---@return wonderland.font.Face?
function FontManager:face(path, index)
	local key = string.format("%s\1%d", path, index or 0)
	local known = self.faces[key]

	if known ~= nil then
		return known or nil
	end

	local face = Face.open(path, index)

	self.faces[key] = face or false

	return face
end

--- Where the font of a spec is: the file it names, the family it names, or -- where it names
--- nothing -- whatever this machine draws with when nothing is named.
---@param spec wonderland.FontSpec
---@return string? path
---@return number? index
function FontManager:where(spec)
	local family = spec.family

	if family == nil then
		return self.registry:default()
	end

	if isFilePath(family) then
		return family, 0
	end

	return self.registry:path(family, { weight = spec.weight or DEFAULT_WEIGHT, italic = spec.italic or false })
end

--- The font a spec asks for, made now if this is the first thing to ask for it. Every size of a
--- family is a font of its own and every kind of anything else is shared: the fonts an app has
--- asked for are kept, so a repaint asks by number and resolves nothing.
---@param spec wonderland.FontSpec
---@return wonderland.font.Font? font
---@return string? err
function FontManager:resolve(spec)
	local key = keyOf(spec)
	local known = self.byKey[key]

	if known ~= nil then
		return known
	end

	local path, index = self:where(spec)

	if path == nil then
		return nil, "No font on this machine to draw text with"
	end

	local face = self:face(path, index)

	if face == nil then
		return nil, string.format("%s could not be read as a font", path)
	end

	-- The fonts to ask about a character this one does not draw, in the order worth asking: what a
	-- title in another language is drawn with. They are read as they are needed, so a screen of
	-- latin text pays for the one face.
	local fallbacks = {}
	local seen = { [path] = true }

	for _, fallback in ipairs(self.registry:fallbacks(spec.family or "sans-serif")) do
		if not seen[fallback] then
			seen[fallback] = true
			fallbacks[#fallbacks + 1] = { fallback, 0 }
		end
	end

	local primary = Atlas.new(face, spec.pixelHeight or DEFAULT_PIXEL_HEIGHT, {
		pictures = self.textureManager,
		characters = spec.characters,
	})

	local manager = self
	local font = Font.new(primary, {
		spec = spec,
		fallbacks = fallbacks,
		load = function(fallbackPath, fallbackIndex)
			return manager:face(fallbackPath, fallbackIndex)
		end,
	})

	font.id = #self.fonts + 1
	self.fonts[font.id] = font
	self.byKey[key] = font

	return font
end

--- The font a style asks for, where the elements above it have named the rest: what a style says
--- about a family or a size is a change to the font it inherits, not a font of its own.
---@param from wonderland.font.Font?
---@param changes { family: string?, pixelHeight: number?, weight: number?, italic: boolean? }
---@return wonderland.font.Font? font
---@return string? err
function FontManager:derive(from, changes)
	local base = (from and from.spec) or self.defaultSpec or {}

	return self:resolve({
		family = changes.family or base.family,
		pixelHeight = changes.pixelHeight or base.pixelHeight,
		weight = changes.weight or base.weight,
		italic = changes.italic ~= nil and changes.italic or base.italic,
		characters = changes.family == nil and changes.pixelHeight == nil and base.characters or nil,
	})
end

---@param id Font
---@return wonderland.font.Font?
function FontManager:get(id)
	return self.fonts[id]
end

--- The font text is drawn in when it names none: what the app set, or the machine's own sans at
--- the default size where the app set nothing.
---
--- What an app set is a spec rather than a font until something is drawn, so that a screen with no
--- text in it costs nothing at all -- not a face read, not an atlas, not a texture. The first line
--- that is drawn resolves it, and every line after that reads what it came to.
---@return wonderland.font.Font?
function FontManager:getDefault()
	if self.defaultFont == nil and self.defaultSpec ~= nil then
		self.defaultFont = self:resolve(self.defaultSpec)
	end

	return self.defaultFont
end

--- What text is drawn in when it names no font: a spec, or a font that was resolved by hand. What a
--- spec comes to is not worked out here -- see `getDefault` -- so an app that names a family its
--- machine does not have still starts, and still draws: it draws in the machine's own sans.
---@param spec wonderland.FontSpec | wonderland.font.Font
function FontManager:setDefault(spec)
	if spec.id ~= nil and spec.atlases ~= nil then
		local font = spec
		self.defaultFont, self.defaultSpec = font, font.spec

		return
	end

	---@cast spec wonderland.FontSpec
	self.defaultFont, self.defaultSpec = nil, spec
end

--- What has been packed since the last frame, put into the pictures the screen samples: a glyph
--- an app's text needed is in the frame that follows the one it was measured in.
function FontManager:flush()
	for _, font in ipairs(self.fonts) do
		font:flush()
	end
end

return FontManager
