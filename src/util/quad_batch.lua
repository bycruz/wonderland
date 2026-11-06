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
--   the four corners (8) | the middle of the box and the arcs inside it (4) | the picture's id (1)
--   | how deep it is (1) | the part of the picture the box is (4) | the cut (3) | the colour (4)
--   | whether it is its own colours (2)
--
-- The corners are in the coordinates the batch is handed; the middle of the box is where a corner
-- of the quad is measured from, in those same coordinates, and the arcs are how far inside the box
-- their own box starts, in pixels. The part of the picture the box is is what the shader maps across
-- the box, and what the fragment blurs with, so it is written for every quad rather than left for
-- the blurred ones to write.
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
	// What the shader can work out from the rest is not carried: where a quad samples the picture is
	// the part of the picture the box is, mapped across the box, which is the box the cut is
	// measured against and the part of the picture it is drawn from -- so it is the two corners and
	// the two of the box that are written, and the fragment works the rest out.
	//
	// The fields are in the order that leaves no room for padding between them: what is a whole
	// float first, then what is four bytes, then what is two, then what is one. What the shader
	// reads them as is the order of the tables below rather than the order here, so the two are free
	// to differ.
	typedef struct {
		float c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y;  // its four corners, top left round
		float centreX, centreY;                        // the middle of the box a corner is measured from
		float innerX, innerY;                          // and where the arcs of a round one sit inside it
		float texture;                                 // which picture it samples
		float z;                                       // and how deep it is
		uint32_t rgba;                                 // the colour: a byte a channel, one number
		uint16_t u0, v0, u1, v1;                       // the part of the picture the box is, of 65535
		uint16_t radius, band, blur;                   // the cut of it and the spread: pixels, as halves
		uint8_t own, border;                           // whether the picture is drawn as it is, and how thick a ring is, of 255
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
---@type wonderland.QuadBatch.Attribute[]
local CORNER_ATTRIBUTES = {
	{ type = "f32", size = 2, offset = 0, name = "x" },       -- where this corner of the unit square is
	{ type = "f32", size = 2, offset = 0, name = "scaleX" },  -- and how many pixels a coordinate of it is worth
}

---@class wonderland.QuadBatch.Attribute
---@field type string
---@field size number
---@field name string?
---@field normalized boolean?
---@field offset number

---@type wonderland.QuadBatch.Attribute[]
local INSTANCE_ATTRIBUTES = {
	{ type = "f32", size = 4, offset = 0, name = "c0x" },     -- the quad's four corners, top left round
	{ type = "f32", size = 4, offset = 0, name = "c2x" },
	{ type = "f32", size = 4, offset = 0, name = "centreX" }, -- the middle of the box, and the arcs inside it
	{ type = "u16", size = 4, offset = 0, name = "u0", normalized = true },
	{ type = "f16", size = 3, offset = 0, name = "radius" },
	{ type = "u8", size = 4, offset = 0, name = "rgba", normalized = true },
	{ type = "f32", size = 1, offset = 0, name = "texture" },
	{ type = "f32", size = 1, offset = 0, name = "z" },
	{ type = "u8", size = 1, offset = 0, name = "own", normalized = true },
	{ type = "u8", size = 1, offset = 0, name = "border", normalized = true },
}

-- Where each of them is, as the descriptor wants it: worked out from the structs at load, so that
-- a field added to one is a field the other knows about.
for _, attribute in ipairs(CORNER_ATTRIBUTES) do
	attribute.offset = ffi.offsetof("wl_corner", assert(attribute.name))
	attribute.name = nil
end

for _, attribute in ipairs(INSTANCE_ATTRIBUTES) do
	attribute.offset = ffi.offsetof("wl_instance", assert(attribute.name))
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
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field radius number
---@field band number
---@field blur number
---@field rgba number # The colour, a byte a channel, which is what the gpu reads as four
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
---@field texture number? # The texture a run is drawn from
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
local function toByte(value)
	return math.min(255, math.max(0, math.floor(value * 255 + 0.5)))
end

-- The bits of a value, for the fields a vertex keeps as a half: a radius, a band and a blur. All
-- three of them are pixels and none is negative, so what is left is to rebase the exponent and drop
-- the thirteen bits of mantissa a half has no room for, rounded to the nearest of what is left.
local sameBits = ffi.new("union { float f; uint32_t u; }")
---@cast sameBits wonderland.ffi.sameBits

---@param value number
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
local function toUnit(value)
	return math.min(65535, math.max(0, math.floor(value * 65535 + 0.5)))
end

-- The whole of a picture, as the pair of numbers a box that samples all of it is given: what a quad
-- with no part of its own to name is written with, and what a shape of a canvas samples.
local UV_WHOLE = 65535 + 65535 * 65536

--- The part of a picture a box is, as the one number a pair of them is: a 65535th across and a
--- 65535th down in one number, which is what an instance keeps it in.
---
---   batch:quad(x, y, w, h, 1, colour, texture, batch.uv(0.5, 0), batch.uv(1, 0.5))
---
--- The narrowing happens here so that it happens once: whoever has the picture's own numbers -- a
--- glyph's, which are fractions of an atlas -- packs them here rather than handing four of them over
--- to be narrowed one at a time.
---@param across number
---@param down number
---@return number
function batch.uv(across, down)
	return bit.tobit(toUnit(across) + toUnit(down) * 65536)
end

--- A colour as the one number an instance keeps it in: a byte a channel, the red lowest, which is
--- the order the struct holds them in.
---
--- Colours are fractions of one everywhere above this -- a style, a shape of a canvas -- and this is
--- where they become the bytes the shader reads as those fractions again. A caller that has the
--- bytes already, as an element of a screen does, packs them itself: a byte per channel and three
--- shifts is what a colour costs there, where four fractions were four multiplies and four floors.
---@param r number
---@param g number
---@param b number
---@param a number
---@return number
function batch.colour(r, g, b, a)
	return bit.tobit(toByte(r) + toByte(g) * 256 + toByte(b) * 65536 + toByte(a) * 16777216)
end

--- A colour that is already the four bytes of one, as the one number an instance keeps it in: what
--- a screen writes, because what a node of it holds a colour as is the bytes the gpu is given --
--- `node.bgR` and the three beside it -- and a caller with those has nothing to narrow.
---@param r number
---@param g number
---@param b number
---@param a number
---@return number
function batch.rgba(r, g, b, a)
	return bit.tobit(r + g * 256 + b * 65536 + a * 16777216)
end

--- What a quad samples and what is left of it: the part of the picture the box is, how deep it is
--- drawn, its colour, which picture that is, and whether it is drawn as it is.
---
--- Eleven values is a call the recorder cannot keep in registers: what it does with them is more
--- than it can coalesce, and the trace it is in is thrown away -- see `putBox`, which is the other
--- half of what this used to be written as, and `quad`, which is where the two are called.
---@param instance wonderland.ffi.wl_instance
---@param uv0 number
---@param uv1 number
---@param z number
---@param colour number
---@param texture number
---@param own number?
local function putPicture(instance, uv0, uv1, z, colour, texture, own)
	-- The part of the picture the box is, as the two corners it is: a 65535th across and a 65535th
	-- down in each, which is the pair of numbers the instance keeps. What is written here is what was
	-- narrowed once, by whoever had the picture's own numbers to hand -- see `batch.uv`.
	instance.u0, instance.v0 = bit.band(uv0, 0xffff), bit.rshift(uv0, 16)
	instance.u1, instance.v1 = bit.band(uv1, 0xffff), bit.rshift(uv1, 16)
	instance.z = z

	-- The colour is the four bytes it is, in one number: a byte a channel, which is what the shader
	-- reads as the fractions of one they are. Written here rather than narrowed four times over with
	-- a clamp each, which is what a colour handed over as four fractions cost -- see `batch.colour`.
	instance.rgba = colour

	-- Which picture it samples, as the id it is: narrowed no further than it is, because the two
	-- backends do not agree on an integer vertex attribute -- one scales a narrowed one back into a
	-- fraction and the other reads a number -- and a picture is a number the shader looks a band up
	-- by either way.
	instance.texture = texture

	-- How this one's picture is drawn: nought a shape the colour goes through, one a picture of its own
	-- colours, two the coverage of a glyph, which the shader corrects for gamma. The vertex shader
	-- reads the byte as the number it is.
	instance.own = own or 0
end

--- The box a quad covers, written as the four corners the gpu reads: it is handed the box rather
--- than the corners because every quad but a shape of a canvas is one -- a box cut down by the pane
--- it is in is a box, and one drawn past the box it is in by a blur is a box.
---
--- A box and not the corners is also four numbers fewer at every call: what a call hands over is
--- what the recorder has to keep alive across it, and a call that hands over eleven of them is one
--- it cannot coalesce -- see `putPicture` and `putCorners`.
---@param instance wonderland.ffi.wl_instance
---@param left number # In the coordinates the batch is handed, which are the gpu's own
---@param top number
---@param right number
---@param bottom number
local function putBox(instance, left, top, right, bottom)
	instance.c0x, instance.c0y, instance.c1x, instance.c1y = left, top, right, top
	instance.c2x, instance.c2y, instance.c3x, instance.c3y = right, bottom, left, bottom
end

--- One quad of four corners that are not a box, which is what a shape of a canvas is: a line, a
--- slice of a circle, a bar of a spectrum that is not square to the screen. What it samples is one
--- point of the picture it is given, which is the white one, so the whole of it is that point.
---@param instance wonderland.ffi.wl_instance
---@param x1 number # The corners, in the order they go round
---@param y1 number
---@param x2 number
---@param y2 number
---@param x3 number
---@param y3 number
---@param x4 number
---@param y4 number
local function putCorners(instance, x1, y1, x2, y2, x3, y3, x4, y4)
	instance.c0x, instance.c0y, instance.c1x, instance.c1y = x1, y1, x2, y2
	instance.c2x, instance.c2y, instance.c3x, instance.c3y = x3, y3, x4, y4
end

--- How far what a quad draws is spread, in pixels, as the half an instance keeps it in: nought for
--- every quad that asked for none, which is nearly all of them.
---@param instance wonderland.ffi.wl_instance
---@param blur number
local function putBlur(instance, blur)
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
---@param colour number # The colour as its four bytes: see `batch.colour`
---@param texture number # Which picture it samples, which is what the run it is in is drawn with
---@param uv0 number? # The part of the picture the box is, as its corners: see `batch.uv`
---@param uv1 number?
---@param own number? # Whether the picture is drawn as it is rather than through the colour
function QuadBatch:quad(left, top, right, bottom, z, colour, texture, uv0, uv1, own)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if texture ~= self.texture then
		self:startRun(texture)
	end

	local instances = self.instances
	local at = self.quads

	-- The box a quad of two corners is cut against is the quad itself, which is what the shader maps
	-- the picture across and measures a corner of it from.
	local halfX = math.abs(right - left) * self.scaleX * 0.5
	local halfY = math.abs(bottom - top) * self.scaleY * 0.5
	local instance = instances[at]

	putBox(instance, left, top, right, bottom)
	putPicture(instance, uv0 or 0, uv1 or UV_WHOLE, z, colour, texture, own)

	instance.centreX, instance.centreY = (left + right) * 0.5, (top + bottom) * 0.5

	-- A quad that is not round and not spread says so in a cut of nought and a blur of nought, which
	-- is what nearly every quad in a screen writes: it is written here as the halves they are rather
	-- than narrowed by anything, because nought is nought in both.
	instance.innerX, instance.innerY = halfX, halfY
	instance.radius, instance.band, instance.blur = 0, 0, 0
	instance.border = 0

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
---@param colour number # The colour as its four bytes: see `batch.colour`
---@param texture number # Which picture it samples, which a shape of the caller's own has none of
function QuadBatch:points(x1, y1, x2, y2, x3, y3, x4, y4, z, colour, texture)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if texture ~= self.texture then
		self:startRun(texture)
	end

	-- A shape of a canvas is four points and no box: what it is cut against is the box its corners
	-- come to, which nothing reads -- a shape names no cut and no blur, and what it samples is one
	-- point of a picture whatever it is drawn across.
	local left, right = math.min(x1, x2, x3, x4), math.max(x1, x2, x3, x4)
	local top, bottom = math.min(y1, y2, y3, y4), math.max(y1, y2, y3, y4)
	local instance = self.instances[self.quads]

	putCorners(instance, x1, y1, x2, y2, x3, y3, x4, y4)
	putPicture(instance, 0, UV_WHOLE, z, colour, texture, 0)

	instance.centreX, instance.centreY = (left + right) * 0.5, (top + bottom) * 0.5
	instance.innerX, instance.innerY = math.abs(right - left) * self.scaleX * 0.5,
		math.abs(bottom - top) * self.scaleY * 0.5
	instance.radius, instance.band, instance.blur = 0, 0, 0
	instance.border = 0

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
---@param colour number # The colour as its four bytes: see `batch.colour`
---@param texture number
function QuadBatch:triangle(x1, y1, x2, y2, x3, y3, z, colour, texture)
	self:points(x1, y1, x2, y2, x3, y3, x3, y3, z, colour, texture)
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
---
--- The box comes after everything a quad usually says, so that a quad which is its own box -- which
--- is every box that a pane did not cut -- is a call that stops at the radius. What a call is
--- written as is what the recorder has to keep alive across it, and a call that hands over four
--- numbers nothing is going to read is four numbers too many: see `put`.
---@param left number # Normalized, as `quad` takes them
---@param top number
---@param right number
---@param bottom number
---@param z number
---@param colour number # The colour as its four bytes: see `batch.colour`
---@param texture number
---@param uv0 number? # The part of the picture the box is, as its corners: see `batch.uv`
---@param uv1 number?
---@param radius number # How round the corners are: bigger than the box gets the roundest it can be
---@param band number? # How sharp the edge is, over one pixel either side by default
---@param own number? # Whether the picture is drawn as it is rather than through the colour
---@param blur number? # How far what it draws is spread, in pixels, nothing for not at all
---@param boxLeft number? # The box the corners belong to, in the coordinates the quad is in
---@param boxTop number?
---@param boxRight number?
---@param boxBottom number?
---@param border number? # A ring of this many pixels drawn inside the cut, instead of a fill
function QuadBatch:roundQuad(left, top, right, bottom, z, colour, texture, uv0, uv1, radius, band, own, blur,
	boxLeft, boxTop, boxRight, boxBottom, border)
	if self.quads >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if texture ~= self.texture then
		self:startRun(texture)
	end

	local instances = self.instances
	local at = self.quads

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

	-- Where the quad samples the picture is worked out from the box and the part of the picture the
	-- box is, so what is written is that part and no mapping of it: a quad drawn past the box it is
	-- in -- what a blur is -- reads past the part of the picture that is there, which is what fades
	-- its edge out.
	local instance = instances[at]

	putBox(instance, left, top, right, bottom)
	putPicture(instance, uv0 or 0, uv1 or UV_WHOLE, z, colour, texture, own)
	putCut(instance, innerX, innerY, radius, band)
	putBlur(instance, blur or 0)
	instance.border = math.max(0, math.min(255, math.floor((border or 0) + 0.5)))

	instance.centreX, instance.centreY = centreX, centreY

	finish(self)
end

---@return number # Bytes written, which is what the gpu is told to read
function QuadBatch:instanceBytes()
	return self.quads * INSTANCE_SIZE
end

batch.RUN_NUMBERS = RUN_NUMBERS
batch.RUN_TEXTURE = RUN_TEXTURE
batch.RUN_FIRST = RUN_FIRST

return batch
