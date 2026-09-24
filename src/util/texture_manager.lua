-- Pictures, as the gpu holds them: one texture per picture, made when the picture is uploaded, of
-- exactly the size the picture is.
--
-- There is no atlas and no array for a whole screen to share, and nothing to size before an app
-- starts: a picture costs what it is and no more, a four thousand pixel photograph next to an
-- eight pixel icon being the two of them. What an atlas would buy -- one draw call for the whole
-- screen -- is bought by the batch instead: the quads that share a picture are a run, and a run is
-- a draw call. See `wonderland.QuadBatch` and `wonderland.plugin.Render:recordFrame`.
--
--   local logo = textures:upload(image)
--   textures:bindGroup(logo) -- what a draw call of its quads is given
--
-- A picture is uploaded in bands -- rows of it, stacked as layers of one array texture -- because
-- of how an upload reaches the gpu: hood stages one through host visible memory, and the memory a
-- driver hands out that way is a small window rather than the whole card. Uploading a picture
-- whole asks for a window the size of the picture, which is what fails once the window is busy
-- with other things; in bands, what one upload holds is bounded, and a picture of any size is a
-- handful of them.
--
-- A band is a layer, so where in its texture a picture is depends on how far down it a pixel is:
-- the shader works that out from what a picture records here -- the layer its bands start at, how
-- many of them a picture of its height spans, and the last of them. That is `slots`, one per
-- picture, read by the shader through the texture id a quad was drawn with.
local ffi = require("ffi")
local backend = require("wonderland.backend")

--- What a texture is uploaded from: a plain RGBA buffer and its shape. What the `image` package
--- decodes is this shape as well, which is what makes a picture a file came in uploadable as it is.
---@alias Image { width: number, height: number, channels: number, pixels: ffi.cdata*, buffer: string? }

---@alias Texture number # Which picture a quad samples: a slot of this manager's

--- One texture, and the bind group every quad drawn from it is given.
---@class TextureManager.Texture
---@field texture hood.Texture
---@field view hood.TextureView
---@field bindGroup hood.BindGroup
---@field layers number

--- A picture, as the shader needs it: the texture it is in, the layer its first band is, how many
--- layers its rows span, and the last of them.
---@class TextureManager.Slot
---@field width number
---@field height number
---@field texture number # Which of the manager's textures it is in
---@field base number
---@field scale number
---@field last number

-- The sampler's binding is one of its own on Vulkan, where a sampler and the texture it reads are
-- two objects, and the texture's own unit on OpenGL, where they are one.
local SAMPLER_BINDING = backend.isVulkan and 1 or 0

-- Where the shader reads a picture's bands from, and how much of it is one picture: a vec4 of
-- base layer, layers spanned, last layer, and one to spare.
local SLOT_BINDING = 2
local SLOT_FLOATS = 4

-- How large a texture may be, a side. Vulkan's own floor is 4096 and OpenGL's is 1024, and every
-- driver this runs on is well past both, so a picture bigger than this is refused by name rather
-- than by whatever a driver does about it.
local MAX_SIZE = 8192

-- How many layers one texture may have: 256 is Vulkan's floor for `maxImageArrayLayers`, and an
-- animation with more frames than that takes more textures rather than one longer one.
local MAX_LAYERS = 256

-- How much of a picture one upload stages through host visible memory, in pixels: eight megabytes.
-- Every driver this runs on hands out a window of that memory rather than the whole card -- a
-- resizable BAR is what a machine with a large one has -- and an upload that asks for more than is
-- free is the one that fails, so a picture is uploaded in bands of this much however large it is.
local DEFAULT_UPLOAD_PIXELS = 2 * 1024 * 1024

---@class TextureManager
---@field device hood.Device
---@field sampler hood.Sampler
---@field layout hood.BindGroupLayout # The layout every texture's bind group is made with
---@field slots TextureManager.Slot[] # What each picture is drawn by, by the id a quad holds
---@field slotCount number # How many of them there are, since the array is not a Lua one
---@field slotBuffer hood.Buffer # And those, in the buffer the shader reads them from
---@field slotCapacity number # How many it holds before it is made again
---@field textures TextureManager.Texture[]
---@field textureCount number
---@field uploadPixels number # Pixels one upload may hold: the bands a picture is split into
---@field pending { slot: Texture, image: Image }[] # Pictures written since the last frame was drawn
---@field stage ffi.cdata*? # The buffer a band is staged in, kept: a gif has one per frame
---@field stagePixels number # How much of a band it holds
---@field whiteTexture Texture # The picture a box with no picture of its own is drawn with
---@field errorTexture Texture # And the one that says a texture id was not one
local TextureManager = {}
TextureManager.__index = TextureManager

