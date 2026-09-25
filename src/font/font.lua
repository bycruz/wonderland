-- A font at a size: the glyphs a line is drawn from, where each of them goes, and which face of a
-- chain draws it.
--
-- A font is a chain rather than a face. The first face is the one an app named and the ones after it
-- are read only when a character none of the faces read so far draws comes up. A run -- where every
-- glyph of a line goes -- is kept, because a screen of labels asks for the same strings over and over.
local ffi = require("ffi")
local Atlas = require("wonderland.font.atlas")
local reader = require("wonderland.font.reader")
local utf8 = require("wonderland.font.utf8")

-- A glyph of a run. A run is measured once and drawn every frame, so this is an array of structs
-- rather than a table a glyph.
ffi.cdef [[
	typedef struct {
		int32_t x, y, width, height;  // where the ink is drawn, in whole pixels
		float u0, v0, u1, v1;         // and where it is in its picture
		float pen;                    // where the pen was when it was placed, from the start of its
		                              // line: where a caret before it sits
		float advance;                // how far it moved the pen
		uint32_t texture;             // the picture it is drawn from
		uint32_t cluster;             // the byte of the line it came from, from nought
		int32_t own;                  // whether that picture is of its own colours -- an emoji
	} wl_glyph;

	// One line of a run: the range of the run's glyphs that are its own, how wide it came out, and
	// which way it reads.
	typedef struct {
		int32_t first, count;
		int32_t rtl;
		double width;
	} wl_line;
]]

--- The line box of a run: the font's line height, times how many lines there are.
---@class wonderland.font.Run
---@field width number # How far the pen moves over the widest of its lines
---@field height number
---@field lines ffi.cdata*? # `wl_line`, one per line, from the top
---@field lineCount number # How many, since the array is not a Lua one
---@field glyphs ffi.cdata*? # `wl_glyph`, one per glyph in the order they are drawn, nothing for an empty line
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
---@field pen number # Where the pen was when it was placed, from the start of its line
---@field advance number # And how far it moved it
---@field texture number
---@field cluster number # The byte of the line it came from, from nought
---@field own number

--- One line of a run.
---@class wonderland.font.Line: ffi.cdata*
---@field first number
---@field count number
---@field rtl number # Whether the line reads right to left, which is what a caret counts by
---@field width number

-- Runs are pure functions of the font, the string and the width it was cut to, so they are kept.
-- Bounded, because an app can invent strings forever, as a clock does.
local RUN_CACHE_LIMIT = 2048

-- Dropped a batch at a time: dropping one at a time leaves it evicting on every line after that.
local RUN_EVICT = RUN_CACHE_LIMIT / 2

-- One per measured line, never reused: two lines are the same line only if they are the same run.
local nextRunId = 0

-- The character a line cut short ends with: one that is not in the string it is drawn for, so a
-- line that was cut can be told from a line that ends that way.
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

--- One face at one pixel height, with whatever follows it for the characters it does not draw.
---@class wonderland.font.Font
---@field id number? # What an app and an element hold it by, given when a manager resolves it
---@field spec wonderland.FontSpec # What it was resolved from, for a style to change one part of
---@field atlases wonderland.font.Atlas[] # The faces that have been read, the named one first
---@field pixelHeight number # What every face of the chain is read at, which is what a piece is shaped at
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
---@field private pieces wonderland.font.Piece[] # Where a line is cut into what one face draws of it
---@field private piecesAt number # How many of them the line being measured came to
local Font = {}
Font.__index = Font

--- One stretch of a line that one face draws, and what it was shaped into -- nothing where the reader
--- cannot shape, which is a stretch measured a character at a time.
---@class wonderland.font.Piece
---@field atlas wonderland.font.Atlas
---@field line number # Which line of the string it is on, from nought
---@field from number # The byte of the string it starts at, from one, as Lua counts strings
---@field to number
---@field shaped wonderland.font.Shaped?

