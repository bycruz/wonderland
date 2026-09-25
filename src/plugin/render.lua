local ffi = require("ffi")
local hood = require("hood")
local image = require("image")

local VertexLayout = require("hood").VertexLayout
local TextureManager = require("wonderland.util.texture_manager")
local Assets = require("wonderland.util.assets")
local QuadBatch = require("wonderland.util.quad_batch")
local FontManager = require("wonderland.util.font_manager")
local backend = require("wonderland.backend")

local isVulkan = backend.isVulkan
local shaderType = backend.shaderType
local shaderExt = backend.shaderExt

---@class wonderland.plugin.Render.Context
---@field window wonderland.RenderWindow
---@field swapchain hood.Swapchain?
---@field capture wonderland.plugin.Render.Capture?
---@field clear wonderland.Color
---@field quadPipeline hood.Pipeline
---@field quadVertex hood.Buffer
---@field quadIndex hood.Buffer
---@field target hood.Texture? # What this frame draws into, taken before the screen is built for it
---@field targetView hood.TextureView?
---@field targetWidth number # And how big it is, which is what a screen of this frame is laid out at
---@field targetHeight number
---@field quadRuns ffi.cdata*? # uint32_t*, the texture and first quad of each run
---@field vertexCapacity number # Bytes the vertex buffer holds before it grows
---@field indexCapacity number # And the index buffer
---@field runCapacity number # How many runs of quads fit before the run buffer grows
---@field runCount number # How many the frame the gpu has was drawn with
---@field quads number # And how many quads it was, which is where the last run ends
---@field depthBuffer hood.Texture
---@field depthBufferView hood.TextureView
---@field ui? wonderland.Element
---@field screen? wonderland.Layout.Screen
---@field root? number
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
---@field assets wonderland.Assets

---@class wonderland.plugin.Render<Message>: wonderland.Plugin, { onWindowCreate: Message }
---@field windowPlugin wonderland.plugin.Window<any>
---@field mainCtx wonderland.plugin.Render.Context?
---@field contexts table<wonderland.RenderWindow, wonderland.plugin.Render.Context>
---@field sharedResources wonderland.plugin.Render.SharedResources?
---@field device hood.Device? # Made when a window is first registered: see `RenderPlugin:getDevice`
---@field presentMode string # How frames reach the display
local RenderPlugin = {}

-- How many frames in a row may be asked for while there is still nothing to draw into.
local DRAW_RETRIES = 3
RenderPlugin.__index = RenderPlugin

---@class wonderland.plugin.Render.Options
---@field presentMode string? # "fifo" waits for the display, "immediate" does not