---@param device hood.Device
---@param opts { uploadPixels: number? }? # What one upload may hold, for a machine that knows better
---@return TextureManager
function TextureManager.new(device, opts)
	local sampler = device:createSampler({
		minFilter = "nearest",
		magFilter = "nearest",
		mipmapFilter = "nearest",
		addressModeU = "clamp-to-edge",
		addressModeV = "clamp-to-edge",
		addressModeW = "clamp-to-edge"
	})

	local layout = device:createBindGroupLayout({
		{ type = "texture", binding = 0, visibility = { "FRAGMENT" } },
		{ type = "sampler", binding = SAMPLER_BINDING, visibility = { "FRAGMENT" } },
		{ type = "storage-buffer", binding = SLOT_BINDING, visibility = { "FRAGMENT" } },
	})

	local this = setmetatable({
		device = device,
		sampler = sampler,
		layout = layout,
		uploadPixels = (opts and opts.uploadPixels) or DEFAULT_UPLOAD_PIXELS,
		pending = {},
		stagePixels = 0,
		slots = {},
		slotCount = 0,
		slotBuffer = device:createBuffer({ size = 64 * SLOT_FLOATS * ffi.sizeof("float"),
			usages = { "STORAGE", "COPY_DST" } }),
		slotCapacity = 64,
		textures = {},
		textureCount = 0,
	}, TextureManager)

	-- A box with no picture is drawn with the first of these, which is why it is uploaded first:
	-- the white texture is texture nought, and the quads of a background, a border or a caret ask
	-- for nought rather than for their own.
	this.whiteTexture = this:upload({
		width = 1,
		height = 1,
		channels = 4,
		pixels = ffi.new("uint8_t[?]", 4, { 255, 255, 255, 255 }),
		buffer = "",
	})
	this.errorTexture = this:upload({
		width = 2,
		height = 2,
		channels = 4,
		pixels = ffi.new("uint8_t[?]", 16, {
			255, 0, 255, 255,
			0, 0, 0, 255,
			0, 0, 0, 255,
			255, 0, 255, 255,
		}),
		buffer = "",
	})

	return this
end

function TextureManager:destroy()
	for _, texture in ipairs(self.textures) do
		texture.bindGroup:destroy()
		texture.view:destroy()
		texture.texture:destroy()
	end

	self.textures = {}
	self.textureCount = 0
	self.slots = {}
	self.slotCount = 0
	self.pending = {}
	self.stage, self.stagePixels = nil, 0

	self.slotBuffer:destroy()
	self.sampler:destroy()
	self.layout:destroy()
end

--- How a picture of this size is laid out: the rows one band holds, and how many bands that is.
--- The bands come out equal whatever the picture is, so what an upload holds is bounded by the
--- width of the picture rather than by its height.
---@param width number
---@param height number
---@param uploadPixels number # What one upload may hold
---@return number layerHeight
---@return number bands
local function banding(width, height, uploadPixels)
	local rows = math.max(1, math.floor(uploadPixels / width))
	local bands = math.ceil(height / rows)

	return math.ceil(height / bands), bands
end

--- A texture of as many layers as the pictures going into it, and the bind group every quad drawn
--- from it is given.
---@param width number # The width of a layer, which is the width of the pictures
---@param height number # And its height, which is the rows of one band
---@param layers number
---@return number # Its place in `textures`
function TextureManager:createTexture(width, height, layers)
	assert(width <= MAX_SIZE and height <= MAX_SIZE and layers <= MAX_LAYERS,
		string.format("A texture of %dx%dx%d is larger than this renderer makes", width, height, layers))

	local texture = self.device:createTexture({
		extents = { dim = "2d", width = width, height = height, count = layers },
		format = "rgba8unorm",
		usages = { "TEXTURE_BINDING", "COPY_DST" }
	})

	local view = texture:createView({})
	local id = self.textureCount

	self.textures[id] = {
		texture = texture,
		view = view,
		layers = layers,
		bindGroup = self:createBindGroup(view),
	}

	self.textureCount = id + 1

	return id
end

