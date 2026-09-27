-- The frame's instances, written straight into memory that can be handed to the gpu, and the
-- runs of quads that share a picture.
--
-- This used to be a Lua array of numbers per frame with a copy into ffi memory at the
-- end, which for a screen of text meant a table of forty thousand entries built and
-- thrown away sixty times a second. One buffer is kept instead and written into.
--
-- A quad names the picture it samples, and the frame is drawn one bind group at a time:
-- the quads of one picture are a run, drawn in one call, and the run after it is another.
-- The runs are in the order the walk wrote the quads, so nothing about a screen is reordered
-- to draw it -- which is what keeps a picture drawn over another one over it.
--
-- What is written is one *instance* a quad: the gpu draws the same four corners over and over,
-- and each of them is told where that quad's four corners are, what it samples and how it is cut.
-- It is one block a quad rather than a vertex a corner of it, which is where most of the frame
-- went: nearly everything a quad says is said once for all four of its corners, and writing it
-- four times over was four times the memory and four times the writing.
--
-- The four corners the gpu draws are the unit square, in the order the instances name theirs:
--
--   (0,0) top left | (1,0) top right | (1,1) bottom right | (0,1) bottom left
--
-- and one of their two attributes carries what a corner of the quad's own coordinates comes to,
-- which is a pixel: where a box is cut is measured in pixels either way, so that a rounded corner
-- is round on a window that is not square.
--
-- An instance is the one the render plugin's descriptor declares, and the descriptor is built from
-- the same tables below, so the two cannot describe different things:
--
--   the four corners (8) | the middle of the box and the arcs inside it (4) | the picture, and
--   where across it this quad is (4) | the part of the picture the box is (4) | the cut (3)
--   | the colour (4) | the picture's id (1) | how deep it is (1) | whether it is its own colours (2)
--
-- The corners are in the coordinates the batch is handed; the middle of the box is where a corner
-- of the quad is measured from, in those same coordinates, and the arcs are how far inside the box
-- their own box starts, in pixels. The part of the picture the box is and how far it is spread are
-- what the fragment blurs with, and are nought for a quad that asked for no blur.
--
-- What is narrowed is narrowed once a quad rather than four times: a colour is four bytes rather
-- than sixteen, a cut and a blur are halves, and the part of a picture a box is costs two bytes an
-- end. What is left at full width is what needs the room -- where the corners are, where across a
-- picture this quad samples, and which point of it that is, which is a fraction of an atlas a
-- glyph is a cell of. A picture's id is at full width too: the two backends disagree about an
-- integer vertex attribute, so it is carried as the number it is.
local bit = require("bit")
local ffi = require("ffi")

ffi.cdef [[
	// One corner of the unit square the gpu draws every quad as: where it is in it, and how many
	// pixels one of the quad's own coordinates is worth, which is half the window it is drawn into.
	typedef struct {
		float x, y;
		float scaleX, scaleY;
	} wl_corner;

	// One quad, as the render plugin's descriptor describes it. It is written as these fields rather
	// than at hand counted offsets, and the descriptor is built from the same tables below, so the
	// two cannot describe different things.
	//
	// The fields are in the order that leaves no room for padding between them: what is a whole
	// float first, then what is two bytes, then what is one. What the shader reads them as is the
	// order of the tables below rather than the order here, so the two are free to differ.
	typedef struct {
		float c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y;  // its four corners, top left round
		float centreX, centreY;                        // the middle of the box a corner is measured from
		float innerX, innerY;                          // and where the arcs of a round one sit inside it
		float u, v, du, dv;                            // where its top left samples the picture, and across
		float texture;                                 // which picture it samples
		float z;                                       // and how deep it is
		uint16_t u0, v0, u1, v1;                       // the part of the picture the box is, of 65535
		uint16_t radius, band, blur;                   // the cut of it and the spread: pixels, as halves
		uint8_t r, g, b, a;                            // the colour, a byte a channel
		uint8_t own, pad;                              // whether the picture is drawn as it is, of 255
	} wl_instance;
]]

local batch = {}

local VERTICES_PER_QUAD = 4

-- What a run is, as the numbers it is: which picture it draws with, and the quad it starts at.
-- Two numbers a run, in one array, because a run is looked at once per draw call and a struct
-- would be a second type for the same two.
local RUN_TEXTURE, RUN_FIRST = 0, 1
local RUN_NUMBERS = 2

local cornerArray = ffi.typeof("wl_corner[?]")
local instanceArray = ffi.typeof("wl_instance[?]")
local runArray = ffi.typeof("uint32_t[?]")