---@param windowPlugin wonderland.plugin.Window
---@param opts wonderland.plugin.Render.Options?
function RenderPlugin.new(windowPlugin, opts)
	return setmetatable({
		contexts = {},
		windowPlugin = windowPlugin,

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

	self:getDevice().queue:waitIdle()

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

	ctx.quadVertex = self:getDevice():createBuffer({
		size = vertexCapacity,
		usages = { "VERTEX", "COPY_DST" },
		mapped = true
	})
	ctx.quadIndex = self:getDevice():createBuffer({
		size = indexCapacity,
		usages = { "INDEX", "COPY_DST" },
		mapped = true
	})
	ctx.vertexCapacity = vertexCapacity
	ctx.indexCapacity = indexCapacity
end

--- The frame the ui just built, handed over as the memory it was written into: the vertices, the
--- indices, and the runs of quads that share a picture, which are the draw calls it comes to.
---
--- The runs are copied rather than referred to, because the batch the ui writes into is one batch
--- and a screen with two windows in it is two frames: what a context is drawn from is what it was
--- handed, not what the window after it put there.
---@param window wonderland.RenderWindow
---@param batch wonderland.QuadBatch
function RenderPlugin:setRenderData(window, batch)
	local ctx = self:getContext(window)

	local vertexSize = batch:vertexFloats() * ffi.sizeof("float")
	local indexSize = batch:indexCount() * ffi.sizeof("uint32_t")

	self:reserve(ctx, vertexSize, indexSize)
	self:reserveRuns(ctx, batch.runCount)

	self:getDevice().queue:writeBuffer(ctx.quadVertex, vertexSize, batch.vertices)
	self:getDevice().queue:writeBuffer(ctx.quadIndex, indexSize, batch.indices)

	ffi.copy(ctx.quadRuns, batch.runs, batch.runCount * QuadBatch.RUN_NUMBERS * ffi.sizeof("uint32_t"))

	ctx.runCount = batch.runCount
	ctx.quads = batch.quads
end

--- How many runs of quads fit before the buffer they are handed over in grows. A run is two
--- numbers, and a frame is drawn with far fewer of them than it has quads.
---@param ctx wonderland.plugin.Render.Context
---@param runs number
function RenderPlugin:reserveRuns(ctx, runs)
	if runs <= ctx.runCapacity then
		return
	end

	local capacity = math.max(ctx.runCapacity, 1)
	while capacity < runs do
		capacity = capacity * 2
	end

	ctx.quadRuns = ffi.new("uint32_t[?]", capacity * QuadBatch.RUN_NUMBERS)
	ctx.runCapacity = capacity
end

-- A quad is four vertices and six indices, and this many of them fit before either
-- buffer has to grow.
local INITIAL_QUADS = 4096

---@param window winit.Window
function RenderPlugin:register(window)
	local windowCtx = self.windowPlugin:getContext(window)
	assert(windowCtx, "Window context not found for render plugin")

	local swapchain = windowCtx.surface:configure(self:getDevice(), { presentMode = self.presentMode })

	return self:createContext(window, swapchain)
end

--- The device every frame is drawn with, made when a window first needs one.
---
--- An app with its plugins installed and no window yet -- which is every app between `App:setup`
--- and its first window -- is not holding a gpu device for a screen it cannot draw, and neither is
--- a test that only wants to know which plugins an app is made of. What a device costs is not the
--- memory alone: a machine hands out a few of them and no more, so an app that took one for each
--- of its own setups is an app that fails to take the one it draws with.
---@return hood.Device
function RenderPlugin:getDevice()
	if self.device == nil then
		local adapter = self.windowPlugin.instance:requestAdapter({ powerPreference = "high-performance" })

		self.device = adapter:requestDevice()
	end

	return assert(self.device, "A window was registered with no device to draw it with")
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

	-- The last two are what a cut box is cut with, in pixels: where this corner of the quad is from
	-- the middle of the box and how far the arcs sit inside it, then the radius of the cut and how
	-- sharp its edge is.
	local vertexDescriptor = VertexLayout
		.new()
		:withAttribute({ type = "f32", size = 3, offset = 0 }) -- position (vec3)
		:withAttribute({ type = "f32", size = 4, offset = 12 }) -- color (rgba)
		:withAttribute({ type = "f32", size = 2, offset = 28 }) -- uv
		:withAttribute({ type = "f32", size = 1, offset = 36 }) -- the picture it samples
		:withAttribute({ type = "f32", size = 4, offset = 40 }) -- corner (vec4)
		:withAttribute({ type = "f32", size = 2, offset = 56 }) -- edge (radius, band)
		:withAttribute({ type = "f32", size = 1, offset = 64 }) -- whether the picture is its own colours

	-- The ui writes vertices itself, so the two have to describe the same vertex.
	assert(QuadBatch.FLOATS_PER_VERTEX * ffi.sizeof("float") == vertexDescriptor:getStride(),
		"The quad batch and the vertex descriptor disagree about the vertex size")

	-- Room for a full screen of text to start with: 256 KB of vertices and 96 KB of
	-- indices, where the same pair used to reserve 4 MB for a screen that never came.
	local vertexCapacity = vertexDescriptor:getStride() * INITIAL_QUADS
	local indexCapacity = ffi.sizeof("uint32_t") * 6 * INITIAL_QUADS

	-- Mapped, because a screen is written again every time it changes: without it each
	-- write is a staged upload with a submit and a queue wait behind it, which measured
	-- four tenths of a millisecond per repaint however small the screen was.
	local quadVertex = self:getDevice():createBuffer({
		size = vertexCapacity,
		usages = { "VERTEX", "COPY_DST" },
		mapped = true
	})
	local quadIndex = self:getDevice():createBuffer({
		size = indexCapacity,
		usages = { "INDEX", "COPY_DST" },
		mapped = true
	})

	-- What every context of this plugin shares: one device's textures, the fonts uploaded into
	-- them, and the pictures an app draws. Made before the pipeline, because the layout a texture
	-- bind group is made with is the layout the pipeline is drawn with.
	if not self.sharedResources then
		local textureManager = TextureManager.new(self:getDevice())

		self.sharedResources = {
			textureManager = textureManager,
			fontManager = FontManager.new(textureManager),
			assets = Assets.new(textureManager)
		}
	end

	local quadLayout = assert(self.sharedResources).textureManager.layout

	-- hood does not expose the swapchain format to the language server, and a headless
	-- context has no swapchain: it draws into an rgba8unorm texture.
	local targetFormat = "rgba8unorm"
	if swapchain then
		---@diagnostic disable-next-line: undefined-field
		targetFormat = swapchain.format
	end

	local quadPipeline = self:getDevice():createPipeline({
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

	-- The depth attachment is the size of what is drawn into, which is the swapchain and not always
	-- the size the window says it is: an attachment of another size is a pass that cannot be made.
	local depthWidth, depthHeight = window.width, window.height

	if swapchain then
		---@diagnostic disable-next-line: undefined-field
		depthWidth, depthHeight = swapchain.width, swapchain.height
	end

	local depthBuffer = self:getDevice():createTexture({
		extents = { dim = "2d", width = depthWidth, height = depthHeight },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" }
	})

	-- Initialize shared resources
	if not self.mainCtx then
		local textureManager = TextureManager.new(self:getDevice())

		local fontManager = FontManager.new(textureManager)

		self.sharedResources = {
			textureManager = textureManager,
			fontManager = fontManager,
			assets = Assets.new(textureManager)
		}
	end

	---@type wonderland.plugin.Render.Context
	local ctx = {
		window = window,
		swapchain = swapchain,
		vertexCapacity = vertexCapacity,
		indexCapacity = indexCapacity,
		clear = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
		quadPipeline = quadPipeline,
		quadVertex = quadVertex,
		quadIndex = quadIndex,
		runCapacity = 0,
		runCount = 0,
		quads = 0,
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

	local texture = self:getDevice():createTexture({
		extents = { dim = "2d", width = width, height = height },
		format = "rgba8unorm",
		usages = { "RENDER_ATTACHMENT", "COPY_SRC" }
	})

	---@type wonderland.plugin.Render.Capture
	capture = {
		texture = texture,
		view = texture:createView({}),
		buffer = self:getDevice():createBuffer({ size = width * height * 4, usages = { "MAP_READ" } }),
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
	-- What an animation has read since the last frame goes into this one, before the pass it is
	-- drawn in: a copy is not something a render pass can have recorded inside it, and going
	-- through the queue instead would be this frame waiting for the gpu to be idle.
	local shared = self.sharedResources

	if shared then
		-- What a font packed since the last frame -- a glyph of a character no screen had drawn
		-- before -- goes into the frame being recorded: a line measured in a face's atlas this
		-- frame is drawn from a picture that has the glyph in it this frame.
		shared.fontManager:flush()
		shared.textureManager:flush(encoder)
	end

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
	encoder:setViewport(0, 0, width, height)
	encoder:setVertexBuffer(0, ctx.quadVertex)
	encoder:setIndexBuffer(ctx.quadIndex, "u32")

	-- A run at a time, in the order the walk wrote them: every quad of a run samples the picture
	-- the run names, so the bind group changes between runs and not between quads -- and the
	-- picture's own bands are read by the shader from the id each vertex carries. A line of text is
	-- one run and one draw call, and a screen of pictures is as many as it has of them.
	if ctx.runCount > 0 then
		local manager = assert(self.sharedResources).textureManager
		local runs = assert(ctx.quadRuns)

		for run = 0, ctx.runCount - 1 do
			local at = run * QuadBatch.RUN_NUMBERS
			local texture = runs[at + QuadBatch.RUN_TEXTURE]
			local first = runs[at + QuadBatch.RUN_FIRST]
			-- Where this run ends: the quad the next one starts at, or the end of the frame.
			local after = run + 1 < ctx.runCount
					and runs[at + QuadBatch.RUN_NUMBERS + QuadBatch.RUN_FIRST]
				or ctx.quads

			encoder:setBindGroup(0, manager:bindGroup(texture))
			encoder:drawIndexed((after - first) * 6, 1, first * 6)
		end
	end

	encoder:endRendering()
end

--- The size a frame of this window is drawn into, which is what its screen is laid out at.
---
--- It is the target the frame is drawn into -- taken by `retarget`, before the screen is built --
--- rather than the size the window says it is: an X11 window and the surface it is drawn into are
--- told about a resize at different moments, and a screen laid out against the window while it is
--- drawn into a surface of another size is a screen the compositor stretches to fit.
---
--- A screen with no window behind it is the size it says, since there is nothing else for it to be.
---@param window wonderland.RenderWindow
---@return number width
---@return number height
function RenderPlugin:size(window)
	local ctx = self.contexts[window]

	if ctx and ctx.target then
		return ctx.targetWidth, ctx.targetHeight
	end

	if ctx and ctx.swapchain then
		return ctx.swapchain.width, ctx.swapchain.height
	end

	return window.width, window.height
end

--- Takes the target this frame draws into, so that a screen can be laid out at the size of what it
--- is drawn into rather than at the size of what the last frame was drawn into.
---
--- A swapchain whose surface changed under it is reconfigured here, before any of the screen is
--- built: a frame built for the old size and drawn into the new one is a frame the compositor
--- stretches, and during a resize that is every frame of the drag.
---
--- Answers with whether there is anything to draw into; a frame with nothing is one the caller
--- drops, and the redraw it asks for is what tries again.
---@param window wonderland.RenderWindow
---@return boolean
function RenderPlugin:retarget(window)
	local ctx = self:getContext(window)

	if not ctx then
		return false
	end

	if ctx.target then
		return true
	end

	if not ctx.swapchain then
		-- A screen with no window behind it draws into the capture it is read back from.
		return true
	end

	local texture = ctx.swapchain:getCurrentTexture()

	if not texture then
		self:resize(ctx)

		texture = ctx.swapchain:getCurrentTexture()
	end

	if not texture then
		-- The surface is still moving under it. A frame is asked for again -- but only a few times
		-- in a row, so that a window that is gone, or one being dragged, is not a loop that draws
		-- as fast as it can: see `drawRetries`.
		ctx.drawRetries = (ctx.drawRetries or 0) + 1

		if ctx.drawRetries <= DRAW_RETRIES then
			ctx.window.shouldRedraw = true
		end

		return false
	end

	ctx.drawRetries = 0
	ctx.target = texture
	ctx.targetView = texture:createView({})
	ctx.targetWidth, ctx.targetHeight = ctx.swapchain.width, ctx.swapchain.height

	return true
end

--- Reconfigures a swapchain whose surface changed under it, which is what a resize
--- looks like from here.
---@param ctx wonderland.plugin.Render.Context
function RenderPlugin:resize(ctx)
	local windowCtx = assert(self.windowPlugin:getContext(ctx.window))
	ctx.swapchain = windowCtx.surface:configure(self:getDevice(), { presentMode = self.presentMode }, ctx.swapchain)

	local oldBufferView, oldBuffer = ctx.depthBufferView, ctx.depthBuffer
	ctx.depthBuffer = self:getDevice():createTexture({
		extents = { dim = "2d", width = ctx.swapchain.width, height = ctx.swapchain.height },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" }
	})
	ctx.depthBufferView = ctx.depthBuffer:createView({})

	oldBufferView:destroy()
	oldBuffer:destroy()
end

--- The command buffer a frame is recorded into. A frame that goes into a swapchain is recorded
--- into the swapchain's own, one per image, which is the one that is free: an image is not handed
--- out again until the frame that used it is done, so the recording that goes with it is done
--- too. A frame recorded into a fresh command buffer instead is a pool of them -- the driver's to
--- size, hundreds of kilobytes of it -- for every frame, which is a window that grows by a pool a
--- frame for as long as it is drawn, and a process that runs out of memory for it.
---
--- A screen that is read back rather than shown has no swapchain to take one from, so it records
--- into a command buffer of its own: it is not a frame, and it happens when a screenshot or a
--- test asks for one rather than every frame.
---@param ctx wonderland.plugin.Render.Context
---@return hood.CommandEncoder
function RenderPlugin:frameEncoder(ctx)
	if ctx.swapchain then
		return ctx.swapchain:createCommandEncoder()
	end

	return self:getDevice():createCommandEncoder()
end

---@param ctx wonderland.plugin.Render.Context
---@return boolean drawn # false when there was nothing to draw into
function RenderPlugin:draw(ctx)
	local view, width, height

	if ctx.capture then
		view, width, height = ctx.capture.view, ctx.capture.width, ctx.capture.height
	else
		-- What the frame draws into, taken before the screen was built for it: see `retarget`, which
		-- is what a frame that has not been through it yet is given here.
		if not ctx.target then
			return false
		end

		view, width, height = assert(ctx.targetView), ctx.targetWidth, ctx.targetHeight
	end

	local encoder = self:frameEncoder(ctx)

	self:recordFrame(ctx, encoder, view, width, height)

	if ctx.swapchain then
		self:getDevice().queue:submit(encoder:finish())
		self:getDevice().queue:present(ctx.swapchain)
	else
		self:recordCopy(ctx, encoder)
		self:getDevice().queue:submit(encoder:finish())
	end

	ctx.target, ctx.targetView = nil, nil

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
		local encoder = self:frameEncoder(ctx)

		self:recordFrame(ctx, encoder, capture.view, capture.width, capture.height)
		self:recordCopy(ctx, encoder)
		self:getDevice().queue:submit(encoder:finish())
	end

	local capture = assert(ctx.capture)

	-- The copy has to have finished before the buffer can be read.
	self:getDevice().queue:waitIdle()

	local buffer = capture.buffer
	buffer:mapAsync()
	local raw = ffi.cast(bytePointer, buffer:getMappedRange())
	local pixels = ffi.string(raw, capture.width * capture.height * 4)
	buffer:unmap()

	return pixels
end

--- Writes what the context last drew to a file, in the format its extension names: png, jpg,
--- bmp, tga, qoi and the rest of what the image package writes. It costs a render and a read
--- back, so it is for a screenshot or a test rather than a frame.
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

	-- What was read back is a string, and the encoder takes the buffer a texture is written
	-- from, so it is copied into one rather than handed over: a string is not a pointer, and
	-- the encode happens inside the call below.
	local buffer = ffi.new("uint8_t[?]", #pixels)
	ffi.copy(buffer, pixels, #pixels)

	return image.new(capture.width, capture.height, 4, buffer):save(path)
end

--- Frees what a context holds, and what the contexts shared once the last one goes.
--- Something that makes a screen per test wants this: the shared resources alone hold every
--- picture the app has uploaded.
---@param window wonderland.RenderWindow
function RenderPlugin:destroy(window)
	local ctx = self.contexts[window]
	if not ctx then
		return
	end

	if ctx.capture then
		ctx.capture.view:destroy()
		ctx.capture.texture:destroy()
		ctx.capture.buffer:destroy()
	end

	ctx.depthBufferView:destroy()
	ctx.depthBuffer:destroy()
	ctx.quadVertex:destroy()
	ctx.quadIndex:destroy()
	ctx.quadPipeline:destroy()

	self.contexts[window] = nil

	if self.mainCtx == ctx then
		self.mainCtx = nil
	end

	if next(self.contexts) ~= nil then
		return
	end

	local shared = self.sharedResources
	if shared then
		shared.textureManager:destroy()
		self.sharedResources = nil
	end
end

-- What a render plugin is asked for is nothing: a frame is the ui plugin's -- it is the one that
-- knows what the screen came out to and whether it is worth drawing -- and what the renderer
-- draws with is what the ui handed it. See `wonderland.plugin.UI:frame`.
return RenderPlugin
