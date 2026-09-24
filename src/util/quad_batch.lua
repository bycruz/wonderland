-- The frame's vertices and indices, written straight into memory that can be handed to
-- the gpu.
--
-- This used to be a Lua array of numbers per frame with a copy into ffi memory at the
-- end, which for a screen of text meant a table of forty thousand entries built and
-- thrown away sixty times a second. One buffer is kept instead and written into.
--
-- The vertex is the one the render plugin's descriptor declares, and it asserts the two
-- agree so the pair cannot drift apart:
--
--   position (3) | colour (4) | uv (2) | texture (1) | corners (4) | edge (2)
--
-- The corners are the four numbers a box is cut with: where this corner of the quad is from the
-- middle of the box, and where the arc's own box starts, both in pixels measured across the
-- window -- so a radius means the same thing sideways as down. The two after them are how round
-- that cut is and how sharp it is: a radius, and a band that says over how many pixels the edge
-- changes. A band of one is the whole of a pixel either side of the edge, which is what a box
-- with round corners wants; a wider one is a shadow, whose edge is spread out over its blur.
-- A quad that is not cut at all says so in a band of nought, which is the number written for
-- every quad that is not asked to be round.
local ffi = require("ffi")

local batch = {}

local VERTICES_PER_QUAD = 4
local INDICES_PER_QUAD = 6
local FLOATS_PER_VERTEX = 16

--- Where a vertex holds what, as floats from the start of it: the corner numbers, then the
--- radius and the band beside it.
local ROUND = 10
local EDGE = 14

local quadArray = ffi.typeof("float[?]")
local indexArray = ffi.typeof("uint32_t[?]")

--- Quads to make room for before a frame has asked for any.
local DEFAULT_CAPACITY = 1024

---@class wonderland.QuadBatch
---@field vertices ffi.cdata* # float*, four vertices per quad
---@field indices ffi.cdata* # uint32_t*, six indices per quad
---@field quads number # How many are in it
---@field capacity number # How many fit before it grows
---@field scaleX number # How many pixels one of a quad's x coordinates is worth
---@field scaleY number # and one of its y coordinates, which is what keeps a corner round
local QuadBatch = {}
QuadBatch.__index = QuadBatch

---@param capacity number?
---@return wonderland.QuadBatch
function batch.new(capacity)
	capacity = capacity or DEFAULT_CAPACITY

	return setmetatable({
		vertices = quadArray(capacity * VERTICES_PER_QUAD * FLOATS_PER_VERTEX),
		indices = indexArray(capacity * INDICES_PER_QUAD),
		quads = 0,
		capacity = capacity,
		scaleX = 1,
		scaleY = 1,
	}, QuadBatch)
end

--- How many pixels the coordinates a quad is written in are worth, which is half the window it is
--- drawn into. Rounding a corner is the only thing that needs it -- a radius is asked for in pixels
--- -- and both directions are needed rather than one: a radius is as long sideways as it is down,
--- and a quad that is a pixel taller than it is wide is a smaller part of the window one way than
--- the other.
---@param width number
---@param height number
function QuadBatch:setViewport(width, height)
	self.scaleX, self.scaleY = width * 0.5, height * 0.5
end

---@param quads number
function QuadBatch:reserve(quads)
	if quads <= self.capacity then
		return
	end

	local capacity = self.capacity
	while capacity < quads do
		capacity = capacity * 2
	end

	local vertices = quadArray(capacity * VERTICES_PER_QUAD * FLOATS_PER_VERTEX)
	local indices = indexArray(capacity * INDICES_PER_QUAD)

	-- What has been written so far is still part of this frame.
	ffi.copy(vertices, self.vertices, self.quads * VERTICES_PER_QUAD * FLOATS_PER_VERTEX * ffi.sizeof("float"))
	ffi.copy(indices, self.indices, self.quads * INDICES_PER_QUAD * ffi.sizeof("uint32_t"))

	self.vertices = vertices
	self.indices = indices
	self.capacity = capacity
