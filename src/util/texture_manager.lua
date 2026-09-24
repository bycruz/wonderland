local ffi = require("ffi")

--- A plain RGBA buffer, which is all a texture upload needs.
---@class Image
---@field width number
---@field height number
---@field channels number
---@field pixels ffi.cdata* # width * height * channels bytes
---@field buffer string?
local Image = {}

---@param width number
---@param height number
---@param channels number
---@param pixels ffi.cdata*
---@param buffer? string
---@return Image
function Image.new(width, height, channels, pixels, buffer)
	return { width = width, height = height, channels = channels, pixels = pixels, buffer = buffer }
end

-- Every texture lives in a layer of one array, which is what lets a quad name the
-- texture it samples instead of the renderer rebinding for each one. A texture array is
-- one size for all its layers, so the size is the largest texture an app uploads and the
-- layers are how many it uploads, and between them they decide how much of the gpu this
-- holds: size * size * 4 * layers bytes. At the defaults that is 32 MB, which covers a
-- few font atlases and a screenful of icons; raise it for larger images, and mind that
-- the whole array is allocated up front because a texture array cannot be resized.
local DEFAULT_SIZE = 512
local DEFAULT_LAYERS = 32

---@alias Texture number
---@alias TextureMetadata { width: number, height: number, image?: Image }

---@class wonderland.TextureOptions
---@field size number? # Edge of a texture in pixels, 512 by default
---@field layers number? # How many textures fit in the array, 32 by default

---@class TextureManager
---@field size number # Edge of a layer, in pixels
---@field layers number # How many textures fit
---@field device hood.Device
---@field textures TextureMetadata[]
---@field textureCount number
---@field textureUVScaleBuffer hood.Buffer
---@field texture hood.Texture
---@field view hood.TextureView
---@field sampler hood.Sampler
---@field whiteTexture Texture
---@field errorTexture Texture
local TextureManager = {}
TextureManager.__index = TextureManager

---@param device hood.Device
---@param opts wonderland.TextureOptions?
function TextureManager.new(device, opts)
	local size = (opts and opts.size) or DEFAULT_SIZE
	local layers = (opts and opts.layers) or DEFAULT_LAYERS

	local texture = device:createTexture({
		extents = { dim = "2d", width = size, height = size, count = layers },
		format = "rgba8unorm",
		usages = { "TEXTURE_BINDING", "STORAGE_BINDING", "COPY_DST", "COPY_SRC", "RENDER_ATTACHMENT" }
	})

	local sampler = device:createSampler({
		minFilter = "nearest",
		magFilter = "nearest",
		mipmapFilter = "nearest",
		addressModeU = "clamp-to-edge",
		addressModeV = "clamp-to-edge",
		addressModeW = "clamp-to-edge"
	})

	-- Use vec4 for proper alignment
	local textureUVScaleBuffer = device:createBuffer({
		size = layers * ffi.sizeof("float") * 2,
		usages = { "STORAGE", "COPY_DST" }
	})

	local this = setmetatable({
		size = size,
		layers = layers,
		textureCount = 0,
		textureUVScaleBuffer = textureUVScaleBuffer,
		texture = texture,
		view = texture:createView({}),
		sampler = sampler,
		device = device,
		textures = {}
	}, TextureManager)

	this.whiteTexture = this:upload(Image.new(1, 1, 4, ffi.new("uint8_t[?]", 4, { 255, 255, 255, 255 }), ""))
	this.errorTexture = this:upload(Image.new(
		2,
		2,
		4,
		ffi.new("uint8_t[?]", 16, {
			255,
			0,
			255,
			255,
			0,
			0,
			0,
			255,
			0,
			0,
			0,
			255,
			255,
			0,
			255,
			255
		}),
		""
	))

	return this
end

function TextureManager:destroy()
	self.texture:destroy()
	self.textureUVScaleBuffer:destroy()
	self.sampler:destroy()
end

---@param id Texture
---@param width number
---@param height number
function TextureManager:setTextureDimensions(id, width, height)
	local texture = self.textures[id]
	assert(texture, "Texture does not exist")

	texture.width, texture.height = width, height

	-- Using std430, don't need to align to vec4
	local uvScale = ffi.new("float[2]", width / self.size, height / self.size)
	self.device.queue:writeBuffer(self.textureUVScaleBuffer, 8, uvScale, id * 8)
end

---@param width number
---@param height number
---@return Texture
function TextureManager:allocate(width, height)
	local layer = self.textureCount
	if layer >= self.layers then
		error(string.format(
			"No room for another texture: the array holds %d. Give the render plugin more layers, " ..
			"at %d bytes of gpu each.", self.layers, self.size * self.size * 4))
	end

	self.textures[layer] = { width = width, height = height }
	self:setTextureDimensions(layer, width, height)
	self.textureCount = self.textureCount + 1

	return layer
end

---@param id Texture
---@return number, number
function TextureManager:getSize(id)
	local texture = self.textures[id]
	assert(texture, "Texture does not exist")
	return texture.width, texture.height
end

---@param image Image
function TextureManager:update(texture, image)
	assert(self.textures[texture], "Texture does not exist")
	assert(image.width <= self.size and image.height <= self.size, string.format(
		"A %dx%d texture does not fit a %dx%d layer: give the render plugin a larger texture size.",
		image.width, image.height, self.size, self.size))

	-- The array is rgba8unorm and the shader reads it as such, so a buffer of fewer
	-- channels would be sampled as if its bytes were pixels of four.
	assert(image.channels == 4, "A texture takes four channels")

	self:setTextureDimensions(texture, image.width, image.height)
	self.device.queue:writeTexture(self.texture, { layer = texture, width = image.width, height = image.height },
		image.pixels)
