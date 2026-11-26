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
---@field border number

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
---@field request wonderland.QuadBatch.Request # the quad a `From` call writes: see below
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

--- One quad a caller is asking for, in one place a call hands over as a pointer rather than as
--- eighteen values. It is a scratch structure rather than a new one a quad: what a call carries is
--- what the recorder has to keep alive across it, and a request of eighteen arguments is one it
--- cannot coalesce -- so the values go into memory first, where they are plain stores, and the
--- call is `self` and the request.
---
--- The doubles matter: a position or a size that is a float32 is 0.7 read as 0.69999999, which is
--- a pixel on a 1200 pixel screen. The caller writes pixels, `clippedQuad` writes the normalized
--- corners the batch reads, and both are the same width as the numbers they came from.
---
--- `hasBand` says whether a band was named (a band of nought is a hard edge, and no band at all is
--- the one pixel either side a round corner has by default) and `hasBox` says whether the box the
--- corners belong to is the quad itself or a box a clip cut it down from.
---@class wonderland.QuadBatch.Request: ffi.cdata*
---@field left number
---@field top number
---@field right number
---@field bottom number
---@field z number
---@field radius number
---@field band number
---@field blur number
---@field border number
---@field spread number
---@field boxLeft number
---@field boxTop number
---@field boxRight number
---@field boxBottom number
---@field colour number
---@field texture number
---@field uv0 number
---@field uv1 number
---@field own number
---@field hasBox number
---@field hasBand number
local request = ffi.new([[
	struct {
		double left, top, right, bottom;
		double z, radius, band, blur, border, spread;
		double boxLeft, boxTop, boxRight, boxBottom;
		uint32_t colour, texture, uv0, uv1;
		uint8_t own, hasBox, hasBand;
	}
]])

-- On the class as well as the module: a batch instance is indexed through the class, and a
-- canvas drawing with one asks it for the request it fills.
batch.request = request
QuadBatch.request = request

--- The corners, the part of the picture and what they are drawn with: everything a quad says that
--- does not depend on how round or how spread it is. It is a function of its own so that what it
--- reads is dead before the cut is worked out -- a side trace that starts at the cut inherits what
--- is still live there, and enough of them is more than the register allocator can coalesce. See
--- `QuadBatch:roundQuadFrom`.
---@param instance wonderland.ffi.wl_instance
---@param r wonderland.QuadBatch.Request
local function putCorners(instance, r)
	local left, top, right, bottom = r.left, r.top, r.right, r.bottom
	local uv0, uv1 = r.uv0, r.uv1

	instance.c0x, instance.c0y, instance.c1x, instance.c1y = left, top, right, top
	instance.c2x, instance.c2y, instance.c3x, instance.c3y = right, bottom, left, bottom

	-- The part of the picture the box is, as the two corners it is: a 65535th across and a 65535th
	-- down in each, which is the pair of numbers the instance keeps. What is written here is what was
	-- narrowed once, by whoever had the picture's own numbers to hand -- see `batch.uv`.
	instance.u0, instance.v0 = bit.band(uv0, 0xffff), bit.rshift(uv0, 16)
	instance.u1, instance.v1 = bit.band(uv1, 0xffff), bit.rshift(uv1, 16)
	instance.z = r.z

	-- The colour is the four bytes it is, in one number: a byte a channel, which is what the shader
	-- reads as the fractions of one they are. Written here rather than narrowed four times over with
	-- a clamp each, which is what a colour handed over as four fractions cost -- see `batch.colour`.
	instance.rgba = r.colour

	-- Which picture it samples, as the id it is: narrowed no further than it is, because the two
	-- backends do not agree on an integer vertex attribute -- one scales a narrowed one back into a
	-- fraction and the other reads a number -- and a picture is a number the shader looks a band up
	-- by either way.
	instance.texture = r.texture

	-- How this one's picture is drawn: nought a shape the colour goes through, one a picture of its own
	-- colours, two the coverage of a glyph, which the shader corrects for gamma. The vertex shader
	-- reads the byte as the number it is.
	instance.own = r.own
end

-- The box a cut of a quad is measured against, for the request whose quad a clip cut down: the
-- corners of a box are still the corners of the whole box. It is read in a function of its own
-- because it is the rare case -- a quad that is its own box is nearly every round box -- and four
-- values read here are four values the path every cut is written on does not carry. See `putCut`.
---@param r wonderland.QuadBatch.Request
---@return number left
---@return number top
---@return number right
---@return number bottom
local function clippedBox(r)
	return r.boxLeft, r.boxTop, r.boxRight, r.boxBottom
end