end

function QuadBatch:reset()
	self.quads = 0
end

--- A vertex of one quad: the corner, then what every corner of the quad shares.
---@param vertices ffi.cdata*
---@param index number # Where to write, in floats
---@param x number
---@param y number
---@param u number
---@param v number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
local function put(vertices, index, x, y, u, v, z, r, g, b, a, texture)
	vertices[index] = x
	vertices[index + 1] = y
	vertices[index + 2] = z
	vertices[index + 3] = r
	vertices[index + 4] = g
	vertices[index + 5] = b
	vertices[index + 6] = a
	vertices[index + 7] = u
	vertices[index + 8] = v
	vertices[index + 9] = texture

	-- Written every time, and to nothing: the corners of the quad written into this slot
	-- before it are still there, and the gpu would cut this one with them.
	vertices[index + EDGE] = 0
	vertices[index + EDGE + 1] = 0
end

--- A vertex of a quad whose corners are round: where it is from the middle of the box, where the
--- arc's own box starts, and how big the radius is -- all three across the window, in pixels.
---@param vertices ffi.cdata*
---@param index number
---@param x number
---@param y number
---@param u number
---@param v number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
---@param cornerX number
---@param cornerY number
---@param innerX number
---@param innerY number
---@param radius number
---@param band number
local function putRound(vertices, index, x, y, u, v, z, r, g, b, a, texture, cornerX, cornerY, innerX, innerY,
	radius, band)
	put(vertices, index, x, y, u, v, z, r, g, b, a, texture)

	vertices[index + ROUND] = cornerX
	vertices[index + ROUND + 1] = cornerY
	vertices[index + ROUND + 2] = innerX
	vertices[index + ROUND + 3] = innerY
	vertices[index + EDGE] = radius
	vertices[index + EDGE + 1] = band
end

--- The quad the vertices just written make: its six indices, and one more in the batch.
---@param self wonderland.QuadBatch
local function finish(self)
	local indices = self.indices
	local first = self.quads * VERTICES_PER_QUAD
	local at = self.quads * INDICES_PER_QUAD

	indices[at] = first
	indices[at + 1] = first + 1
	indices[at + 2] = first + 2
	indices[at + 3] = first
	indices[at + 4] = first + 2
	indices[at + 5] = first + 3

	self.quads = self.quads + 1
end

--- Adds one quad, growing to fit if this frame is the largest so far.
---@param left number # Normalized, so the gpu can use them as they are
---@param top number
---@param right number
---@param bottom number
---@param z number
---@param r number # The colour, as numbers rather than a table: this is the per frame path
---@param g number
---@param b number
---@param a number
---@param texture number # Which layer of the texture array it samples
---@param u0 number?
---@param v0 number?
---@param u1 number?
---@param v1 number?
function QuadBatch:quad(left, top, right, bottom, z, r, g, b, a, texture, u0, v0, u1, v1)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	local vertices = self.vertices
	local index = self.quads * VERTICES_PER_QUAD * FLOATS_PER_VERTEX

	u0, v0, u1, v1 = u0 or 0, v0 or 0, u1 or 1, v1 or 1

	put(vertices, index, left, top, u0, v0, z, r, g, b, a, texture)
	put(vertices, index + FLOATS_PER_VERTEX, right, top, u1, v0, z, r, g, b, a, texture)
	put(vertices, index + FLOATS_PER_VERTEX * 2, right, bottom, u1, v1, z, r, g, b, a, texture)
	put(vertices, index + FLOATS_PER_VERTEX * 3, left, bottom, u0, v1, z, r, g, b, a, texture)

	finish(self)
end