end

---@param image Image
function TextureManager:upload(image)
	local texture = self:allocate(image.width, image.height)
	self:update(texture, image)
	return texture
end

-- What sits between two frames packed into one layer, in pixels. A frame drawn at the size it
-- was decoded samples its own pixels and nothing else, but one drawn larger -- or moved by half
-- a pixel -- reads past its edge, and the sampler clamps at the end of a layer rather than at the
-- end of a frame.
local PACK_GUTTER = 1

---@param destination ffi.cdata* # uint8_t*, a layer's worth of pixels
---@param source ffi.cdata* # uint8_t*, one frame of four channels
---@param width number
---@param height number
---@param x number
---@param y number
---@param stride number # How wide a row of the destination is, in pixels
local function blit(destination, source, width, height, x, y, stride)
	local rowBytes = width * 4

	for row = 0, height - 1 do
		ffi.copy(destination + (y + row) * stride * 4 + x * 4, source + row * rowBytes, rowBytes)
	end
end

--- Every frame of an animation, packed into as few layers as fit: a gif of thirty frames of a
--- hundred pixels is one layer rather than thirty, which is the difference between a picture that
--- plays and one that runs a texture array out of layers.
---
--- Each frame comes back with the layer it landed in and the part of it to sample, and a layer is
--- written whole -- the frames, and nothing around them -- so that what a frame's edge reads past
--- it is transparent rather than whatever the last upload left there.
---@param frames Image[] # in playback order, all the same size, four channels
---@return { texture: Texture, uv: wonderland.UV }[]
function TextureManager:uploadFrames(frames)
	local count = #frames
	local first = assert(frames[1], "An animation needs at least one frame")
	local width, height = first.width, first.height

	for index = 2, count do
		assert(frames[index].width == width and frames[index].height == height,
			"Every frame of an animation is the same size")
	end

	assert(width > 0 and height > 0 and width <= self.size and height <= self.size, string.format(
		"A %dx%d frame does not fit a %dx%d layer: give the render plugin a larger texture size.",
		width, height, self.size, self.size))

	-- How many frames sit in one layer: the cells are the frame plus the gutter, and the last one
	-- of a row or a column may have its gutter cut off by the edge of the layer.
	local stepX, stepY = width + PACK_GUTTER, height + PACK_GUTTER
	local columns = math.max(1, math.floor((self.size - width) / stepX) + 1)
	local rows = math.max(1, math.floor((self.size - height) / stepY) + 1)
	local perLayer = columns * rows

	local layers = math.ceil(count / perLayer)
	local pixels = ffi.new("uint8_t[?]", self.size * self.size * 4)
	local placed = {}

	for layer = 0, layers - 1 do
		local from = layer * perLayer
		local to = math.min(from + perLayer, count) - 1
		-- Taken first, because a frame that lands in this layer is drawn from it either way: what
		-- is allocated is the layer the frame is going into.
		local texture = self:allocate(self.size, self.size)

		ffi.fill(pixels, self.size * self.size * 4)

		for index = from, to do
			local slot = index - from
			local column, row = slot % columns, math.floor(slot / columns)
			local x, y = column * stepX, row * stepY

			blit(pixels, frames[index + 1].pixels, width, height, x, y, self.size)

			-- The part of the layer a frame is, in the coordinates a sampler reads it in: a
			-- layer's own uv scale is one, so a frame is where in it that it was written.
			placed[index + 1] = {
				texture = texture,
				uv = {
					u0 = x / self.size,
					v0 = y / self.size,
					u1 = (x + width) / self.size,
					v1 = (y + height) / self.size,
				},
			}
		end

		self.device.queue:writeTexture(self.texture,
			{ layer = texture, width = self.size, height = self.size }, pixels)
	end

	return placed
end

---@param binding number The binding index for the texture array
---@param samplerBinding number The binding index for the sampler
---@param dimsBinding number The binding index for the dimensions buffer
---@return hood.BindGroupLayout
function TextureManager:createBindGroupLayout(binding, samplerBinding, dimsBinding)
	return self.device:createBindGroupLayout({
		{
			type = "texture",
			binding = binding,
			visibility = { "FRAGMENT" }
		},
		{
			type = "sampler",
			binding = samplerBinding,
			visibility = { "FRAGMENT" }
		},
		{
			type = "storage-buffer",
			binding = dimsBinding,
			visibility = { "FRAGMENT" }
		}
	})
end

---Create a bind group for this texture manager
---@param layout hood.BindGroupLayout The bind group layout to use for this bind group
---@param binding number The binding index for the texture array
---@param samplerBinding number The binding index for the sampler
---@param dimsBinding number The binding index for the dimensions buffer
---@return hood.BindGroup
function TextureManager:createBindGroup(layout, binding, samplerBinding, dimsBinding)
	return self.device:createBindGroup({
		layout = layout,
		entries = {
			{
				type = "texture",
				binding = binding,
				texture = self.view,
				visibility = { "FRAGMENT" }
			},
			{
				type = "sampler",
				binding = samplerBinding,
				sampler = self.sampler,
				visibility = { "FRAGMENT" }
			},
			{
				type = "storage-buffer",
				binding = dimsBinding,
				buffer = self.textureUVScaleBuffer,
				visibility = { "FRAGMENT" }
			}
		}
	})
end

return TextureManager
