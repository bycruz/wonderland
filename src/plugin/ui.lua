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

--- Where a box that scrolls shows through: a quad is drawn down to this, and the part of the
--- texture that goes with the part that is left, so a glyph half out of a pane is cut rather
--- than squashed into the half of itself that shows.
---@class wonderland.plugin.UI.Clip
---@field left number
---@field top number
---@field right number
---@field bottom number

---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param windowWidth number
---@param windowHeight number
---@param left number
---@param top number
---@param right number
---@param bottom number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
---@param radius number? # How round the box's corners are, in pixels, nothing for square ones
---@param band number? # How sharp the edge of it is, one pixel either side by default
---@param grow number? # How far past the box the quad is drawn: a shadow is its own blur
local function clippedQuad(batch, clip, windowWidth, windowHeight, left, top, right, bottom, z, r, g, b, a,
	texture, u0, v0, u1, v1, radius, band, grow)
	-- A quad that is drawn past its box is one whose edge is spread out, so what is drawn is the
	-- box and the space the spreading needs; the box itself is what the corner arithmetic is about.
	local drawnLeft, drawnTop = left - (grow or 0), top - (grow or 0)
	local drawnRight, drawnBottom = right + (grow or 0), bottom + (grow or 0)
	-- The quad the box asked for, when all of it shows. Most quads are inside the clip -- only the
	-- ones at the edge of a pane that scrolls are not -- and working out where a quad is cut costs
	-- a pair of divisions, so the ones that need nothing are the ones that get nothing.
	if drawnLeft >= clip.left and drawnTop >= clip.top and drawnRight <= clip.right and drawnBottom <= clip.bottom then
		-- Cut and square are a call each rather than one argument to the same call: they are not
		-- drawn in the same numbers, and a screen of text is nearly all of one of them.
		if band or (radius and radius > 0) then
			batch:roundQuad(
				toNDC(drawnLeft, windowWidth),
				-toNDC(drawnTop, windowHeight),
				toNDC(drawnRight, windowWidth),
				-toNDC(drawnBottom, windowHeight),
				z,
				r, g, b, a,
				texture,
				u0, v0, u1, v1,
				radius or 0,
				toNDC(left, windowWidth),
				-toNDC(top, windowHeight),
				toNDC(right, windowWidth),
				-toNDC(bottom, windowHeight),
				band
			)
		else
			batch:quad(
				toNDC(left, windowWidth),
				-toNDC(top, windowHeight),
				toNDC(right, windowWidth),
				-toNDC(bottom, windowHeight),
				z,
				r, g, b, a,
				texture,
				u0, v0, u1, v1
			)
		end

		return
	end

	local atLeft = drawnLeft < clip.left and clip.left or drawnLeft
	local atTop = drawnTop < clip.top and clip.top or drawnTop
	local atRight = drawnRight > clip.right and clip.right or drawnRight
	local atBottom = drawnBottom > clip.bottom and clip.bottom or drawnBottom

	if atRight <= atLeft or atBottom <= atTop then
		return
	end

	local du = (u1 - u0) / (drawnRight - drawnLeft)
	local dv = (v1 - v0) / (drawnBottom - drawnTop)

	-- What is drawn is what is inside the clip but the corners are the corners of the whole box: a
	-- box cut down to a sliver by the pane it is in is still a box with round corners, and the
	-- corners of the sliver are not corners of it.
	if band or (radius and radius > 0) then
		batch:roundQuad(
			toNDC(atLeft, windowWidth),
			-toNDC(atTop, windowHeight),
			toNDC(atRight, windowWidth),
			-toNDC(atBottom, windowHeight),
			z,
			r, g, b, a,
			texture,
			u0 + du * (atLeft - drawnLeft), v0 + dv * (atTop - drawnTop),
			u0 + du * (atRight - drawnLeft), v0 + dv * (atBottom - drawnTop),
			radius or 0,
			toNDC(left, windowWidth),
			-toNDC(top, windowHeight),
			toNDC(right, windowWidth),
			-toNDC(bottom, windowHeight),
			band
		)

		return
	end

	batch:quad(
		toNDC(atLeft, windowWidth),
		-toNDC(atTop, windowHeight),
		toNDC(atRight, windowWidth),
		-toNDC(atBottom, windowHeight),
		z,
		r, g, b, a,
		texture,
		u0 + du * (atLeft - drawnLeft), v0 + dv * (atTop - drawnTop),
		u0 + du * (atRight - drawnLeft), v0 + dv * (atBottom - drawnTop)
	)
