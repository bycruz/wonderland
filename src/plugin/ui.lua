local QuadBatch = require("wonderland.util.quad_batch")

---@class wonderland.plugin.UI: wonderland.Plugin
---@field layoutPlugin wonderland.plugin.Layout
---@field renderPlugin wonderland.plugin.Render
---@field batch wonderland.QuadBatch
local UI = {}
UI.__index = UI

---@param layoutPlugin wonderland.plugin.Layout
---@param renderPlugin wonderland.plugin.Render
function UI.new(layoutPlugin, renderPlugin)
	return setmetatable({ layoutPlugin = layoutPlugin, renderPlugin = renderPlugin, batch = QuadBatch.new() }, UI)
end

---@param pos number
---@param screenSize number
---@return number
local function toNDC(pos, screenSize)
	return (pos / (screenSize * 0.5)) - 1.0
end

--- Converts a z-index to an NDC z-value
---@param z number?
local function convertZ(z)
	return 1 - math.min(z or 0, 100000) / 1000000
end

-- A box with no colour of its own is drawn with its texture as it is, which is white.
local WHITE_R, WHITE_G, WHITE_B, WHITE_A = 1.0, 1.0, 1.0, 1.0

---@param batch wonderland.QuadBatch
---@param bx number
---@param by number
---@param bw number
---@param bh number
---@param r number
---@param g number
---@param b number
---@param a number
---@param z number
---@param windowWidth number
---@param windowHeight number
local function addBorderQuad(batch, bx, by, bw, bh, r, g, b, a, z, windowWidth, windowHeight)
	if bw <= 0 or bh <= 0 then
		return
	end

	batch:quad(
		toNDC(bx, windowWidth),
		-toNDC(by, windowHeight),
		toNDC(bx + bw, windowWidth),
		-toNDC(by + bh, windowHeight),
		convertZ(z + 1),
		r, g, b, a,
		0
	)
end

--- A line is drawn from the run it measured into, which is where its glyphs are.
---@param batch wonderland.QuadBatch
---@param run wonderland.font.Run
---@param node wonderland.Node
---@param x number # Absolute, so the glyphs land on whole pixels
---@param y number
---@param z number
---@param fontManager FontManager
---@param windowWidth number
---@param windowHeight number
local function generateTextQuads(batch, run, node, x, y, z, fontManager, windowWidth, windowHeight)
	local r, g, b = node.fgR / 255, node.fgG / 255, node.fgB / 255
	local font = node.font ~= 0 and (node.font - 1)
		or assert(fontManager:getDefault(), "No font to draw text with: load one and make it the default")

	-- A line may be given more room than it needs, and then it says where in that room
	-- the line sits.
	local offset = 0
	if node.justify == 1 then
		offset = math.floor((node.width - run.width) / 2 + 0.5)
	elseif node.justify == 2 then
		offset = node.width - run.width
	end

	local originX, originY = x + offset, y
	local zIndex = convertZ(z)

	-- One array of glyphs, read by index: the run was measured as structs, so drawing a
	-- line costs a handful of loads rather than a table lookup per glyph.
	for index = 0, run.count - 1 do
		local glyph = run.glyphs[index]

		batch:quad(
			toNDC(originX + glyph.x, windowWidth),
			-toNDC(originY + glyph.y, windowHeight),
			toNDC(originX + glyph.x + glyph.width, windowWidth),
			-toNDC(originY + glyph.y + glyph.height, windowHeight),
			zIndex,
			r, g, b, node.fgA / 255,
			font,
			glyph.u0, glyph.v0, glyph.u1, glyph.v1
		)
	end
end

