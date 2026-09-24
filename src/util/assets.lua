-- Pictures: what `image` decodes from a file, uploaded, and kept by path.
--
--   local logo = self.assets:image("logo.png")
--   div():style(sty():size(logo.width, logo.height):image(logo.texture, logo.uv))
--
-- The decoding is the `image` package's, which reads png, jpeg, gif and the rest of them, and what
-- it decoded is handed to the texture manager, which is where a picture becomes something a style
-- can name. A view function asks for the same picture on every repaint, so what a path came to is
-- remembered and asking for it twice costs a lookup.
--
-- An animation is read a frame at a time rather than the whole of it at once:
--
--   local dance = self.assets:gif("dance.gif")
--   local frame = dance:current()
--   div():style(sty():size(frame.width, frame.height):image(frame.texture, frame.uv))
--
-- A gif of eighty frames of a photograph is eighty frames of decoding and seventy megabytes, which
-- read whole is a fifth of a second before anything is drawn and all of it held from then on. Read
-- a frame at a time, the first frame is on screen in a few milliseconds, the rest are decoded and
-- uploaded as the clock reaches them, and what a screen holds of a gif is the layers a few frames
-- of it cycle through rather than every frame of it.
--
-- Which frame is current is the clock's, and the screen it is drawn on is asked for again when the
-- next one is due. See `wonderland.plugin.UI:tick`, which owns that clock, and `Assets:advance`,
-- which moves them on.
--
-- An animation whose frames come from somewhere other than a file -- a video being decoded, a
-- camera, anything that hands over a picture -- is a stream the app writes into, and everything
-- after the writing is the same: the same ring of layers, the same picture a style names, the same
-- frame the screen is asked for again on.
--
--   local video = self.assets:stream({ width = 1920, height = 1080 })
--
--   self:every(1 / 60, function()          -- see `wonderland.Tick`
--       local decoded = decodeTheNextFrame()
--       if decoded then video:frame(decoded) end
--   end)
--
--   local shown = video:current()
--   div():style(sty():size(shown.width, shown.height):image(shown.texture, shown.uv))
local image = require("image")
local time = require("wonderland.time")

--- One picture, uploaded: how big it is, and the texture a style draws it with.
---@class wonderland.Asset
---@field width number
---@field height number
---@field texture Texture # What a style is handed to draw it with
---@field uv wonderland.UV # And the part of it to draw, which is the whole of a picture

--- A frame of an animation, which is a picture shown for a while.
---@class wonderland.Frame: wonderland.Asset
---@field delay number # How long it is shown for, in seconds, as every time here is

-- The least time a frame is shown for, in seconds. A file that names no delay, or one that names a
-- millisecond, would otherwise be a screen rebuilt as fast as the loop can go.
local MIN_DELAY = 0.02

-- How many frames of an animation are read ahead of being drawn: the layers the frames are read
-- into and cycle through. One would do for an animation drawn as it is played, and the ones past
-- that are room for a screen that draws another frame of its own -- the one before this, a strip
-- of what is coming -- without the layer under it being written over.
local RING = 4

-- What a picture that is the whole of its texture is sampled with. One table, because nothing
-- reads it but a style, which copies the numbers out of it.
local FULL = { u0 = 0, v0 = 0, u1 = 1, v1 = 1 }

--- Where the frames of a stream come from, where it is not the app: something with a frame to
--- hand over and, if it loops, a way back to the first one. What `image` opens a file as is this.
---@class wonderland.FrameSource
---@field next fun(source: any): image.Image?
---@field rewind fun(source: any)?

--- A stream of frames, drawn as the clock reaches them, and which of them is being shown.
---
--- What it holds is what has been shown so far: how many frames a source has, and so how long the
--- whole of it runs for, is not known until it has been played through once.
---@class wonderland.Stream
---@field width number
---@field height number
---@field index number # Which frame is being shown, from one
---@field at number? # When that frame started being shown, on the ui's clock
---@field delay number # How long a frame is shown for where it does not say for itself
---@field single boolean # Whether there turned out to be one frame, which never moves on
---@field shown wonderland.Frame? # The one being drawn, which is what `current` answers with
---@field private source wonderland.FrameSource? # Where the frames come from, for one read as it plays
---@field private textureManager TextureManager
---@field private texture number # The texture of layers the frames are written into
---@field private layers number
---@field private slots wonderland.Frame[] # What a frame is drawn by, made as they come
---@field private count number # How many frames have been shown since the source last started over
---@field private ringed boolean # Whether the frames come from the app rather than from a source
local Stream = {}
Stream.__index = Stream

