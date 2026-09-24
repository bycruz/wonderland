local ffi = require("ffi")
local hood = require("hood")

local VertexLayout = require("hood.vertex_layout")
local TextureManager = require("wonderland.util.texture_manager")
local QuadBatch = require("wonderland.util.quad_batch")
local FontManager = require("wonderland.util.font_manager")
local backend = require("wonderland.backend")

local isVulkan = backend.isVulkan
local shaderType = backend.shaderType
local shaderExt = backend.shaderExt
local png = require("wonderland.util.png")

---@class wonderland.plugin.Render.Context
---@field window wonderland.RenderWindow
---@field swapchain hood.Swapchain?
---@field capture wonderland.plugin.Render.Capture?
---@field clear wonderland.Color
---@field quadBindGroupLayout hood.BindGroupLayout
---@field quadPipeline hood.Pipeline
---@field quadVertex hood.Buffer
---@field quadIndex hood.Buffer
---@field vertexCapacity number # Bytes the vertex buffer holds before it grows
---@field indexCapacity number # And the index buffer
---@field depthBuffer hood.Texture
---@field depthBufferView hood.TextureView
---@field ui? wonderland.Element
---@field screen? wonderland.Layout.Screen
---@field root? number
---@field nIndices number
---@field drawRetries number? # Frames asked for in a row with no texture to draw into

--- An offscreen target a frame can be read back from.
---@class wonderland.plugin.Render.Capture
---@field texture hood.Texture
---@field view hood.TextureView
---@field buffer hood.Buffer
---@field width number
---@field height number

---@class wonderland.plugin.Render.SharedResources
---@field textureManager TextureManager
---@field fontManager FontManager
---@field bindGroup hood.BindGroup

---@class wonderland.plugin.Render<Message>: wonderland.Plugin, { onWindowCreate: Message }
---@field windowPlugin wonderland.plugin.Window<any>
---@field mainCtx wonderland.plugin.Render.Context?
---@field contexts table<wonderland.RenderWindow, wonderland.plugin.Render.Context>
---@field sharedResources wonderland.plugin.Render.SharedResources?
---@field device hood.Device
---@field textureOptions wonderland.TextureOptions?
---@field presentMode string # How frames reach the display
local RenderPlugin = {}

-- How many frames in a row may be asked for while there is still nothing to draw into.
local DRAW_RETRIES = 3
RenderPlugin.__index = RenderPlugin

---@class wonderland.plugin.Render.Options
---@field presentMode string? # "fifo" waits for the display, "immediate" does not
---@field textures wonderland.TextureOptions? # How much room the textures get

---@param windowPlugin wonderland.plugin.Window
---@param opts wonderland.plugin.Render.Options?
function RenderPlugin.new(windowPlugin, opts)
	local adapter = windowPlugin.instance:requestAdapter({ powerPreference = "high-performance" })
	local device = adapter:requestDevice()

	return setmetatable({
		device = device,
		contexts = {},
		windowPlugin = windowPlugin,
		textureOptions = opts and opts.textures,

		-- Frames are waited for by the display unless an app says otherwise: a redraw that
		-- is not waited for is a render loop, and a render loop takes the machine with it.
		presentMode = (opts and opts.presentMode) or "fifo",
	}, RenderPlugin)
end