--- The middle of the box and how far its corners are cut: the half of it either way, the radius
--- and the band, and the blur a spread-out edge is drawn with. It is written after the corners so
--- that at the guards below only the box and the cut are live.
---
--- A value that is nought is written as a half of nought rather than through `toHalf`: nought is
--- nought in a half too, and the call would be answered by that function's first guard every time.
--- A guard taken for every quad of a frame is an exit the recorder starts a side trace from, and
--- that side trace carries everything after it in the frame -- which is longer than a trace may be.
--- A cut is written for every round box of every frame, so that exit was taken for every one of
--- them and this path was never compiled: it ran interpreted, every frame. The band is the same
--- story: the one pixel a cut with no band of its own is is the half 0x3c00, and a band of a half
--- is narrowed as rarely as a radius is.
---@param instance wonderland.ffi.wl_instance
---@param r wonderland.QuadBatch.Request
---@param scaleX number
---@param scaleY number
local function putCut(instance, r, scaleX, scaleY)
	-- The box the corners belong to is the quad itself unless the request names another one.
	local boxLeft, boxTop, boxRight, boxBottom = r.left, r.top, r.right, r.bottom

	if r.hasBox ~= 0 then
		boxLeft, boxTop, boxRight, boxBottom = clippedBox(r)
	end

	local halfX = math.abs(boxRight - boxLeft) * scaleX * 0.5
	local halfY = math.abs(boxBottom - boxTop) * scaleY * 0.5

	instance.centreX, instance.centreY = (boxLeft + boxRight) * 0.5, (boxTop + boxBottom) * 0.5

	-- A radius bigger than the box it is asked for is the roundest the box can be: the arcs meet
	-- in the middle of it, and what is left is a box round all the way down its short side. The
	-- minimum is the IR min rather than a branch, which matters here: a circle asks for a radius
	-- that is exactly half its box, so this is taken for every round box and a branch would be a
	-- side trace started for every one of them.
	local radius = math.min(r.radius, math.min(halfX, halfY))

	-- A cut that names no band is one pixel either side of an edge, which is what a box wants.
	local band = r.band

	if r.hasBand == 0 then
		band = 1
	end

	instance.innerX, instance.innerY = halfX - radius, halfY - radius

	if radius > 0 then
		instance.radius = toHalf(radius)
	else
		instance.radius = 0
	end

	if band == 1 then
		instance.band = 0x3c00
	elseif band > 0 then
		instance.band = toHalf(band)
	else
		instance.band = 0
	end

	local blur = r.blur

	if blur > 0 then
		instance.blur = toHalf(blur)
	else
		instance.blur = 0
	end

	instance.border = math.max(0, math.min(255, math.floor(r.border + 0.5)))
end

--- Adds one quad, growing to fit if this frame is the largest so far. What it writes is all read
--- from the request that was filled for it: see `request`.
function QuadBatch:quadFrom()
	local r = request
	local at = self.quads

	if at >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	-- Opening the run here rather than through a call: a call made among the values a quad is
	-- written from is one the recorder has to keep every one of them alive across, and enough
	-- of them is more than it can coalesce. A run cannot overflow the array before a quad does,
	-- since every run holds at least the quad that opened it.
	local texture = r.texture

	if texture ~= self.texture then
		local run = self.runCount * RUN_NUMBERS

		self.runs[run + RUN_TEXTURE] = texture
		self.runs[run + RUN_FIRST] = at
		self.runCount = self.runCount + 1
		self.texture = texture
	end

	local instance = self.instances[at]

	putCorners(instance, r)

	-- The box a quad of two corners is cut against is the quad itself, which is what the shader maps
	-- the picture across and measures a corner of it from.
	instance.centreX, instance.centreY = (r.left + r.right) * 0.5, (r.top + r.bottom) * 0.5

	-- A quad that is not round and not spread says so in a cut of nought and a blur of nought, which
	-- is what nearly every quad in a screen writes: it is written here as the halves they are rather
	-- than narrowed by anything, because nought is nought in both.
	instance.innerX = math.abs(r.right - r.left) * self.scaleX * 0.5
	instance.innerY = math.abs(r.bottom - r.top) * self.scaleY * 0.5
	instance.radius, instance.band, instance.blur = 0, 0, 0
	instance.border = 0

	self.quads = at + 1
end

--- Opens a run of quads that sample another picture, for a caller that has the room for the quad
--- it is about to write: a glyph of a face after the first, or a picture of its own. It is a call
--- rather than five lines in the caller's loop because the branch out of a loop is a side trace
--- that inherits the loop's values, and this one is taken by the glyphs that name a face of their
--- own rather than by the line.
---@param texture number
function QuadBatch:openRun(texture)
	local run = self.runCount * RUN_NUMBERS

	self.runs[run + RUN_TEXTURE] = texture
	self.runs[run + RUN_FIRST] = self.quads
	self.runCount = self.runCount + 1
	self.texture = texture
end

