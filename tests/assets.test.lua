-- Pictures: what a file decodes to, how it is uploaded, and the clock a gif is played on.
--
-- An asset is a texture, and a texture needs a device, so this file is skipped where there is no
-- gpu, the way the headless tests are. What is checked here is what an asset is; what a picture
-- comes out as on screen is checked there, where there is a screen to look at.
local ffi = require("ffi")
local test = require("lde-test")
local image = require("image")
local wonderland = require("wonderland")
local TextureManager = require("wonderland.util.texture_manager")

local div, sty = wonderland.div, wonderland.sty

-- The two fixtures are found beside this file rather than by the working directory a test is run
-- from, which is the project's own.
local HERE = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".")

-- Three frames of four pixels, one colour each, shown for a tenth, a tenth and two tenths of a
-- second. It is written by ImageMagick, which is not the encoder that reads it back:
--
--   magick -delay 10 -size 4x4 xc:'#ff0000' -delay 10 -size 4x4 xc:'#00ff00' \
--     -delay 20 -size 4x4 xc:'#0000ff' -loop 0 spinner.gif
local SPINNER = HERE .. "/fixtures/spinner.gif"

-- Making a screen is what needs a gpu, and a build machine may not have one: rather than fail
-- there, say why and skip.
local gpuErr = nil

do
	local ok, err = pcall(function()
		wonderland.headless.new(function() return div() end, { width = 8, height = 8 }):close()
	end)

	if not ok then
		gpuErr = tostring(err)
		print("asset tests skipped: " .. gpuErr)
	end
end

local canUpload = gpuErr == nil

--- A screen to upload pictures through. What is drawn in it is nothing: these tests are about
--- what a picture is, and a device is all one needs.
---@return wonderland.Headless
local function aScreen()
	return wonderland.headless.new(function() return div() end, { width = 8, height = 8 })
end

--- A picture of one colour, written where the asset manager can read it back. A png is written
--- by the same package that reads it, which is what makes every format but a gif a fixture
--- nothing has to carry.
---@param width number
---@param height number
---@param channels number
---@param color number[]
---@param extension string
---@return string path
local function written(width, height, channels, color, extension)
	local path = os.tmpname() .. "." .. extension
	local picture = image.new(width, height, channels)

	picture:fill(color[1], color[2], color[3], color[4])
	assert(picture:save(path))

	return path
end

--- A frame the app decoded itself, which is what a video is: pixels in the shape the texture
--- manager takes, with no file behind them.
---@param width number
---@param height number
---@param level number
---@return image.Image
local function decoded(width, height, level)
	local pixels = ffi.new("uint8_t[?]", width * height * 4)

	for at = 0, width * height - 1 do
		pixels[at * 4] = level
		pixels[at * 4 + 3] = 255
	end

	---@type any
	return { width = width, height = height, channels = 4, pixels = pixels }
end

---@param screen wonderland.Headless
---@return TextureManager
local function texturesOf(screen)
	return assert(screen.plugins.render.sharedResources).textureManager
end

--- A time is a double, and two tenths added to a clock twice is not the same double as four
--- tenths added to it once: what a delay comes to is compared near enough to read.
---@param actual number?
---@param expected number
---@return boolean
local function nearTime(actual, expected)
	return actual ~= nil and math.abs(actual - expected) < 1e-9
end

test.skipIf(not canUpload)("decodes a picture and uploads it, whatever the file held", function()
	local screen = aScreen()

	-- Three channels: a colour with no alpha in it, which is what a texture cannot hold.
	local path = written(3, 2, 3, { 10, 20, 30, 255 }, "png")
	local logo = screen.assets:image(path)
	local width, height = texturesOf(screen):getSize(logo.texture)

	test.equal(logo.width, 3)
	test.equal(logo.height, 2)
	test.equal(width, 3, "it is a texture of its own size")
	test.equal(height, 2)
	test.equal(logo.uv.u0, 0, "and a picture is the whole of it")
	test.equal(logo.uv.v0, 0)
	test.equal(logo.uv.u1, 1)
	test.equal(logo.uv.v1, 1)

	screen:close()
	os.remove(path)
end)