--- A frame writes its vertices and indices into these, so they start at a screenful
--- and grow when a bigger one comes along, rather than reserving the worst case for every
--- app. Growing waits for the queue because a frame still in flight is reading them.
---@param ctx wonderland.plugin.Render.Context
---@param vertexBytes number
---@param indexBytes number
function RenderPlugin:reserve(ctx, vertexBytes, indexBytes)
	if vertexBytes <= ctx.vertexCapacity and indexBytes <= ctx.indexCapacity then
		return
	end

	self.device.queue:waitIdle()

	local vertexCapacity = math.max(ctx.vertexCapacity, 1)
	while vertexCapacity < vertexBytes do
		vertexCapacity = vertexCapacity * 2
	end

	local indexCapacity = math.max(ctx.indexCapacity, 1)
	while indexCapacity < indexBytes do
		indexCapacity = indexCapacity * 2
	end

	ctx.quadVertex:destroy()
	ctx.quadIndex:destroy()

	ctx.quadVertex = self.device:createBuffer({
		size = vertexCapacity,
		usages = { "VERTEX", "COPY_DST" },
		mapped = true
	})
	ctx.quadIndex = self.device:createBuffer({
		size = indexCapacity,
		usages = { "INDEX", "COPY_DST" },
		mapped = true
	})
	ctx.vertexCapacity = vertexCapacity
	ctx.indexCapacity = indexCapacity
end

--- The frame the ui just built, handed over as the memory it was written into.
---@param window wonderland.RenderWindow
---@param batch wonderland.QuadBatch
function RenderPlugin:setRenderData(window, batch)
	local ctx = self:getContext(window)

	local vertexSize = batch:vertexFloats() * ffi.sizeof("float")
	local indexSize = batch:indexCount() * ffi.sizeof("uint32_t")

	self:reserve(ctx, vertexSize, indexSize)

	self.device.queue:writeBuffer(ctx.quadVertex, vertexSize, batch.vertices)
	self.device.queue:writeBuffer(ctx.quadIndex, indexSize, batch.indices)

	ctx.nIndices = batch:indexCount()
end

-- A quad is four vertices and six indices, and this many of them fit before either
-- buffer has to grow.
local INITIAL_QUADS = 4096

local bindings = {
	centralTexture = 0,
	centralSampler = isVulkan and 1 or 0, -- Combine for OpenGL
	dimsBuffer = 2
}

---@param window winit.Window
function RenderPlugin:register(window)
	local windowCtx = self.windowPlugin:getContext(window)
	assert(windowCtx, "Window context not found for render plugin")

	local swapchain = windowCtx.surface:configure(self.device, { presentMode = self.presentMode })

	return self:createContext(window, swapchain)
end

--- A headless context draws into an offscreen target the size of its window instead
--- of a swapchain, so a screen can be rendered, read back and checked without one.
---@param window wonderland.RenderWindow
---@return wonderland.plugin.Render.Context
function RenderPlugin:registerHeadless(window)
	return self:createContext(window, nil)
end