--- Adds one quad with round corners, which is the same quad as `quad` asks for and a radius to
--- cut it with.
---
--- It is a call of its own rather than an argument of `quad` because of how rare it is: a round
--- box is a box with a background, and the quads it is drawn among are glyphs, which are never
--- round. Two shapes at one call site is a trace that is left and entered again for every one of
--- them -- the pointer path compiles, then the next glyph throws it away -- and a site that does
--- that often enough is one the recorder stops compiling at all.
---
--- Everything about the corners is in pixels: the radius, and the box they are round in, which is
--- passed only when a clip cut the quad down to less than the box it was asked for -- the corners
--- of a box cut by the pane it is in are still the corners of the whole box.
---@param left number # Normalized, as `quad` takes them
---@param top number
---@param right number
---@param bottom number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
---@param u0 number?
---@param v0 number?
---@param u1 number?
---@param v1 number?
---@param radius number # How round the corners are: bigger than the box gets the roundest it can be
---@param boxLeft number? # The box the corners belong to, in the coordinates the quad is in
---@param boxTop number?
---@param boxRight number?
---@param boxBottom number?
---@param band number? # How sharp the edge is, over one pixel either side by default
function QuadBatch:roundQuad(left, top, right, bottom, z, r, g, b, a, texture, u0, v0, u1, v1, radius, boxLeft,
	boxTop, boxRight, boxBottom, band)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	local vertices = self.vertices
	local index = self.quads * VERTICES_PER_QUAD * FLOATS_PER_VERTEX

	u0, v0, u1, v1 = u0 or 0, v0 or 0, u1 or 1, v1 or 1

	-- One pixel either side of the edge unless the caller says otherwise, which is what a box
	-- with round corners wants and what a shadow does not.
	band = band or 1

	-- Where the corners are cut from: the middle of the box, how far the arcs sit inside it, and
	-- the radius itself. All of it in pixels either way, so that an arc is a circle.
	local scaleX, scaleY = self.scaleX, self.scaleY

	boxLeft, boxTop = boxLeft or left, boxTop or top
	boxRight, boxBottom = boxRight or right, boxBottom or bottom

	local halfX = math.abs(boxRight - boxLeft) * scaleX * 0.5
	local halfY = math.abs(boxBottom - boxTop) * scaleY * 0.5

	-- A radius bigger than the box it is asked for is the roundest the box can be: the arcs meet
	-- in the middle of it, and what is left is a box round all the way down its short side.
	if radius > halfX then
		radius = halfX
	end

	if radius > halfY then
		radius = halfY
	end

	local innerX, innerY = halfX - radius, halfY - radius
	local centreX, centreY = (boxLeft + boxRight) * 0.5, (boxTop + boxBottom) * 0.5

	putRound(vertices, index, left, top, u0, v0, z, r, g, b, a, texture,
		(left - centreX) * scaleX, (top - centreY) * scaleY, innerX, innerY, radius, band)
	putRound(vertices, index + FLOATS_PER_VERTEX, right, top, u1, v0, z, r, g, b, a, texture,
		(right - centreX) * scaleX, (top - centreY) * scaleY, innerX, innerY, radius, band)
	putRound(vertices, index + FLOATS_PER_VERTEX * 2, right, bottom, u1, v1, z, r, g, b, a, texture,
		(right - centreX) * scaleX, (bottom - centreY) * scaleY, innerX, innerY, radius, band)
	putRound(vertices, index + FLOATS_PER_VERTEX * 3, left, bottom, u0, v1, z, r, g, b, a, texture,
		(left - centreX) * scaleX, (bottom - centreY) * scaleY, innerX, innerY, radius, band)

	finish(self)
end

---@return number # Floats written, which is what the gpu is told to read
function QuadBatch:vertexFloats()
	return self.quads * VERTICES_PER_QUAD * FLOATS_PER_VERTEX
end

---@return number
function QuadBatch:indexCount()
	return self.quads * INDICES_PER_QUAD
end

batch.VERTICES_PER_QUAD = VERTICES_PER_QUAD
batch.INDICES_PER_QUAD = INDICES_PER_QUAD
batch.FLOATS_PER_VERTEX = FLOATS_PER_VERTEX

return batch
