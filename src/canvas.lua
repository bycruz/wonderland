-- A box an app draws shapes in: what a spectrum, a waveform, a meter or a graph is made of.
--
--   div():style(sty():fill()):canvas(function(canvas)
--       for index, level in ipairs(spectrum) do
--           canvas:rect(index * 6, canvas.height - level, 5, level, "#3b82f6")
--       end
--   end)
--
-- What it is handed is a box as wide and as tall as the room its element was given, in whole pixels
-- from that element's top left corner -- the room inside its padding and its border, which is the
-- room a child of it would get. What it draws goes into the frame its screen is, where the element
-- is: over what is under the element, under what is over it, cut by the pane the element is in.
--
-- The shapes are one colour each, with no edge of their own and nothing blended between them, and
-- none of them is a picture: what a shader of an app's own or another renderer built on hood draws
-- is a texture shown by a screen instead -- `wonderland.plugin.Render:texture` and `:target`.
--
-- One canvas is handed to every draw of every frame and written into again, so nothing here
-- allocates and what a caller keeps is its own state: this frame's spectrum is the app's, and so is
-- the history of the last ones.
local ffi = require("ffi")

--- The colours a canvas knows by name. What a caller writes as a hex string is anything at all.
local NAMED = {
	black = { 0, 0, 0 },
	white = { 1, 1, 1 },
	red = { 1, 0, 0 },
	green = { 0, 0.6, 0.2 },
	blue = { 0.23, 0.51, 0.96 },
	grey = { 0.5, 0.5, 0.5 },
	gray = { 0.5, 0.5, 0.5 },
}

--- The four numbers a colour is, as the numbers a frame is written with: a name, a hex string, or
--- a table of channels. What none of those is is white, which is what a canvas draws where it was
--- given something it cannot read rather than drawing nothing.
---@param colour string|wonderland.Color
---@return number r
---@return number g
---@return number b
---@return number a
local function colourOf(colour)
	if type(colour) == "table" then
		return colour.r or colour[1] or 0, colour.g or colour[2] or 0, colour.b or colour[3] or 0,
			colour.a or colour[4] or 1
	end

	if type(colour) == "string" then
		local named = NAMED[colour:lower()]

		if named ~= nil then
			return named[1], named[2], named[3], 1
		end

		local hex = colour:match("^#(%x+)$")

		if hex ~= nil then
			local step = #hex <= 3 and 1 or 2

			---@param index number
			---@return number
			local function part(index)
				local byte = tonumber(hex:sub(index * step + 1, index * step + step), 16) or 0

				return step == 1 and byte / 15 or byte / 255
			end

			return part(0), part(1), part(2), #hex == 8 and part(3) or 1
		end
	end

	return 1, 1, 1, 1
end

--- Where a point is in the frame's own coordinates: what the frame's vertices are written in.
---@param pos number
---@param screenSize number
---@return number
local function toNDC(pos, screenSize)
	return (pos / (screenSize * 0.5)) - 1.0
end

