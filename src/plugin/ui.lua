local bit = require("bit")
local ffi = require("ffi")
local QuadBatch = require("wonderland.util.quad_batch")
local style = require("wonderland.style")
local wonderlandElement = require("wonderland.element")
local time = require("wonderland.time")

-- The element arena, read by the node's index into it: what a caret is for, and what has been
-- typed into the field it belongs to.
local pointers, strings = wonderlandElement.pointers, wonderlandElement.strings

-- The clock the screen is on: a window that is waiting for the next event uses no time at all, and
-- it is that wait the frame after it is measured against. See `wonderland.time`.
local now = time.now

--- What a screen has to do on its own, as a thing the app can ask for: it is handed the time it
--- was called at and the window it is for, and it answers how long it wants before it is called
--- again -- nought to be called as soon as the loop comes round, nothing at all to be done with.
---
--- A callback whose work is a new frame asks for one itself, with the ticker's own `present`:
--- whether a download finishing is worth a frame is the app's answer, and this is the app's own
--- work rather than the screen's.
---@alias wonderland.Tick fun(at: number, window: wonderland.RenderWindow): number?

---@class wonderland.plugin.UI.Ticker
---@field fn wonderland.Tick
---@field window wonderland.RenderWindow? # The one it is for, taken from the first it is asked about
---@field due number? # When it is next asked, on the ui's clock
---@field cancelled boolean?
---@field cancel fun(self: wonderland.plugin.UI.Ticker) # Done with it, before its next turn
---@field present fun(self: wonderland.plugin.UI.Ticker) # A frame asked for now, for what it just did
---@field private ui wonderland.plugin.UI

---@class wonderland.plugin.UI: wonderland.Plugin
---@field layoutPlugin wonderland.plugin.Layout
---@field renderPlugin wonderland.plugin.Render
---@field batch wonderland.QuadBatch
---@field tickers wonderland.plugin.UI.Ticker[] # What the app asked to be called back on
---@field frameInterval number # The least time between frames, in seconds: see `UI:requestRedraw`
---@field caretBlink number # How long a caret is drawn for and how long it is not, nought for one that stays
local UI = {}
UI.__index = UI

-- The caret: a bar this wide, this far in from the edges of the line it is on, and on for half a
-- second and off for half a second. The width is whole pixels because it is drawn as a quad, and
-- two of them is the thinnest bar a screen shows as a bar rather than as a faint edge.
--
-- A blink is a frame every half second of a window that is otherwise doing nothing, which the loop
-- has to be woken for: it waits for the next event and an idle window has none. What wakes it is
-- the end of its wait, which `UI:tick` asks it for -- see `app.run`, which is where a loop with a
-- screen in it is told when to come back.
local CARET_WIDTH = 2
local CARET_INSET = 2
local CARET_BLINK = 0.5

-- A display shows a frame for a frame's time. A present that waits for the display is what keeps
-- a window to that on most platforms, and the ones where it does not -- X11 handing frames over
-- without waiting for one, which is what XWayland does -- leave the app free to hand over as many
-- frames as it is asked for. A pointer dragged across a window is a thousand events a second, so
-- without this it is a thousand frames a second for a display that shows sixty: the compositor is
-- given more than it can show, and a driver that keeps something for every present is given more
-- than it can hold -- which is a window that stops answering after a few seconds of dragging.
local FRAME_INTERVAL = 1 / 60

---@param layoutPlugin wonderland.plugin.Layout
---@param renderPlugin wonderland.plugin.Render
function UI.new(layoutPlugin, renderPlugin)
	return setmetatable({
		layoutPlugin = layoutPlugin,
		renderPlugin = renderPlugin,
		batch = QuadBatch.new(),
		tickers = {},
		frameInterval = FRAME_INTERVAL,
		caretBlink = CARET_BLINK,
	}, UI)
end