---@param window wonderland.RenderWindow
---@param swapchain hood.Swapchain?
---@return wonderland.plugin.Render.Context
function RenderPlugin:createContext(window, swapchain)

	-- The last two are what a round box is cut with, in pixels: where this corner of the quad is
	-- from the middle of the box and how far the arcs sit inside it, then the radius itself.
	local vertexDescriptor = VertexLayout
		.new()
		:withAttribute({ type = "f32", size = 3, offset = 0 }) -- position (vec3)
		:withAttribute({ type = "f32", size = 4, offset = 12 }) -- color (rgba)
		:withAttribute({ type = "f32", size = 2, offset = 28 }) -- uv
		:withAttribute({ type = "f32", size = 1, offset = 36 }) -- texture id
		:withAttribute({ type = "f32", size = 4, offset = 40 }) -- corner (vec4)
		:withAttribute({ type = "f32", size = 1, offset = 56 }) -- radius

	-- The ui writes vertices itself, so the two have to describe the same vertex.
	assert(QuadBatch.FLOATS_PER_VERTEX * ffi.sizeof("float") == vertexDescriptor:getStride(),
		"The quad batch and the vertex descriptor disagree about the vertex size")

	-- Room for a full screen of text to start with: 240 KB of vertices and 96 KB of
	-- indices, where the same pair used to reserve 4 MB for a screen that never came.
	local vertexCapacity = vertexDescriptor:getStride() * INITIAL_QUADS
	local indexCapacity = ffi.sizeof("uint32_t") * 6 * INITIAL_QUADS

	-- Mapped, because a screen is written again every time it changes: without it each
	-- write is a staged upload with a submit and a queue wait behind it, which measured
	-- four tenths of a millisecond per repaint however small the screen was.
	local quadVertex = self.device:createBuffer({
		size = vertexCapacity,
		usages = { "VERTEX", "COPY_DST" },
		mapped = true
	})
	local quadIndex = self.device:createBuffer({
		size = indexCapacity,
		usages = { "INDEX", "COPY_DST" },
		mapped = true
	})

	local quadLayout = self.device:createBindGroupLayout({
		{
			type = "texture",
			binding = bindings.centralTexture,
			visibility = { "FRAGMENT" }
		},
		{
			type = "sampler",
			binding = bindings.centralSampler,
			visibility = { "FRAGMENT" }
		},
		{
			type = "storage-buffer",
			binding = bindings.dimsBuffer,
			visibility = { "FRAGMENT" }
		}
	})

	-- hood does not expose the swapchain format to the language server, and a headless
	-- context has no swapchain: it draws into an rgba8unorm texture.
	local targetFormat = "rgba8unorm"
	if swapchain then
		---@diagnostic disable-next-line: undefined-field
		targetFormat = swapchain.format
	end

	local quadPipeline = self.device:createPipeline({
		layout = quadLayout,
		vertex = {
			module = { type = shaderType, source = require("wonderland.shaders.main.vert." .. shaderExt) },
			buffers = { vertexDescriptor }
		},
		fragment = {
			module = { type = shaderType, source = require("wonderland.shaders.main.frag." .. shaderExt) },
			targets = {
				{
					blend = "alpha-blending",
					writeMask = hood.ColorWrites.All,
					format = targetFormat
				}
			}
		},
		depthStencil = {
			depthWriteEnabled = true,
			depthCompare = "less-equal",
			format = "depth24plus"
		}
	})

	local depthBuffer = self.device:createTexture({
		extents = { dim = "2d", width = window.width, height = window.height },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" }
	})

	-- Initialize shared resources
	if not self.mainCtx then
		local textureManager = TextureManager.new(self.device, self.textureOptions)

		local bindGroupLayout = textureManager:createBindGroupLayout(
			bindings.centralTexture,
			bindings.centralSampler,
			bindings.dimsBuffer
		)

		local bindGroup = textureManager:createBindGroup(
			bindGroupLayout,
			bindings.centralTexture,
			bindings.centralSampler,
			bindings.dimsBuffer
		)

		local fontManager = FontManager.new(textureManager)

		self.sharedResources = {
			bindGroup = bindGroup,
			bindGroupLayout = bindGroupLayout,
			textureManager = textureManager,
			fontManager = fontManager
		}
	end

	---@type wonderland.plugin.Render.Context
	local ctx = {
		window = window,
		swapchain = swapchain,
		vertexCapacity = vertexCapacity,
		indexCapacity = indexCapacity,
		clear = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
		quadBindGroupLayout = quadLayout,
		quadPipeline = quadPipeline,
		quadVertex = quadVertex,
		quadIndex = quadIndex,
		nIndices = 0,
		depthBuffer = depthBuffer,
		depthBufferView = depthBuffer:createView({})
	}

	if not swapchain then
		ctx.capture = self:ensureCapture(ctx)
	end

	self.contexts[window] = ctx
	self.mainCtx = self.mainCtx or ctx
	return ctx
end

--- SAFETY: Returns non-nil as we will assume user registers all windows properly :)
function RenderPlugin:getContext(window)
	return self.contexts[window]
end

local bytePointer = ffi.typeof("const uint8_t*")