--- How many bytes one instance is, which is what the gpu is told to read between two of them.
local INSTANCE_SIZE = ffi.sizeof("wl_instance")

--- The indices of one quad, which never change: the gpu is handed this once and draws every quad
--- in the frame with it, rather than six numbers a quad written out again every frame.
local QUAD_INDICES = ffi.new("uint16_t[6]", 0, 1, 2, 0, 2, 3)

--- What the render plugin's descriptors are built from: the fields above, in the order the shader
--- reads them, with the type the hardware is told to read each one as. A field that is not a whole
--- float is normalized, so that a whole number of bytes arrives in the shader as the fraction of
--- one it is -- a colour of 255 as 1.0, a colour of 0 as 0.0 -- which is what keeps the shaders the
--- same as they were before any of it was packed.
local CORNER_ATTRIBUTES = {
	{ type = "f32", size = 2, name = "x" },       -- where this corner of the unit square is
	{ type = "f32", size = 2, name = "scaleX" },  -- and how many pixels a coordinate of it is worth
}

local INSTANCE_ATTRIBUTES = {
	{ type = "f32", size = 4, name = "c0x" },     -- the quad's four corners, top left round
	{ type = "f32", size = 4, name = "c2x" },
	{ type = "f32", size = 4, name = "centreX" }, -- the middle of the box, and the arcs inside it
	{ type = "f32", size = 4, name = "u" },       -- the picture, and where across it this quad is
	{ type = "u16", size = 4, name = "u0", normalized = true },
	{ type = "f16", size = 3, name = "radius" },
	{ type = "u8", size = 4, name = "r", normalized = true },
	{ type = "f32", size = 1, name = "texture" },
	{ type = "f32", size = 1, name = "z" },
	{ type = "u8", size = 1, name = "own", normalized = true },
}

-- Where each of them is, as the descriptor wants it: worked out from the structs at load, so that
-- a field added to one is a field the other knows about.
for _, attribute in ipairs(CORNER_ATTRIBUTES) do
	attribute.offset = ffi.offsetof("wl_corner", attribute.name)
	attribute.name = nil
end

for _, attribute in ipairs(INSTANCE_ATTRIBUTES) do
	attribute.offset = ffi.offsetof("wl_instance", attribute.name)
	attribute.name = nil
end

--- What the ui writes, and what the render plugin's descriptors and draws are made from: one
--- instance a quad, the four corners every quad is drawn as, and the indices that draw them.
batch.INSTANCE_SIZE = INSTANCE_SIZE
batch.INSTANCE_ATTRIBUTES = INSTANCE_ATTRIBUTES
batch.CORNER_ATTRIBUTES = CORNER_ATTRIBUTES
batch.CORNERS = VERTICES_PER_QUAD
batch.QUAD_INDICES = QUAD_INDICES

--- One instance, as the language server sees it: it cannot see an ffi.cdef, so the fields are
--- spelled out here, which is the only way to get them checked.
---@class wonderland.ffi.wl_instance: ffi.cdata*
---@field c0x number
---@field c0y number
---@field c1x number
---@field c1y number
---@field c2x number
---@field c2y number
---@field c3x number
---@field c3y number
---@field centreX number
---@field centreY number
---@field innerX number
---@field innerY number
---@field u number
---@field v number
---@field du number
---@field dv number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field radius number
---@field band number
---@field blur number
---@field r number
---@field g number
---@field b number
---@field a number
---@field texture number
---@field z number
---@field own number

--- One corner of the unit square every quad is drawn as, as the language server sees it.
---@class wonderland.ffi.wl_corner: ffi.cdata*
---@field x number
---@field y number
---@field scaleX number
---@field scaleY number

--- The same four bytes read as a float and as the number they are: how a value is narrowed to the
--- bits of a half, which is what the cut and the blur of a quad are kept as.
---@class wonderland.ffi.sameBits: ffi.cdata*
---@field f number
---@field u number

--- Quads to make room for before a frame has asked for any.
local DEFAULT_CAPACITY = 1024

---@class wonderland.QuadBatch
---@field instances ffi.cdata* # `wl_instance*`, one a quad
---@field corners ffi.cdata* # `wl_corner*`, the four the gpu draws every quad as
---@field runs ffi.cdata* # uint32_t*, the texture and first quad of each run
---@field runCount number # How many runs this frame has
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

	local quads = setmetatable({
		instances = instanceArray(capacity),
		corners = cornerArray(VERTICES_PER_QUAD),
		runs = runArray(capacity * RUN_NUMBERS),
		runCount = 0,
		texture = nil,
		quads = 0,
		capacity = capacity,
		scaleX = 1,
		scaleY = 1,
	}, QuadBatch)

	return quads