---@param textureManager TextureManager
---@param opts { width: number, height: number, layers: number?, delay: number?, source: wonderland.FrameSource? }
---@return wonderland.Stream
function Stream.new(textureManager, opts)
	local layers = opts.layers or RING

	---@type wonderland.Stream
	return setmetatable({
		width = opts.width,
		height = opts.height,
		textureManager = textureManager,
		texture = textureManager:uploadLayers(opts.width, opts.height, layers),
		layers = layers,
		source = opts.source,
		ringed = opts.source == nil,
		delay = opts.delay or MIN_DELAY,
		single = false,
		slots = {},
		count = 0,
		index = 1,
	}, Stream)
end

--- The frame that is being shown: how big it is, the picture it is drawn with, and how long it is
--- shown for. Nothing at all until the first frame of a stream the app writes into has been given.
---@return wonderland.Frame?
function Stream:current()
	return self.shown
end

--- When the frame being shown is due to change, on the clock the ui keeps.
---@return number
function Stream:due()
	return (self.at or 0) + (self.shown and self.shown.delay or self.delay)
end

--- Where a frame of the file is drawn from: the layer of the ring its turn came to, named by a
--- slot of its own.
---
--- A slot per frame index rather than per layer is what says a screen changed when the animation
--- moves on: two frames of a gif are drawn out of the same texture, and it is the id a quad names
--- that tells them apart.
---@param index number
---@return wonderland.Frame
function Stream:frameAt(index)
	local known = self.slots[index]

	if known == nil then
		known = {
			width = self.width,
			height = self.height,
			texture = self.textureManager:createSlot(self.width, self.height, self.texture,
				(index - 1) % self.layers),
			uv = FULL,
			delay = 0,
		}

		self.slots[index] = known
	end

	return known
end

--- Puts a frame where it is drawn from: the layer whose turn it is, named by a slot of its own,
--- with the time it is shown for.
---
--- What a frame is written into is a layer of the ring rather than a picture of its own, so the
--- frame being drawn by the gpu is not the one being written over -- which is what makes a stream
--- of frames cost a copy each and no waiting for the display at all.
---@param frame image.Image
---@param delay number? # How long it is shown for, in seconds, where it does not say for itself
---@return wonderland.Frame
function Stream:put(frame, delay)
	self.count = self.count + 1

	-- A stream the app writes into names its slots by the ring, so that a video of any length
	-- costs the layers it cycles through; one read from a file names them by the frame, because
	-- what frame of it is being shown is what it comes back to.
	local index = self.ringed and ((self.count - 1) % self.layers) + 1 or self.count
	local shown = self:frameAt(index)

	self.textureManager:writeLayer(shown.texture, frame)

	-- A gif says how long a frame is shown for in milliseconds and the clock here counts seconds.
	shown.delay = delay or (frame.delay ~= nil and math.max(frame.delay / 1000, MIN_DELAY) or nil)
		or self.delay

	return shown
end

--- A frame the app decoded, shown now: what a video being played is, where the frames come from
--- something other than a file. What it does is put the frame in the ring and make it the one the
--- screen draws -- and the screen is asked for again by whoever drew it, since the clock a decoder
--- keeps is its own: see `wonderland.Tick`.
---@param frame image.Image
---@param delay number? # How long it is shown for, in seconds
---@return wonderland.Frame
function Stream:frame(frame, delay)
	local shown = self:put(frame, delay)
	local now = time.now()

	self.index = self.count
	self.shown = shown
	self.at = now

	return shown
end

--- Reads the frame after the ones already read, which is the frame the animation is at. What is
--- after the last frame of an animation is its first frame again; a file of a single frame has
--- nothing after it at all, which is nothing here.
---@return wonderland.Frame? frame
function Stream:read()
	local frame = assert(self.source):next()

	if frame == nil then
		-- The end of the file. A file of one frame is that frame forever; anything else runs again
		-- from the top, which is what a gif that says nothing about it does.
		if self.count < 2 then
			self.single = true

			return nil
		end

		assert(self.source).rewind(self.source)
		self.count = 0
		frame = self.source:next()

		if frame == nil then
			return nil
		end
	end

	return self:put(frame)
end

--- Moves on to the next frame when this one has been shown for as long as it said, and answers
--- whether it did. A file of one frame stays on it, so nothing is asked for again.
---
--- What it is compared against is the time the frame is due rather than the delay worked out
--- again: a clock is a double, and the difference between two times a tenth of a second apart is
--- not always that tenth -- which is a frame that comes or goes a hair early.
---@param now number # Seconds, on the clock the ui keeps
---@return boolean # Whether the frame a screen draws changed
function Stream:advance(now)
	-- A stream the app writes into is the app's own clock: nothing here moves it on, and what comes
	-- of a frame it gave is the frame it is drawing.
	if self.source == nil then
		return false
	end

	-- A file the clock has not looked at yet starts its time now rather than at nought, which on a
	-- clock counting from some fixed point is a very long time ago: its first frame would go by
	-- before it was ever drawn.
	if self.at == nil then
		self.at = now

		return false
	end

	if now < self:due() then
		return false
	end

	if self.single then
		return false
	end

	local frame = self:read()

	if frame == nil then
		return false
	end

	-- The frame read is the frame the animation is at, counted from the start of the file: a frame
	-- the animation has come back around to is the first one again.
	self.index = self.count
	self.shown = frame
	self.at = now

	return true
