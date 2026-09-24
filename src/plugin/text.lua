--- Text stays one element. It is measured here so the layout has something to place,
--- and the run that measured it is handed to the quad pass, which draws its glyphs: one
--- element per character would be simpler to draw and much more expensive to lay out.
local bit = require("bit")
local style = require("wonderland.style")
local wonderlandElement = require("wonderland.element")

local pointers, strings = wonderlandElement.pointers, wonderlandElement.strings
local TEXT_INPUT, GROWS = wonderlandElement.TEXT_INPUT, wonderlandElement.GROWS

---@class wonderland.plugin.Text: wonderland.Plugin
---@field renderPlugin wonderland.plugin.Render
local Text = {}
Text.__index = Text

---@param renderPlugin wonderland.plugin.Render
function Text.new(renderPlugin) ---@return wonderland.plugin.Text
	return setmetatable({ renderPlugin = renderPlugin }, Text)
end

--- Measured from the top down, because a line is drawn in the font of whatever it sits
--- in unless it names one itself.
---@param element wonderland.Element
---@param inherited Font? # What the elements above this one are drawn with
---@return wonderland.Element
function Text:measure(element, inherited)
	-- Taken per call rather than kept: what a tree is built with can intern a style, and
	-- interning is what moves the array it is read from.
	local arena = style.arena
	local base = arena[element.baseStyle]
	local font = (base.font ~= 0 and base.font) or inherited
	local line = strings[element.text]

	-- A field that is as tall as what is typed into it is one whose value has to be measured: how
	-- many lines it is, and how tall a line of it is, is what the layout sizes the box from. The
	-- value is text like any other, and it is measured in the font the field is drawn in. A field
	-- that says nothing about its size is not measured: what is in it is drawn by the app, which
	-- measures it itself, and a screen of fields pays nothing for this.
	local sized = bit.band(element.flags, TEXT_INPUT) ~= 0 and bit.band(element.flags, GROWS) ~= 0

	if line ~= nil or sized then
		local fontManager = self.renderPlugin.sharedResources.fontManager
		assert(fontManager, "Font manager not initialized in render plugin")

		local drawing = (font ~= 0 and font) or assert(fontManager:getDefault(),
			"No font to draw text with: load one and make it the default, or name one in a style")
		local bitmap = fontManager:getBitmap(drawing)

		-- Only the run and the font it was drawn with are attached. How big a line is
		-- belongs to the layout, because a style is shared by every element that looks the
		-- same: writing the measured size here would give every one of them the size of
		-- the first.
		if line ~= nil then
			element.run = wonderlandElement.pushRun(bitmap:getRun(line))
		end

		if sized then
			element.valueRun = wonderlandElement.pushRun(bitmap:getRun(wonderlandElement.inputOf(element)))
		end

		element.fontId = drawing
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