test.skipIf(not canUpload)("uploads a picture at its own size, whatever that size is", function()
	local screen = aScreen()
	local manager = texturesOf(screen)

	-- Two sizes that no one size could be: one past what a texture array would have held, and one
	-- that is nothing beside it. Both are textures of their own size, and neither made room for
	-- the other.
	local wide = written(640, 360, 4, { 10, 20, 30, 255 }, "png")
	local tall = written(3, 700, 4, { 40, 50, 60, 255 }, "png")

	local picture = screen.assets:image(wide)
	local strip = screen.assets:image(tall)

	local width, height = manager:getSize(picture.texture)
	test.equal(width, 640, "a picture is uploaded as the size it is")
	test.equal(height, 360)
	test.equal(picture.width, 640, "and is drawn at it")
	test.equal(picture.height, 360)

	local stripWidth, stripHeight = manager:getSize(strip.texture)
	test.equal(stripWidth, 3, "one that is almost nothing is almost nothing")
	test.equal(stripHeight, 700)

	-- What is held is the white texture, the one that says a texture id was not one, and these
	-- two: nothing is allocated ahead of the pictures an app asks for, and neither picture made
	-- room for the other.
	test.equal(manager.textureCount, 4, "and nothing was made room for before either of them")

	screen:close()
	os.remove(wide)
	os.remove(tall)
end)

test.skipIf(not canUpload)("decodes a path once, however often a view asks for it", function()
	local screen = aScreen()
	local path = written(2, 2, 4, { 255, 0, 0, 255 }, "png")
	local manager = texturesOf(screen)
	local before = manager.textureCount

	local first = screen.assets:image(path)
	local second = screen.assets:image(path)

	test.equal(second, first, "the second ask is the first picture")
	test.equal(manager.textureCount, before + 1, "and nothing was uploaded for it")

	screen:close()
	os.remove(path)
end)

test.skipIf(not canUpload)("says what it could not read, naming the file", function()
	local screen = aScreen()
	local path = os.tmpname() .. ".png"
	local file = assert(io.open(path, "wb"))

	file:write("this is not a png, whatever it says")
	file:close()

	local ok, err = pcall(function() screen.assets:image(path) end)
	test.falsy(ok, "a file nothing can decode is refused")

	local missing, missingErr = pcall(function() screen.assets:image(path .. ".gone") end)
	test.falsy(missing)
	test.includes(tostring(missingErr), path .. ".gone", "and one that is not there names itself")

	screen:close()
	os.remove(path)
end)

