-- The header of a font file: what family it belongs to, and at what weight and slant it is set.
--
--   local sfnt = require("wonderland.font.sfnt")
--   local names = sfnt.names(reader, 0) -- { family = "DejaVu Sans", subfamily = "Bold", ... }
--
-- A machine with a desktop on it has a few hundred font files and an app that names a family
-- wants the one file that is it. What a file is called is in its header: the `name` table holds
-- the name in every language and for every platform the font was made for, and `OS/2` says how
-- heavy it is and whether it is slanted. A font is megabytes of outlines behind a two-kilobyte
-- header, so reading a file whole to learn its family is a hundred megabytes of reading to learn
-- what the first kilobyte held.
--
-- Every number in an sfnt is big endian and the tables are not beside each other, so what is
-- wanted is taken out of the bytes rather than off a cast. The tables are reached through a
-- reader rather than a string, for the same reason one step down: the caller hands one that
-- seeks, the two or three slices that answer the question are read, and nothing else is touched.
--
-- A file that cannot be parsed answers nothing rather than raising: a machine's font directory
-- holds whatever has been put in it, and one file that is not a font is a font that is not
-- indexed.
local sfnt = {}

--- Where the bytes of a font file are read from: this many bytes at this offset, or nothing where
--- the file ends before them.
---@alias wonderland.font.Reader fun(offset: number, length: number): string?

--- What a font file says about itself.
---@class wonderland.font.Names
---@field family string # The typographic family where there is one, which is the name to ask for
---@field subfamily string
---@field weight number # As CSS counts it: 100 to 900
---@field italic boolean # Whether it is the slanted member of its family

-- What a font file starts with. TrueType and its older spelling, PostScript outlines under a
-- CFF table, and Apple's Type 1 in an sfnt wrapper.
local MAGIC = {
	["\0\1\0\0"] = true,
	["true"] = true,
	["OTTO"] = true,
	["typ1"] = true,
}

-- No font has anywhere near this many tables, and a table this large is not one. Both are there
-- so that a directory which has been read wrong cannot ask for a slice the size of the file.
local MAX_TABLES = 512
local MAX_TABLE = 1 << 20

--- A whole number of two bytes, big endian. Nothing in a font header is little endian, which is
--- what makes reading the bytes out better than casting a pointer at them: a cast would read the
--- right number on one machine and a wrong one on another.
---@param data string
---@param at number # Where it starts, counting from one
---@return number
local function u16(data, at)
	local high, low = data:byte(at, at + 1)

	if high == nil or low == nil then
		return 0
	end

	return (high << 8) | low
end

---@param data string
---@param at number
---@return number
local function u32(data, at)
	local a, b, c, d = data:byte(at, at + 3)

	if d == nil then
		return 0
	end

	return (a << 24) | (b << 16) | (c << 8) | d
end