--- Adds one quad that is a glyph: its four corners, the part of the picture it is, and its colour,
--- with no cut, no blur and no border about it -- which is every glyph drawn inside the pane it is
--- in. It grows nothing and opens no run: the loop that draws a line does both before it, because
--- a loop that carries those two branches per glyph is a loop the recorder gives up on.
function QuadBatch:glyphFrom()
	local r = request
	local at = self.quads
	local instance = self.instances[at]

	putCorners(instance, r)

	instance.centreX, instance.centreY = (r.left + r.right) * 0.5, (r.top + r.bottom) * 0.5
	instance.innerX = math.abs(r.right - r.left) * self.scaleX * 0.5
	instance.innerY = math.abs(r.bottom - r.top) * self.scaleY * 0.5
	instance.radius, instance.band, instance.blur = 0, 0, 0
	instance.border = 0

	self.quads = at + 1
end

--- Adds one quad, the values of which are the request's: the call a caller outside a frame makes.
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
	local r = request

	r.left, r.top, r.right, r.bottom = left, top, right, bottom
	r.z, r.colour, r.texture = z, colour, texture
	r.uv0, r.uv1 = uv0 or 0, uv1 or UV_WHOLE
	r.own = own or 0

	self:quadFrom()
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
		local run = self.runCount * RUN_NUMBERS

		self.runs[run + RUN_TEXTURE] = texture
		self.runs[run + RUN_FIRST] = self.quads
		self.runCount = self.runCount + 1
		self.texture = texture
	end

	-- A shape of a canvas is four points and no box: what it is cut against is the box its corners
	-- come to, which nothing reads -- a shape names no cut and no blur, and what it samples is one
	-- point of a picture whatever it is drawn across.
	local left, right = math.min(x1, x2, x3, x4), math.max(x1, x2, x3, x4)
	local top, bottom = math.min(y1, y2, y3, y4), math.max(y1, y2, y3, y4)
	local at = self.quads
	local instance = self.instances[at]

	instance.c0x, instance.c0y, instance.c1x, instance.c1y = x1, y1, x2, y2
	instance.c2x, instance.c2y, instance.c3x, instance.c3y = x3, y3, x4, y4

	instance.u0, instance.v0 = 0, 0
	instance.u1, instance.v1 = bit.band(UV_WHOLE, 0xffff), bit.rshift(UV_WHOLE, 16)
	instance.z = z
	instance.rgba = colour
	instance.texture = texture
	instance.own = 0

	instance.centreX, instance.centreY = (left + right) * 0.5, (top + bottom) * 0.5
	instance.innerX, instance.innerY = math.abs(right - left) * self.scaleX * 0.5,
		math.abs(bottom - top) * self.scaleY * 0.5
	instance.radius, instance.band, instance.blur = 0, 0, 0
	instance.border = 0

	self.quads = at + 1
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
--- the box the quad itself is unless the request says a clip cut the quad down to less than the
--- box it was asked for -- the corners of a box cut by the pane it is in are still the corners of
--- the whole box.
---
--- What it writes is all read from the request that was filled for it: a call that carries no
--- values is one the recorder has nothing to keep alive across. See `request`.
function QuadBatch:roundQuadFrom()
	local r = request
	local at = self.quads

	if at >= self.capacity then
		self:reserve(self.capacity + 1)
	end

	if r.texture ~= self.texture then
		local run = self.runCount * RUN_NUMBERS

		self.runs[run + RUN_TEXTURE] = r.texture
		self.runs[run + RUN_FIRST] = at
		self.runCount = self.runCount + 1
		self.texture = r.texture
	end

	local instance = self.instances[at]

	-- The corners first and the cut after them: the values a side trace starting at the radius
	-- inherits are the box and the cut alone, rather than everything a quad says. See `putCorners`.
	putCorners(instance, r)
	putCut(instance, r, self.scaleX, self.scaleY)

	self.quads = at + 1
end

--- Adds one round quad, the values of which are the request's: the call a caller outside a frame
--- makes. What is round about it comes after everything a quad usually says so that a quad that
--- is its own box is a call that stops at the radius. See `request`.
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
	local r = request

	r.left, r.top, r.right, r.bottom = left, top, right, bottom
	r.z, r.colour, r.texture = z, colour, texture
	r.uv0, r.uv1 = uv0 or 0, uv1 or UV_WHOLE
	r.radius, r.band, r.own = radius, band or 0, own or 0
	r.hasBand = band ~= nil and 1 or 0
	r.blur, r.border, r.spread = blur or 0, border or 0, 0

	if boxLeft ~= nil then
		r.hasBox = 1
		r.boxLeft, r.boxTop = boxLeft, assert(boxTop)
		r.boxRight, r.boxBottom = assert(boxRight), assert(boxBottom)
	else
		r.hasBox = 0
	end

	self:roundQuadFrom()
end

---@return number # Bytes written, which is what the gpu is told to read
function QuadBatch:instanceBytes()
	return self.quads * INSTANCE_SIZE
end

batch.RUN_NUMBERS = RUN_NUMBERS
batch.RUN_TEXTURE = RUN_TEXTURE
batch.RUN_FIRST = RUN_FIRST

return batch