end

--- How many pixels the coordinates a quad is written in are worth, which is half the window it is
--- drawn into. Rounding a corner is the only thing that needs it -- a radius is asked for in pixels
--- -- and both directions are needed rather than one: a radius is as long sideways as it is down,
--- and a quad that is a pixel taller than it is wide is a smaller part of the window one way than
--- the other.
---
--- What the gpu draws is the unit square either way, so this is written into the four corners of it
--- rather than carried per quad: the same two numbers for every quad of the frame, and a window
--- that changed size is four corners written again.
---@param width number
---@param height number
function QuadBatch:setViewport(width, height)
	self.scaleX, self.scaleY = width * 0.5, height * 0.5

	local corners = self.corners
	local scaleX, scaleY = self.scaleX, self.scaleY

	corners[0].x, corners[0].y = 0, 0
	corners[1].x, corners[1].y = 1, 0
	corners[2].x, corners[2].y = 1, 1
	corners[3].x, corners[3].y = 0, 1

	corners[0].scaleX, corners[0].scaleY = scaleX, scaleY
	corners[1].scaleX, corners[1].scaleY = scaleX, scaleY
	corners[2].scaleX, corners[2].scaleY = scaleX, scaleY
	corners[3].scaleX, corners[3].scaleY = scaleX, scaleY
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

	local instances = instanceArray(capacity)
	local runs = runArray(capacity * RUN_NUMBERS)

	-- What has been written so far is still part of this frame.
	ffi.copy(instances, self.instances, self.quads * INSTANCE_SIZE)
	ffi.copy(runs, self.runs, self.runCount * RUN_NUMBERS * ffi.sizeof("uint32_t"))

	self.instances = instances
	self.runs = runs
	self.capacity = capacity
end

function QuadBatch:reset()
	self.quads = 0
	self.runCount = 0
	self.texture = nil
end

--- Every quad from here on is drawn with another picture, so the run the last one was in ends
--- and another starts. A quad that samples what the one before it did joins that run, which is
--- what makes a line of text one draw call rather than one per glyph.
---@param texture number
function QuadBatch:startRun(texture)
	if self.runCount >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	local at = self.runCount * RUN_NUMBERS

	self.runs[at + RUN_TEXTURE] = texture
	self.runs[at + RUN_FIRST] = self.quads
	self.runCount = self.runCount + 1
	self.texture = texture
end

--- Throws away the quads past a point, and the runs that were only theirs: a frame is drawn
--- again with the caret taken out, and what is left of it is what the gpu is given.
---@param quads number
function QuadBatch:truncate(quads)
	if quads >= self.quads then
		return
	end

	self.quads = quads

	-- A run that starts at or past the end of the frame is gone, and the one before it is what
	-- the next quad written will join if it samples the same picture.
	while self.runCount > 0 do
		local at = (self.runCount - 1) * RUN_NUMBERS

		if self.runs[at + RUN_FIRST] < quads then
			self.texture = self.runs[at + RUN_TEXTURE]

			return
		end

		self.runCount = self.runCount - 1
	end

	self.texture = nil
end

-- A colour as the byte a vertex keeps it in, and what a byte comes to: a colour is a fraction of
-- one everywhere above this, and the hardware is told to read the byte back as that fraction, so
-- nothing that reads a vertex has to know it was ever narrowed. The clamp is what keeps a colour
-- that is not one -- nought to one is what a style hands over -- from wrapping round to the far end
-- of the byte it is in.
---@param value number
---@return number
local function toByte(value)
	return math.min(255, math.max(0, math.floor(value * 255 + 0.5)))
end

-- The bits of a value, for the fields a vertex keeps as a half: a radius, a band and a blur. All
-- three of them are pixels and none is negative, so what is left is to rebase the exponent and drop
-- the thirteen bits of mantissa a half has no room for, rounded to the nearest of what is left.
local sameBits = ffi.new("union { float f; uint32_t u; }")
---@cast sameBits wonderland.ffi.sameBits

---@param value number
---@return number
local function toHalf(value)
	if not (value > 0) then
		return 0
	end

	sameBits.f = value

	local bits = sameBits.u
	local exponent = bit.band(bit.rshift(bits, 23), 0xff)

	-- Too small for a half to hold at all is nought, and too large is as far as a half goes: neither
	-- is a radius, a band or a blur, but the arithmetic must not wrap round either way.
	if exponent < 113 then
		return 0
	end

	if exponent > 143 then
		return 0x7bff
	end

	-- The top bit of the thirteen that are dropped is half of what is dropped, so adding it in is
	-- rounding to the nearest of the two halves either side.
	return bit.lshift(exponent - 112, 10) + bit.rshift(bit.band(bits, 0x7fffff) + 0x1000, 13)