--- A code point as the bytes UTF-8 writes it in.
---@param code number
---@return string
local function utf8(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
	elseif code < 0x10000 then
		return string.char(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
	end

	return string.char(
		0xF0 | (code >> 18),
		0x80 | ((code >> 12) & 0x3F),
		0x80 | ((code >> 6) & 0x3F),
		0x80 | (code & 0x3F)
	)
end

--- A UTF-16 big endian string as UTF-8, which is what a Windows name record holds and what the
--- rest of the library reads. A character past the basic plane is two units -- a high one and a
--- low one -- and a high one with nothing after it is a name that has been cut in half, which is
--- left as the character it says it is rather than dropped.
---@param data string
---@return string
local function utf16beToUtf8(data)
	local out, at = {}, 1

	while at + 1 <= #data do
		local code = (data:byte(at) << 8) | data:byte(at + 1)

		at += 2

		if code >= 0xD800 and code <= 0xDBFF and at + 1 <= #data then
			local low = (data:byte(at) << 8) | data:byte(at + 1)

			if low >= 0xDC00 and low <= 0xDFFF then
				code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
				at += 2
			end
		end

		out[#out + 1] = utf8(code)
	end

	return table.concat(out)
end

--- How much a name record is worth believing. A font holds its name once per platform and once per
--- language, and the records disagree: the Windows ones carry the name a modern app asks for,
--- while a Mac record often keeps the name the font had before it was renamed -- "Helvetica Neue
--- Bold" where the Windows record says the family is "Helvetica Neue". English is preferred within
--- a platform because a family name is the same word in every language, and a localized one is
--- the same family under a name nothing else calls it.
---@param platform number
---@param encoding number
---@param language number
---@return number
local function scoreOf(platform, encoding, language)
	if platform == 3 and encoding == 1 then
		return language == 0x409 and 6 or 5
	elseif platform == 3 and encoding == 10 then
		return 4
	elseif platform == 0 then
		return 3
	elseif platform == 1 and encoding == 0 then
		return 2
	end

	return 0
end

--- One name out of a `name` table, by the number that names it. The typographic numbers are asked
--- for before the family ones because a family with more weights than the family name can hold --
--- "Inter Light", "Inter SemiBold" -- is one typographic family whose family name is the one a
--- stylesheet writes: "Inter".
---@param table string
---@param wanted number
---@return string?
local function nameRecord(table, wanted)
	local count = u16(table, 3)
	local storage = u16(table, 5) + 1
	local best, bestScore = nil, 0

	for index = 0, count - 1 do
		local at = index * 12 + 7
		local platform, encoding, language = u16(table, at), u16(table, at + 2), u16(table, at + 4)
		local score = u16(table, at + 6) == wanted and scoreOf(platform, encoding, language) or 0

		if score > bestScore then
			local length, offset = u16(table, at + 8), u16(table, at + 10)
			local from = storage + offset
			local to = from + length - 1

			-- A record that points past the table it is in is a table that has been read wrong:
			-- the name is skipped rather than taken from whatever follows.
			if length > 0 and to <= #table then
				local text = table:sub(from, to)

				-- A Mac record is bytes in the Mac's own encoding, which for a family name is
				-- ASCII: the letters past it are accents, and a family named with one is a family
				-- whose name is looked up by the letters anyway.
				if platform ~= 1 then
					text = utf16beToUtf8(text)
				end

				-- A few fonts pad a name out with a nought, which is not part of it.
				text = text:gsub("%z", "")

				if text ~= "" then
					best, bestScore = text, score
				end
			end
		end
	end

	return best
end

--- What the font at an offset says about itself, or nothing where there is no font there. The
--- offset is nought for a font file and the start of a font inside a collection for one that is
--- in a `.ttc`.
---@param reader wonderland.font.Reader
---@param offset number
---@return wonderland.font.Names?
function sfnt.names(reader, offset)
	local header = reader(offset, 12)

	if header == nil or #header < 12 or MAGIC[header:sub(1, 4)] == nil then
		return nil
	end

	local tables = u16(header, 5)

	if tables == 0 or tables > MAX_TABLES then
		return nil
	end

	-- The table directory: one record per table, a tag and where the table is in the file. It is
	-- the whole of what the file has to say about its own layout, and it is read in one slice.
	local directory = reader(offset + 12, tables * 16)

	if directory == nil or #directory < tables * 16 then
		return nil
	end

	local nameAt, nameLength, os2At, headAt = nil, nil, nil, nil

	for index = 0, tables - 1 do
		local at = index * 16 + 1
		local tag = directory:sub(at, at + 3)

		if tag == "name" then
			nameAt, nameLength = u32(directory, at + 8), u32(directory, at + 12)
		elseif tag == "OS/2" then
			os2At = u32(directory, at + 8)
		elseif tag == "head" then
			headAt = u32(directory, at + 8)
		end
	end

	-- A file with no name table is a file no family name leads to, and one whose name table
	-- claims to be larger than any name table is a directory with nothing to believe in it.
	if nameAt == nil or nameLength == 0 or nameLength > MAX_TABLE then
		return nil
	end

	-- Every offset in a font counts from the start of that font, which is the start of the file for
	-- a file that holds one font and the first byte of the font inside a collection for a `.ttc`.
	local table = reader(offset + nameAt, nameLength)

	if table == nil or #table < 6 then
		return nil
	end

	local family = nameRecord(table, 16) or nameRecord(table, 1)

	if family == nil then
		return nil
	end

	local weight = 400
	local italic = false

	if os2At ~= nil then
		-- usWeightClass is at four bytes in and fsSelection at sixty-two, and the table is under
		-- a hundred bytes: it is read in one slice rather than sought into twice. A table shorter
		-- than that read is an old or a broken one, and the file's weight is then unknown.
		local metrics = reader(offset + os2At, 64)

		if metrics ~= nil and #metrics >= 64 then
			local selection = u16(metrics, 63)

			-- Bit nought is italic and bit nine is oblique, which is what a request for italic
			-- is answered with on a family that has no italic face: a slanted face under either
			-- name is the one an app asking for italic means.
			weight = u16(metrics, 5)
			italic = (selection & 1) ~= 0 or (selection & 0x200) ~= 0
		end
	end

	if not italic and headAt ~= nil then
		-- macStyle is at forty-four bytes in. It is consulted where `OS/2` said upright or was not
		-- there at all, because a Mac-made font slants its italic in that flag and never had an
		-- `OS/2` table to say otherwise.
		local head = reader(offset + headAt, 46)

		if head ~= nil and #head >= 46 then
			italic = (u16(head, 45) & 2) ~= 0
		end
	end

	-- A usWeightClass outside the range CSS uses is a font that says nothing about its weight
	-- rather than one that is lighter than everything.
	if weight < 100 or weight > 900 then
		weight = 400
	end

	return {
		family = family,
		subfamily = nameRecord(table, 17) or nameRecord(table, 2) or "",
		weight = weight,
		italic = italic,
	}
end

--- Whether a file is a collection of fonts rather than one font: several faces in one file, which
--- is what a machine ships where the same outlines are set at four weights.
---@param reader wonderland.font.Reader
---@return boolean
function sfnt.isCollection(reader)
	local tag = reader(0, 4)

	return tag ~= nil and tag == "ttcf"
end

--- Where each font in a file starts, in the order the file names them, which is the index a face
--- inside a collection is asked for by. A file that is one font answers with that one font, and
--- one that is not a font at all answers nothing.
---@param reader wonderland.font.Reader
---@return number[]?
function sfnt.offsets(reader)
	local header = reader(0, 12)

	if header == nil or #header < 12 then
		return nil
	end

	if header:sub(1, 4) ~= "ttcf" then
		return MAGIC[header:sub(1, 4)] ~= nil and { 0 } or nil
	end

	local count = u32(header, 9)

	if count == 0 or count > MAX_TABLES then
		return nil
	end

	local table = reader(12, count * 4)

	if table == nil or #table < count * 4 then
		return nil
	end

	local offsets = {}

	for index = 0, count - 1 do
		offsets[index + 1] = u32(table, index * 4 + 1)
	end

	return offsets
end

return sfnt
