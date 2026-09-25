-- Reading UTF-8, one character at a time: a string in Lua is bytes and a character in one is one to
-- four of them.
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

--- How many bytes come before a caret one character back of this one. A key that walks a caret or
--- takes a character away counts characters, and one byte back is the middle of a character for most
--- of what is typed. A byte that starts nothing is a character of one byte, so a string that is not
--- text still moves.
---@param text string
---@param at number # How many bytes come before the caret, from nought
---@return number # How many come before the caret one character back of it, which is `at` at the start
function utf8.back(text, at)
	local before, position = 0, 1

	while position <= at do
		local _, after = utf8.decode(text, position)

		-- The character the caret is inside of, or at the end of, is the one before it.
		if after > at then
			return position - 1
		end

		before, position = position, after
	end

	return before
end

---@param text string
---@param at number # How many bytes come before the caret, from nought
---@return number # How many come before the caret one character on from it, which is `at` at the end
function utf8.forward(text, at)
	local _, after = utf8.decode(text, at + 1)

	return math.min(after - 1, #text)
end

return utf8