test.skipIf(not canUpload)("shows a frame the app decoded, and cycles the pictures it is drawn from", function()
	local screen = aScreen()
	local video = screen.assets:stream({ width = 4, height = 4, layers = 3 })

	test.equal(video:current(), nil, "nothing is shown until the app gives it a frame")

	local first = video:frame(decoded(4, 4, 10), 0.5)

	test.equal(video:current(), first, "the frame the app gave is the one drawn")
	test.equal(first.width, 4, "as large as the stream was made")
	test.equal(first.delay, 0.5, "and shown for as long as the app said")

	local second = video:frame(decoded(4, 4, 20))
	local third = video:frame(decoded(4, 4, 30))
	local fourth = video:frame(decoded(4, 4, 40))

	test.truthy(first.texture ~= second.texture, "a frame is not the picture the one before it was in")
	test.truthy(second.texture ~= third.texture)
	test.truthy(fourth.texture == first.texture, "and a stream of any length cycles the layers it has")
	test.equal(#video.slots, 3, "so what it costs is the layers, and not the frames shown in them")
	test.falsy(video:advance(100), "nothing here moves a stream on: the app's clock is its own")

	screen:close()
end)

test.skipIf(not canUpload)("reads a gif a frame at a time, and comes back with the first of them", function()
	local screen = aScreen()
	local dance = screen.assets:gif(SPINNER)

	test.equal(dance.width, 4, "the size of the file is the size of its frames")
	test.equal(dance.height, 4)
	test.equal(dance.index, 1, "it starts on its first frame")
	test.equal(dance:current().delay, 0.1, "which the file says is a tenth of a second")

	screen:close()
end)

test.skipIf(not canUpload)("uploads a picture in bands, so that one upload is never the picture", function()
	local screen = aScreen()

	-- A budget a picture this size does not fit in, so that what is being checked -- a picture
	-- uploaded in pieces and read as one -- is something a small picture can show.
	local manager = TextureManager.new(texturesOf(screen).device, { uploadPixels = 10240 })
	local path = written(200, 100, 4, { 10, 20, 30, 255 }, "png")
	local picture = manager:upload(assert(image.load(path)))

	test.equal(manager:getSize(picture), 200, "a picture is still the size it was uploaded at")
	local slot = manager.slots[picture]

	test.equal(slot.base, 0, "its first band is the first layer of its texture")
	test.equal(slot.scale, 2, "a picture of a hundred rows is two of the fifty a band holds")
	test.equal(slot.last, 1, "and reaches the second layer of it")
	test.equal(manager.textures[slot.texture].layers, 2, "which is what the texture was made with")

	os.remove(path)
	manager:destroy()
	screen:close()
end)

test.skipIf(not canUpload)("holds the frames of an animation in the layers they cycle through", function()
	local screen = aScreen()
	local manager = texturesOf(screen)
	local before = manager.textureCount
	local dance = screen.assets:gif(SPINNER)

	-- Every frame of the file that the clock has reached is drawn by an id of its own, and the
	-- ones after the first few name a layer that a frame before them did: what is held is the
	-- layers, not a layer a frame.
	test.equal(manager.slots[dance:current().texture].base, 0,
		"the frame the file came back with is the first layer")

	local layers = {}

	for index = 1, 4 do
		local frame = dance:read()

		if frame == nil then
			break
		end

		layers[index] = manager.slots[frame.texture].base
	end

	test.equal(layers[1], 1, "the next frame of the file is the next layer")
	test.equal(layers[2], 2)
	test.equal(layers[3], 0, "and the file starting again is the first layer once more")
	test.equal(layers[4], 1)

	test.equal(manager.textureCount, before + 1, "and the whole animation is one texture of layers")
	test.equal(manager.textures[manager.slots[dance:current().texture].texture].layers, 4)

	screen:close()
end)

test.skipIf(not canUpload)("plays a gif by the delays its frames came with", function()
	local screen = aScreen()
	local assets = screen.assets
	local dance = assets:gif(SPINNER)

	-- The clock is the caller's: `wonderland.plugin.UI:tick` is what keeps a real one, and the
	-- arithmetic it does is the arithmetic this checks.
	local start = 1000

	test.falsy(assets:advance(start), "the first look at a gif starts its clock and nothing else")
	test.equal(dance.index, 1)
	test.equal(dance:current().delay, 0.1, "and the frame it is on is the one the file started with")
	test.truthy(nearTime(assets:due(), start + 0.1), "the first frame is due a tenth of a second later")

	test.falsy(assets:advance(start + 0.05), "half a frame in, it is still the first one")
	test.equal(dance.index, 1)

	test.truthy(assets:advance(assert(assets:due())), "what is due is shown for as long as it said")
	test.equal(dance.index, 2)

	test.falsy(assets:advance(assert(assets:due()) - 0.05), "and the next one is not, a moment sooner")
	test.equal(dance.index, 2)

	test.truthy(assets:advance(assert(assets:due())))
	test.equal(dance.index, 3)
	test.equal(dance:current().delay, 0.2, "the third frame is shown for two tenths")
	test.truthy(nearTime(assets:due(), start + 0.4), "which is when the next one is due")

	test.falsy(assets:advance(start + 0.3), "which is not over yet")
	test.equal(dance.index, 3)

	test.truthy(assets:advance(assert(assets:due())))
	test.equal(dance.index, 1, "and then it starts again")

	screen:close()
end)

test.skipIf(not canUpload)("asks for nothing while no gif is playing", function()
	local screen = aScreen()

	test.equal(screen.assets:due(), nil, "nothing is due")
	test.falsy(screen.assets:advance(1000), "and nothing has anything to do")

	screen:close()
end)

test.skipIf(not canUpload)("writes a screenshot in the format its extension names", function()
	local screen = wonderland.headless.new(function()
		return div():style(sty():fill():bg("#204060"))
	end, { width = 4, height = 4 })

	screen:draw()

	local path = os.tmpname() .. ".png"
	test.truthy(screen:save(path), "the png was written")

	local shot = assert(image.load(path))
	test.equal(shot.format and shot.format.name, "PNG")
	test.equal(shot.width, 4)
	test.equal(shot.height, 4)

	local r, g, b = shot:getPixel(2, 2)
	test.equal(r, 32, "the colour it was drawn in")
	test.equal(g, 64)
	test.equal(b, 96)

	-- The same screen again as a jpeg, which is a lossy format: the colour is near enough, and
	-- what is being checked is that the extension is what says the format.
	local jpeg = os.tmpname() .. ".jpg"
	test.truthy(screen:save(jpeg))

	local compressed = assert(image.load(jpeg))
	test.equal(compressed.format and compressed.format.name, "JPEG")
	test.equal(compressed.width, 4)
	test.equal(compressed.height, 4)

	local jr, jg, jb = compressed:getPixel(2, 2)
	test.less(math.abs(jr - 32), 16, "the red is still the red it was drawn in")
	test.less(math.abs(jg - 64), 16)
	test.less(math.abs(jb - 96), 16)

	screen:close()
	os.remove(path)
	os.remove(jpeg)
end)