--- Walks the laid out screen, which is an array of nodes: a walk is an index and an
--- offset, and children are reached through the runs of child indices.
---@param batch wonderland.QuadBatch
---@param screen wonderland.Layout.Screen
---@param index number
---@param parentX number
---@param parentY number
---@param windowWidth number
---@param windowHeight number
---@param parentZ number?
---@param fontManager FontManager
local function generateNodeQuads(batch, screen, index, parentX, parentY, windowWidth, windowHeight, parentZ,
	fontManager)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local z = math.max(node.zIndex, parentZ or 0)

	if node.visible ~= 0 and node.paint ~= 0 then
		local r, g, b, a = node.bgR, node.bgG, node.bgB, node.bgA

		if node.texture ~= 0 and r == 0 and g == 0 and b == 0 then
			r, g, b, a = WHITE_R, WHITE_G, WHITE_B, WHITE_A
		end

		batch:quad(
			toNDC(x, windowWidth),
			-toNDC(y, windowHeight),
			toNDC(x + node.width, windowWidth),
			-toNDC(y + node.height, windowHeight),
			convertZ(z),
			r, g, b, a,
			node.texture,
			node.u0, node.v0, node.u1, node.v1
		)
	end

	if node.visible ~= 0 and node.run ~= 0 then
		generateTextQuads(batch, assert(screen.runs[node.run]), node, x, y, z, fontManager, windowWidth, windowHeight)
	end

	-- Borders come after the box they are on, so they land on top of it.
	if node.visible ~= 0 then
		local r, g, b, a = node.borderR, node.borderG, node.borderB, node.borderA
		local width, height = node.width, node.height

		if node.borderTop > 0 then
			addBorderQuad(batch, x, y, width, node.borderTop, r, g, b, a, z, windowWidth, windowHeight)
		end

		if node.borderBottom > 0 then
			addBorderQuad(batch, x, y + height - node.borderBottom, width, node.borderBottom, r, g, b, a, z,
				windowWidth, windowHeight)
		end

		if node.borderLeft > 0 then
			addBorderQuad(batch, x, y, node.borderLeft, height, r, g, b, a, z, windowWidth, windowHeight)
		end

		if node.borderRight > 0 then
			addBorderQuad(batch, x + width - node.borderRight, y, node.borderRight, height, r, g, b, a, z,
				windowWidth, windowHeight)
		end
	end

	for at = 0, node.childCount - 1 do
		generateNodeQuads(batch, screen, screen.childIndices[node.firstChild + at - 1], x, y, windowWidth,
			windowHeight, z, fontManager)
	end
end


function UI:requestRedraw(window)
	window.shouldRedraw = true -- shh. I'll figure out a way to make this use the eventhandler later.
end

--- A window that changed size is another solve of the same screen, because the screen is laid
--- out against the window; one the pointer moved in may be drawn differently where the pointer
--- is. Both are another repaint, and a repaint that comes out the same as the last one costs a
--- solve and no more, so this does not have to be clever about which of them changed anything.
---
--- The layout is asked before this is, because the plugins are asked in the order they were
--- added, and it is the layout that says where the pointer is.
---@param event winit.Event
---@param _handler winit.EventManager
function UI:event(event, _handler)
	local name = event.name

	if name == "resize" or name == "mouseMove" or name == "mousePress"
		or name == "mouseRelease" or name == "focusOut" then
		self:refreshView(event.window)
	end
end

---@param window wonderland.RenderWindow
function UI:refreshView(window)
	-- The screen is built and laid out again first: this is where a repaint starts.
	self.layoutPlugin:refreshView(window)

	local ctx = self.layoutPlugin.contexts[window]

	-- Nothing to draw for a window no screen was made in.
	if not ctx then
		return
	end

	-- The font a line is drawn in is looked up only when there is a line to draw, so a
	-- screen without text does not need a font at all.
	local fontManager = assert(self.renderPlugin.sharedResources).fontManager

	local screen = assert(ctx.screen)

	-- A repaint whose screen came out the same as the one the gpu already has needs no
	-- quads built and nothing uploaded: that is the whole point of the layout being one
	-- flat array of plain data. The first frame is always built, whatever it says, because
	-- a window that has never been given a frame has nothing to show.
	if screen.changed or not ctx.uploaded then
		self.batch:reset()
		generateNodeQuads(self.batch, screen, assert(ctx.root), 0, 0, window.width, window.height, nil, fontManager)

		self.renderPlugin:setRenderData(window, self.batch)
		ctx.uploaded = true

		-- A frame is asked for only when the one the gpu has is not the one the screen solves
		-- to. Everything that can repaint goes through here -- a click, a resize, the pointer
		-- moving -- and most of those come out the same as the last one: a pointer that moved
		-- across the same element, a window resized back to the size it was, a message that
		-- changed nothing the screen shows. Asking the window to draw those would spend a
		-- frame on nothing and, worse, spend it waiting for the display, which is time the
		-- next event spends queued behind it. That is what made the pointer feel slow.
		self:requestRedraw(window)
	end
end

return UI