---@param primary wonderland.font.Atlas
---@param opts { spec: wonderland.FontSpec?, load: fun(path: string, index: number?): wonderland.font.Face?, fallbacks: { string, number? }[]? }
---@return wonderland.font.Font
function Font.new(primary, opts)
	---@type wonderland.font.Font
	local font = setmetatable({
		spec = opts.spec,
		atlases = { primary },
		pixelHeight = primary.pixelHeight,
		glyphs = {},
		ascent = primary.ascent,
		descent = primary.descent,
		lineHeight = primary.lineHeight,
		runs = {},
		runCount = 0,
		load = opts.load,
		pending = {},
		pieces = {},
		piecesAt = 0,
	}, Font)

	-- Copied rather than held: the list belongs to the registry that made it, and a chain that
	-- read a fallback takes it off this one.
	for _, fallback in ipairs(opts.fallbacks or {}) do
		font.pending[#font.pending + 1] = { fallback[1], fallback[2] }
	end

	return font
end

--- The face that draws a character: the ones already read, then the ones after them one at a time,
--- and the font's own face for a character none of them draws -- drawn as its missing glyph.
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

--- Where a character is drawn from and where it was packed. Kept: one lookup a character the first
--- time a line is measured and nothing after that.
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

--- Cuts one line into the pieces one face draws of it and shapes each piece with that face: joining
--- and kerning are decisions a font makes about the letters beside each other, so a piece has to be
--- the whole of what one face draws. A piece whose face cannot be shaped is measured a character at
--- a time. The pieces go into an array the font keeps, so nothing here is allocated.
---@param self wonderland.font.Font
---@param text string
---@param from number
---@param to number
---@param line number
---@return number glyphs # How many the pieces of the line came to between them
local function shapeLine(self, text, from, to, line)
	local pieces, at, count, glyphs = self.pieces, from, self.piecesAt, 0

	while at <= to do
		local codepoint, after = utf8.decode(text, at)
		local atlas = self:glyphFor(codepoint).atlas
		local piece = count > 0 and pieces[count] or nil

		if piece == nil or piece.atlas ~= atlas or piece.line ~= line then
			count = count + 1
			piece = pieces[count]

			if piece == nil then
				piece = {}
				pieces[count] = piece
			end

			piece.atlas, piece.line, piece.from, piece.shaped = atlas, line, at, nil
		end

		piece.to = after - 1
		at = after
	end

	self.piecesAt = count

	for index = 1, count do
		local piece = pieces[index]
		local shaped = piece.shaped

		if shaped == nil and reader.shapes(piece.atlas.face) then
			shaped = reader.shape(piece.atlas.face, text:sub(piece.from, piece.to), self.pixelHeight)
			piece.shaped = shaped
		end

		glyphs = glyphs + (shaped ~= nil and #shaped.glyphs or countOf(text, piece.from, piece.to))
	end

	return glyphs
end

--- Where every glyph of a line goes, measured once and kept. A width cuts each line to it, with
--- the last character a line can hold replaced by an ellipsis: what a long title in a short box is.
---@param text string
---@param maxWidth number?
---@return wonderland.font.Run
function Font:getRun(text, maxWidth)
	-- A line that fits the width it is cut to is the line with no width at all: measuring it again
	-- would be a second cache entry for every width a window was ever drawn at.
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

	-- How many lines the string is and how many glyphs they come to, counted from the shaped pieces
	-- rather than the characters: a ligature is one glyph of two characters. Both arrays are made
	-- once, before anything is placed.
	self.piecesAt = 0

	local lineCount, glyphCount, scan = 1, 0, 1

	while true do
		local newline = text:find("\n", scan, true)
		local last = (newline or #text + 1) - 1

		glyphCount = glyphCount + shapeLine(self, text, scan, last, lineCount - 1)

		if newline == nil then
			break
		end

		lineCount = lineCount + 1
		scan = newline + 1
	end

	---@type ffi.cdata*?
	local array = glyphCount > 0 and ffi.new("wl_glyph[?]", glyphCount) or nil
	local lines = ffi.new("wl_line[?]", lineCount)
	local lineStep = math.floor(self.lineHeight + 0.5)
	local pieces, piecesAt = self.pieces, self.piecesAt
	local pieceAt = 1
	local widest, written, drawn, start = 0, 0, 0, 1

	for line = 0, lineCount - 1 do
		local newline = text:find("\n", start, true)
		local last = (newline or #text + 1) - 1
		local baseline = math.floor(self.ascent + 0.5) + line * lineStep
		local first = written
		-- Bytes are counted from the start of the line, not of the string: that is how a caret is
		-- counted -- a line and a byte of it, and nothing about the lines around it.
		local base = start - 1
		local pen, rtl, ltrBytes = 0.0, 0, 0

		-- The pieces of this line, in the order they are read: where a glyph goes and how far it
		-- moves the pen are the shaper's answers rather than a sum of advances, so what is kerned
		-- together lands where the font put it.
		while pieceAt <= piecesAt and pieces[pieceAt].line == line do
			local piece = pieces[pieceAt]
			local atlas, shaped = piece.atlas, piece.shaped

			if shaped ~= nil then
				local glyphs = shaped.glyphs
				local piecePen = 0.0

				for index = 1, #glyphs do
					local glyph = glyphs[index]
					local ink = atlas:byGlyph(glyph.glyph, math.floor(glyph.advance + 0.5))
					local into = assert(array)[written]
					---@cast into wonderland.font.PlacedGlyph

					into.x = math.floor(pen + glyph.x + ink.left + 0.5)
					into.y = math.floor(baseline + ink.top + 0.5)
					into.width, into.height = ink.width, ink.height
					into.u0, into.v0, into.u1, into.v1 = ink.u0, ink.v0, ink.u1, ink.v1
					into.pen, into.advance = pen + piecePen, glyph.advance
					into.texture = ink.texture
					into.cluster = piece.from - 1 - base + glyph.cluster
					into.own = ink.colour and 1 or 0

					-- The pen position is the advances before it, not where the glyph was drawn: a
					-- mark is drawn where it sits on a letter and moves nothing, and a caret is a pen.
					piecePen = piecePen + glyph.advance
					written = written + 1
				end

				pen = pen + shaped.width

				-- A line is set the way most of it is set, counted in bytes. Cutting a line by face
				-- cannot arrange a line of two directions the way a bidi pass over the whole of it
				-- would; what matters here is the line a caret is counted along.
				if shaped.rtl then
					rtl = rtl + (piece.to - piece.from + 1)
				else
					ltrBytes = ltrBytes + (piece.to - piece.from + 1)
				end
			else
				local at = piece.from

				while at <= piece.to do
					local codepoint, after = utf8.decode(text, at)
					local glyph = atlas:glyph(codepoint)
					local into = assert(array)[written]
					---@cast into wonderland.font.PlacedGlyph

					into.x = math.floor(pen + glyph.left + 0.5)
					into.y = math.floor(baseline + glyph.top + 0.5)
					into.width, into.height = glyph.width, glyph.height
					into.u0, into.v0, into.u1, into.v1 = glyph.u0, glyph.v0, glyph.u1, glyph.v1
					into.pen, into.advance = pen, glyph.advance
					into.texture = glyph.texture
					into.cluster = at - 1 - base
					into.own = glyph.colour and 1 or 0

					pen = pen + glyph.advance
					written = written + 1
					at = after
				end
			end

			pieceAt = pieceAt + 1
		end

		local total, width, from, count = written - first, pen, first, written - first

		rtl = rtl > ltrBytes and 1 or 0

		-- A line too wide for its room is cut to it, with an ellipsis where it was cut: what is kept
		-- is what fits beside the ellipsis, so the cut is where the pen stops fitting.
		if maxWidth ~= nil and width > maxWidth then
			local dots = self:glyphFor(ELLIPSIS).glyph
			local budget = maxWidth - dots.advance
			local kept, used = 0, 0.0

			if rtl ~= 0 then
				-- A line that reads right to left ends at its left, so it is cut from the left: what
				-- is kept is the end that still fits and the ellipsis goes at the left of it.
				for at = total - 1, 0, -1 do
					local advance = assert(array)[first + at].advance

					if used + advance > budget then break end

					used, kept = used + advance, kept + 1
				end
			else
				local at = 0

				while at < total and used + assert(array)[first + at].advance <= budget do
					used, kept, at = used + assert(array)[first + at].advance, kept + 1, at + 1
				end
			end

			-- What is kept is moved rather than measured again, so it is moved by where its own far
			-- edge has to be.
			local keepFrom = rtl ~= 0 and first + (total - kept) or first
			local keepTo = rtl ~= 0 and first + total - 1 or first + kept - 1
			local left, right, seen = 0.0, 0.0, false

			for at = keepFrom, keepTo do
				local glyph = assert(array)[at]
				local edge = glyph.pen + glyph.advance

				if not seen or glyph.pen < left then left = glyph.pen end
				if not seen or edge > right then right = edge end
				seen = true
			end

			local shift, dotsPen = 0.0, right

			if rtl ~= 0 then
				shift, dotsPen = dots.advance - left, 0.0
			end

			if shift ~= 0 then
				for at = keepFrom, keepTo do
					local into = assert(array)[at]

					into.x = math.floor(into.x + shift + 0.5)
					into.pen = into.pen + shift
				end
			end

			-- The ellipsis takes the place of a dropped glyph: the first of them where the line reads
			-- left to right, the last where it reads the other way.
			local into = assert(array)[rtl ~= 0 and keepFrom - 1 or first + kept]
			---@cast into wonderland.font.PlacedGlyph

			into.x = math.floor(dotsPen + dots.left + 0.5)
			into.y = math.floor(baseline + dots.top + 0.5)
			into.width, into.height = dots.width, dots.height
			into.u0, into.v0, into.u1, into.v1 = dots.u0, dots.v0, dots.u1, dots.v1
			into.pen, into.advance = dotsPen, dots.advance
			into.texture = dots.texture
			into.cluster = rtl ~= 0 and 0 or (kept < total and assert(array)[first + kept].cluster or 0)
			into.own = dots.colour and 1 or 0

			width = dots.advance + right - (rtl ~= 0 and left or 0)
			from, count = rtl ~= 0 and keepFrom - 1 or first, kept + 1
		end

		lines[line].first, lines[line].count = from, count
		lines[line].rtl = rtl
		lines[line].width = width
		drawn = drawn + count

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
		count = drawn,
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

--- The picture the first face of the font is in, which is what a glyph with no picture of its own
--- is drawn from.
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
