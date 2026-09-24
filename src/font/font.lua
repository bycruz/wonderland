-- A font at a size, as the screen uses it: the characters it draws, where each of them goes, and
-- which of the faces of it draws them.
--
-- A font is a chain rather than a face. The first face of it is the one an app named, and the ones
-- after it are read only when a character the faces already read do not draw comes up -- which is
-- what makes a track's title in a language the app's own font has no glyphs for still a title. The
-- chain is walked per character and the answer is kept, so a line costs one lookup a character the
-- first time it is measured and nothing after that.
--
-- Measuring a line is what everything else here is for: a run is where each glyph of a line goes,
-- as one array of structs the quad pass reads, and it is kept because a screen of labels asks for
-- the same strings over and over.
local ffi = require("ffi")
local Atlas = require("wonderland.font.atlas")
local utf8 = require("wonderland.font.utf8")

-- A glyph of a run, as the array of them is: eight numbers, whole ones as whole ones, and the
-- picture the ink is in. A run is measured once and drawn every frame, so it is read far more
-- often than it is written, and a struct is a tenth of what a table per glyph costs.
ffi.cdef [[
	typedef struct {
		int32_t x, y, width, height;  // where the ink is drawn, in whole pixels
		float u0, v0, u1, v1;         // and where it is in its picture
		int32_t advance;              // how far the pen moves for it, which is where the next one
		                              // starts -- and where a caret before it sits
		uint32_t texture;             // the picture it is drawn from, which a chain of faces makes
		                              // more than one of
	} wl_glyph;

	// One line of a run: the range of the run's glyphs that are its own, and how wide it came
	// out, which is what a line that is not left-aligned is placed by.
	typedef struct {
		int32_t first, count;
		double width;
	} wl_line;
]]

--- The line box of a run: the font's line height, times how many lines there are.
---@class wonderland.font.Run
---@field width number # How far the pen moves over the widest of its lines
---@field height number
---@field lines ffi.cdata*? # `wl_line`, one per line, from the top
---@field lineCount number # How many, since the array is not a Lua one
---@field glyphs ffi.cdata*? # `wl_glyph`, one per character from nought, nothing for an empty line
---@field count number # How many, since the array is not a Lua one
---@field id number # Stable for the life of the run: what a frame compares to tell whether a line changed

--- One glyph of a run, placed from the run's top left corner. The language server cannot see an
--- ffi.cdef, so the fields are spelled out here.
---@class wonderland.font.PlacedGlyph: ffi.cdata*
---@field x number
---@field y number
---@field width number
---@field height number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field advance number
---@field texture number

--- One line of a run.
---@class wonderland.font.Line: ffi.cdata*
---@field first number
---@field count number
---@field width number

-- Runs are pure functions of the font, the string and the width it was cut to, so they are kept.
-- The cache is bounded because an app can invent strings forever, as a clock does.
local RUN_CACHE_LIMIT = 2048

-- How many of the oldest lines are dropped when the cache is full: dropping one at a time would
-- leave it evicting on every line measured after that.
local RUN_EVICT = RUN_CACHE_LIMIT / 2

-- Handed out one per measured line and never reused, so two lines are the same line only if they
-- are the same run.
local nextRunId = 0

-- The character a line cut short ends with. It is the one character that is not in the string it
-- is drawn for, so a line that was cut can be told from a line that ends that way.
local ELLIPSIS = 0x2026

--- Whether a measurement is of a string drawn as it is or of one cut to a width.
---@param text string
---@param maxWidth number?
---@return string
local function keyOf(text, maxWidth)
	if maxWidth == nil then
		return text
	end

	return string.format("%s\1%.2f", text, maxWidth)
end

--- One face, at one pixel height, with whatever follows it for the characters it does not draw.
---@class wonderland.font.Font
---@field id number? # What an app and an element hold it by, given when a manager resolves it
---@field spec wonderland.FontSpec # What it was resolved from, for a style to change one part of
---@field atlases wonderland.font.Atlas[] # The faces that have been read, the named one first
---@field glyphs table<number, { atlas: wonderland.font.Atlas, glyph: wonderland.font.Glyph }>
---@field ascent number
---@field descent number
---@field lineHeight number
---@field runs table<string, wonderland.font.Run>
---@field runCount number
---@field private load fun(path: string, index: number?): wonderland.font.Face?
---@field private pending { string, number? }[] # The fallbacks not read yet, in order
---@field private recent table<number, string> # The last lines measured, oldest first
---@field private recentAt number
---@field private codepoints number[] # Where a line is decoded, kept: a measure allocates nothing
---@field private advances number[]
local Font = {}
Font.__index = Font