---@param view hood.TextureView
---@return hood.BindGroup
function TextureManager:createBindGroup(view)
	return self.device:createBindGroup({
		layout = self.layout,
		entries = {
			{ type = "texture", binding = 0, texture = view, visibility = { "FRAGMENT" } },
			{ type = "sampler", binding = SAMPLER_BINDING, sampler = self.sampler,
				visibility = { "FRAGMENT" } },
			{ type = "storage-buffer", binding = SLOT_BINDING, buffer = self.slotBuffer,
				visibility = { "FRAGMENT" } },
		}
	})
end

--- Writes a picture into the layers of a texture, a band at a time: the layers `first` to
--- `first + bands - 1` hold it, its top band first.
---
--- Every band is written whole, the rows a picture does not reach being nothing at all, so what a
--- pixel reads past the bottom of a picture is transparent rather than what was there before.
---
--- What is held at once is one band's worth of pixels, which is what keeps a photograph from being
--- an upload the size of the photograph.
---@param texture number
---@param first number # The layer its first band goes in
---@param image Image
---@param layerHeight number
---@param bands number
function TextureManager:writeBands(texture, first, image, layerHeight, bands)
	local width, height = image.width, image.height
	local pixels = width * layerHeight * 4
	local layer = assert(self.textures[texture])

	-- Kept rather than made per band: a gif is a band of a frame per frame, and a buffer of that
	-- size asked for and thrown away once per frame is churn for nothing.
	if self.stagePixels < pixels then
		self.stage = ffi.new("uint8_t[?]", pixels)
		self.stagePixels = pixels
	end

	local stage = assert(self.stage)

	for band = 0, bands - 1 do
		local top = band * layerHeight
		local rows = math.min(layerHeight, height - top)

		ffi.fill(stage, width * layerHeight * 4)

		for row = 0, rows - 1 do
			ffi.copy(stage + row * width * 4, image.pixels + (top + row) * width * 4, width * 4)
		end

		self.device.queue:writeTexture(layer.texture,
			{ layer = first + band, width = width, height = layerHeight }, stage)
	end
end

--- Records what the shader needs to place a picture: the layer its bands start at, how many of
--- them a picture of its height spans, and the last of them.
---@param width number
---@param height number
---@param texture number
---@param first number
---@param layerHeight number
---@param bands number
---@return Texture
function TextureManager:addSlot(width, height, texture, first, layerHeight, bands)
	-- Counted rather than taken from `#slots`: a slot is nought based -- the shader reads the one
	-- a quad was drawn with -- and the length of a table whose keys start at nought is not a
	-- number Lua gives an answer for.
	local slot = self.slotCount

	if slot >= self.slotCapacity then
		self:growSlots(slot + 1)
	end

	self.slots[slot] = {
		width = width,
		height = height,
		texture = texture,
		base = first,
		scale = height / layerHeight,
		last = first + bands - 1,
	}

	self.slotCount = slot + 1

	self:writeSlot(slot, self.slotBuffer)

	return slot
end

---@param slot number
---@param buffer hood.Buffer
function TextureManager:writeSlot(slot, buffer)
	local metadata = assert(self.slots[slot])
	local entry = ffi.new("float[4]", { metadata.base, metadata.scale, metadata.last, 0 })

	self.device.queue:writeBuffer(buffer, SLOT_FLOATS * ffi.sizeof("float"), entry,
		slot * SLOT_FLOATS * ffi.sizeof("float"))
end

--- More room for what the shader reads, and a bind group per texture made again with it: a bind
--- group holds the buffer it was made with, and what a screen draws with has to be the slots as
--- they are now.
---@param slots number
function TextureManager:growSlots(slots)
	local capacity = self.slotCapacity
	while capacity < slots do
		capacity = capacity * 2
	end

	local buffer = self.device:createBuffer({ size = capacity * SLOT_FLOATS * ffi.sizeof("float"),
		usages = { "STORAGE", "COPY_DST" } })

	for slot = 0, self.slotCount - 1 do
		self:writeSlot(slot, buffer)
	end

	local old = self.slotBuffer

	self.slotBuffer = buffer
	self.slotCapacity = capacity

	for id, texture in ipairs(self.textures) do
		texture.bindGroup = self:createBindGroup(texture.view)
		self.textures[id] = texture
	end

	old:destroy()
end

