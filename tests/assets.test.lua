-- Pictures: what a file decodes to, how it is uploaded, and the clock a gif is played on.
--
-- An asset is a texture, and a texture needs a device, so this file is skipped where there is no
-- gpu, the way the headless tests are. What is checked here is what an asset is; what a picture
-- comes out as on screen is checked there, where there is a screen to look at.
local test = require("lde-test")
local image = require("image")
local wonderland = require("wonderland")

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

test.skipIf(not canUpload)("comes back with every frame of a gif, and the time each is shown for", function()
	local screen = aScreen()
	local dance = screen.assets:gif(SPINNER)

	test.equal(dance.width, 4)
	test.equal(dance.height, 4)
	test.equal(#dance.frames, 3, "the gif is three frames")
	test.equal(dance.frames[1].delay, 0.1, "a tenth of a second each")
	test.equal(dance.frames[2].delay, 0.1)
	test.equal(dance.frames[3].delay, 0.2)
	test.equal(dance.duration, 0.4, "and it runs for four tenths of a second")
	test.equal(dance:current(), dance.frames[1], "it starts on its first frame")

	screen:close()
end)

test.skipIf(not canUpload)("packs the frames of an animation into the layers they fit", function()
	local screen = aScreen()
	local manager = texturesOf(screen)
	local frames = {}

	-- Frames nothing decoded: what is packed is a shape, and a gif is one way to get one.
	for index = 1, 25 do
		local frame = image.new(200, 100, 4)

		frame:fill(index, 0, 0, 255)
		frames[index] = frame
	end

	local packed = manager:uploadFrames(frames)
	local layers, perLayer = {}, {}

	for _, place in ipairs(packed) do
		test.equal(place.uv.v1 - place.uv.v0, 100 / 512, "a frame is as tall as the picture")
		test.truthy(place.uv.u0 >= 0 and place.uv.u1 <= 1, "and inside the layer it was put in")

		layers[place.texture] = true
		perLayer[place.texture] = (perLayer[place.texture] or 0) + 1
	end

	test.equal(test.count(layers), 3, "twenty five frames of 200 by 100 fit three layers deep")
	test.equal(perLayer[packed[1].texture], 10, "ten to a layer")
	test.equal(perLayer[packed[11].texture], 10, "and ten to the next")
	test.equal(perLayer[packed[21].texture], 5, "and what is left of them to the last")

	test.equal(packed[10].texture, packed[1].texture, "the tenth is still in the first layer")
	test.notEqual(packed[11].texture, packed[10].texture, "and the eleventh starts the next one")
	test.notEqual(packed[2].uv.u0, packed[1].uv.u0, "frames beside each other are not on top of each other")
	test.equal(packed[2].uv.u0, packed[1].uv.u1 + 1 / 512, "with a pixel between them to spare")

	screen:close()
end)

test.skipIf(not canUpload)("shares one layer between the frames of a gif, each its own part of it", function()
	local screen = aScreen()
	local dance = screen.assets:gif(SPINNER)

	test.equal(dance.frames[2].texture, dance.frames[1].texture, "three small frames are one layer")
	test.equal(dance.frames[3].texture, dance.frames[1].texture)
	test.equal(dance.frames[1].uv.u0, 0, "the first is at the start of it")
	test.equal(dance.frames[1].uv.u1 - dance.frames[1].uv.u0, 4 / 512, "a frame wide, no more")
	test.notEqual(dance.frames[2].uv.u0, dance.frames[1].uv.u1,
		"and the next is a gutter further on, so nothing of one is in the other")

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
	test.truthy(nearTime(assets:due(), start + 0.1), "the first frame is due a tenth of a second later")

	test.falsy(assets:advance(start + 0.05), "half a frame in, it is still the first one")
	test.equal(dance.index, 1)

	test.truthy(assets:advance(assert(assets:due())), "what is due is shown for as long as it said")
	test.equal(dance.index, 2)

	test.falsy(assets:advance(assert(assets:due()) - 0.05), "and the next one is not, a moment sooner")
	test.equal(dance.index, 2)

	test.truthy(assets:advance(assert(assets:due())))
	test.equal(dance.index, 3)
	test.truthy(nearTime(assets:due(), start + 0.4), "the third frame is shown for two tenths")

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