end

-- A fraction of a picture as the whole number of 65535ths a vertex keeps it in.
---@param value number
---@return number
local function toUnit(value)
	return math.min(65535, math.max(0, math.floor(value * 65535 + 0.5)))
end

--- One quad, written as the instance the gpu draws it with: its four corners, the box they are cut
--- against, where across a picture it samples, and what is left of the quad itself.
---
--- Everything a quad says that is not one of its corners is written once here rather than four
--- times over into four vertices, and what can be worked out from what is here is not written at
--- all: the fragment's own corner of the box is the one the vertex shader works out from the corner
--- of the quad it is drawing.
---@param instance wonderland.ffi.wl_instance
---@param c0x number # The corners, top left round the way the unit square goes
---@param c0y number
---@param c1x number
---@param c1y number
---@param c2x number
---@param c2y number
---@param c3x number
---@param c3y number
---@param centreX number # The middle of the box a corner of it is measured from
---@param centreY number
---@param innerX number # Where the arcs of a round corner sit inside it, in pixels
---@param innerY number
---@param u number # Where its top left samples the picture, and how far one corner of it moves that
---@param v number
---@param du number
---@param dv number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
---@param own number? # Whether the picture is drawn as it is rather than through the colour
local function put(instance, c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y, centreX, centreY, innerX, innerY,
	u, v, du, dv, z, r, g, b, a, texture, own)
	instance.c0x, instance.c0y, instance.c1x, instance.c1y = c0x, c0y, c1x, c1y
	instance.c2x, instance.c2y, instance.c3x, instance.c3y = c2x, c2y, c3x, c3y
	instance.centreX, instance.centreY = centreX, centreY
	instance.innerX, instance.innerY = innerX, innerY
	instance.u, instance.v, instance.du, instance.dv = u, v, du, dv
	instance.z = z

	-- Narrowed here rather than four times over, and clamped: a colour that is not a fraction of one
	-- -- nought to one is what a style hands over -- would otherwise wrap round to the far end of
	-- the byte it is in.
	instance.r, instance.g, instance.b, instance.a = toByte(r), toByte(g), toByte(b), toByte(a)

	instance.texture = texture

	-- Whether this one's picture is drawn as it is or through the colour, which every quad but a
	-- glyph says no to.
	instance.own = own or 0

	-- A quad that is not round and not spread says so in a cut of nought and a blur of nought, and
	-- reads nothing of the rest: which is what every quad in a screen that asked for neither writes.
	instance.radius, instance.band, instance.blur = 0, 0, 0
	instance.u0, instance.v0, instance.u1, instance.v1 = 0, 0, 0, 0
end

--- What a blurred quad is read with: the part of the picture the box is, which a tap that falls
--- past reads as nothing at all -- the picture beside a glyph in a sheet is another glyph -- and how
--- far what it draws is spread, in pixels.
---@param instance wonderland.ffi.wl_instance
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
---@param blur number
local function putBlur(instance, u0, v0, u1, v1, blur)
	instance.u0, instance.v0 = toUnit(u0), toUnit(v0)
	instance.u1, instance.v1 = toUnit(u1), toUnit(v1)
	instance.blur = toHalf(blur)
end

--- The cut of a quad: how round its corners are and how sharp the edge of that is, both as the
--- halves an instance keeps them in, and how far inside the box the arcs of it sit, in pixels.
---@param instance wonderland.ffi.wl_instance
---@param innerX number
---@param innerY number
---@param radius number
---@param band number
local function putCut(instance, innerX, innerY, radius, band)
	instance.innerX, instance.innerY = innerX, innerY
	instance.radius, instance.band = toHalf(radius), toHalf(band)
end

--- One more quad in the batch.
---@param self wonderland.QuadBatch
local function finish(self)
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
---@param texture number # Which picture it samples, which is what the run it is in is drawn with
---@param u0 number?
---@param v0 number?
---@param u1 number?
---@param v1 number?
---@param own number? # Whether the picture is drawn as it is rather than through the colour
function QuadBatch:quad(left, top, right, bottom, z, r, g, b, a, texture, u0, v0, u1, v1, own)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if texture ~= self.texture then
		self:startRun(texture)
	end

	local instances = self.instances
	local at = self.quads

	u0, v0, u1, v1 = u0 or 0, v0 or 0, u1 or 1, v1 or 1

	put(instances[at], left, top, right, top, right, bottom, left, bottom, left, top, 0, 0,
		u0, v0, u1 - u0, v1 - v0, z, r, g, b, a, texture, own)

	finish(self)