end

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
local function addBorderQuad(batch, clip, bx, by, bw, bh, r, g, b, a, z, windowWidth, windowHeight)
	if bw <= 0 or bh <= 0 then
		return
	end

	clippedQuad(batch, clip, windowWidth, windowHeight, bx, by, bx + bw, by + bh, convertZ(z + 1), r, g, b, a, 0,
		0, 0, 1, 1)
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
local function generateTextQuads(batch, clip, run, node, x, y, z, fontManager, windowWidth, windowHeight)
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

		clippedQuad(batch, clip, windowWidth, windowHeight, originX + glyph.x, originY + glyph.y,
			originX + glyph.x + glyph.width, originY + glyph.y + glyph.height, zIndex, r, g, b,
			node.fgA / 255, font, glyph.u0, glyph.v0, glyph.u1, glyph.v1)
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
local function generateNodeQuads(batch, screen, clip, index, parentX, parentY, windowWidth, windowHeight, parentZ,
	fontManager)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local z = math.max(node.zIndex, parentZ or 0)

	-- The shadow first, so the box is drawn over it. It is the box itself, moved and drawn with
	-- its edge spread out: the quad it is drawn as is the box grown by that spreading, and the
	-- cut the shader makes is of the box, so what shows is the box's own shape going soft.
	if node.visible ~= 0 and node.shadowA > 0 then
		local blur = node.shadowBlur
		local band = blur > 0 and (1 / (2 * blur)) or 1

		clippedQuad(batch, clip, windowWidth, windowHeight, x + node.shadowX, y + node.shadowY,
			x + node.shadowX + node.width, y + node.shadowY + node.height, convertZ(z),
			node.shadowR / 255, node.shadowG / 255, node.shadowB / 255, node.shadowA / 255,
			0, 0, 0, 1, 1, node.radius, band, blur + 1)
	end

	if node.visible ~= 0 and node.paint ~= 0 then
		local r, g, b, a = node.bgR, node.bgG, node.bgB, node.bgA

		if node.texture ~= 0 and r == 0 and g == 0 and b == 0 then
			r, g, b, a = WHITE_R, WHITE_G, WHITE_B, WHITE_A
		end

		clippedQuad(batch, clip, windowWidth, windowHeight, x, y, x + node.width, y + node.height,
			convertZ(z), r, g, b, a, node.texture, node.u0, node.v0, node.u1, node.v1, node.radius)
	end

	if node.visible ~= 0 and node.run ~= 0 then
		generateTextQuads(batch, clip, assert(screen.runs[node.run]), node, x, y, z, fontManager, windowWidth,
			windowHeight)
	end

	-- Borders come after the box they are on, so they land on top of it.
	if node.visible ~= 0 then
		local r, g, b, a = node.borderR, node.borderG, node.borderB, node.borderA
		local width, height = node.width, node.height

		if node.borderTop > 0 then
			addBorderQuad(batch, clip, x, y, width, node.borderTop, r, g, b, a, z, windowWidth, windowHeight)
		end

		if node.borderBottom > 0 then
			addBorderQuad(batch, clip, x, y + height - node.borderBottom, width, node.borderBottom, r, g, b, a, z,
				windowWidth, windowHeight)
		end

		if node.borderLeft > 0 then
			addBorderQuad(batch, clip, x, y, node.borderLeft, height, r, g, b, a, z, windowWidth, windowHeight)
		end

		if node.borderRight > 0 then
			addBorderQuad(batch, clip, x + width - node.borderRight, y, node.borderRight, height, r, g, b, a, z,
				windowWidth, windowHeight)
		end
	end

	-- What a box that scrolls shows of its children is what is inside it: the clip is narrowed to
	-- it, and stays narrowed for everything below.
	local below = clip

	if node.scrolls ~= 0 then
		below = {
			left = math.max(clip.left, x),
			top = math.max(clip.top, y),
			right = math.min(clip.right, x + node.width),
			bottom = math.min(clip.bottom, y + node.height),
		}
	end

	for at = 0, node.childCount - 1 do
		generateNodeQuads(batch, screen, below, screen.childIndices[node.firstChild + at - 1], x, y, windowWidth,
			windowHeight, z, fontManager)
	end

	-- A scroll bar is drawn over the strip it reserved, once the content is down: the track is the
	-- colour it was given made fainter, and the thumb is as much of the track as the box shows of
	-- the content. It is only there when there is something to scroll, which is what "shows up"
	-- means -- a list that fits has no bar.
	local bar = node.scrolls ~= 0 and screen.bars[index - 1]

	if node.visible ~= 0 and bar and bar.width > 0 and bar.max > 0 then
		local left = x + node.width - bar.width
		local thumb = node.height * (node.height / (node.height + bar.max))

		if thumb < bar.least then
			thumb = bar.least
		end

		if thumb > node.height then
			thumb = node.height
		end

		-- Where the thumb may travel is what is left of the box once the thumb is in it, so the
		-- end of the list puts the thumb's end at the end of the box rather than past it.
		local span = node.height - thumb
		local at = math.min(math.max(node.scroll / bar.max, 0), 1)
		local top = y + (span > 0 and at * span or 0)

		-- Drawn inside its own pane rather than the clip it is under, so a bar cannot come out of
		-- the box it belongs to and over whatever is beside it.
		clippedQuad(batch, below, windowWidth, windowHeight, left, y, left + bar.width, y + node.height,
			convertZ(z), bar.r, bar.g, bar.b, bar.a * 0.25, 0, 0, 0, 1, 1)
		clippedQuad(batch, below, windowWidth, windowHeight, left, top, left + bar.width, top + thumb,
			convertZ(z + 1), bar.r, bar.g, bar.b, bar.a, 0, 0, 0, 1, 1)
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
		self.batch:setViewport(window.width, window.height)
		generateNodeQuads(self.batch, screen, { left = 0, top = 0, right = window.width, bottom = window.height },
			assert(ctx.root), 0, 0, window.width, window.height, nil, fontManager)

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
