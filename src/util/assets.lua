-- Pictures: what `image` decoded from a file, uploaded once, and kept by path.
--
--   local logo = self.assets:image("logo.png")
--   div():style(sty():size(logo.width, logo.height):image(logo.texture, logo.uv))
--
-- The decoding is the `image` package's, which reads png, jpeg, gif and the rest of them, and
-- what it decoded is handed to the texture manager, which is where a picture becomes something
-- a style can name. A view function asks for the same picture on every repaint, so what a path
-- came to is remembered and asking for it twice costs a lookup.
--
-- An animated file -- a gif -- is decoded with every frame of it and played by the delay each
-- frame carries:
--
--   local dance = self.assets:gif("dance.gif")
--   local frame = dance:current()
--   div():style(sty():size(frame.width, frame.height):image(frame.texture, frame.uv))
--
-- Which frame is current is the clock's, and the screen it is drawn on is asked for again when
-- the next one is due. See `wonderland.plugin.UI:tick`, which owns that clock, and
-- `Assets:advance`, which moves them on.
local image = require("image")

--- One picture, uploaded: how big it is, and the texture a style draws it with.
---@class wonderland.Asset
---@field width number
---@field height number
---@field texture Texture # The layer of the texture array it was uploaded into
---@field uv wonderland.UV # The part of that layer it occupies

--- A frame of an animation, which is a picture shown for a while.
---@class wonderland.Frame: wonderland.Asset
---@field delay number # How long it is shown for, in seconds, as every time here is

--- A file with several frames in it, and which of them is being shown.
---@class wonderland.Gif
---@field width number
---@field height number
---@field frames wonderland.Frame[]
---@field duration number # How long the whole of it runs for, in seconds
---@field index number # Which frame is being shown, from one
---@field at number? # When that frame started being shown, on the ui's clock
local Gif = {}
Gif.__index = Gif

--- The frame that is being shown.
---@return wonderland.Frame
function Gif:current()
	return self.frames[self.index]
end

--- When the frame being shown is due to change, on the clock the ui keeps.
---@return number
function Gif:due()
	return (self.at or 0) + self.frames[self.index].delay
end

--- Moves on to the next frame when this one has been shown for as long as it said, and answers
--- whether it did. A gif of one frame stays on it, so nothing is asked for again.
---
--- What it is compared against is the time the frame is due rather than the delay worked out
--- again: a clock is a double, and the difference between two times a tenth of a second apart is
--- not always that tenth -- which is a frame that comes or goes a hair early.
---@param now number # Seconds, on the clock the ui keeps
---@return boolean # Whether the frame a screen draws changed
function Gif:advance(now)
	local count = #self.frames

	if count < 2 then
		return false
	end

	-- A gif the clock has not looked at yet starts its time now rather than at nought, which on a
	-- clock counting from some fixed point is a very long time ago: its first frame would go by
	-- before it was ever drawn.
	if self.at == nil then
		self.at = now

		return false
	end

	if now < self:due() then
		return false
	end

	self.index = self.index % count + 1
	self.at = now

	return true
end

---@class wonderland.Assets
---@field textureManager TextureManager
---@field images table<string, wonderland.Asset> # What each path came to
---@field gifs table<string, wonderland.Gif>
---@field playing wonderland.Gif[] # And the ones being played, which the clock is asked about
local Assets = {}
Assets.__index = Assets

-- The least time a frame is shown for, in seconds. A file that names no delay, or one that
-- names a millisecond, would otherwise be a screen rebuilt as fast as the loop can go.
local MIN_DELAY = 0.02

-- What a picture that is the whole of its texture is sampled with, which is every one of them
-- but a frame of an animation. One table, because nothing reads it but a style, which copies
-- the numbers out of it.
local FULL = { u0 = 0, v0 = 0, u1 = 1, v1 = 1 }

---@param textureManager TextureManager
---@return wonderland.Assets
function Assets.new(textureManager)
	return setmetatable({ textureManager = textureManager, images = {}, gifs = {}, playing = {} }, Assets)
end

--- One picture, uploaded into a layer of its own. A picture the app drew itself goes through here
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

--- Every frame of an animated file, decoded once and remembered by path, ready to be played
--- from its first frame: a file with one picture in it is one frame of gif, which never moves on.
--- It costs the layers the frames are packed into, so a long gif wants a render plugin with more.
---@param path string
---@return wonderland.Gif
function Assets:gif(path)
	local known = self.gifs[path]

	if known then
		return known
	end

	local decoded, err = image.loadFrames(path)
	assert(decoded, err)

	local width, height = decoded.width, decoded.height
	local sources, delays = {}, {}

	for index, frame in ipairs(decoded.frames) do
		-- Every frame of an animation is a view into the one buffer it was decoded into, so a
		-- frame that has to be widened is copied out of it before it is let go of.
		sources[index] = frame.channels ~= 4 and frame:convert(4) or frame
		-- A gif says how long a frame is shown for in milliseconds; the clock the ui keeps
		-- counts seconds, and a frame is timed by it.
		delays[index] = math.max((frame.delay or 0) / 1000, MIN_DELAY)
	end

	local packed = self.textureManager:uploadFrames(sources)

	decoded:close()

	local frames = {}
	local duration = 0

	for index, place in ipairs(packed) do
		frames[index] = {
			width = width,
			height = height,
			texture = place.texture,
			uv = place.uv,
			delay = delays[index],
		}

		duration = duration + delays[index]
	end

	local gif = setmetatable({
		width = width,
		height = height,
		frames = frames,
		duration = duration,
		index = 1,
	}, Gif)

	-- A gif that has been asked for by name is played until the process ends: there is nothing
	-- here that pauses one, because what a screen shows is the app's to say and it says it by
	-- not drawing it.
	self.gifs[path] = gif
	self.playing[#self.playing + 1] = gif

	return gif
end

--- Moves every gif that is playing on to its next frame where that is due, and answers whether
--- any of them is a screen the gpu does not have yet.
---@param now number # Seconds, on the clock the ui keeps
---@return boolean
function Assets:advance(now)
	local changed = false

	for _, gif in ipairs(self.playing) do
		if gif:advance(now) then
			changed = true
		end
	end

	return changed
end

--- When the next frame of a playing gif is due, which is when a loop that waits for its next
--- event has to be woken: nothing, where none of them is playing.
---@return number?
function Assets:due()
	local due = nil

	for _, gif in ipairs(self.playing) do
		-- A gif of one frame never moves on, and one the clock has not started has nothing due
		-- yet: the tick that starts it is the one that asks it again.
		if #gif.frames > 1 and gif.at ~= nil then
			local at = gif:due()

			if due == nil or at < due then
				due = at
			end
		end
	end

	return due
end

return Assets
