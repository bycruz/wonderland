-- The instances of a frame: what one is made of, and what of it is packed. Nothing here needs a
-- gpu: the batch writes plain memory, and what it wrote is what is read back.
local test = require("lde-test")
local batch = require("wonderland.util.quad_batch")

--- A batch with one round quad written into it, for what it wrote to be read back.
---@param opts { radius: number, band: number?, blur: number?, r: number?, u0: number? }
---@return wonderland.ffi.wl_instance
local function written(opts)
	local quads = batch.new()

	quads:setViewport(100, 100)

	-- The whole of the window, so that a radius of twenty four is not cut down to the box it is
	-- asked for: a radius bigger than the box is the roundest the box can be.
	quads:roundQuad(-1, -1, 1, 1, 1, opts.r or 0.5, 0.25, 1.0, 0.5, 7, opts.u0 or 0.5, 0.25, 1.0, 0.75,
		opts.radius, nil, nil, nil, nil, opts.band, nil, opts.blur)

	return quads.instances[0]
end

-- What a quad is written as is one instance, and the descriptor the render plugin draws it with is
-- built from the same table: a field added, widened or reordered here is one the descriptor follows.
-- This is the size of one as it stands, against the two hundred and forty the four vertices of a
-- quad used to be.
test.it("a quad is one instance, and one a whole number of four byte steps", function()
	test.equal(batch.INSTANCE_SIZE, 92, "the bytes one instance is")
	test.equal(batch.INSTANCE_SIZE % 4, 0, "which the gpu asks to be a whole number of them")

	local names = {}

	for _, attribute in ipairs(batch.INSTANCE_ATTRIBUTES) do
		test.equal(attribute.offset % (attribute.type == "f32" and 4 or 2), 0,
			"a field is where the hardware can read it: " .. attribute.type)
		test.falsy(names[attribute.offset], "and no two fields are in the same place")
		names[attribute.offset] = true
	end

	test.equal(#batch.INSTANCE_ATTRIBUTES, 10, "and it holds what the shader reads it as")
	test.equal(#batch.CORNER_ATTRIBUTES, 2, "with what a corner of the unit square is read as")
	test.equal(batch.QUAD_INDICES[0], 0, "and the indices every quad is drawn with")
	test.equal(batch.QUAD_INDICES[2], 2)
	test.equal(batch.QUAD_INDICES[5], 3)
end)

-- The corners the gpu draws are the same four for every quad of every frame, and what a corner of a
-- quad's own coordinates is worth is the only thing about them that changes: a window that changed
-- size writes four corners again.
test.it("the unit square every quad is drawn as is four corners", function()
	local quads = batch.new()

	quads:setViewport(200, 100)

	test.equal(quads.corners[0].x, 0, "the first corner is the top left of it")
	test.equal(quads.corners[0].y, 0)
	test.equal(quads.corners[1].x, 1, "and the second is the top right")
	test.equal(quads.corners[2].y, 1, "the third is the bottom right")
	test.equal(quads.corners[3].x, 0, "and the fourth is the bottom left")
	test.equal(quads.corners[3].scaleX, 100, "half the window across is what a coordinate is worth")
	test.equal(quads.corners[3].scaleY, 50, "and half of it down")
end)

-- A colour is a fraction of one everywhere above the batch, so what is kept of it is the byte the
-- hardware scales back into that fraction: what is written is what a shader sees, to the byte.
test.it("a colour is kept as a byte", function()
	local instance = written({ radius = 0 })

	test.equal(instance.r, 128, "half of one is a byte of 128")
	test.equal(instance.g, 64, "and a quarter of it is 64")
	test.equal(instance.b, 255, "as one is the top of the range")
	test.equal(instance.a, 128, "each channel on its own")
end)

-- A cut and a blur are pixels, and a half is a whole number of pixels to a fraction of one: four
-- pixels is four, and the band of a shadow is what a half of one comes to.
test.it("a cut and a blur are kept as halves", function()
	test.equal(written({ radius = 1 }).radius, 0x3c00, "one pixel is one as a half")
	test.equal(written({ radius = 3 }).radius, 0x4200, "and three is three")
	test.equal(written({ radius = 24 }).radius, 0x4e00, "and twenty four is twenty four")
	test.equal(written({ radius = 1, band = 0.5 }).band, 0x3800, "a band of a half is a half")
	test.equal(written({ radius = 1, blur = 24 }).blur, 0x4e00, "a blur of twenty four is twenty four")
	test.equal(written({ radius = 1 }).blur, 0, "and a quad that asked for none says nought")
end)

test.it("the part of a picture a box is is kept as 65535ths", function()
	local instance = written({ radius = 0, u0 = 0.5, blur = 1 })

	test.equal(instance.u0, 32768, "half of a picture is half of the range")
	test.equal(instance.v0, 16384, "and a quarter of it is a quarter")
	test.equal(instance.u1, 65535, "as the whole of it is the whole range")
	test.equal(instance.v1, 49151, "to the nearest 65535th")
end)

-- A quad that asked for neither a cut nor a blur says so in noughts rather than leaving what was
-- written into that slot by the quad before it, which the gpu would draw it with.
test.it("a quad that is neither round nor spread writes noughts", function()
	local quads = batch.new()

	quads:setViewport(100, 100)
	quads:roundQuad(0, 0, 0.5, 0.5, 1, 1, 1, 1, 1, 7, 0.5, 0.5, 1, 1, 8, nil, nil, nil, nil, 0.5)
	quads:quad(0, 0, 0.5, 0.5, 1, 1, 1, 1, 1, 7, 0.5, 0.5, 1, 1)

	local instance = quads.instances[1]

	test.equal(instance.radius, 0, "the cut of the second quad is nought")
	test.equal(instance.band, 0)
	test.equal(instance.blur, 0, "and so is the blur of it")
	test.equal(instance.innerX, 0, "and where its arcs would have been")
	test.equal(instance.u0, 0, "and the part of a picture it is drawn with")
end)

-- A quad is drawn as one, whatever shape it is: the four corners are what it is, and the box they
-- are cut against is only what a corner of it is measured from.
test.it("a quad of four corners is written as the four it is given", function()
	local quads = batch.new()

	quads:setViewport(100, 100)
	quads:points(0.25, 0.5, 0.75, 0.25, 0.5, 0.75, -1, 1, 1, 1, 1, 1, 1, 7)

	local instance = quads.instances[0]

	test.equal(instance.c0x, 0.25, "the first corner is the first point")
	test.equal(instance.c0y, 0.5)
	test.equal(instance.c2x, 0.5, "and the third triangle of it is the fourth point")
	test.equal(instance.c3y, 1, "which need not be a box at all")
	test.equal(quads.quads, 1, "and it is one quad")
end)