--- The corners of a circle, as a shape of as many sides.
---@param x number
---@param y number
---@param radius number
---@param sides number
---@return number[]
local function circlePoints(x, y, radius, sides)
	local points = {}

	for at = 0, sides - 1 do
		local angle = at / sides * math.pi * 2

		points[#points + 1] = x + math.cos(angle) * radius
		points[#points + 1] = y + math.sin(angle) * radius
	end

	return points
end

--- The points of a shape with the part of it outside a clip taken off, which is what a shape the
--- clip cuts through is drawn as.
---
--- It is Sutherland and Hodgman: the shape is walked once per edge of the clip, and what comes out
--- of each walk is the part of it inside that edge. A triangle cut by the corner of a pane comes
--- out of it as a shape of up to seven corners, which is what is drawn as the fan of them.
---@param clip wonderland.plugin.UI.Clip
---@param points number[] # The corners, a pair of numbers each, in the order they go round
---@return number[] inside # The corners that are, which is nothing where none of it is
local function clipPoints(clip, points)
	local inside = points

	---@param test fun(x: number, y: number): boolean
	---@param cross fun(x1: number, y1: number, x2: number, y2: number): number, number
	---@return number[]
	local function cut(test, cross)
		local out = {}
		local count = #inside / 2

		for at = 0, count - 1 do
			local x1, y1 = inside[at * 2 + 1], inside[at * 2 + 2]
			local next2 = (at + 1) % count
			local x2, y2 = inside[next2 * 2 + 1], inside[next2 * 2 + 2]
			local first, second = test(x1, y1), test(x2, y2)

			if first then
				out[#out + 1], out[#out + 2] = x1, y1
			end

			if first ~= second then
				local x, y = cross(x1, y1, x2, y2)

				out[#out + 1], out[#out + 2] = x, y
			end
		end

		return out
	end

	--- Where a stretch of an edge crosses one of the clip's edges, which is the corner the walk
	--- adds.
	---@param axis number # 1 across, 2 down
	---@param value number # Where the clip's edge is
	---@return fun(x1: number, y1: number, x2: number, y2: number): number, number
	local function crossing(axis, value)
		return function(x1, y1, x2, y2)
			local from, to = axis == 1 and x1 or y1, axis == 1 and x2 or y2
			local at = (value - from) / (to - from)

			if axis == 1 then
				return value, y1 + (y2 - y1) * at
			end

			return x1 + (x2 - x1) * at, value
		end
	end

	inside = cut(function(x) return x >= clip.left end, crossing(1, clip.left))
	inside = cut(function(x) return x <= clip.right end, crossing(1, clip.right))
	inside = cut(function(_, y) return y >= clip.top end, crossing(2, clip.top))
	inside = cut(function(_, y) return y <= clip.bottom end, crossing(2, clip.bottom))

	return inside
end

--- A shape at the canvas's own corner, clipped to what shows of it and drawn as the fan of what is
--- left: what every shape of more than four corners comes to.
---
--- What it is given is in the canvas's own coordinates and what it draws is in the frame's: the two
--- differ by where the element is, and the clip is the frame's, so the move happens here and once,
--- whether or not the shape needs cutting.
---@param self wonderland.Canvas
---@param points number[] # The corners, from the canvas's corner
---@param r number
---@param g number
---@param b number
---@param a number
---@return wonderland.Canvas
local function fan(self, points, r, g, b, a)
	local store = self.store
	local clip = store.clip
	local count = #points / 2

	if count < 3 then
		return self
	end

	-- safety: the moved shape is written over rather than made again, because a spectrum is a shape
	-- per bar per frame; it is copied before it is cut, since the cut is what makes a table of a
	-- different size
	local moved = store.moved
	local left, right, top, bottom = math.huge, -math.huge, math.huge, -math.huge

	for at = 1, count do
		local x, y = store.left + points[at * 2 - 1], store.top + points[at * 2]

		moved[at * 2 - 1], moved[at * 2] = x, y

		if x < left then left = x end
		if x > right then right = x end
		if y < top then top = y end
		if y > bottom then bottom = y end
	end

	if right <= clip.left or left >= clip.right or bottom <= clip.top or top >= clip.bottom then
		return self
	end

	if left < clip.left or top < clip.top or right > clip.right or bottom > clip.bottom then
		local corners = {}

		for at = 1, count * 2 do
			corners[at] = moved[at]
		end

		moved = clipPoints(clip, corners)
		count = #moved / 2
	end

	if count < 3 then
		return self
	end

	local batch, z, white = store.batch, store.z, store.white
	local windowWidth, windowHeight = store.windowWidth, store.windowHeight

	for at = 1, count - 2 do
		batch:triangle(toNDC(moved[1], windowWidth), -toNDC(moved[2], windowHeight),
			toNDC(moved[at * 2 + 1], windowWidth), -toNDC(moved[at * 2 + 2], windowHeight),
			toNDC(moved[at * 2 + 3], windowWidth), -toNDC(moved[at * 2 + 4], windowHeight), z, r, g, b, a,
			white)
	end

	return self
end

--- A box an app draws shapes in. The screen makes it and hands it to the draw of a canvas element:
--- what it is about is one element of one frame, and it is handed out again for the next.
---@class wonderland.Canvas
---@field width number # How wide the room it was given is, in pixels
---@field height number # And how tall
local Canvas = {}
Canvas.__index = Canvas

-- Where a shape is written, and what it is cut by: what the screen points the canvas at before it
-- hands it over, and nothing an app is asked about.
---@class wonderland.Canvas.Store
---@field batch wonderland.QuadBatch
---@field clip wonderland.plugin.UI.Clip
---@field windowWidth number
---@field windowHeight number
---@field left number
---@field top number
---@field z number
---@field white number
---@field moved number[] # The corners of the shape being drawn, moved into the frame's own coordinates

--- The canvas a screen draws with, made once and written into again for every draw: a canvas made
--- per draw would be a table per canvas per frame, and a frame allocates nothing of its own.
---@return wonderland.Canvas
function Canvas.new()
	return setmetatable({ width = 0, height = 0, store = { moved = {} } }, Canvas)
end

--- Points the canvas at a frame, a room and a clip: what the screen does before it hands the canvas
--- to an app, and what it does again for the next canvas of the frame.
---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param windowWidth number
---@param windowHeight number
---@param left number # Where the room is, in the coordinates the frame is clipped in
---@param top number
---@param width number
---@param height number
---@param z number # The depth the element is drawn at, as the frame is written with it
---@param white number # The picture a shape of no picture of its own is drawn with
---@return wonderland.Canvas
function Canvas:draw(batch, clip, windowWidth, windowHeight, left, top, width, height, z, white)
	local store = self.store

	store.batch, store.clip = batch, clip
	store.windowWidth, store.windowHeight = windowWidth, windowHeight
	store.left, store.top, store.z, store.white = left, top, z, white

	self.width, self.height = width, height

	return self
end

--- A rectangle, with its top left corner at `x`, `y` and the size it is given. `radius` rounds its
--- corners, and a rectangle of no width or no height is nothing at all.
---@param x number
---@param y number
---@param width number
---@param height number
---@param colour string|wonderland.Color
---@param radius number? # How round its corners are, in pixels
---@return wonderland.Canvas
function Canvas:rect(x, y, width, height, colour, radius)
	if width <= 0 or height <= 0 then
		return self
	end

	local store = self.store
	local left, top = store.left + x, store.top + y
	local right, bottom = left + width, top + height
	local clip = store.clip

	-- A shape that is nowhere near the clip is not drawn, and one that is in it whole is drawn as
	-- it is: most shapes of most frames are one of those, and neither costs the cutting.
	if right <= clip.left or left >= clip.right or bottom <= clip.top or top >= clip.bottom then
		return self
	end

	local r, g, b, a = colourOf(colour)
	local cut = left < clip.left or top < clip.top or right > clip.right or bottom > clip.bottom

	if not cut then
		if radius ~= nil and radius > 0 then
			store.batch:roundQuad(toNDC(left, store.windowWidth), -toNDC(top, store.windowHeight),
				toNDC(right, store.windowWidth), -toNDC(bottom, store.windowHeight), store.z, r, g, b, a,
				store.white, 0, 0, 1, 1, radius)
		else
			store.batch:quad(toNDC(left, store.windowWidth), -toNDC(top, store.windowHeight),
				toNDC(right, store.windowWidth), -toNDC(bottom, store.windowHeight), store.z, r, g, b, a,
				store.white)
		end

		return self
	end

	-- What the clip cuts through is drawn as the part of it that shows, which is what keeps a
	-- spectrum inside the pane it is scrolled in from drawing over the rest of the screen. A corner
	-- of a box the clip cut is still a corner of the box, so the whole box is what the corners are
	-- worked out from. See `QuadBatch:roundQuad`.
	local drawnLeft = math.max(left, clip.left)
	local drawnTop = math.max(top, clip.top)
	local drawnRight = math.min(right, clip.right)
	local drawnBottom = math.min(bottom, clip.bottom)

	if radius ~= nil and radius > 0 then
		store.batch:roundQuad(toNDC(drawnLeft, store.windowWidth), -toNDC(drawnTop, store.windowHeight),
			toNDC(drawnRight, store.windowWidth), -toNDC(drawnBottom, store.windowHeight), store.z, r, g, b, a,
			store.white, 0, 0, 1, 1, radius, toNDC(left, store.windowWidth),
			-toNDC(top, store.windowHeight), toNDC(right, store.windowWidth),
			-toNDC(bottom, store.windowHeight))
	else
		store.batch:quad(toNDC(drawnLeft, store.windowWidth), -toNDC(drawnTop, store.windowHeight),
			toNDC(drawnRight, store.windowWidth), -toNDC(drawnBottom, store.windowHeight), store.z, r, g, b, a,
			store.white)
	end

	return self
end

--- A line from one point to another, as thick as it is told: what a playhead, a gridline or a scope
--- trace is drawn with.
---
--- It is drawn as a rectangle turned to face the way it goes, because that is what a line of a
--- thickness is, and the clip cuts it as the shape it comes to. A line of no length is a point and
--- one of no thickness is nothing, so neither is drawn.
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param thickness number
---@param colour string|wonderland.Color
---@return wonderland.Canvas
function Canvas:line(x1, y1, x2, y2, thickness, colour)
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)

	if length <= 0 or thickness <= 0 then
		return self
	end

	local store = self.store
	local half = thickness / 2
	-- Either side of the line, which is its direction turned a quarter turn.
	local nx, ny = -dy / length * half, dx / length * half
	local r, g, b, a = colourOf(colour)
	local points = {
		x1 + nx, y1 + ny,
		x2 + nx, y2 + ny,
		x2 - nx, y2 - ny,
		x1 - nx, y1 - ny,
	}

	return fan(self, points, r, g, b, a)
end

--- A circle, as a shape of as many sides as it is told: sixteen, or as many as make a side shorter
--- than a pixel where that is fewer.
---@param x number # Its middle
---@param y number
---@param radius number
---@param colour string|wonderland.Color
---@param sides number?
---@return wonderland.Canvas
function Canvas:circle(x, y, radius, colour, sides)
	if radius <= 0 then
		return self
	end

	local r, g, b, a = colourOf(colour)
	local count = sides or math.max(8, math.min(64, math.ceil(radius)))

	return fan(self, circlePoints(x, y, radius, count), r, g, b, a)
end

--- A shape of as many corners as are given, filled: the corners are `x1, y1, x2, y2`, and on.
---
--- What is drawn is the fan of them, so a shape that is not convex -- one that curves back on
--- itself -- is drawn as the fan of the corners and not as the shape. A spectrum, a waveform, a bar
--- and a meter are either convex or are several of these.
---@param points number[] # The corners of it, a pair of numbers each
---@param colour string|wonderland.Color
---@return wonderland.Canvas
function Canvas:polygon(points, colour)
	local r, g, b, a = colourOf(colour)

	return fan(self, points, r, g, b, a)
end

return Canvas
