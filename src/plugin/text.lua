--- Text stays one element. It is measured here so the layout has something to place,
--- and the run that measured it is handed to the quad pass, which draws its glyphs: one
--- element per character would be simpler to draw and much more expensive to lay out.
---
--- What a line is drawn in is resolved here as well, because a style names a family and a size
--- and a screen draws in a font: the two are put together by the font manager, once per style and
--- per font it inherits -- which is a table lookup per element per repaint, and no work at all for
--- a screen that named nothing.
local bit = require("bit")
local style = require("wonderland.style")
local wonderlandElement = require("wonderland.element")

local pointers, strings = wonderlandElement.pointers, wonderlandElement.strings
local TEXT_INPUT, GROWS = wonderlandElement.TEXT_INPUT, wonderlandElement.GROWS

-- The bits of a style that are about the font its contents are drawn in: a style that names any
-- of them is a font its elements are drawn in, made from the font they already inherit.
local TYPOGRAPHY = style.PRESENT.fontFamily | style.PRESENT.fontSize | style.PRESENT.fontWeight
	| style.PRESENT.fontItalic

---@class wonderland.plugin.Text: wonderland.Plugin
---@field renderPlugin wonderland.plugin.Render
---@field private fonts table<number, table<number, wonderland.font.Font>> # A style's font, by what it inherits
local Text = {}
Text.__index = Text

---@param renderPlugin wonderland.plugin.Render
function Text.new(renderPlugin) ---@return wonderland.plugin.Text
	return setmetatable({ renderPlugin = renderPlugin, fonts = {} }, Text)
end

--- The font an element is drawn in: what its style says about the font it inherits, or -- where
--- it says nothing -- the font itself.
---
--- A style names a family and a size, and a font is a face at a size: what the same style comes to
--- is kept, so a screen of rows that name one family resolves it once and every row after that
--- reads it. The number of fonts a screen can ask for is the number of things it named.
---@param slot number # The style the element was built with
---@param base wonderland.StyleSlot
---@param inherited wonderland.font.Font?
---@return wonderland.font.Font
function Text:fontFor(slot, base, inherited)
	local byInherited = self.fonts[slot]

	if byInherited == nil then
		byInherited = {}
		self.fonts[slot] = byInherited
	end

	local key = inherited ~= nil and inherited.id or 0
	local known = byInherited[key]

	if known ~= nil then
		return known
	end

	local fontManager = assert(self.renderPlugin.sharedResources, "No font manager yet").fontManager
	local flags = base.flags
	local italic = nil

	if bit.band(flags, style.PRESENT.fontItalic) ~= 0 then
		italic = base.fontItalic ~= 0
	end

	local font, err = fontManager:derive(inherited, {
		family = base.fontFamily ~= 0 and style.familyAt(base.fontFamily) or nil,
		pixelHeight = base.fontSize ~= 0 and base.fontSize or nil,
		weight = base.fontWeight ~= 0 and base.fontWeight or nil,
		italic = italic,
	})

	assert(font, err or "No font to draw text with: load one and make it the default, or name one in a style")

	byInherited[key] = font

	return font
end

--- Measured from the top down, because a line is drawn in the font of whatever it sits
--- in unless it names one itself.
---@param element wonderland.Element
---@param inherited wonderland.font.Font? # What the elements above this one are drawn with
---@return wonderland.Element
function Text:measure(element, inherited)
	-- Taken per call rather than kept: what a tree is built with can intern a style, and
	-- interning is what moves the array it is read from.
	local arena = style.arena
	local base = arena[element.baseStyle]
	local font = inherited

	-- A font an element was handed by number is one an app wired up itself, and one it named by
	-- family or size is a change to the font its contents inherit.
	if bit.band(base.flags, TYPOGRAPHY) ~= 0 then
		font = self:fontFor(element.baseStyle, base, inherited)
	elseif base.font ~= 0 then
		local wired = assert(self.renderPlugin.sharedResources).fontManager:get(base.font)

		if wired ~= nil then
			font = wired
		end
	end

	local line = strings[element.text]

	-- A field that is as tall as what is typed into it is one whose value has to be measured: how
	-- many lines it is, and how tall a line of it is, is what the layout sizes the box from. The
	-- value is text like any other, and it is measured in the font the field is drawn in. A field
	-- that says nothing about its size is not measured: what is in it is drawn by the app, which
	-- measures it itself, and a screen of fields pays nothing for this.
	local sized = bit.band(element.flags, TEXT_INPUT) ~= 0 and bit.band(element.flags, GROWS) ~= 0

	if line ~= nil or sized then
		local fontManager = assert(self.renderPlugin.sharedResources).fontManager
		local drawing = font or fontManager:getDefault()

		assert(drawing,
			"No font to draw text with: load one and make it the default, or name one in a style")

		-- Only the run and the font it was drawn with are attached. How big a line is
		-- belongs to the layout, because a style is shared by every element that looks the
		-- same: writing the measured size here would give every one of them the size of
		-- the first.
		if line ~= nil then
			element.run = wonderlandElement.pushRun(drawing:getRun(line))
		end

		if sized then
			element.valueRun = wonderlandElement.pushRun(drawing:getRun(wonderlandElement.inputOf(element)))
		end

		element.fontId = assert(drawing.id)
		font = drawing
	end

	local child = element.childFirst

	while child ~= 0 do
		local childElement = pointers[child]

		self:measure(childElement, font)
		child = childElement.nextSibling
	end

	return element
end

return Text