--- An offscreen target the size of the context's window, kept around because a
--- screenshot may be asked for more than once.
---@param ctx wonderland.plugin.Render.Context
---@return wonderland.plugin.Render.Capture
function RenderPlugin:ensureCapture(ctx)
	local width, height = ctx.window.width, ctx.window.height
	local capture = ctx.capture

	if capture and capture.width == width and capture.height == height then
		return capture
	end

	if capture then
		capture.view:destroy()
		capture.texture:destroy()
		capture.buffer:destroy()
	end

	local texture = self.device:createTexture({
		extents = { dim = "2d", width = width, height = height },
		format = "rgba8unorm",
		usages = { "RENDER_ATTACHMENT", "COPY_SRC" }
	})

	---@type wonderland.plugin.Render.Capture
	capture = {
		texture = texture,
		view = texture:createView({}),
		buffer = self.device:createBuffer({ size = width * height * 4, usages = { "MAP_READ" } }),
		width = width,
		height = height
	}

	ctx.capture = capture

	return capture
end

--- Records one frame of whatever the context was last told to draw.
---@param ctx wonderland.plugin.Render.Context
---@param encoder hood.CommandEncoder
---@param target hood.TextureView
---@param width number
---@param height number
function RenderPlugin:recordFrame(ctx, encoder, target, width, height)
	encoder:beginRendering({
		colorAttachments = {
			{
				op = { type = "clear", color = ctx.clear },
				texture = target
			}
		},
		depthStencilAttachment = {
			op = { type = "clear", depth = 1 },
			texture = ctx.depthBufferView
		}
	})
	encoder:setPipeline(ctx.quadPipeline)
	encoder:setBindGroup(0, self.sharedResources.bindGroup)
	encoder:setViewport(0, 0, width, height)
	encoder:setVertexBuffer(0, ctx.quadVertex)
	encoder:setIndexBuffer(ctx.quadIndex, "u32")
	encoder:drawIndexed(ctx.nIndices, 1)
	encoder:endRendering()
end

--- Reconfigures a swapchain whose surface changed under it, which is what a resize
--- looks like from here.
---@param ctx wonderland.plugin.Render.Context
function RenderPlugin:resize(ctx)
	local windowCtx = assert(self.windowPlugin:getContext(ctx.window))
	ctx.swapchain = windowCtx.surface:configure(self.device, { presentMode = self.presentMode }, ctx.swapchain)

	local oldBufferView, oldBuffer = ctx.depthBufferView, ctx.depthBuffer
	ctx.depthBuffer = self.device:createTexture({
		extents = { dim = "2d", width = ctx.swapchain.width, height = ctx.swapchain.height },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" }
	})
	ctx.depthBufferView = ctx.depthBuffer:createView({})

	oldBufferView:destroy()
	oldBuffer:destroy()
end

---@param ctx wonderland.plugin.Render.Context
---@return boolean drawn # false when the swapchain had to be reconfigured first
function RenderPlugin:draw(ctx)
	local view, width, height

	if ctx.capture then
		view, width, height = ctx.capture.view, ctx.capture.width, ctx.capture.height
	else
		local texture = ctx.swapchain:getCurrentTexture()

		if not texture then
			-- The swapchain is out of date, which is what a resize looks like from here.
			-- This frame is the one that resize asked for: reconfiguring and dropping it
			-- would leave the window showing nothing, because a redraw is only asked for
			-- when something changes, and by then the change has already happened.
			self:resize(ctx)

			texture = ctx.swapchain:getCurrentTexture()
		end

		if not texture then
			-- Still nothing to draw into. A swapchain being reconfigured may settle in a
			-- frame or two, so another frame is asked for -- but only a few times: a window
			-- that is gone, or one being dragged, would otherwise have the loop draw as fast
			-- as it can. What is left of this frame is the next real resize.
			ctx.drawRetries = (ctx.drawRetries or 0) + 1

			if ctx.drawRetries <= DRAW_RETRIES then
				ctx.window.shouldRedraw = true
			end

			return false
		end

		view, width, height = texture:createView({}), ctx.swapchain.width, ctx.swapchain.height
	end

	local encoder = self.device:createCommandEncoder()
	self:recordFrame(ctx, encoder, view, width, height)

	if ctx.swapchain then
		self.device.queue:submit(encoder:finish())
		self.device.queue:present(ctx.swapchain)
	else
		self:recordCopy(ctx, encoder)
		self.device.queue:submit(encoder:finish())
	end

	ctx.drawRetries = 0

	return true