--- What the app wants woken for, in the order it asked: a decoder with a frame ready, a player
--- with a position to read, anything that has work of its own rather than work an event brought.
---
--- The window it is for is taken from the first the loop asks about, so an app that registers
--- this before its window exists -- in `init`, which is where an app's own setup goes -- does not
--- have to know when one is made. A callback that wants a frame asks for it with the ticker's
--- own `present`, and one that is done with is `cancel`led, which is also what answering nothing
--- from the callback does.
---@param fn wonderland.Tick
---@param window wonderland.RenderWindow?
---@return wonderland.plugin.UI.Ticker
function UI:onTick(fn, window)
	local ui = self
	---@type wonderland.plugin.UI.Ticker
	local ticker = { fn = fn, window = window, ui = ui }

	ticker.cancel = function()
		ticker.cancelled = true
	end

	ticker.present = function()
		if ticker.window ~= nil then
			ui:requestRedraw(ticker.window, true)
		end
	end

	self.tickers[#self.tickers + 1] = ticker

	return ticker
end

--- A frame asked for now rather than at the display's own rate: what a screen that has just been
--- given something new to show asks for. See `UI:requestRedraw`, which is the rationed one.
---@param window wonderland.RenderWindow
function UI:present(window)
	self:requestRedraw(window, true)
end

---@param pos number
---@param screenSize number
---@return number
local function toNDC(pos, screenSize)
	return (pos / (screenSize * 0.5)) - 1.0
end

--- Converts a z-index to an NDC z-value
---@param z number?
local function convertZ(z)
	return 1 - math.min(z or 0, 100000) / 1000000
end

-- A box with no colour of its own is drawn with its texture as it is, which is white.
local WHITE_R, WHITE_G, WHITE_B, WHITE_A = 1.0, 1.0, 1.0, 1.0

--- Where a box that scrolls shows through: a quad is drawn down to this, and the part of the
--- texture that goes with the part that is left, so a glyph half out of a pane is cut rather
--- than squashed into the half of itself that shows.
--- The caret of a field, as a frame draws it: which element it is for, where in its value it is,
--- and -- once the walk has been over that element -- the quad it comes out to. The walk fills that
--- second half in and the frame keeps it, because a blink is that quad going out and coming back
--- without any of the frame being built again.
---@class wonderland.plugin.UI.Caret
---@field element wonderland.Element
---@field value number # The string handle of what has been typed into the field
---@field line number # Which line of it the caret is on, from nought
---@field column number # And how many bytes of that line come before it
---@field placed boolean? # Whether the field was walked, which is what says the quad is there
---@field left number?
---@field top number?
---@field right number?
---@field bottom number?
---@field z number?
---@field clip wonderland.plugin.UI.Clip?
---@field r number?
---@field g number?
---@field b number?
---@field a number?

-- A byte past the end of a line, which is what a click at the left of a right-to-left line comes to:
-- the bytes of such a line run from its right, so its left end is past every byte of it. The layout
-- clamps a column past the end of a line to the end of it -- see `Layout:setCaret`.
local PAST_THE_LINE = 1 << 24

---@class wonderland.plugin.UI.Clip
---@field left number
---@field top number
---@field right number
---@field bottom number

---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param windowWidth number
---@param windowHeight number
---@param left number
---@param top number
---@param right number
---@param bottom number
---@param z number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texture number
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
---@param radius number? # How round the box's corners are, in pixels, nothing for square ones
---@param band number? # How sharp the edge of it is, one pixel either side by default
---@param grow number? # How far past the box the quad is drawn: a shadow is its own blur
local function clippedQuad(batch, clip, windowWidth, windowHeight, left, top, right, bottom, z, r, g, b, a,
	texture, u0, v0, u1, v1, radius, band, grow, own)
	-- A quad that is drawn past its box is one whose edge is spread out, so what is drawn is the
	-- box and the space the spreading needs; the box itself is what the corner arithmetic is about.
	local drawnLeft, drawnTop = left - (grow or 0), top - (grow or 0)
	local drawnRight, drawnBottom = right + (grow or 0), bottom + (grow or 0)
	-- The quad the box asked for, when all of it shows. Most quads are inside the clip -- only the
	-- ones at the edge of a pane that scrolls are not -- and working out where a quad is cut costs
	-- a pair of divisions, so the ones that need nothing are the ones that get nothing.
	if drawnLeft >= clip.left and drawnTop >= clip.top and drawnRight <= clip.right and drawnBottom <= clip.bottom then
		-- Cut and square are a call each rather than one argument to the same call: they are not
		-- drawn in the same numbers, and a screen of text is nearly all of one of them.
		if band or (radius and radius > 0) then
			batch:roundQuad(
				toNDC(drawnLeft, windowWidth),
				-toNDC(drawnTop, windowHeight),
				toNDC(drawnRight, windowWidth),
				-toNDC(drawnBottom, windowHeight),
				z,
				r, g, b, a,
				texture,
				u0, v0, u1, v1,
				radius or 0,
				toNDC(left, windowWidth),
				-toNDC(top, windowHeight),
				toNDC(right, windowWidth),
				-toNDC(bottom, windowHeight),
				band,
				own
			)
		else
			batch:quad(
				toNDC(left, windowWidth),
				-toNDC(top, windowHeight),
				toNDC(right, windowWidth),
				-toNDC(bottom, windowHeight),
				z,
				r, g, b, a,
				texture,
				u0, v0, u1, v1,
				own
			)
		end

		return
	end

	local atLeft = drawnLeft < clip.left and clip.left or drawnLeft
	local atTop = drawnTop < clip.top and clip.top or drawnTop
	local atRight = drawnRight > clip.right and clip.right or drawnRight
	local atBottom = drawnBottom > clip.bottom and clip.bottom or drawnBottom

	if atRight <= atLeft or atBottom <= atTop then
		return
	end

	local du = (u1 - u0) / (drawnRight - drawnLeft)
	local dv = (v1 - v0) / (drawnBottom - drawnTop)

	-- What is drawn is what is inside the clip but the corners are the corners of the whole box: a
	-- box cut down to a sliver by the pane it is in is still a box with round corners, and the
	-- corners of the sliver are not corners of it.
	if band or (radius and radius > 0) then
		batch:roundQuad(
			toNDC(atLeft, windowWidth),
			-toNDC(atTop, windowHeight),
			toNDC(atRight, windowWidth),
			-toNDC(atBottom, windowHeight),
			z,
			r, g, b, a,
			texture,
			u0 + du * (atLeft - drawnLeft), v0 + dv * (atTop - drawnTop),
			u0 + du * (atRight - drawnLeft), v0 + dv * (atBottom - drawnTop),
			radius or 0,
			toNDC(left, windowWidth),
			-toNDC(top, windowHeight),
			toNDC(right, windowWidth),
			-toNDC(bottom, windowHeight),
			band,
			own
		)

		return
	end

	batch:quad(
		toNDC(atLeft, windowWidth),
		-toNDC(atTop, windowHeight),
		toNDC(atRight, windowWidth),
		-toNDC(atBottom, windowHeight),
		z,
		r, g, b, a,
		texture,
		u0 + du * (atLeft - drawnLeft), v0 + dv * (atTop - drawnTop),
		u0 + du * (atRight - drawnLeft), v0 + dv * (atBottom - drawnTop),
		own
	)
end

---@param batch wonderland.QuadBatch
---@param bx number
---@param by number
---@param bw number
---@param bh number
---@param r number
---@param g number
---@param b number
---@param a number
---@param z number
---@param windowWidth number
---@param windowHeight number
local function addBorderQuad(batch, clip, bx, by, bw, bh, r, g, b, a, z, windowWidth, windowHeight)
	if bw <= 0 or bh <= 0 then
		return
	end

	clippedQuad(batch, clip, windowWidth, windowHeight, bx, by, bx + bw, by + bh, convertZ(z + 1), r, g, b, a, 0,
		0, 0, 1, 1)
end

--- A line is drawn from the run it measured into, which is where its glyphs are. A run of
--- several lines is drawn line by line, each of them placed in the box on its own: a line that
--- is not as wide as the box is aligned by its own width, not by the widest one in the run.
---@param batch wonderland.QuadBatch
---@param run wonderland.font.Run
---@param node wonderland.Node
---@param x number # Absolute, so the glyphs land on whole pixels
---@param y number
---@param z number
---@param fontManager FontManager
---@param windowWidth number
---@param windowHeight number
local function generateTextQuads(batch, clip, run, node, x, y, z, fontManager, windowWidth, windowHeight)
	local r, g, b = node.fgR / 255, node.fgG / 255, node.fgB / 255

	-- The picture a glyph is drawn from is the one it was measured in, because a line may be drawn
	-- by more than one face: a character the font an app named has no glyph for is drawn from the
	-- face after it in the chain, and the run's glyphs name the picture each of them is in. What
	-- the font itself answers with is where a glyph with no picture of its own is drawn from, which
	-- is a glyph of a font that was measured with no gpu under it.
	local font = node.font ~= 0 and fontManager:get(node.font - 1)
		or assert(fontManager:getDefault(), "No font to draw text with: load one and make it the default")

	local zIndex = convertZ(z)

	-- One array of glyphs and one of lines, read by index: the run was measured as structs, so
	-- drawing a line costs a handful of loads rather than a table lookup per glyph.
	for lineIndex = 0, run.lineCount - 1 do
		local line = run.lines[lineIndex]

		-- A line may be given more room than it needs, and then it says where in that room it sits.
		local offset = 0
		if node.justify == 1 then
			offset = math.floor((node.width - line.width) / 2 + 0.5)
		elseif node.justify == 2 then
			offset = node.width - line.width
		end

		local originX = x + offset

		for at = 0, line.count - 1 do
			local glyph = assert(run.glyphs)[line.first + at]
			local picture = glyph.texture ~= 0 and glyph.texture or font:picture()

			-- A glyph that is a picture of its own -- an emoji -- is drawn as the picture rather
			-- than through the text's colour: what the colour is of it is how opaque the element is.
			clippedQuad(batch, clip, windowWidth, windowHeight, originX + glyph.x, y + glyph.y,
				originX + glyph.x + glyph.width, y + glyph.y + glyph.height, zIndex, r, g, b,
				node.fgA / 255, picture, glyph.u0, glyph.v0, glyph.u1, glyph.v1, nil, nil, nil,
				glyph.own)
		end
	end
end

--- Where the caret is, as the pen it sits at, given the byte of the line it is at.
---
--- A glyph is not a character, so the byte is looked up among the glyphs and what is answered is the
--- pen that glyph was placed at. A line that reads right to left runs the other way: the caret for a
--- byte is at the far edge of the glyphs that byte came from.
---@param run wonderland.font.Run
---@param line number
---@param byte number # How many bytes of that line come before the caret
---@return number pen # From the left edge of the run
---@return number lineStep # How tall a line of it is, which the caret is drawn no taller than
local function caretPen(run, line, byte)
	local lineStep = run.height / run.lineCount
	local glyphs = run.glyphs
	local glyphLine = run.lines[line] ---@type wonderland.font.Line

	if glyphs == nil or glyphLine == nil or glyphLine.count <= 0 then
		return 0, lineStep
	end

	local first, count = glyphLine.first, glyphLine.count

	-- A glyph is not always the whole of a character: a mark sits on a letter, in the same bytes, and
	-- is placed where it is placed. So a byte is worth the edge of the group its glyphs make -- the
	-- right edge of it where the line reads right to left, the left where it does not.
	if glyphLine.rtl ~= 0 then
		local pen = nil

		for at = 0, count - 1 do
			local glyph = glyphs[first + at]

			if glyph.cluster >= byte then
				local edge = glyph.pen + glyph.advance

				if pen == nil or edge > pen then
					pen = edge
				end
			end
		end

		return pen or 0, lineStep
	end

	local pen = nil

	for at = 0, count - 1 do
		local glyph = glyphs[first + at]

		if glyph.cluster >= byte and (pen == nil or glyph.pen < pen) then
			pen = glyph.pen
		end
	end

	if pen ~= nil then
		return pen, lineStep
	end

	-- A byte past every glyph puts the caret where the line stops rather than nowhere.
	return glyphLine.width, lineStep
end

--- Where a line of a run is drawn inside the box it is in: a line may be given more room than it
--- needs, and then it says where in that room it sits -- which is where the glyphs of it are drawn,
--- and so where the caret beside them goes and where a click on them lands.
---@param node wonderland.Node
---@param line wonderland.font.Line?
---@return number # From the left edge of the box
local function lineOffset(node, line)
	if line == nil or node.run == 0 then
		return 0
	end

	if node.justify == 1 then
		return math.floor((node.width - line.width) / 2 + 0.5)
	elseif node.justify == 2 then
		return node.width - line.width
	end

	return 0
end

--- Where the caret of a field is drawn this frame, and what it is drawn as, kept on the caret the
--- walk was handed: a frame is built once and the quad of it is drawn last, so what a blink needs
--- to put back is the whole of what is decided here.
---
--- What it is placed from is a line of text -- the one the field draws, or the field's own content
--- origin where it draws none -- so `x` and `y` are that line's top left corner rather than the
--- field's: where a field puts the text it draws is the app's, and a field that centres it is one
--- whose caret is beside the text rather than at the top of the box.
---@param caret wonderland.plugin.UI.Caret
---@param element wonderland.Element # What the line belongs to, which is where its font is
---@param node wonderland.Node # The node it is drawn as, which is what says how it is aligned
---@param x number # Absolute, as the walk has it
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
---@param fontManager FontManager
local function placeCaret(caret, element, node, x, y, z, clip, fontManager)
	local value = strings[caret.value]

	-- The font the line was measured in, which is the element's: what a line is drawn in is what
	-- its parents said unless it named one itself, and the measurement that says it did is the one
	-- the text plugin keeps on the element. A field that draws no text of its own is measured in
	-- whatever the window's default is, which is the font the value would have been drawn in.
	local font = element.fontId ~= 0 and fontManager:get(element.fontId)
		or assert(fontManager:getDefault(), "No font to draw text with: load one and make it the default")

	-- A line the screen draws cut to its box is measured cut when the caret beside it is placed,
	-- so that the caret lands in the text that is on screen rather than in the text that was too
	-- long for it. See `wonderland.plugin.Layout`, which is where a line is cut.
	local maxWidth = bit.band(node.styleFlags, style.PRESENT.ellipsis) ~= 0
			and (node.width - node.paddingLeft - node.paddingRight)
		or nil
	local run = font:getRun(value, maxWidth)
	local pen, lineStep = caretPen(run, caret.line, caret.column)
	local height = lineStep - CARET_INSET * 2
	local line = run.lines[caret.line] ---@type wonderland.font.Line

	-- A line that is given more room than it needs sits where it says in it, which is where it is
	-- drawn: the caret goes with it, and a line with no room of its own starts at nought.
	caret.left = x + lineOffset(node, line) + pen
	caret.top = y + caret.line * lineStep + CARET_INSET
	caret.right = caret.left + CARET_WIDTH
	caret.bottom = caret.top + (height > 0 and height or lineStep)
	caret.z = z + 2
	caret.clip = clip
	caret.placed = true
end

--- The first line of text drawn inside an element, and where it ended up: the line a caret is
--- placed from, found the way the walk finds it -- the field's own, if it draws one, and otherwise
--- the first line of whatever it draws.
---@param screen wonderland.Layout.Screen
---@param index number
---@param parentX number
---@param parentY number
---@param element wonderland.Element
---@param inField boolean?
---@return wonderland.Node? node
---@return number? x
---@return number? y
---@return wonderland.font.Run? run
local function findFieldText(screen, index, parentX, parentY, element, inField)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local inside = inField or pointers[node.element] == element

	if inside and node.run ~= 0 and node.visible ~= 0 then
		return node, x, y, screen.runs[node.run]
	end

	for at = 0, node.childCount - 1 do
		local foundNode, foundX, foundY, foundRun = findFieldText(screen,
			screen.childIndices[node.firstChild + at - 1], x, y, element, inside)

		if foundNode ~= nil then
			return foundNode, foundX, foundY, foundRun
		end
	end

	return nil
end

--- Where a point in a line of text is, as a line and a byte of it. A point past the end of a line is
--- the end of that line; one above the first line or below the last is the first or the last.

--- What a glyph came from is the byte it kept, so a click lands at a character boundary.
---@param run wonderland.font.Run
---@param node wonderland.Node # What the line is drawn as, which is what says how it is aligned
---@param x number # Absolute, where the line starts
---@param y number
---@param pointX number
---@param pointY number
---@return number line
---@return number byte # How many bytes of that line come before the caret
local function caretAtPoint(run, node, x, y, pointX, pointY)
	local step = run.height / run.lineCount
	local line = math.floor((pointY - y) / step)

	if line < 0 then
		line = 0
	elseif line > run.lineCount - 1 then
		line = run.lineCount - 1
	end

	local glyphLine = run.lines[line] ---@type wonderland.font.Line
	local glyphs = run.glyphs

	if glyphLine == nil or glyphs == nil or glyphLine.count <= 0 then
		return line, 0
	end

	-- Measured from the same left edge and across the same pens the line was drawn along, so a click
	-- between two glyphs puts the caret where those two glyphs are.
	local first, count = glyphLine.first, glyphLine.count
	local target = pointX - x - lineOffset(node, glyphLine)

	-- A line that reads right to left is drawn from the right, so a gap between two of its glyphs is
	-- the byte the glyph on the right of the gap came from, and the gap at its far left is the end of
	-- the line.
	if glyphLine.rtl ~= 0 then
		for at = 0, count - 1 do
			local glyph = glyphs[first + at]

			if target < glyph.pen + glyph.advance / 2 then
				return line, at > 0 and glyphs[first + at - 1].cluster or PAST_THE_LINE
			end
		end

		return line, glyphs[first + count - 1].cluster
	end

	local best, bestDistance = PAST_THE_LINE, math.abs(glyphLine.width - target)

	for at = 0, count - 1 do
		local glyph = glyphs[first + at]
		local distance = math.abs(glyph.pen - target)

		if distance < bestDistance then
			best, bestDistance = glyph.cluster, distance
		end
	end

	return line, best
end

---@param batch wonderland.QuadBatch
---@param caret wonderland.plugin.UI.Caret
---@param windowWidth number
---@param windowHeight number
local function addCaretQuad(batch, caret, windowWidth, windowHeight)
	if not caret.placed then
		return
	end

	clippedQuad(batch, caret.clip, windowWidth, windowHeight, caret.left, caret.top, caret.right,
		caret.bottom, convertZ(caret.z), caret.r, caret.g, caret.b, caret.a, 0, 0, 0, 1, 1)
end

--- Walks the laid out screen, which is an array of nodes: a walk is an index and an
--- offset, and children are reached through the runs of child indices.
---@param batch wonderland.QuadBatch
---@param screen wonderland.Layout.Screen
---@param index number
---@param parentX number
---@param parentY number
---@param windowWidth number
---@param windowHeight number
---@param parentZ number?
---@param fontManager FontManager
---@param caret wonderland.plugin.UI.Caret? # The caret of the field that has the keyboard, if one has it
---@param inField boolean? # Whether this node is inside that field, which is where the caret is
local function generateNodeQuads(batch, screen, clip, index, parentX, parentY, windowWidth, windowHeight, parentZ,
	fontManager, caret, inField)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local z = math.max(node.zIndex, parentZ or 0)

	-- Only looked at when there is a caret to place: a screen with no field focused is walked
	-- without reaching for the element behind a node at all.
	local element = caret and pointers[node.element] or nil
	local inside = inField or (caret ~= nil and element ~= nil and element == caret.element)

	-- The colour of a caret is the field's, wherever in it the caret turns out to be placed from:
	-- one nothing named a colour for is drawn white, since a field whose text cannot be seen is one
	-- whose caret should at least be there.
	if caret ~= nil and inside and not inField and element ~= nil and element == caret.element then
		local field = node

		if field.fgA == 0 then
			caret.r, caret.g, caret.b, caret.a = WHITE_R, WHITE_G, WHITE_B, WHITE_A
		else
			caret.r, caret.g, caret.b, caret.a =
				field.fgR / 255, field.fgG / 255, field.fgB / 255, field.fgA / 255
		end
	end

	-- The shadow first, so the box is drawn over it. It is the box itself, moved and drawn with
	-- its edge spread out: the quad it is drawn as is the box grown by that spreading, and the
	-- cut the shader makes is of the box, so what shows is the box's own shape going soft.
	if node.visible ~= 0 and node.shadowA > 0 then
		local blur = node.shadowBlur
		local band = blur > 0 and (1 / (2 * blur)) or 1

		clippedQuad(batch, clip, windowWidth, windowHeight, x + node.shadowX, y + node.shadowY,
			x + node.shadowX + node.width, y + node.shadowY + node.height, convertZ(z),
			node.shadowR / 255, node.shadowG / 255, node.shadowB / 255, node.shadowA / 255,
			0, 0, 0, 1, 1, node.radius, band, blur + 1)
	end

	if node.visible ~= 0 and node.paint ~= 0 then
		local r, g, b, a = node.bgR, node.bgG, node.bgB, node.bgA

		if node.texture ~= 0 and r == 0 and g == 0 and b == 0 then
			r, g, b, a = WHITE_R, WHITE_G, WHITE_B, WHITE_A
		end

		clippedQuad(batch, clip, windowWidth, windowHeight, x, y, x + node.width, y + node.height,
			convertZ(z), r, g, b, a, node.texture, node.u0, node.v0, node.u1, node.v1, node.radius)
	end

	if node.visible ~= 0 and node.run ~= 0 then
		generateTextQuads(batch, clip, assert(screen.runs[node.run]), node, x, y, z, fontManager, windowWidth,
			windowHeight)
	end

	-- Borders come after the box they are on, so they land on top of it.
	if node.visible ~= 0 then
		local r, g, b, a = node.borderR, node.borderG, node.borderB, node.borderA
		local width, height = node.width, node.height

		if node.borderTop > 0 then
			addBorderQuad(batch, clip, x, y, width, node.borderTop, r, g, b, a, z, windowWidth, windowHeight)
		end

		if node.borderBottom > 0 then
			addBorderQuad(batch, clip, x, y + height - node.borderBottom, width, node.borderBottom, r, g, b, a, z,
				windowWidth, windowHeight)
		end

		if node.borderLeft > 0 then
			addBorderQuad(batch, clip, x, y, node.borderLeft, height, r, g, b, a, z, windowWidth, windowHeight)
		end

		if node.borderRight > 0 then
			addBorderQuad(batch, clip, x + width - node.borderRight, y, node.borderRight, height, r, g, b, a, z,
				windowWidth, windowHeight)
		end
	end

	-- What a box that scrolls shows of its children is what is inside it: the clip is narrowed to
	-- it, and stays narrowed for everything below.
	local below = clip

	if node.scrolls ~= 0 then
		below = {
			left = math.max(clip.left, x),
			top = math.max(clip.top, y),
			right = math.min(clip.right, x + node.width),
			bottom = math.min(clip.bottom, y + node.height),
		}
	end

	-- The caret is placed from the line of text a field draws, which is the first one inside it --
	-- what a caret is beside is the text, and where the app put the text is where it goes. A field
	-- that draws none is placed from its own content origin, which is the fallback below.
	if caret ~= nil and inside and node.run ~= 0 and node.visible ~= 0 and not caret.placed then
		placeCaret(caret, assert(element), node, x, y, z, below, fontManager)
	end

	for at = 0, node.childCount - 1 do
		generateNodeQuads(batch, screen, below, screen.childIndices[node.firstChild + at - 1], x, y, windowWidth,
			windowHeight, z, fontManager, caret, inside)
	end

	if caret ~= nil and element ~= nil and element == caret.element and node.visible ~= 0 and not caret.placed then
		placeCaret(caret, element, node, x + node.paddingLeft, y + node.paddingTop, z, below, fontManager)
	end

	-- A scroll bar is drawn over the strip it reserved, once the content is down: the track is the
	-- colour it was given made fainter, and the thumb is as much of the track as the box shows of
	-- the content. It is only there when there is something to scroll, which is what "shows up"
	-- means -- a list that fits has no bar.
	local bar = node.scrolls ~= 0 and screen.bars[index - 1]

	if node.visible ~= 0 and bar and bar.width > 0 and bar.max > 0 then
		local left = x + node.width - bar.width
		local thumb = node.height * (node.height / (node.height + bar.max))

		if thumb < bar.least then
			thumb = bar.least
		end

		if thumb > node.height then
			thumb = node.height
		end

		-- Where the thumb may travel is what is left of the box once the thumb is in it, so the
		-- end of the list puts the thumb's end at the end of the box rather than past it.
		local span = node.height - thumb
		local at = math.min(math.max(node.scroll / bar.max, 0), 1)
		local top = y + (span > 0 and at * span or 0)

		-- Drawn inside its own pane rather than the clip it is under, so a bar cannot come out of
		-- the box it belongs to and over whatever is beside it.
		clippedQuad(batch, below, windowWidth, windowHeight, left, y, left + bar.width, y + node.height,
			convertZ(z), bar.r, bar.g, bar.b, bar.a * 0.25, 0, 0, 0, 1, 1)
		clippedQuad(batch, below, windowWidth, windowHeight, left, top, left + bar.width, top + thumb,
			convertZ(z + 1), bar.r, bar.g, bar.b, bar.a, 0, 0, 0, 1, 1)
	end
end


--- A frame is asked for, at most one for each frame the display has time to show. What the
--- question is asked about is a window, so what says when the last frame went out is kept with it.
--- A frame asked for before that time is not lost: what the screen says goes into the frame that
--- is still to come, and the event after this one asks again.
---@param window wonderland.RenderWindow
---@param forced boolean? # Whether the frame is the window's own, which is not held back
function UI:requestRedraw(window, forced)
	local ctx = self.layoutPlugin.contexts[window]
	local at = now()

	if ctx then
		-- Whether the screen is what asked for the frame: a frame asked for by the screen is one
		-- that may not be worth drawing, and one asked for by the window is not.
		ctx.asked = true

		-- What the events left is owed a screen, whether this frame is the one it is drawn in or
		-- one the display asks for later: a frame that is built without it is a frame of the screen
		-- before the events.
		ctx.owed = true

		-- A frame the window manager asked for is the display's own time: one that was held back
		-- for coming too soon is the one that goes out then, so what a window shows is the state
		-- its events left rather than the state they left a frame ago.
		if not forced and not window.frameAsked and at - (ctx.framedAt or 0) < self.frameInterval then
			return
		end

		ctx.framedAt = at
	end

	window.shouldRedraw = true -- shh. I'll figure out a way to make this use the eventhandler later.
end

--- A window that changed size is another solve of the same screen, because the screen is laid
--- out against the window; one the pointer moved in may be drawn differently where the pointer
--- is. Both are another repaint, and a repaint that comes out the same as the last one costs a
--- solve and no more, so this does not have to be clever about which of them changed anything.
---
--- The screen is not built here, though: what these events change is what the *frame* is built
--- from, and a frame is built once however many events asked for it. A pointer dragged across a
--- window is hundreds of events a second and a frame each is sixty, so a screen built per event is
--- a window that falls further behind the pointer the faster it is dragged -- and, once the events
--- arrive faster than a screen is built, one that never draws at all.
---
--- The layout is asked before this is, because the plugins are asked in the order they were
--- added, and it is the layout that says where the pointer is.
---@param event winit.Event
---@param _handler winit.EventManager
function UI:event(event, _handler)
	local name = event.name

	if name == "redraw" then
		return self:frame(event.window)
	end

	if name == "resize" or name == "mouseMove" or name == "mousePress"
		or name == "mouseRelease" or name == "focusOut" then
		-- A resize is the window rather than what the screen says, and how often it happens is
		-- the window manager's -- a size a frame is shown at, at worst -- so it is not rationed
		-- by the frame's time: a resize held back for coming too soon is a window left at the
		-- size it had, which is a window that looks frozen for as long as nothing else happens.
		self:requestRedraw(event.window, name == "resize")
	end
end

--- The caret as this frame has it: which field it is for and where in it, or nothing where no
--- field has the keyboard. What is typed into the field is kept by handle, since measuring it is
--- what the caret's own place is worked out from.
---@param window wonderland.RenderWindow
---@return wonderland.plugin.UI.Caret?
function UI:caretFor(window)
	local element, line, column = self.layoutPlugin:getCaret(window)

	if element == nil then
		return nil
	end

	return {
		element = element,
		value = element.inputValue,
		line = line,
		column = column,
	}
end

--- A click in a field, put where the caret goes: the point that was clicked, against the text the
--- field draws -- the run of it, and where the walk put it -- as the line and the column the layout
--- is told to put the caret at. It is against the frame that was on screen when the pointer went
--- down, which is the one the pointer was over.
---
--- A field that draws no text of its own is left where the click put it, which is the end of what
--- it holds: where in a field a click is is a question about the text in it, and a field with none
--- has no answer to it.
---@param window wonderland.RenderWindow
function UI:caretClick(window)
	local ctx = self.layoutPlugin.contexts[window]
	local click = ctx and ctx.caretClick

	if click == nil or ctx == nil or ctx.focusedName == nil or ctx.ui == nil or ctx.screen == nil then
		return
	end

	-- Taken whatever comes of it: a click that cannot be placed is a click that is done with, and
	-- one left behind would be put against a frame built later than the one it landed in.
	ctx.caretClick = nil

	local element = self.layoutPlugin:getCaret(window)

	if element == nil then
		return
	end

	local node, x, y, run = findFieldText(assert(ctx.screen), assert(ctx.root), 0, 0, element)

	if node == nil or x == nil or y == nil or run == nil then
		return
	end

	local line, column = caretAtPoint(run, node, x, y, click.x, click.y)

	self.layoutPlugin:setCaret(window, line, column)
end

--- The caret's clock: a caret is drawn for half a second and not for half a second, which is the
--- one thing in a screen that changes on its own. What comes of it is one quad, so the frame it
--- belongs to is not built again for it: see `UI:frame`.
---@param ctx wonderland.plugin.Layout.Context
---@return boolean blinked # Whether the caret came or went, which is a frame's worth of change
function UI:blink(ctx)
	if ctx.focusedName == nil then
		return false
	end

	if ctx.caretOn == nil then
		-- Nothing has blinked yet: a caret that comes with the typing starts by being shown.
		ctx.caretOn, ctx.caretAt = true, now()

		return false
	end

	if self.caretBlink <= 0 then
		ctx.caretOn = true

		return false
	end

	local at = now()

	if ctx.caretAt ~= nil and at - ctx.caretAt < self.caretBlink then
		return false
	end

	ctx.caretAt = at
	ctx.caretOn = not ctx.caretOn

	return true
end

--- What a screen has to do on its own, and when it next does it: a caret that blinks, a key held
--- down in a field, and a gif moving on to its next frame. None of them is a whole screen -- a blink
--- is one quad of the frame the gpu has, and a repeat is one character -- and all of them are what a
--- loop with no timer in it has to be woken for.
---
--- This is what the loop is asked for the time of: it waits for the next event, of which an idle
--- window has none, so a screen with something to do is one that has to say when it wants waking.
--- The frame the end of that wait asks for is the caret coming or going or the key repeating, since
--- whether either is due is the same clock this reads.
---
--- What a repeated key came to is handed back, because the value it edited is the app's: what an edit
--- is told is the app rather than the screen, and where an event's message goes is the app -- so a
--- repeat is a message from somewhere other than an event. See `app.run`, which passes it on.
---
--- A key held down is repeated here rather than by the keyboard, at the rate the layout was given
--- rather than at the keyboard's: what a keyboard repeats of a held key is the same key, and taking
--- its repeats as well would be the two rates added together -- a hold that takes two characters at
--- some moments and one at others. Which presses are the keyboard's own is not something that can be
--- worked out from what arrives, so it is not worked out: it is said, by the keyboard in winit,
--- which marks the press of a repeat -- see `Layout:event`.
---@param window wonderland.RenderWindow
---@param handler winit.EventManager
---@return any? message # What a key that was due to repeat came to, if one was due
function UI:tick(window, handler)
	local ctx = self.layoutPlugin.contexts[window]

	if not ctx then
		return
	end

	local layout = self.layoutPlugin
	local at = now()
	local due = nil ---@type number?
	local message = nil

	if ctx.repeatKey ~= nil and layout.keyRepeatInterval > 0 then
		if ctx.repeatAt == nil then
			-- A key that has just gone down, which is what having no next repeat yet means: what comes
			-- first is the wait before it repeats at all.
			ctx.repeatAt = at + layout.keyRepeatDelay
		end

		if at >= ctx.repeatAt then
			message = layout:key(window, ctx.repeatKey, ctx.repeatMods, ctx.repeatTyped or ctx.repeatKey)
			ctx.repeatAt = at + layout.keyRepeatInterval

			-- A frame of its own, for the same reason a blink is one: a repeat held back for coming
			-- too soon would leave the last of what a held key did on screen until the next event,
			-- which is the key coming up -- a character left behind.
			--
			-- Only where a repeat was a change, though: a key held at the end of what it can do --
			-- backspace in a field with nothing in front of the caret -- is a repeat that came to
			-- nothing, and a frame of the whole screen for nothing is the cost of a hold paid at the
			-- rate of a hold rather than the rate of what it does.
			if message ~= nil then
				self:requestRedraw(window, true)
			end
		end

		due = ctx.repeatAt
	end

	-- The caret, which is the other thing a screen does with no event behind it. What has the
	-- keyboard is not always a caret: a thing the keyboard was tabbed to that answers a click is
	-- a keyboard with nothing blinking under it, and a frame every half second for a caret that
	-- is not there is a screen drawing itself for nothing.
	if self.caretBlink > 0 and self.layoutPlugin:getCaret(window) ~= nil then
		local blink = (ctx.caretAt or at) + self.caretBlink

		if at >= blink then
			-- What is due is a frame, and it is the caret's own clock that has kept it rather than the
			-- frame's: the frame's time is what holds a frame back, so it is not asked through it. The
			-- caret's coming or going is `UI:blink`, which the frame that comes of this runs.
			self:requestRedraw(window, true)
			blink = at + self.caretBlink
		end

		due = due ~= nil and math.min(due, blink) or blink
	end

	-- A gif, which is the other thing a screen draws that changes with no event behind it. What
	-- frame of one is being shown is the clock's, and the frame is a texture and the part of a
	-- layer, which are what a style names: nothing short of a rebuild shows the next one. So a
	-- gif that moved on leaves the screen owed a frame, which the block below asks for at the
	-- display's own rate, and the time the one after it is due is what the loop is woken for.
	local shared = self.renderPlugin.sharedResources
	local assets = shared and shared.assets

	if assets ~= nil then
		if assets:advance(at) then
			ctx.owed = true
		end

		local frames = assets:due()

		if frames ~= nil then
			due = due ~= nil and math.min(due, frames) or frames
		end
	end

	-- What the app asked to be woken for, asked here because this is the one moment a loop with
	-- nothing in it has: it is what a player reads its position on, what a decoder takes the next
	-- frame out of a file on, and what a screen pacing itself to something other than the display
	-- -- a video, an audio clock -- is driven by. A callback that answered nothing is done with,
	-- and one that is done with is dropped here rather than kept to be asked again.
	local tickers = self.tickers
	local live = 0

	for index = 1, #tickers do
		local ticker = tickers[index]

		if ticker.window == nil then
			ticker.window = window
		end

		if not ticker.cancelled and ticker.window == window then
			if ticker.due == nil or at >= ticker.due then
				local wait = ticker.fn(at, window)

				if wait == nil then
					ticker.cancelled = true
				else
					ticker.due = at + math.max(wait, 0)
				end
			end

			if not ticker.cancelled then
				live = live + 1
				tickers[live] = ticker

				local nextAt = assert(ticker.due)

				if nextAt <= at then
					-- A callback that wants to be asked again straight away is one that is racing
					-- the loop rather than the clock, and the loop is given no wait at all: it
					-- comes round as fast as it can, which is what decoding a burst of frames out
					-- of a file is.
					due = due ~= nil and math.min(due, at) or at
				else
					due = due ~= nil and math.min(due, nextAt) or nextAt
				end
			end
		elseif not ticker.cancelled then
			live = live + 1
			tickers[live] = ticker
		end
	end

	for index = #tickers, live + 1, -1 do
		tickers[index] = nil
	end

	-- What the events left, drawn as soon as the display's time allows it. A frame that came too soon
	-- to go out is one the event after it would have asked for again -- and an event that never comes
	-- is a screen left showing what was typed before it, which is what a keystroke that landed on the
	-- heels of another frame would be. So the ask is made again here, where nothing has to arrive for
	-- the loop to be woken: the ration is the same one, so this is a frame at the rate of a frame and
	-- no faster.
	if ctx.owed then
		local ready = (ctx.framedAt or 0) + self.frameInterval

		if at >= ready then
			self:requestRedraw(window, true)
		else
			due = due ~= nil and math.min(due, ready) or ready
		end
	end

	if due ~= nil then
		handler:setTimeout(due - at)
	end

	return message
end

--- The quads of a frame, built from the screen the layout solved and handed to the gpu: the walk,
--- and the caret of the field that has the keyboard added last so that a blink is the frame's last
--- quad rather than a frame of its own.
---
--- The caret is what a frame's quads are remembered by as well as the screen: a caret that moved in
--- a screen that did not is a frame the gpu has to be given again, and one that only blinked is
--- the same frame with that last quad in or out -- which is what `UI:frame` tells apart.
---@param window wonderland.RenderWindow
---@param ctx wonderland.plugin.Layout.Context
---@param key string? # The caret as this frame draws it, for the next one to tell it changed
function UI:walk(window, ctx, key)
	local fontManager = assert(self.renderPlugin.sharedResources).fontManager
	local batch = self.batch
	local caret = self:caretFor(window)

	-- The size the frame is drawn into: the surface under the window rather than the size the
	-- window says it is, which is what the quads are written against and what the clip is. See
	-- `wonderland.plugin.Render:size`.
	local width, height = self.renderPlugin:size(window)

	batch:reset()
	batch:setViewport(width, height)

	generateNodeQuads(batch, assert(ctx.screen), { left = 0, top = 0, right = width,
		bottom = height }, assert(ctx.root), 0, 0, width, height, nil, fontManager, caret)

	-- What the caret's quad is added to: the frame is the quads of the screen and then it, so a
	-- blink is this many of them and no more.
	ctx.caret = caret and caret.placed and caret or nil
	ctx.caretBase = batch.quads

	-- A caret that has not blinked yet is a caret that is drawn: nothing has said it should not be,
	-- and the first thing a field that takes the keyboard does is show where the typing goes.
	if ctx.caret ~= nil and ctx.caretOn ~= false then
		addCaretQuad(batch, ctx.caret, width, height)
	end

	self.renderPlugin:setRenderData(window, batch)
	ctx.uploaded = true
	ctx.frameKey = key
end

--- The caret coming or going: the last quad of the frame the gpu has is the caret's, so this is
--- the frame without it or the frame with it again -- the quads are handed over and nothing is
--- measured, solved or walked. It is the whole of what a blink costs.
---@param window wonderland.RenderWindow
---@param ctx wonderland.plugin.Layout.Context
function UI:toggle(window, ctx)
	local caret = ctx.caret

	if caret == nil or ctx.caretBase == nil then
		return
	end

	if ctx.caretOn then
		if self.batch.quads <= ctx.caretBase then
			local width, height = self.renderPlugin:size(window)

			addCaretQuad(self.batch, caret, width, height)
		end
	else
		-- Taken out with the runs it was in, which is what a frame is drawn from: what is left is
		-- the frame the gpu was given before the caret was put in.
		self.batch:truncate(ctx.caretBase)
	end

	self.renderPlugin:setRenderData(window, self.batch)
end

--- One frame of a window: the screen the state says, and the caret of the field that has the
--- keyboard.
---
--- The screen is built when something is owed it -- what the events left, a window that changed
--- size, a window that has never been drawn -- and not otherwise: a frame the display asked for
--- with nothing behind it is a frame of what is already built, which is what keeps a window that
--- is doing nothing from solving and drawing the whole of its ui at the rate of the display.
---
--- A frame the *screen* asked for that came out the same as the one already on screen is not drawn
--- either: a pointer that moved across an element that does not change for it, a message that
--- changed nothing the screen shows, and a window drawn again for a frame that is already there are
--- frames that would show nothing new, and drawing one spends the display's time on it -- which is
--- time the events behind it spend queued. A frame the *window* asked for is drawn whatever it
--- comes out to, because what it is for is a window that lost what it was showing: an expose, a
--- surface the gpu is not ready to draw into yet.
---@param window wonderland.RenderWindow
function UI:frame(window)
	local ctx = self.layoutPlugin.contexts[window]

	if not ctx then
		return
	end

	-- Where a click in a field put the caret, before anything is built out of it: the point is
	-- against the frame that was on screen when the pointer went down, and the caret it comes to is
	-- one of the things this frame draws.
	self:caretClick(window)

	-- An ask is answered by the frame that comes out of it, which is where the window is told the
	-- frame is ready: see `X11Window:acknowledgeSync`, which is what puts the ask away.
	local asked = ctx.asked or window.frameAsked

	ctx.asked = nil

	-- What the events left for the screen, which is the only reason to look at the view again.
	local owed = ctx.owed or not ctx.uploaded

	ctx.owed = false

	-- What this frame draws into is taken before any of it is built: a screen laid out at the size
	-- of the last frame's target and drawn into this one's is a screen the compositor stretches,
	-- which during a resize is every frame of it.
	if (owed or not ctx.presented) and not self.renderPlugin:retarget(window) then
		return
	end

	if owed then
		self.layoutPlugin:refreshView(window)
	end

	-- Where the caret is, which the frame's quads are remembered by as well as the screen: a caret
	-- that moved is a frame to build again, and one that only blinked is not.
	local element, line, column = self.layoutPlugin:getCaret(window)
	local key = element ~= nil and (tostring(ctx.focusedName) .. ":" .. line .. ":" .. column) or nil

	if key ~= ctx.frameKey then
		-- A caret that moved is drawn from the start of its blink, which is what an editor does
		-- while you type: one that happened to be out at the moment of the typing would be a caret
		-- that goes away exactly when it is looked at. The clock starts again *now* rather than
		-- being forgotten: a blink with no time to it is one that is due, and a caret that has just
		-- been moved would go out on the frame it was moved in.
		ctx.caretOn, ctx.caretAt = true, now()
	end

	local blinked = self:blink(ctx)
	local built = false

	if owed then
		-- The screen that came out, the first frame of a window, and the caret that moved in a screen
		-- that did not: any of them is a frame the gpu does not have. A solve that came out the same,
		-- with a caret that stayed where it was, is not -- and that frame costs the view and no more.
		if assert(ctx.screen).changed or not ctx.uploaded or key ~= ctx.frameKey then
			built = true
			self:walk(window, ctx, key)
		end
	end

	-- The caret coming or going is one quad of the frame the gpu already has -- which is a frame
	-- whether or not the screen was owed one, since the clock the caret blinks on is its own. A
	-- frame that was walked drew the caret as it is now, so there is nothing to put in or out.
	if blinked and not built then
		built = true
		self:toggle(window, ctx)
	end

	if built or blinked or not asked or not ctx.presented then
		ctx.presented = true
		ctx.framedAt = now()
		self.renderPlugin:draw(assert(self.renderPlugin:getContext(window)))
	end
end

--- A repaint that is not a frame: a window being registered, or a screen drawn by hand. The screen
--- is built and given to the gpu, and the frame it came out to is asked for, which is what a
--- window loop draws.
---@param window wonderland.RenderWindow
function UI:refreshView(window)
	-- A click in a field is placed from the frame that was on screen when the pointer went down, so
	-- it is placed before this repaint builds the next one: see `UI:caretClick`.
	self:caretClick(window)
	self.layoutPlugin:refreshView(window)

	local ctx = self.layoutPlugin.contexts[window]

	if not ctx then
		return
	end

	ctx.owed = false

	local element, line, column = self.layoutPlugin:getCaret(window)
	local key = element ~= nil and (tostring(ctx.focusedName) .. ":" .. line .. ":" .. column) or nil

	-- A repaint that comes out the same, with a caret that stayed where it was, is a repaint that
	-- has nothing to upload and no frame to ask for: the gpu already has this one.
	if not (assert(ctx.screen).changed or not ctx.uploaded or key ~= ctx.frameKey) then
		return
	end

	self:walk(window, ctx, key)
	self:requestRedraw(window)
end

return UI
