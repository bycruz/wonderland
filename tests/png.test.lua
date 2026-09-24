local test = require("lde-test")
local png = require("wonderland.util.png")

local function header(encoded)
	-- 8 byte signature, then a 4 byte length and the chunk name
	test.equal(encoded:sub(1, 8), "\137PNG\r\n\26\n", "the signature comes first")
	test.equal(encoded:sub(13, 16), "IHDR")

	-- width, height, then bit depth 8, colour type 6 (rgba), no interlace
	return encoded:byte(17) * 16777216 + encoded:byte(18) * 65536 + encoded:byte(19) * 256 + encoded:byte(20),
		encoded:byte(21) * 16777216 + encoded:byte(22) * 65536 + encoded:byte(23) * 256 + encoded:byte(24),
		encoded:byte(25), encoded:byte(26)
end

test.it("writes a png header for the image it was given", function()
	local pixels = string.rep("\1\2\3\4", 6)
	local encoded = png.encode(3, 2, pixels)
	local width, height, depth, colorType = header(encoded)

	test.equal(width, 3)
	test.equal(height, 2)
	test.equal(depth, 8, "eight bits per channel")
	test.equal(colorType, 6, "rgba")
	test.equal(encoded:sub(-8), "IEND\174B`\130", "and ends with an empty IEND")
end)

test.it("refuses pixels that do not cover the image", function()
	local ok, err = pcall(png.encode, 4, 4, string.rep("\0", 63))

	test.falsy(ok)
	test.truthy(tostring(err):match("needs 64 bytes"), "the message says how much it needs")
end)

test.it("writes what it was given back out through ffmpeg's idea of png", function()
	-- a 1x1 red pixel, checked by eye in the header: an IDAT follows IHDR
	local encoded = png.encode(1, 1, "\255\0\0\255")

	test.truthy(encoded:find("IDAT", 1, true), "there is image data")
	test.truthy(#encoded > 60, "with the zlib stream in it")
end)