end

--- Adds one quad of four arbitrary corners, which is what a shape that is not a box is drawn with:
--- a line, a slice of a circle, a bar of a spectrum that is not square to the screen.
---
--- What it samples is one point of the picture it is given -- a shape of a canvas is given the white
--- one -- so what is drawn is the colour it was given rather than a picture: a caller with a picture
--- of its own wants `quad`.
---@param x1 number # The corners, in the order they go round
---@param y1 number
---@param x2 number
---@param y2 number
---@param x3 number
---@param y3 number
---@param x4 number
---@param y4 number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number # Which picture it samples, which a shape of the caller's own has none of
function QuadBatch:points(x1, y1, x2, y2, x3, y3, x4, y4, z, r, g, b, a, texture)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if texture ~= self.texture then
		self:startRun(texture)
	end

	-- A shape of a canvas is drawn in one colour and samples one point of a picture, so where its
	-- corners are is all it has to say: there is no box it is cut against and nothing to map across
	-- it, which is what a cut of nought and a picture that does not move say.
	put(self.instances[self.quads], x1, y1, x2, y2, x3, y3, x4, y4, x1, y1, 0, 0, 0, 0, 0, 0, z,
		r, g, b, a, texture, 0)

	finish(self)
end

--- Adds one triangle, which is a quad whose last two corners are the same: the second of the two
--- triangles it is drawn as has no area, and a triangle with no area is one nothing is rasterised
--- for. It costs the four vertices this writes and no more, and it is what a fan of a shape that is
--- not a box is made of -- see `wonderland.Canvas`.
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param x3 number
---@param y3 number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
function QuadBatch:triangle(x1, y1, x2, y2, x3, y3, z, r, g, b, a, texture)
	self:points(x1, y1, x2, y2, x3, y3, x3, y3, z, r, g, b, a, texture)
end

--- Adds one quad with round corners, which is the same quad as `quad` asks for and a radius to
--- cut it with.
---
--- It is a call of its own rather than an argument of `quad` because of how rare it is: a round
--- box is a box with a background, and the quads it is drawn among are glyphs, which are never
--- round. Two shapes at one call site is a trace that is left and entered again for every one of
--- them -- the pointer path compiles, then the next glyph throws it away -- and a site that
--- does that often enough is one the recorder stops compiling at all.
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
---@param own number? # Whether the picture is drawn as it is rather than through the colour
---@param blur number? # How far what it draws is spread, in pixels, nothing for not at all
function QuadBatch:roundQuad(left, top, right, bottom, z, r, g, b, a, texture, u0, v0, u1, v1, radius, boxLeft,
	boxTop, boxRight, boxBottom, band, own, blur)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if texture ~= self.texture then
		self:startRun(texture)
	end

	local instances = self.instances
	local at = self.quads

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

	-- A blurred quad is drawn past the box it is in, because that is the room the spread needs, and
	-- its picture is mapped across the box rather than across the quad: the picture stays where it
	-- is and the room around it is the part of it that is not there, which is what the taps that
	-- land in it read as nothing. Every other quad maps it across the quad, which is the same thing
	-- for a quad that was not grown.
	local leftU, topV, rightU, bottomV = u0, v0, u1, v1

	if blur and blur > 0 then
		local spanX, spanY = boxRight - boxLeft, boxBottom - boxTop
		local du = spanX ~= 0 and (u1 - u0) / spanX or 0
		local dv = spanY ~= 0 and (v1 - v0) / spanY or 0

		leftU, rightU = u0 + du * (left - boxLeft), u0 + du * (right - boxLeft)
		topV, bottomV = v0 + dv * (top - boxTop), v0 + dv * (bottom - boxTop)
	end

	local instance = instances[at]

	put(instance, left, top, right, top, right, bottom, left, bottom, centreX, centreY,
		innerX, innerY, leftU, topV, rightU - leftU, bottomV - topV, z, r, g, b, a, texture, own)

	if blur and blur > 0 then
		putBlur(instance, u0, v0, u1, v1, blur)
	end

	putCut(instance, innerX, innerY, radius, band)

	finish(self)
end

---@return number # Bytes written, which is what the gpu is told to read
function QuadBatch:instanceBytes()
	return self.quads * INSTANCE_SIZE
end

batch.RUN_NUMBERS = RUN_NUMBERS
batch.RUN_TEXTURE, batch.RUN_FIRST = RUN_TEXTURE, RUN_FIRST

return batch