end

---@class wonderland.Assets
---@field textureManager TextureManager
---@field images table<string, wonderland.Asset> # What each path came to
---@field streams table<string, wonderland.Stream> # And what each animated file came to
---@field playing wonderland.Stream[] # The ones being played, which the clock is asked about
local Assets = {}
Assets.__index = Assets

---@param textureManager TextureManager
---@return wonderland.Assets
function Assets.new(textureManager)
	return setmetatable({ textureManager = textureManager, images = {}, streams = {}, playing = {} }, Assets)
end

--- Frames that come from somewhere other than a file: a video being decoded, a camera, anything
--- that hands over a picture a frame at a time.
---
---   local video = assets:stream({ width = 1920, height = 1080 })
---   video:frame(decoded)     -- when the decoder has one, and the app asks for a frame
---
--- A stream with a source reads it as the clock reaches each frame, which is what a file is: what
--- it comes to is the same stream, drawn and moved on the same way.
---@param opts { width: number?, height: number?, layers: number?, delay: number?, source: wonderland.FrameSource? }
---@return wonderland.Stream
function Assets:stream(opts)
	local source = opts.source
	local first = nil

	if source ~= nil then
		-- The first frame of a source is read here, and it is the frame the stream starts on as
		-- well as the answer to how large its frames are: reading one to measure it and another
		-- to draw would start an animation on its second frame.
		first = assert(source.next(source), "The stream holds no frames")
	end

	local width = opts.width or (first and first.width)
	local height = opts.height or (first and first.height)

	assert(width and height, "A stream with no source needs the size of its frames")

	---@cast width number
	---@cast height number
	local stream = Stream.new(self.textureManager, {
		width = width,
		height = height,
		layers = opts.layers,
		delay = opts.delay,
		source = source,
	})

	if first ~= nil then
		stream.shown = stream:put(first)

		-- A source is played until the process ends: there is nothing here that pauses one,
		-- because what a screen shows is the app's to say, and it says it by not drawing it.
		self.playing[#self.playing + 1] = stream
	end

	return stream
end

--- One picture, uploaded into a texture of its own. A picture the app drew itself goes through here
--- as well, and is not remembered by anything: what a path came to is, and this is what it came to.
---@param decoded image.Image
---@return wonderland.Asset
function Assets:upload(decoded)
	-- Widened here rather than by the texture, because what the gpu holds is four channels and a
	-- copy of a picture that already has four is a copy nothing needs.
	local source = decoded.channels ~= 4 and decoded:convert(4) or decoded

	return {
		width = source.width,
		height = source.height,
		texture = self.textureManager:upload({
			width = source.width,
			height = source.height,
			channels = 4,
			pixels = source.pixels,
		}),
		uv = FULL,
	}
end

--- A still picture, decoded once and remembered by path. What the bytes are is what decides
--- the format: the extension is only a hint for a file whose bytes say nothing.
---@param path string
---@return wonderland.Asset
function Assets:image(path)
	local known = self.images[path]

	if known then
		return known
	end

	local decoded, err = image.load(path)
	assert(decoded, err)

	local asset = self:upload(decoded)

	-- The texture has the pixels now: the buffer they were decoded into is let go of rather than
	-- kept for the life of the app.
	decoded:close()

	self.images[path] = asset

	return asset
end

--- An animated file, opened and read a frame at a time, remembered by path. What comes back is
--- its first frame, ready to draw, and the rest are read as the clock reaches them.
---
--- A file with one picture in it is an animation of that one frame, which never moves on.
---@param path string
---@return wonderland.Stream
function Assets:gif(path)
	local known = self.streams[path]

	if known then
		return known
	end

	local file, err = image.stream(path)
	assert(file, err)

	---@cast file image.Stream
	local gif = self:stream({ source = file, delay = MIN_DELAY })

	self.streams[path] = gif

	return gif
end

--- Moves every playing stream on to its next frame where that is due, and answers whether any of
--- them is a screen the gpu does not have yet.
---@param now number # Seconds, on the clock the ui keeps
---@return boolean
function Assets:advance(now)
	local changed = false

	for _, stream in ipairs(self.playing) do
		if stream:advance(now) then
			changed = true
		end
	end

	return changed
end

--- When the next frame of a playing stream is due, which is when a loop that waits for its next
--- event has to be woken: nothing, where none of them is playing.
---@return number?
function Assets:due()
	local due = nil

	for _, stream in ipairs(self.playing) do
		-- A file of one frame never moves on, and one the clock has not started has nothing due
		-- yet: the tick that starts it is the one that asks it again.
		if not stream.single and stream.at ~= nil then
			local at = stream:due()

			if due == nil or at < due then
				due = at
			end
		end
	end

	return due
end

return Assets