end

---@param ctx wonderland.plugin.Render.Context
---@param encoder hood.CommandEncoder
function RenderPlugin:recordCopy(ctx, encoder)
	local capture = assert(ctx.capture)

	encoder:copyTextureToBuffer(
		{ texture = capture.texture },
		{ buffer = capture.buffer, bytesPerRow = capture.width * 4 },
		{ width = capture.width, height = capture.height }
	)
end

--- What the context last drew, as RGBA with the top row first. It costs a render, so
--- it is for a screenshot or a test rather than a frame loop.
---@param ctx wonderland.plugin.Render.Context
---@return string? pixels
---@return string? err
function RenderPlugin:getPixels(ctx)
	if ctx.swapchain then
		local capture = self:ensureCapture(ctx)
		local encoder = self.device:createCommandEncoder()

		self:recordFrame(ctx, encoder, capture.view, capture.width, capture.height)
		self:recordCopy(ctx, encoder)
		self.device.queue:submit(encoder:finish())
	end

	local capture = assert(ctx.capture)

	-- The copy has to have finished before the buffer can be read.
	self.device.queue:waitIdle()

	local buffer = capture.buffer
	buffer:mapAsync()
	local raw = ffi.cast(bytePointer, buffer:getMappedRange())
	local pixels = ffi.string(raw, capture.width * capture.height * 4)
	buffer:unmap()

	return pixels
end

--- Writes what the context last drew to a PNG.
---@param ctx wonderland.plugin.Render.Context
---@param path string
---@return boolean? ok
---@return string? err
function RenderPlugin:saveScreenshot(ctx, path)
	local pixels, err = self:getPixels(ctx)
	if not pixels then
		return nil, err
	end

	local capture = assert(ctx.capture)

	return png.write(path, capture.width, capture.height, pixels)
end

--- hood's OpenGL backend does not implement every destroy its types declare, so a
--- resource is asked whether it can be freed rather than assumed to be freeable.
---@param resource { destroy: (fun(self: any))? }?
local function release(resource)
	if resource and resource.destroy then
		resource:destroy()
	end
end

--- Frees what a context holds, and what the contexts shared once the last one goes.
--- Something that makes a screen per test wants this: the texture manager alone holds a
--- texture array hundreds of layers deep.
---@param window wonderland.RenderWindow
function RenderPlugin:destroy(window)
	local ctx = self.contexts[window]
	if not ctx then
		return
	end

	if ctx.capture then
		release(ctx.capture.view)
		release(ctx.capture.texture)
		release(ctx.capture.buffer)
	end

	release(ctx.depthBufferView)
	release(ctx.depthBuffer)
	release(ctx.quadVertex)
	release(ctx.quadIndex)
	release(ctx.quadPipeline)
	release(ctx.quadBindGroupLayout)

	self.contexts[window] = nil

	if self.mainCtx == ctx then
		self.mainCtx = nil
	end

	if next(self.contexts) ~= nil then
		return
	end

	local shared = self.sharedResources
	if shared then
		release(shared.bindGroup)
		shared.textureManager:destroy()
		self.sharedResources = nil
	end
end

--- A window asking to be drawn is the whole of a frame, and the swapchain it is drawn into is
--- this plugin's, so this is where it happens. Returning nothing matters: a message is what
--- update is called with, and a frame is not one.
---@param event winit.Event
---@param _handler winit.EventManager
function RenderPlugin:event(event, _handler)
	if event.name ~= "redraw" then
		return
	end

	local ctx = self:getContext(event.window)

	if ctx then
		self:draw(ctx)
	end
end

return RenderPlugin
