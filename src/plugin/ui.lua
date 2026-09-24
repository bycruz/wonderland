local ffi = require("ffi")
local QuadBatch = require("wonderland.util.quad_batch")
local wonderlandElement = require("wonderland.element")

-- The element arena, read by the node's index into it: what a caret is for, and what has been
-- typed into the field it belongs to.
local pointers, strings = wonderlandElement.pointers, wonderlandElement.strings

-- When a frame went out, on a clock that keeps running while the process does not. A window that
-- is waiting for the next event uses no time at all, and it is that wait the frame after it is
-- measured against: `os.clock` counts the work the process has done, so a window that sat idle
-- for a second would say a frame had just gone out -- and refuse every frame after it, which is
-- a window that stops answering. The call that has that time is the same on every platform but
-- its name, and it is the time since some fixed point, which is all a difference needs.
ffi.cdef [[
	struct wl_timeval { long tv_sec; long tv_usec; };
	int gettimeofday(struct wl_timeval *time, void *zone);
	unsigned long long GetTickCount64(void);
]]

--- The two halves of a time, as that call writes them. The language server cannot see an
--- ffi.cdef, so the fields are spelled out here: it is the only way to get them checked.
---@class wonderland.plugin.UI.Timeval: ffi.cdata*
---@field tv_sec number
---@field tv_usec number

local native = ffi.os == "Windows" and ffi.load("kernel32") or ffi.C
-- ffi.new is typed as a bare pointer, so the fields it has are the ones spelled out above.
---@diagnostic disable-next-line: assign-type-mismatch
local timeval = ffi.new("struct wl_timeval") ---@type wonderland.plugin.UI.Timeval

---@return number # Seconds, for telling one moment from another
local function now()
	if ffi.os == "Windows" then
		return tonumber(native.GetTickCount64()) / 1000
	end

	native.gettimeofday(timeval, nil)

	return tonumber(timeval.tv_sec) + tonumber(timeval.tv_usec) / 1000000
end

---@class wonderland.plugin.UI: wonderland.Plugin
---@field layoutPlugin wonderland.plugin.Layout
---@field renderPlugin wonderland.plugin.Render
---@field batch wonderland.QuadBatch
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
		frameInterval = FRAME_INTERVAL,
		caretBlink = CARET_BLINK,
	}, UI)
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
---@field column number # And how many glyphs of that line come before it
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
	texture, u0, v0, u1, v1, radius, band, grow)
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
				band
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
				u0, v0, u1, v1
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
			band
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
		u0 + du * (atRight - drawnLeft), v0 + dv * (atBottom - drawnTop)
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
	local font = node.font ~= 0 and (node.font - 1)
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

			clippedQuad(batch, clip, windowWidth, windowHeight, originX + glyph.x, y + glyph.y,
				originX + glyph.x + glyph.width, y + glyph.y + glyph.height, zIndex, r, g, b,
				node.fgA / 255, font, glyph.u0, glyph.v0, glyph.u1, glyph.v1)
		end
	end
end

--- Where the caret is, as the pen it sits at: a line of a run starts at the line's first glyph,
--- and what comes before the caret on it is the advances of the glyphs before it -- the same whole
--- pixel advances the pen that placed them was moved by, so the caret lands on the pixel the
--- character after it starts at rather than inside it.
---@param run wonderland.font.Run
---@param line number
---@param column number
---@return number pen # From the left edge of the run
---@return number lineStep # How tall a line of it is, which the caret is drawn no taller than
local function caretPen(run, line, column)
	local lineStep = run.height / run.lineCount
	local glyphs = run.glyphs
	local glyphLine = run.lines[line] ---@type wonderland.font.Line

	if glyphs == nil or glyphLine == nil then
		return 0, lineStep
	end

	-- A column past the end of the line is the end of the line: what is typed after it is not on
	-- it yet, and a value of more bytes than the atlas has glyphs -- one with a character outside
	-- it -- puts the caret at the end rather than nowhere.
	local last = math.min(column, glyphLine.count)
	local pen = 0

	for at = 0, last - 1 do
		pen = pen + glyphs[glyphLine.first + at].advance
	end

	return pen, lineStep
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
	local font = element.fontId ~= 0 and element.fontId
		or assert(fontManager:getDefault(), "No font to draw text with: load one and make it the default")
	local run = fontManager:getBitmap(font):getRun(value)
	local pen, lineStep = caretPen(run, caret.line, caret.column)
	local height = lineStep - CARET_INSET * 2
	local line = run.lines[caret.line] ---@type wonderland.font.Line

	-- A line that is given more room than it needs sits where it says in it, which is where it is
	-- drawn: the caret goes with it, and a line with no room of its own starts at nought.
	local offset = 0

	if line ~= nil and node.run ~= 0 then
		if node.justify == 1 then
			offset = math.floor((node.width - line.width) / 2 + 0.5)
		elseif node.justify == 2 then
			offset = node.width - line.width
		end
	end

	caret.left = x + offset + pen
	caret.top = y + caret.line * lineStep + CARET_INSET
	caret.right = caret.left + CARET_WIDTH
	caret.bottom = caret.top + (height > 0 and height or lineStep)
	caret.z = z + 2
	caret.clip = clip
	caret.placed = true
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

--- What a screen has to do on its own, and when it next does it: a caret that blinks is the one
--- thing, and the frame that comes of it is one quad.
---
--- This is what the loop is asked for the time of: it has no timer in it -- it waits for the next
--- event, of which an idle window has none -- so a screen with something to do is one that has to
--- say when it wants waking. The frame the end of that wait asks for is the caret coming or going,
--- since whether it is due is the same clock this reads.
---@param window wonderland.RenderWindow
---@param handler winit.EventManager
function UI:tick(window, handler)
	local ctx = self.layoutPlugin.contexts[window]

	if not ctx or ctx.focusedName == nil or self.caretBlink <= 0 then
		return
	end

	local at = now()
	local due = (ctx.caretAt or at) + self.caretBlink

	if at >= due then
		-- What is due is a frame, and it is the caret's own clock that has kept it rather than the
		-- frame's: the frame's time is what holds a frame back, so it is not asked through it. The
		-- caret's coming or going is `UI:blink`, which the frame that comes of this runs.
		self:requestRedraw(window, true)
		due = at + self.caretBlink
	end

	handler:setTimeout(due - at)
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

	batch:reset()
	batch:setViewport(window.width, window.height)

	generateNodeQuads(batch, assert(ctx.screen), { left = 0, top = 0, right = window.width,
		bottom = window.height }, assert(ctx.root), 0, 0, window.width, window.height, nil, fontManager, caret)

	-- What the caret's quad is added to: the frame is the quads of the screen and then it, so a
	-- blink is this many of them and no more.
	ctx.caret = caret and caret.placed and caret or nil
	ctx.caretBase = batch.quads

	-- A caret that has not blinked yet is a caret that is drawn: nothing has said it should not be,
	-- and the first thing a field that takes the keyboard does is show where the typing goes.
	if ctx.caret ~= nil and ctx.caretOn ~= false then
		addCaretQuad(batch, ctx.caret, window.width, window.height)
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
			addCaretQuad(self.batch, caret, window.width, window.height)
		end
	else
		self.batch.quads = ctx.caretBase
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

	-- An ask is answered by the frame that comes out of it, which is where the window is told the
	-- frame is ready: see `X11Window:acknowledgeSync`, which is what puts the ask away.
	local asked = ctx.asked or window.frameAsked

	ctx.asked = nil

	-- What the events left for the screen, which is the only reason to look at the view again.
	local owed = ctx.owed or not ctx.uploaded

	ctx.owed = false

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