---@param primary wonderland.font.Atlas
---@param opts { spec: wonderland.FontSpec?, load: fun(path: string, index: number?): wonderland.font.Face?, fallbacks: { string, number? }[]? }
---@return wonderland.font.Font
function Font.new(primary, opts)
	---@type wonderland.font.Font
	local font = setmetatable({
		spec = opts.spec,
		atlases = { primary },
		glyphs = {},
		ascent = primary.ascent,
		descent = primary.descent,
		lineHeight = primary.lineHeight,
		runs = {},
		runCount = 0,
		load = opts.load,
		pending = {},
		codepoints = {},
		advances = {},
	}, Font)

	-- Copied rather than held: the list belongs to the registry that made it, and a chain that
	-- read a fallback takes it off this one.
	for _, fallback in ipairs(opts.fallbacks or {}) do
		font.pending[#font.pending + 1] = { fallback[1], fallback[2] }
	end

	return font
end

--- The face that draws a character: the ones already read, then the ones after them one at a time,
--- and the font's own face for a character none of them draws -- which is drawn as whatever it
--- draws for a character it does not have, and takes the room it takes.
---@param codepoint number
---@return wonderland.font.Atlas
function Font:atlasFor(codepoint)
	for _, atlas in ipairs(self.atlases) do
		if atlas:hasGlyph(codepoint) then
			return atlas
		end
	end

	while #self.pending > 0 do
		local fallback = table.remove(self.pending, 1)
		local face = self.load(fallback[1], fallback[2])

		if face ~= nil then
			local atlas = Atlas.new(face, self.atlases[1].pixelHeight, {
				pictures = self.atlases[1].pictures,
			})

			self.atlases[#self.atlases + 1] = atlas

			if atlas:hasGlyph(codepoint) then
				return atlas
			end
		end
	end

	return self.atlases[1]
end

--- Where a character is drawn from, and where it was packed: the answer is kept, so a line is one
--- lookup a character the first time it is measured and nothing after that.
---@param codepoint number
---@return { atlas: wonderland.font.Atlas, glyph: wonderland.font.Glyph }
function Font:glyphFor(codepoint)
	local known = self.glyphs[codepoint]

	if known ~= nil then
		return known
	end

	local atlas = self:atlasFor(codepoint)
	local entry = { atlas = atlas, glyph = atlas:glyph(codepoint) }

	self.glyphs[codepoint] = entry

	return entry
end

--- Decodes one line of a string into the reusable array of codepoints, and answers how many.
---@param self wonderland.font.Font
---@param text string
---@param from number
---@param to number
---@return number count
local function codepointsIn(self, text, from, to)
	local codepoints = self.codepoints
	local count, at = 0, from

	while at <= to do
		local codepoint
		codepoint, at = utf8.decode(text, at)
		count = count + 1
		codepoints[count] = codepoint
	end

	return count
end

--- How many characters a line of a string holds, without placing any of them.
---@param text string
---@param from number
---@param to number
---@return number
local function countOf(text, from, to)
	local count, at = 0, from

	while at <= to do
		local _, after = utf8.decode(text, at)
		count = count + 1
		at = after
	end

	return count
end

--- Where every glyph of a line goes, measured once and kept. A width cuts each line to it, with
--- the last character a line can hold replaced by an ellipsis: what a long title in a short box is.
---@param text string
---@param maxWidth number?
---@return wonderland.font.Run
function Font:getRun(text, maxWidth)
	-- A line that fits the width it is cut to is the line with no width at all: measuring it again
	-- for the width would be a second entry in the cache for every width a window was ever drawn
	-- at, and nothing about the line would be different.
	if maxWidth ~= nil then
		local whole = self:getRun(text)

		if whole.width <= maxWidth then
			return whole
		end
	end

	local key = keyOf(text, maxWidth)
	local cached = self.runs[key]

	if cached ~= nil then
		return cached
	end

	if self.runCount >= RUN_CACHE_LIMIT then
		-- The oldest lines are dropped rather than all of them: see `RUN_CACHE_LIMIT`.
		local recent, at = self.recent, self.recentAt

		for _ = 1, RUN_EVICT do
			local oldest = recent[at]

			if oldest ~= nil then
				recent[at] = nil
				self.runs[oldest] = nil
				self.runCount = self.runCount - 1
			end

			at = at % RUN_CACHE_LIMIT + 1
		end

		self.recentAt = at
	end

	-- How many lines the string is, and how many glyphs they hold between them: a newline is a
	-- break with nothing drawn at it, so it is not a glyph. Counted before anything is placed,
	-- because both arrays are made once and filled in place.
	local lineCount, glyphCount, scan = 1, 0, 1

	while true do
		local newline = text:find("\n", scan, true)

		if newline == nil then
			glyphCount = glyphCount + countOf(text, scan, #text)
			break
		end

		glyphCount = glyphCount + countOf(text, scan, newline - 1)
		lineCount = lineCount + 1
		scan = newline + 1
	end

	-- One glyph of room a line over, for the ellipsis a cut line ends with.
	---@type ffi.cdata*?
	local array = glyphCount > 0 and ffi.new("wl_glyph[?]", glyphCount + lineCount) or nil
	local lines = ffi.new("wl_line[?]", lineCount)
	local lineStep = math.floor(self.lineHeight + 0.5)
	local widest, placed, start = 0, 0, 1

	for line = 0, lineCount - 1 do
		local newline = text:find("\n", start, true)
		local last = (newline or #text + 1) - 1
		local baseline = math.floor(self.ascent + 0.5) + line * lineStep
		local pen, first = 0, placed
		local count = codepointsIn(self, text, start, last)
		local codepoints, advances = self.codepoints, self.advances
		local width = 0

		for index = 1, count do
			local advance = self:glyphFor(codepoints[index]).glyph.advance

			advances[index] = advance
			width = width + advance
		end

		local fewer, cut = count, false

		if maxWidth ~= nil and width > maxWidth then
			local dots = self:glyphFor(ELLIPSIS).glyph.advance
			local used, fits = 0, 0

			for index = 1, count do
				if used + advances[index] + dots > maxWidth then
					break
				end

				used = used + advances[index]
				fits = index
			end

			pen, fewer, cut, width = 0, fits, true, used
		end

		for index = 1, fewer do
			local glyph = self:glyphFor(codepoints[index]).glyph
			local into = assert(array)[placed]
			---@cast into wonderland.font.PlacedGlyph

			into.x = math.floor(pen + glyph.left + 0.5)
			into.y = math.floor(baseline + glyph.top + 0.5)
			into.width, into.height = glyph.width, glyph.height
			into.u0, into.v0, into.u1, into.v1 = glyph.u0, glyph.v0, glyph.u1, glyph.v1
			into.advance, into.texture = glyph.advance, glyph.texture

			pen = pen + glyph.advance
			placed = placed + 1
		end

		if cut then
			local glyph = self:glyphFor(ELLIPSIS).glyph
			local into = assert(array)[placed]
			---@cast into wonderland.font.PlacedGlyph

			into.x = math.floor(pen + glyph.left + 0.5)
			into.y = math.floor(baseline + glyph.top + 0.5)
			into.width, into.height = glyph.width, glyph.height
			into.u0, into.v0, into.u1, into.v1 = glyph.u0, glyph.v0, glyph.u1, glyph.v1
			into.advance, into.texture = glyph.advance, glyph.texture
			width = pen + glyph.advance
			placed = placed + 1
		end

		lines[line].first, lines[line].count, lines[line].width = first, placed - first, width

		if width > widest then
			widest = width
		end

		start = last + 2
	end

	nextRunId = nextRunId + 1

	---@type wonderland.font.Run
	local run = {
		width = widest,
		height = lineStep * lineCount,
		lines = lines,
		lineCount = lineCount,
		glyphs = array,
		count = placed,
		id = nextRunId,
	}

	self.runs[key] = run
	self.runCount = self.runCount + 1

	local recent = self.recent

	if recent == nil then
		recent = {}
		self.recent, self.recentAt = recent, 1
	end

	recent[self.recentAt] = key
	self.recentAt = self.recentAt % RUN_CACHE_LIMIT + 1

	return run
end

--- The picture the first face of the font is in, which is what a glyph with no picture of its
--- own is drawn from: a glyph measured with a gpu under it names its own, so this is what a screen
--- wired without one falls back to.
---@return number
function Font:picture()
	local sheet = self.atlases[1].sheets[1]

	return sheet ~= nil and sheet.texture or 0
end

--- What has been packed since the last frame, put into the pictures the screen samples.
function Font:flush()
	for _, atlas in ipairs(self.atlases) do
		atlas:flush()
	end
end

return Font
