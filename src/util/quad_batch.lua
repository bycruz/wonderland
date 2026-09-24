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
--   position (3) | colour (4) | uv (2) | texture (1)
local ffi = require("ffi")

local batch = {}

local VERTICES_PER_QUAD = 4
local INDICES_PER_QUAD = 6
local FLOATS_PER_VERTEX = 10

local quadArray = ffi.typeof("float[?]")
local indexArray = ffi.typeof("uint32_t[?]")

--- Quads to make room for before a frame has asked for any.
local DEFAULT_CAPACITY = 1024

---@class wonderland.QuadBatch
---@field vertices ffi.cdata* # float*, four vertices per quad
---@field indices ffi.cdata* # uint32_t*, six indices per quad
---@field quads number # How many are in it
---@field capacity number # How many fit before it grows
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
	}, QuadBatch)
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
