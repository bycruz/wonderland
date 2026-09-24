-- Reading UTF-8, one character at a time.
--
-- A string in Lua is bytes, and a character in one is one to four of them: everything here that
-- counts characters, places glyphs or fits a line into a box asks this where a character starts
-- and what it is. It is a module of its own because the atlas packs a glyph by codepoint and the
-- font measures a line by them, and neither should own the other's reading of a string.
local utf8 = {}

--- One character of a string, and where the one after it starts.
---
--- A byte that starts nothing -- a stray continuation byte, or a sequence the string ends in the
--- middle of -- is read as the character that says so, and takes one byte with it: a string that
--- is not text costs one glyph a byte and not the rest of the line, and where the next character
--- starts is never lost.
---@param text string
---@param at number # Which byte to read from, from one
---@return number codepoint
---@return number after # One past the last byte of it
function utf8.decode(text, at)
	local first = text:byte(at)

	if first == nil then
		return 0xFFFD, at + 1
	end

	if first < 0x80 then
		return first, at + 1
	end

	local count, codepoint

	if first >= 0xF0 then
		count, codepoint = 3, first % 0x08
	elseif first >= 0xE0 then
		count, codepoint = 2, first % 0x10
	elseif first >= 0xC0 then
		count, codepoint = 1, first % 0x20
	else
		return 0xFFFD, at + 1
	end

	for step = 1, count do
		local byte = text:byte(at + step)

		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			return 0xFFFD, at + 1
		end

		codepoint = codepoint * 0x40 + byte % 0x40
	end

	return codepoint, at + count + 1
end

--- The character a string holds, as the one codepoint it is: what a caller that named a
--- character rather than a codepoint is asking about.
---@param char string
---@return number codepoint
---@return number after
function utf8.one(char)
	return utf8.decode(char, 1)
end

return utf8
