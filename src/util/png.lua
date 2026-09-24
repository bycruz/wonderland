-- A PNG writer, enough for a screenshot: 8-bit RGBA, no interlacing, and deflate
-- "stored" blocks so there is no zlib to depend on. A screenshot is written once
-- rather than streamed, so the bytes a real compressor saves do not matter.
local bit = require("bit")

local png = {}

local SIGNATURE = "\137PNG\r\n\26\n"
local MAX_STORED = 65535

local crcTable = {}

for index = 0, 255 do
	local value = index

	for _ = 1, 8 do
		if bit.band(value, 1) == 1 then
			value = bit.bxor(0xEDB88320, bit.rshift(value, 1))
		else
			value = bit.rshift(value, 1)
		end
	end

	crcTable[index] = value
end

---@param data string
---@return number
local function crc32(data)
	local crc = 0xFFFFFFFF

	for index = 1, #data do
		local byte = data:byte(index)
		crc = bit.bxor(bit.rshift(crc, 8), crcTable[bit.band(bit.bxor(crc, byte), 0xFF)])
	end

	return bit.band(bit.bnot(crc), 0xFFFFFFFF)
end

---@param data string
---@return number
local function adler32(data)
	local low, high = 1, 0

	for index = 1, #data do
		low = (low + data:byte(index)) % 65521
		high = (high + low) % 65521
	end

	return high * 65536 + low
end

---@param value number
---@return string
local function u32(value)
	return string.char(
		bit.band(bit.rshift(value, 24), 0xFF),
		bit.band(bit.rshift(value, 16), 0xFF),
		bit.band(bit.rshift(value, 8), 0xFF),
		bit.band(value, 0xFF)
	)
end

---@param value number
---@return string
local function u16(value)
	return string.char(bit.band(value, 0xFF), bit.band(bit.rshift(value, 8), 0xFF))
end

---@param kind string
---@param body string
---@return string
local function chunk(kind, body)
	local payload = kind .. body

	return u32(#body) .. payload .. u32(crc32(payload))
end

--- A zlib stream holding the data in stored deflate blocks.
---@param data string
---@return string
local function zlibStored(data)
	local parts = { "\120\001" }
	local offset = 1

	while offset <= #data do
		local size = math.min(MAX_STORED, #data - offset + 1)
		local isLast = offset + size > #data

		-- The block header is a final bit and a "stored" type, then a length and its
		-- complement, both little endian.
		parts[#parts + 1] = string.char(isLast and 1 or 0) .. u16(size) .. u16(bit.bnot(size))
		parts[#parts + 1] = data:sub(offset, offset + size - 1)
		offset = offset + size
	end

	parts[#parts + 1] = u32(adler32(data))

	return table.concat(parts)
end

--- Encodes 8-bit RGBA pixels, top row first.
---@param width number
---@param height number
---@param pixels string # width * height * 4 bytes
---@return string
function png.encode(width, height, pixels)
	local stride = width * 4
	local expected = stride * height

	assert(#pixels >= expected, string.format("png: an image that size needs %d bytes of pixels, got %d", expected, #pixels))

	-- Every scanline carries a filter byte, and filter 0 is "no filter".
	local rows = {}
	for row = 0, height - 1 do
		rows[#rows + 1] = "\0" .. pixels:sub(row * stride + 1, (row + 1) * stride)
	end

	local header = u32(width) .. u32(height) .. string.char(8, 6, 0, 0, 0)

	return SIGNATURE
		.. chunk("IHDR", header)
		.. chunk("IDAT", zlibStored(table.concat(rows)))
		.. chunk("IEND", "")
end

---@param path string
---@param width number
---@param height number
---@param pixels string
---@return boolean? ok
---@return string? err
function png.write(path, width, height, pixels)
	local file, err = io.open(path, "wb")
	if not file then
		return nil, "Could not open " .. path .. ": " .. tostring(err)
	end

	file:write(png.encode(width, height, pixels))
	file:close()

	return true
end

return png