--- A texture of a picture's size and as many layers as an animation cycles through, which is what
--- a streamed animation is drawn out of: a few frames of room that the frames of the file are
--- written into one after another, rather than one layer for every frame of it.
---
--- What the layers hold until something is written into them is nothing, so a frame is drawn only
--- once it has been read.
---@param width number
---@param height number
---@param layers number
---@return number # The texture's place in `textures`
function TextureManager:uploadLayers(width, height, layers)
	assert(width > 0 and height > 0 and width <= MAX_SIZE and height <= MAX_SIZE, string.format(
		"A %dx%d picture is larger than the %d pixels a side this renderer uploads a texture of.",
		width, height, MAX_SIZE))

	return self:createTexture(width, height, layers)
end

--- What a picture drawn from a texture of layers is: the layer it starts at, and how many of them
--- its rows span, which for a frame is one.
---
--- A slot per frame a stream has reached is what makes a picture that has moved on a screen that
--- has changed: two frames of an animation share the texture they are drawn out of, and it is the
--- slot a quad names that says which of them it is.
---@param width number
---@param height number
---@param texture number
---@param first number
---@return Texture
function TextureManager:createSlot(width, height, texture, first)
	return self:addSlot(width, height, texture, first, height, 1)
end

--- Writes a picture into the layer a slot names, which is what a frame of a streamed animation is
--- read into.
---
--- What it does is hold it until the next frame is recorded, rather than upload it here: an upload
--- through the queue is a submit and a wait for the queue to go idle, and a frame of an animation
--- every tenth of a second waiting for the frame the gpu is drawing is a window that stutters.
--- See `flush`, which is where it becomes the gpu's.
---@param slot Texture
---@param image Image
function TextureManager:writeLayer(slot, image)
	local metadata = assert(self.slots[slot])

	assert(image.width == metadata.width and image.height == metadata.height, string.format(
		"A %dx%d picture does not fit the %dx%d frame this layer holds", image.width, image.height,
		metadata.width, metadata.height))

	self.pending[#self.pending + 1] = { slot = slot, image = image }
end

--- Records the pictures written since the last frame into the frame about to be drawn: the copy is
--- the frame's own, so a frame that reads an animation costs the memcpy of one frame's pixels and
--- nothing waits for the gpu at all.
---
--- A frame that is not drawn -- one that came out the same as the one on screen -- leaves what is
--- pending for the next one, which is a frame later than the picture was read and no worse than
--- not being read at all.
---@param encoder hood.CommandEncoder
function TextureManager:flush(encoder)
	for index = 1, #self.pending do
		local upload = self.pending[index]
		local metadata = assert(self.slots[upload.slot])
		local layer = assert(self.textures[metadata.texture])

		encoder:writeTexture(layer.texture,
			{ layer = metadata.base, width = upload.image.width, height = upload.image.height },
			upload.image.pixels)

		self.pending[index] = nil
	end
end

--- A picture, uploaded into a texture of its own and known by the id it comes back as. There is
--- nothing to allocate ahead of a picture: the picture is what is allocated.
---@param image Image
---@return Texture
function TextureManager:upload(image)
	local width, height = image.width, image.height

	assert(width > 0 and height > 0 and width <= MAX_SIZE and height <= MAX_SIZE, string.format(
		"A %dx%d picture is larger than the %d pixels a side this renderer uploads a texture of.",
		width, height, MAX_SIZE))

	-- The array is rgba8unorm and the shader reads it as such, so a buffer of fewer channels
	-- would be sampled as if its bytes were pixels of four.
	assert(image.channels == 4, "A texture takes four channels")

	local layerHeight, bands = banding(width, height, self.uploadPixels)
	local texture = self:createTexture(width, layerHeight, bands)

	self:writeBands(texture, 0, image, layerHeight, bands)

	-- A picture is its bands one after another, so the shader finds the layer a pixel is in by how
	-- far down the picture it is.
	return self:addSlot(width, height, texture, 0, layerHeight, bands)
end

---@param slot Texture
---@return hood.BindGroup
function TextureManager:bindGroup(slot)
	local metadata = self.slots[slot]

	assert(metadata, "Texture does not exist")

	return assert(self.textures[metadata.texture]).bindGroup
end

--- The size of the picture a slot is, which is the size it was uploaded at.
---@param slot Texture
---@return number, number
function TextureManager:getSize(slot)
	local metadata = self.slots[slot]

	assert(metadata, "Texture does not exist")

	return metadata.width, metadata.height
end

return TextureManager
