local bit = require("bit")
local Canvas = require("wonderland.canvas")
local ffi = require("ffi")
local QuadBatch = require("wonderland.util.quad_batch")
---@type wonderland.QuadBatch.Request
local request = assert(QuadBatch.request)
local style = require("wonderland.style")
local wonderlandElement = require("wonderland.element")
local time = require("wonderland.time")

-- The element arena, read by the node's index into it: what a caret is for, and what has been
-- typed into the field it belongs to.
local pointers, strings = wonderlandElement.pointers, wonderlandElement.strings
local callbacks = wonderlandElement.callbacks

-- The picture a shape of a canvas is drawn with, which is the one a box with no picture of its own
-- is drawn with: a white pixel, so what a shape comes to is the colour it was given.
local WHITE_TEXTURE = 0

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
---@field cancel fun() # Done with it, before its next turn
---@field present fun() # A frame asked for now, for what it just did
---@field ui wonderland.plugin.UI?

---@class wonderland.plugin.UI: wonderland.Plugin
---@field layoutPlugin wonderland.plugin.Layout
---@field renderPlugin wonderland.plugin.Render
---@field batch wonderland.QuadBatch
---@field tickers wonderland.plugin.UI.Ticker[] # What the app asked to be called back on
---@field frameClip wonderland.plugin.UI.Clip? # The clip of a frame being walked: see `UI:walk`
---@field frame (fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow))?
---@field present fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow)
---@field requestRedraw fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)
---@field frame fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow)
---@field refreshView fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow)
---@field toggle fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, ctx: wonderland.plugin.Layout.Context)
---@field tick fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, handler: winit.EventManager): any?
---@field caretFor fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow): any
---@field frameInterval number # The least time between frames, in seconds, for a window whose display rate is not known: see `UI:intervalOf`
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
---@return wonderland.plugin.UI
function UI.new(layoutPlugin, renderPlugin)
	return setmetatable({
	layoutPlugin = layoutPlugin,
	renderPlugin = renderPlugin,
	batch = QuadBatch.new(),
	canvas = Canvas.new(),
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
---@param self wonderland.plugin.UI
function UI:onTick(fn, window)
	local ui = self
	---@type wonderland.plugin.UI.Ticker
	local ticker = { fn = fn, window = window, ui = ui}

	ticker.cancel = function()
		ticker.cancelled = true
	end

	ticker.present = function()
		if ticker.window ~= nil then
			ui:present(ticker.window)
		end
	end

	self.tickers[#self.tickers + 1] = ticker

	return ticker
end

--- A frame asked for now rather than at the display's own rate: what a screen that has just been
--- given something new to show asks for. See `UI:requestRedraw`, which is the rationed one.
---
--- What is asked for this way is drawn whatever the frame comes out to: a screen that says it has
--- something new to show is one whose new thing is not in the quads -- a texture another renderer
--- draws into, a picture a decoder wrote -- and a frame that came out the same as the last one is
--- one that is skipped only where nothing outside the screen changed.
---@param window wonderland.RenderWindow
---@param self wonderland.plugin.UI
function UI:present(window)
	local ctx = self.layoutPlugin.contexts[window]

	if ctx then
		ctx.mustDraw = true
	end

	local requestRedraw = self.requestRedraw --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)]]
	requestRedraw(self, window, true)
end

-- Where a coordinate of a frame is in the frame's own numbers, which is what the gpu is given.
--
-- The window they are worked out against is taken once a frame rather than handed to every quad: a
-- frame is one size and a quad is placed in it a few thousand times, and two arguments to every one
-- of those calls are two values the recorder has to keep alive across them. What is kept is what a
-- coordinate is worth -- half the window, as the multiply it is divided by -- which is what makes
-- this a multiply rather than a division as well.
local frameScaleX, frameScaleY = 1, 1

---@param pos number

---@param pos number

--- Converts a z-index to an NDC z-value
---@param z number?
local function convertZ(z)
	return 1 - math.min(z or 0, 100000) / 1000000
end

-- A box with no colour of its own is drawn with its texture as it is, which is white.
local WHITE_R, WHITE_G, WHITE_B, WHITE_A = 255, 255, 255, 255

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
---@field from number? # The first byte of the value a selection covers, where there is one
---@field to number?
---@field covered boolean? # Whether the walk has drawn the selection, which is once a frame
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

-- What a selection is drawn in: the blue a desktop draws one in, and the colour of the text over it.
-- A highlight of the text's own colour would be invisible on a background of a shade near it, which
-- is the one thing a highlight cannot be.
local SELECTION_R, SELECTION_G, SELECTION_B = 0.23, 0.51, 0.96
local SELECTION_TEXT_R, SELECTION_TEXT_G, SELECTION_TEXT_B = 255, 255, 255

-- How wide a highlight is at the least, which is what an empty line inside a selection is drawn as:
-- a line of nothing selected still has to look like it is part of what is selected.
local SELECTION_LEAST = 6

-- A byte past the end of a line, which is what a click at the left of a right-to-left line comes to:
-- the bytes of such a line run from its right, so its left end is past every byte of it. The layout
-- clamps a column past the end of a line to the end of it -- see `Layout:setCaret`.
local PAST_THE_LINE = 1 << 24

---@class wonderland.plugin.UI.Clip
---@field left number
---@field top number
---@field right number
---@field bottom number
---@field radius number?
---@field boxLeft number?
---@field boxTop number?
---@field boxRight number?
---@field boxBottom number?

--- Whether a point is inside the rounded box of a clip: the corners are the only part of it a
--- rectangle does not say, so this is the rectangle first and the arcs after it.
---
--- A function rather than a closure made for the question, because the question is asked for every
--- quad that reaches into a rounded pane: a closure is a function made every time, and one made in
--- the middle of a frame is memory the frame did not need and a trace the recorder gives up on.
---@param clip wonderland.plugin.UI.Clip
---@param x number
---@param y number
---@param radius number
---@return boolean
local function insideRoundedCorner(clip, x, y, radius)
	local boxLeft = clip.boxLeft or clip.left
	local boxTop = clip.boxTop or clip.top
	local boxRight = clip.boxRight or clip.right
	local boxBottom = clip.boxBottom or clip.bottom
	local innerLeft, innerTop = boxLeft + radius, boxTop + radius
	local innerRight, innerBottom = boxRight - radius, boxBottom - radius
	local limit = radius * radius + 0.001

	if x < boxLeft or x > boxRight or y < boxTop or y > boxBottom then return false end
	local nearestX = x < innerLeft and innerLeft or (x > innerRight and innerRight or x)
	local nearestY = y < innerTop and innerTop or (y > innerBottom and innerBottom or y)
	local dx, dy = x - nearestX, y - nearestY

	return dx * dx + dy * dy <= limit
end

--- Whether a rectangle is wholly inside a rounded clip. The clip's rectangle cuts first; its
--- rounded box cuts the corners, and a child that reaches into one has to use the parent's shape
--- rather than its own.
---@param clip wonderland.plugin.UI.Clip
---@param left number
---@param top number
---@param right number
---@param bottom number
---@return boolean
local function insideRoundedClip(clip, left, top, right, bottom)
	local radius = clip.radius
	if radius == nil or radius <= 0 then return true end

	return insideRoundedCorner(clip, left, top, radius)
	and insideRoundedCorner(clip, right, top, radius)
	and insideRoundedCorner(clip, left, bottom, radius)
	and insideRoundedCorner(clip, right, bottom, radius)
end

--- Draws the quad the request describes, cut to the clip it is drawn in. What the quad is, where
--- it goes and what is round about it all come from `request` rather than from the call: a call of
--- fifteen values is one the recorder keeps every one of alive across, and that is the register
--- coalescing it gives up on. Writing the request first is a store a value, and what the batch is
--- handed is one pointer whose fields it reads back.
---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param request wonderland.QuadBatch.Request
local function clippedQuad(batch, clip, request)
	local left, top, right, bottom = request.left, request.top, request.right, request.bottom
	local radius, band = request.radius, request.band
	local own, blur, border = request.own, request.blur, request.border
	local banded = request.hasBand ~= 0
	local grow = request.spread

	if not banded then
		band = 1
	end

	if blur > 0 then
		-- What a blur spreads has to be drawn somewhere, so the quad is grown by the room the taps
		-- read in: twice the blur, which is as far as the furthest of them reaches.
		grow = blur * 2

		-- A box with round corners is cut where its corners are, and that cut is what fades its edge
		-- -- spread over the blur rather than over the one pixel it is antialiased by. Everything
		-- else is its own picture, and what the taps read past the part of it that is there is what
		-- fades its edge out.
		if radius > 0 then
			band = 1 / (2 * blur)
		else
			band = 0
		end

		banded = true
	end

	-- A quad that is drawn past its box is one whose edge is spread out, so what is drawn is the
	-- box and the space the spreading needs; the box itself is what the corner arithmetic is about.
	local drawnLeft, drawnTop = left - grow, top - grow
	local drawnRight, drawnBottom = right + grow, bottom + grow
	-- The quad the box asked for, when all of it shows. Most quads are inside the clip -- only the
	-- ones at the edge of a pane that scrolls are not -- and working out where a quad is cut costs
	-- a pair of divisions, so the ones that need nothing are the ones that get nothing.
	local rounded = clip.radius ~= nil and clip.radius > 0
	local cutRound = rounded and not insideRoundedClip(clip, drawnLeft, drawnTop, drawnRight, drawnBottom)

	if not cutRound and drawnLeft >= clip.left and drawnTop >= clip.top and drawnRight <= clip.right
	and drawnBottom <= clip.bottom then
		-- Cut and square are a call each rather than one argument to the same call: they are not
		-- drawn in the same numbers, and a screen of text is nearly all of one of them.
		--
		-- A quad drawn past its box is the one case where the corners and the box differ, and it is
		-- the box that is handed over then: a quad that is its own box leaves the call at the
		-- radius, which is four values the recorder does not have to keep alive for nothing.
		-- The box it is drawn as, in the coordinates the gpu reads, which are the ones this batch
		-- was handed a viewport for: a multiply and a subtract each rather than a call each, because
		-- a call among the arguments of a call is one the recorder has to keep the arguments it has
		-- already worked out alive across -- see `putBox` in `wonderland.util.quad_batch`.
		local scaleX, scaleY = frameScaleX, frameScaleY
		request.left, request.top = left * scaleX - 1.0, 1.0 - top * scaleY
		request.right, request.bottom = right * scaleX - 1.0, 1.0 - bottom * scaleY

		-- Everything about the cut is written before the branch on it, so that the values the
		-- branch needs are the box and the spread rather than the cut of every kind of quad too:
		-- a square quad reads none of them -- but `own` is one both calls read.
		request.radius, request.band, request.hasBand = radius, band, banded and 1 or 0
		request.own, request.blur, request.border = own, blur, border

		if banded or radius > 0 or border > 0 then
			if grow ~= 0 then
				-- The box the corners belong to is the one asked for, and what is drawn is that
				-- box and the room the spreading needs: both sets of corners are already fields of
				-- the request, and the box is read back from them.
				request.hasBox = 1
				request.boxLeft, request.boxTop = request.left, request.top
				request.boxRight, request.boxBottom = request.right, request.bottom
				request.left, request.top = drawnLeft * scaleX - 1.0, 1.0 - drawnTop * scaleY
				request.right, request.bottom = drawnRight * scaleX - 1.0, 1.0 - drawnBottom * scaleY
			else
				request.hasBox = 0
			end

			batch:roundQuadFrom()
		else
			batch:quadFrom()
		end

		return
	end

	-- The part of the quad that shows: what the clip cut off it is not drawn, and the box the
	-- corners of it are measured from is still the whole box -- see below.
	local atLeft = drawnLeft < clip.left and clip.left or drawnLeft
	local atTop = drawnTop < clip.top and clip.top or drawnTop
	local atRight = drawnRight > clip.right and clip.right or drawnRight
	local atBottom = drawnBottom > clip.bottom and clip.bottom or drawnBottom

	if atRight <= atLeft or atBottom <= atTop then
		return
	end

	-- What is drawn is what is inside the clip, but what it is drawn from is the box it was asked
	-- for: the shader maps the picture across that box and measures a corner of it from its middle,
	-- so a picture stays where it is under a cut rather than being squeezed into the sliver of it
	-- that shows, and a box cut down to a sliver by the pane it is in is still a box with round
	-- corners -- the corners of the sliver are not corners of it.
	--
	-- Both calls take that box: `roundQuad` asks for it, and `quad` cannot, because a quad of two
	-- corners is its own box. So a square box that a clip cut down is drawn with `roundQuad` at a
	-- radius of nought -- a cut of the picture, with an edge as hard as the one it has uncut.
	local scaleX, scaleY = frameScaleX, frameScaleY
	local ndcLeft, ndcTop = left * scaleX - 1.0, 1.0 - top * scaleY
	local ndcRight, ndcBottom = right * scaleX - 1.0, 1.0 - bottom * scaleY
	local shownLeft, shownTop = atLeft * scaleX - 1.0, 1.0 - atTop * scaleY
	local shownRight, shownBottom = atRight * scaleX - 1.0, 1.0 - atBottom * scaleY
	local cutRadius, cutBand = radius, banded and band or (radius > 0 and 1 or 0)

	if cutRound then
		cutRadius, cutBand = clip.radius or 0, 1
		ndcLeft = (clip.boxLeft or clip.left) * scaleX - 1.0
		ndcTop = 1.0 - (clip.boxTop or clip.top) * scaleY
		ndcRight = (clip.boxRight or clip.right) * scaleX - 1.0
		ndcBottom = 1.0 - (clip.boxBottom or clip.bottom) * scaleY
	end

	-- The box the corners belong to is in the request beside the corners, and a cut that names no
	-- band is one pixel either side of a round edge and a hard one on a square.
	request.radius, request.band, request.hasBand = cutRadius, cutBand, 1
	request.own, request.blur, request.border = own, blur, border
	request.hasBox = 1
	request.boxLeft, request.boxTop = ndcLeft, ndcTop
	request.boxRight, request.boxBottom = ndcRight, ndcBottom
	request.left, request.top = shownLeft, shownTop
	request.right, request.bottom = shownRight, shownBottom

	batch:roundQuadFrom()
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
---@param blur number? # How far the line is spread, in pixels, which is the blur of the box it is on
---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param r number
---@param g number
---@param b number
---@param a number
local function addBorderQuad(batch, clip, bx, by, bw, bh, r, g, b, a, z, blur)
	if bw <= 0 or bh <= 0 then
		return
	end

	local colour = QuadBatch.colour(r, g, b, a)

	request.left, request.top, request.right, request.bottom = bx, by, bx + bw, by + bh
	request.z, request.colour, request.texture = convertZ(z + 1), colour, 0
	request.uv0, request.uv1 = 0, 0xFFFFFFFF
	request.radius, request.band, request.hasBand = 0, 0, 0
	request.own, request.blur, request.border, request.spread = 0, blur or 0, 0, 0

	clippedQuad(batch, clip, request)
end

-- The glyphs a tight loop cannot write: their index, the line origin they are placed from and the
-- colour they are drawn in, in tables kept between frames, so that a glyph crossing the edge of its
-- pane is drawn by the general path without the loop that draws the rest carrying those branches.
local glyphEdge, glyphEdgeOrigins, glyphEdgeColours = {}, {}, {}

-- Where each line of a run is drawn and from which byte its selection is counted, worked out before
-- the glyphs are: the loop that draws the glyphs walks the lines with them rather than around them.
-- Only the lines that have a glyph in them are kept, in order, so stepping to the next one is a
-- comparison rather than a search.
local walkLineOrigins, walkLineEnds, walkLineBases = {}, {}, {}

--- One glyph drawn the general way: what one crossing the edge of its pane needs, and what every
--- glyph of a line is drawn with where the clip is round or the box is blurred.
---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param glyph wonderland.font.PlacedGlyph
---@param left number
---@param top number
---@param zIndex number
---@param colour number
---@param picture number
---@param blur number
local function clippedGlyph(batch, clip, glyph, left, top, zIndex, colour, picture, blur)
	request.left, request.top = left, top
	request.right, request.bottom = left + glyph.width, top + glyph.height
	request.z, request.colour, request.texture = zIndex, colour, picture
	request.uv0, request.uv1 = glyph.uv0, glyph.uv1
	request.radius, request.band, request.hasBand = 0, 0, 0
	request.own, request.blur, request.border, request.spread = glyph.own, blur, 0, 0

	clippedQuad(batch, clip, request)
end

--- A line is drawn from the run it measured into, which is where its glyphs are. A run of
--- several lines is drawn line by line, each of them placed in the box on its own: a line that
--- is not as wide as the box is aligned by its own width, not by the widest one in the run.
---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param run wonderland.font.Run
---@param node wonderland.Node
---@param x number # Absolute, so the glyphs land on whole pixels
---@param y number
---@param z number
---@param fontManager FontManager
---@param value string? # What the run was measured from, where a selection is counted in its bytes
---@param from number? # The first byte of it a selection covers, where there is one
---@param to number?
local function generateTextQuads(batch, clip, run, node, x, y, z, fontManager, value, from, to)
	-- What a glyph is drawn in is the same for every glyph of the line, so it is packed once here
	-- rather than four numbers narrowed into a colour per glyph: the colour of the text, and the one
	-- that reads on the highlight for a glyph the selection covers.
	local ink = QuadBatch.rgba(node.fgR, node.fgG, node.fgB, node.fgA)
	local marked = QuadBatch.rgba(SELECTION_TEXT_R, SELECTION_TEXT_G, SELECTION_TEXT_B, node.fgA)
	local selecting = value ~= nil and from ~= nil and to ~= nil and from < to

	-- The picture a glyph is drawn from is the one it was measured in, because a line may be drawn
	-- by more than one face: a character the font an app named has no glyph for is drawn from the
	-- face after it in the chain, and the run's glyphs name the picture each of them is in. What
	-- the font itself answers with is where a glyph with no picture of its own is drawn from, which
	-- is a glyph of a font that was measured with no gpu under it.
	local font = node.font ~= 0 and fontManager:get(node.font - 1)
	or assert(fontManager:getDefault(), "No font to draw text with: load one and make it the default")

	-- Where a glyph with no picture of its own is drawn from, which is the same answer for every
	-- glyph of the line: asked once, since asking it per glyph is a walk of the font's faces per
	-- glyph per frame.
	local fallback = font:picture()

	-- A run with nothing in it is a line that is drawn as nothing: a field with no value, a box
	-- whose text is the empty string, which is most rows of most screens. It is asked once rather
	-- than per glyph, so it is asked here -- where nothing is also an answer, and one there is
	-- nothing left to do about.
	local glyphs = run.glyphs

	if glyphs == nil then
		return
	end

	-- A run that is wholly outside the pane it is in draws nothing: every glyph of it is clipped
	-- away, so none of them is written. What it may reach past its box by is the bearing of a
	-- glyph, which is no more than a line is tall, so a run a line outside the pane is one that
	-- cannot put a pixel in it -- and a list of a hundred rows drawn under a pane that shows eight
	-- is a hundred runs walked for nothing.
	--
	-- It is the walk of one node, not of its children: a child placed against the outside of its
	-- parent is a box of its own, and it is the child that says whether it is in the pane.
	-- How far past the pane the run reaches is one number rather than four tests: the greatest of
	-- the distances past each edge of it, which is a maximum and not a branch. A run that scrolls
	-- into the pane is a guard exiting every frame otherwise, and each exit is a side trace the
	-- recorder compiles for a run that is drawn the same way as the one before it.
	local reachX, reachY = run.width + run.height, run.height * 2
	local margin = math.max(clip.left - (x + reachX), (x - reachX) - clip.right, clip.top - (y + reachY),
		(y - reachY) - clip.bottom)

	if margin > 0 then
		return
	end

	local zIndex = convertZ(z)

	-- What is the same for every glyph of the run is read once: a field of the node read in a loop
	-- is a load the recorder has to keep alive across every call the loop makes.
	local blur = node.blur
	local justify, width = node.justify, node.width

	-- A line is drawn by the tight loops below unless something about it needs the general path: a
	-- clip with round corners cuts every glyph of it, and a blurred box spreads every one.
	local tight = blur == 0 and (clip.radius or 0) <= 0

	-- One array of glyphs and one of lines, read by index: the run was measured as structs, so
	-- drawing a line costs a handful of loads rather than a table lookup per glyph.
	--
	-- A field of a line is read where it is wanted rather than a line held to read it from: the
	-- array is of structs, so reading one out is a reference made for the reading, and one kept
	-- across the glyph loop is a reference that cannot be given back before the loop needs it --
	-- which is a reference a line per frame, for what is three numbers.
	local lines = run.lines
	local lineCount = run.lineCount
	local lineBase = 0

	-- A rounded clip or a blurred box needs the general path for every glyph of the line, which is
	-- rare: it keeps the walk of one line at a time it always had.
	if not tight then
		for lineIndex = 0, lineCount - 1 do
			local lineWidth = lines[lineIndex].width
			local offset = 0

			if justify == 1 then
				offset = math.floor((width - lineWidth) / 2 + 0.5)
			elseif justify == 2 then
				offset = width - lineWidth
			end

			local originX = x + offset
			local first, count = lines[lineIndex].first, lines[lineIndex].count

			if selecting then
				local selFrom, selTo = assert(from), assert(to)

				for at = 0, count - 1 do
					local glyph = glyphs[first + at]
					local colour = ink

					if lineBase + glyph.cluster >= selFrom and lineBase + glyph.cluster < selTo then
						colour = marked
					end

					clippedGlyph(batch, clip, glyph, math.floor(originX + glyph.x + 0.5),
						math.floor(y + glyph.y + 0.5), zIndex, colour,
						glyph.texture ~= 0 and glyph.texture or fallback, blur)
				end

				local break_ = assert(value):find("\n", lineBase + 1, true)

				if break_ ~= nil then
					lineBase = break_
				end
			else
				for at = 0, count - 1 do
					local glyph = glyphs[first + at]

					clippedGlyph(batch, clip, glyph, math.floor(originX + glyph.x + 0.5),
						math.floor(y + glyph.y + 0.5), zIndex, ink,
						glyph.texture ~= 0 and glyph.texture or fallback, blur)
				end
			end
		end

		return
	end

	-- Where each line that has a glyph in it is drawn, and from which byte its selection is counted:
	-- what the loop below would otherwise work out per line, from a loop around the glyphs that the
	-- recorder cannot follow -- which is the per-line prologue and its request stores running in the
	-- interpreter while the glyphs are compiled.
	local origins, ends, bases = walkLineOrigins, walkLineEnds, walkLineBases
	local kept = 0

	for lineIndex = 0, lineCount - 1 do
		local lineWidth = lines[lineIndex].width
		local offset = 0

		if justify == 1 then
			offset = math.floor((width - lineWidth) / 2 + 0.5)
		elseif justify == 2 then
			offset = width - lineWidth
		end

		local first, count = lines[lineIndex].first, lines[lineIndex].count

		if count > 0 then
			kept = kept + 1
			origins[kept] = x + offset
			ends[kept] = first + count
			bases[kept] = lineBase
		end

		if selecting then
			local break_ = assert(value):find("\n", lineBase + 1, true)

			if break_ ~= nil then
				lineBase = break_
			end
		end
	end

	-- One loop over every glyph of the run, with the line it is on stepped along inside it: the
	-- lines with glyphs in them are in order and each is non-empty, so one comparison moves to the
	-- next. A glyph that is not wholly inside the clip is left for the pass after this one.
	local edges, edgeOrigins, edgeColours = glyphEdge, glyphEdgeOrigins, glyphEdgeColours
	local edgeCount = 0
	local lineAt = 1
	local lineEnd = ends[1]
	local originX = origins[1]
	local base = bases[1]
	local scaleX, scaleY = frameScaleX, frameScaleY
	local clipLeft, clipTop, clipRight, clipBottom = clip.left, clip.top, clip.right, clip.bottom
	local total = run.count

	batch:reserve(batch.quads + total)

	if selecting then
		local selFrom, selTo = assert(from), assert(to)

		for at = 0, total - 1 do
			if at == lineEnd then
				lineAt = lineAt + 1
				lineEnd = ends[lineAt]
				originX = origins[lineAt]
				base = bases[lineAt]
			end

			local glyph = glyphs[at]
			local left = math.floor(originX + glyph.x + 0.5)
			local top = math.floor(y + glyph.y + 0.5)
			local right, bottom = left + glyph.width, top + glyph.height
			local colour = ink

			if base + glyph.cluster >= selFrom and base + glyph.cluster < selTo then
				colour = marked
			end

			-- One comparison for the four edges of the clip: the largest of how far the box goes
			-- past each of them is a maximum rather than four branches, and it is nought or less
			-- for a glyph that is wholly inside.
			if math.max(clipLeft - left, clipTop - top, right - clipRight, bottom - clipBottom) <= 0 then
				local picture = glyph.texture ~= 0 and glyph.texture or fallback

				if picture ~= batch.texture then
					local runIndex = batch.runCount * QuadBatch.RUN_NUMBERS

					batch.runs[runIndex + QuadBatch.RUN_TEXTURE] = picture
					batch.runs[runIndex + QuadBatch.RUN_FIRST] = batch.quads
					batch.runCount = batch.runCount + 1
					batch.texture = picture
				end

				request.left, request.top = left * scaleX - 1.0, 1.0 - top * scaleY
				request.right, request.bottom = right * scaleX - 1.0, 1.0 - bottom * scaleY
				request.z, request.colour, request.texture = zIndex, colour, picture
				request.uv0, request.uv1 = glyph.uv0, glyph.uv1
				request.own = glyph.own

				batch:glyphFrom()
			else
				edgeCount = edgeCount + 1
				edges[edgeCount] = at
				edgeOrigins[edgeCount] = originX
				edgeColours[edgeCount] = colour
			end
		end
	else
		for at = 0, total - 1 do
			if at == lineEnd then
				lineAt = lineAt + 1
				lineEnd = ends[lineAt]
				originX = origins[lineAt]
			end

			local glyph = glyphs[at]
			local left = math.floor(originX + glyph.x + 0.5)
			local top = math.floor(y + glyph.y + 0.5)
			local right, bottom = left + glyph.width, top + glyph.height

			if math.max(clipLeft - left, clipTop - top, right - clipRight, bottom - clipBottom) <= 0 then
				local picture = glyph.texture ~= 0 and glyph.texture or fallback

				if picture ~= batch.texture then
					local runIndex = batch.runCount * QuadBatch.RUN_NUMBERS

					batch.runs[runIndex + QuadBatch.RUN_TEXTURE] = picture
					batch.runs[runIndex + QuadBatch.RUN_FIRST] = batch.quads
					batch.runCount = batch.runCount + 1
					batch.texture = picture
				end

				request.left, request.top = left * scaleX - 1.0, 1.0 - top * scaleY
				request.right, request.bottom = right * scaleX - 1.0, 1.0 - bottom * scaleY
				request.z, request.colour, request.texture = zIndex, ink, picture
				request.uv0, request.uv1 = glyph.uv0, glyph.uv1
				request.own = glyph.own

				batch:glyphFrom()
			else
				edgeCount = edgeCount + 1
				edges[edgeCount] = at
				edgeOrigins[edgeCount] = originX
			end
		end
	end

	-- The glyphs that cross the edge of their pane, drawn after the rest: a glyph at the edge is
	-- rare, and a branch for it inside the loop is a side exit taken once per line that meets one.
	if edgeCount > 0 then
		for edge = 1, edgeCount do
			local glyph = glyphs[edges[edge]]

			clippedGlyph(batch, clip, glyph, math.floor(edgeOrigins[edge] + glyph.x + 0.5),
				math.floor(y + glyph.y + 0.5), zIndex, selecting and edgeColours[edge] or ink,
				glyph.texture ~= 0 and glyph.texture or fallback, blur)
		end
	end
end

--- Where the caret is, as the pen it sits at, given the byte of the line it is at.
---
---@param run wonderland.font.Run
---@param index number
local function lineAt(run, index)
	local lines = assert(run.lines)
	return assert(lines[index])
end

---@param a number?
---@param b number
local function earliest(a, b)
	if a == nil then return b end
	return math.min(a, b)
end

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
	local glyphLine = lineAt(run, line)

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
local function lineOffset(node, line)
	if line == nil or node.run == 0 then
		return 0
	end

	-- A line set against the right of its box starts at a fraction of a pixel whenever the line is
	-- not a whole number of pixels wide, and a glyph drawn from a fraction is one the sampler spreads
	-- over two: the line is put on the nearest whole pixel, as the one set from the left is.
	if node.justify == 1 then
		return math.floor((node.width - line.width) / 2 + 0.5)
	elseif node.justify == 2 then
		return math.floor(node.width - line.width + 0.5)
	end

	return 0
end

--- The run a field's caret and its selection are placed against: the value, measured in the font
--- the field is drawn in -- what a line is drawn in is what its parents said unless it named one
--- itself -- and cut to the box where the field cuts its line, so that a caret lands in the text
--- that is on screen rather than in the text that was too long for it. See `wonderland.plugin.Layout`,
--- which is where a line is cut.
---@param element wonderland.Element
---@param node wonderland.Node
---@param value string
---@param fontManager FontManager
---@return wonderland.font.Run
local function fieldRun(element, node, value, fontManager)
	local font = element.fontId ~= 0 and fontManager:get(element.fontId)
	or assert(fontManager:getDefault(), "No font to draw text with: load one and make it the default")
	local maxWidth = bit.band(node.styleFlags, style.PRESENT.ellipsis) ~= 0
	and (node.width - node.paddingLeft - node.paddingRight)
	or nil

	return font:getRun(value, maxWidth)
end

--- The quads a selection is drawn as: on every line it touches, the room between the two bytes of it
--- on that line, in the pens that line was drawn along. The pens are the caret's own -- a caret and
--- the highlight beside it agree about where a character is -- and where the selection runs off the
--- end of a line, the room it comes to is the ink of the line rather than the advance of it: the room
--- a line takes goes on past its last letter, over the space after it and the bearings either side,
--- and a highlight drawn to there is a blue box with nothing in it.
---
--- What it is drawn in is the blue a selection is drawn in everywhere, and what the text over it is
--- drawn in is the colour that reads on that blue -- see `generateTextQuads`.
---@param batch wonderland.QuadBatch
---@param clip wonderland.plugin.UI.Clip
---@param caret wonderland.plugin.UI.Caret
---@param element wonderland.Element
---@param node wonderland.Node
---@param x number
---@param y number
---@param z number
---@param fontManager FontManager
---@param windowWidth number
---@param windowHeight number
local function selectionQuads(batch, clip, caret, element, node, x, y, z, fontManager, windowWidth, windowHeight)
	local stored = strings[caret.value]
	local from, to = caret.from, caret.to

	if stored == nil or from == nil or to == nil or from >= to then
		return
	end

	local value = stored --[[@as string]]
	local run = fieldRun(element, node, value, fontManager)
	local lineStep = run.height / run.lineCount
	local zIndex = convertZ(z)
	local start = 1

	for line = 0, run.lineCount - 1 do
			local newline = value:find("\n", start, true)
			-- The line's own bytes of the value, as the half open range a selection is counted in.
			local lineFrom, lineTo = start - 1, (newline or #value + 1) - 1
			local first, last = math.max(from, lineFrom), math.min(to, lineTo)
			local whole = from <= lineFrom and to > lineTo

			if first < last or whole then
				local glyphLine = lineAt(run, line)
				local offset = lineOffset(node, glyphLine)
				-- Both pens are taken into locals first: a call in the last argument of `math.min` is a
				-- call that hands over *all* of what it returns, and `caretPen` answers with the pen and
				-- the height of a line -- which is a left edge a line's height away from the right one.
				local penFirst = caretPen(run, line, first - lineFrom)
				local penLast = caretPen(run, line, last - lineFrom)
				local left = math.min(penFirst, penLast)
				local right = math.max(penFirst, penLast)

				if last == first then
					right = left + SELECTION_LEAST
				end

				-- Where the ink of the line is, which is what an end of the selection that leaves the line
				-- is drawn to: the advance of a line carries on past its last letter, so a selection of the
				-- whole of it would otherwise be a blue box with a space's worth of nothing in it.
				local inkedLeft, inkedRight = nil, nil
				local glyphs = assert(run.glyphs)

				for at = 0, glyphLine.count - 1 do
						local glyph = glyphs[glyphLine.first + at]

						if glyph.width > 0 then
							inkedLeft = math.min(inkedLeft or glyph.x, glyph.x)
							inkedRight = math.max(inkedRight or (glyph.x + glyph.width), glyph.x + glyph.width)
						end
					end

				if from <= lineFrom and inkedLeft ~= nil then
					left = inkedLeft
				end

				if to >= lineTo and inkedRight ~= nil then
					right = inkedRight
				end

				local colour = QuadBatch.colour(SELECTION_R, SELECTION_G, SELECTION_B, 1.0)

				request.left, request.top = x + offset + left, y + line * lineStep
				request.right, request.bottom = x + offset + right, y + line * lineStep + lineStep
				request.z, request.colour, request.texture = zIndex, colour, 0
				request.uv0, request.uv1 = 0, 0xFFFFFFFF
				request.radius, request.band, request.hasBand = 0, 0, 0
				request.own, request.blur, request.border, request.spread = 0, 0, 0, 0

				clippedQuad(batch, clip, request)
			end

			start = lineTo + 2
		end
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
	local value = assert(strings[caret.value]) --[[@as string]]
	local run = fieldRun(element, node, value, fontManager)
	local pen, lineStep = caretPen(run, caret.line, caret.column)
	local height = lineStep - CARET_INSET * 2
	local line = lineAt(run, caret.line)

	-- A line that is given more room than it needs sits where it says in it, which is where it is
	-- drawn: the caret goes with it, and a line with no room of its own starts at nought.
	caret.left = x + lineOffset(node, line) + pen
	caret.top = y + caret.line * lineStep + CARET_INSET
	caret.right = caret.left + CARET_WIDTH
	caret.bottom = caret.top + (height > 0 and height or lineStep)
	caret.z = z + 2

	-- A copy rather than the walk's own clip: the walk reuses its clip tables every frame, and a
	-- blink rebuilds the caret's quad from this one without a walk.
	local kept = caret.clip

	if kept == nil then
		kept = {}
		caret.clip = kept
	end

	kept.left, kept.top, kept.right, kept.bottom = clip.left, clip.top, clip.right, clip.bottom
	kept.radius, kept.boxLeft, kept.boxTop = clip.radius, clip.boxLeft, clip.boxTop
	kept.boxRight, kept.boxBottom = clip.boxRight, clip.boxBottom

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

	local glyphLine = lineAt(run, line)
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

	local colour = QuadBatch.rgba(assert(caret.r), assert(caret.g), assert(caret.b), assert(caret.a))

	request.left, request.top = assert(caret.left), assert(caret.top)
	request.right, request.bottom = assert(caret.right), assert(caret.bottom)
	request.z, request.colour, request.texture = convertZ(caret.z), colour, 0
	request.uv0, request.uv1 = 0, 0xFFFFFFFF
	request.radius, request.band, request.hasBand = 0, 0, 0
	request.own, request.blur, request.border, request.spread = 0, 0, 0, 0

	clippedQuad(batch, assert(caret.clip), request)
end

-- What a walk is drawn with, kept here rather than handed down every level of it: the walk is a
-- loop over a stack of its own, and every node of it reads what it draws with from here.
---@type wonderland.QuadBatch
local walkBatch
---@type wonderland.Layout.Screen?
local walkScreen
---@type number
local walkWidth, walkHeight
---@type FontManager
local walkFontManager
---@type wonderland.plugin.UI.Caret?
local walkCaret
---@type wonderland.Canvas?
local walkCanvas

-- The walk's stack, which is what makes the walk a loop rather than a call into itself: a recursive
-- walk is one LuaJIT stops inlining at a handful of levels, and the trace it gives up on is the
-- whole screen drawn in the interpreter, where every field of every node is a call. The arrays are
-- kept between frames and grown for a screen bigger than the last one, so a frame's stack allocates
-- nothing.
--
-- An entry is the node it is at, which of its children is next, where that node sits, the clip it
-- is drawn in and whether it is inside the caret's field. A node is drawn when it is first reached
-- and then put back on the stack with the ordinal of its next child: its children are drawn over
-- it, and when the ordinal runs out it is finished -- the caret's fallback and a scroll bar are
-- drawn then.
local walkStackIndex, walkStackChild, walkStackX, walkStackY, walkStackZ, walkStackInside
---@type wonderland.plugin.UI.Clip[]
local walkStackClips = {}
local walkStackSize = 0

-- The clips a walk narrows for the boxes that scroll, one table each reused every frame: a frame
-- that made one is a frame that left a table for the collector, and the boxes a page scrolls are
-- the same ones every frame. What is drawn from one after the walk -- the caret's clip, which a
-- blink rebuilds its quad from -- is copied onto the caret for that reason.
---@type wonderland.plugin.UI.Clip[]
local walkClipPool = {}
local walkClipCount = 0

---@param nodes number
local function walkStackReserve(nodes)
	if nodes <= walkStackSize then
		return
	end

	local size = walkStackSize > 0 and walkStackSize or 256

	while size < nodes do
		size = size * 2
	end

	walkStackIndex = ffi.new("int32_t[?]", size)
	walkStackChild = ffi.new("int32_t[?]", size)
	walkStackX = ffi.new("double[?]", size)
	walkStackY = ffi.new("double[?]", size)
	walkStackZ = ffi.new("double[?]", size)
	walkStackInside = ffi.new("uint8_t[?]", size)
	walkStackSize = size
end

--- The shadow a box is drawn with, before the box itself so the box lands over it: the box moved
--- and drawn with its edge spread out, which is what fades out of the shape the shader cuts.
---@param node wonderland.Node
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function shadowQuads(node, x, y, z, clip)
	local blur = node.shadowBlur
	local band = blur > 0 and (1 / (2 * blur)) or 1

	request.left, request.top = x + node.shadowX, y + node.shadowY
	request.right, request.bottom = x + node.shadowX + node.width, y + node.shadowY + node.height
	request.z, request.colour, request.texture = convertZ(z),
		QuadBatch.rgba(node.shadowR, node.shadowG, node.shadowB, node.shadowA), 0
	request.uv0, request.uv1 = 0, 0xFFFFFFFF
	request.radius, request.band, request.hasBand = node.radius, band, 1
	request.own, request.blur, request.border = 0, 0, 0
	request.spread = blur + 1

	clippedQuad(walkBatch, clip, request)
end

--- The box itself: the colour it came out with, or the picture it shows, over what is under it.
---@param node wonderland.Node
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function backgroundQuads(node, x, y, z, clip)
	-- The colours the node came out with, whatever said them: a box with a picture and no colour of
	-- its own was given white by its style, and one that named a colour of its own is drawn in it
	-- however dark that colour is.
	request.left, request.top = x, y
	request.right, request.bottom = x + node.width, y + node.height
	request.z, request.colour, request.texture = convertZ(z),
		QuadBatch.rgba(node.bgR, node.bgG, node.bgB, node.bgA), node.texture
	request.uv0, request.uv1 = node.u0 + node.v0 * 65536, node.u1 + node.v1 * 65536
	request.radius, request.band, request.hasBand = node.radius, 0, 0
	request.own, request.blur, request.border, request.spread = 0, node.blur, 0, 0

	clippedQuad(walkBatch, clip, request)
end

--- What the element draws itself, in the room its padding and its border leave -- which is the room
--- a child of it would get -- and at the depth everything of this element is drawn at.
---@param here wonderland.Element
---@param node wonderland.Node
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function canvasQuads(here, node, x, y, z, clip)
	local draw = callbacks[here.oncanvas]

	if draw ~= nil then
		local canvas = walkCanvas --[[@as wonderland.Canvas]]
		local left = x + node.paddingLeft
		local top = y + node.paddingTop
		local roomWidth = node.width - node.paddingLeft - node.paddingRight - node.borderLeft - node.borderRight
		local roomHeight = node.height - node.paddingTop - node.paddingBottom - node.borderTop - node.borderBottom

		draw(canvas:draw(walkBatch, clip, walkWidth, walkHeight, left, top, roomWidth, roomHeight, convertZ(z),
			WHITE_TEXTURE))
	end
end

--- The text a box draws, and the selection behind it. A selection is drawn at the depth of the text
--- it covers, before the text, because the batch draws in the order it was written; the node it is
--- drawn on is the node the caret is placed from, which is the first one inside the field.
---@param node wonderland.Node
---@param element wonderland.Element?
---@param inside boolean # Whether this node is inside the caret's field
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function textQuads(node, element, inside, x, y, z, clip)
	local value, from, to = nil, nil, nil

	if walkCaret ~= nil and inside and not walkCaret.covered then
		local caret = walkCaret --[[@as wonderland.plugin.UI.Caret]]

		caret.covered = true
		selectionQuads(walkBatch, clip, caret, assert(element), node, x, y, z, walkFontManager, walkWidth,
			walkHeight)
		value, from, to = strings[caret.value], caret.from, caret.to
	end

	local screen = walkScreen --[[@as wonderland.Layout.Screen]]

	generateTextQuads(walkBatch, clip, assert(screen.runs[node.run]), node, x, y, z, walkFontManager, value, from,
		to)
end

--- The border of a box, drawn after the box it is on so it lands on top of it. A uniform border on a
--- rounded box is one ring quad rather than four rectangles: the shader cuts both the outer and the
--- inner edge, so the ring follows the corners instead of crossing them.
---@param node wonderland.Node
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function borderQuads(node, x, y, z, clip)
	local r, g, b, a = node.borderR / 255, node.borderG / 255, node.borderB / 255, node.borderA / 255
	local width, height = node.width, node.height
	local uniform = node.borderTop > 0
	and node.borderTop == node.borderRight and node.borderTop == node.borderBottom
	and node.borderTop == node.borderLeft

	if uniform then
		request.left, request.top = x, y
		request.right, request.bottom = x + width, y + height
		request.z, request.colour, request.texture = z + 1, QuadBatch.colour(r, g, b, a), 0
		request.uv0, request.uv1 = 0, 0xFFFFFFFF
		request.radius, request.band, request.hasBand = node.radius, 1, 1
		request.own, request.blur, request.border, request.spread = 0, 0, node.borderTop, 0

		clippedQuad(walkBatch, clip, request)

		return
	end

	if node.borderTop > 0 then
		addBorderQuad(walkBatch, clip, x, y, width, node.borderTop, r, g, b, a, z, node.blur)
	end

	if node.borderBottom > 0 then
		addBorderQuad(walkBatch, clip, x, y + height - node.borderBottom, width, node.borderBottom, r, g, b, a, z,
			node.blur)
	end

	if node.borderLeft > 0 then
		addBorderQuad(walkBatch, clip, x, y, node.borderLeft, height, r, g, b, a, z, node.blur)
	end

	if node.borderRight > 0 then
		addBorderQuad(walkBatch, clip, x + width - node.borderRight, y, node.borderRight, height, r, g, b, a, z,
			node.blur)
	end
end

--- The track and the thumb of a box that scrolls, drawn inside the pane it reserved and over the
--- content: the track is the colour it was given made fainter, and the thumb is as much of the
--- track as the box shows of the content.
---@param node wonderland.Node
---@param bar { max: number, width: number, least: number, r: number, g: number, b: number, a: number } # The `wl_bar` of the node, only there for a box that scrolls
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function scrollBarQuads(node, bar, x, y, z, clip)
	local left = x + node.width - bar.width
	local thumb = node.height * (node.height / (node.height + bar.max))

	if thumb < bar.least then
		thumb = bar.least
	end

	if thumb > node.height then
		thumb = node.height
	end

	-- Where the thumb may travel is what is left of the box once the thumb is in it, so the end of
	-- the list puts the thumb's end at the end of the box rather than past it.
	local span = node.height - thumb
	local at = math.min(math.max(node.scroll / bar.max, 0), 1)
	local top = y + (span > 0 and at * span or 0)

	request.left, request.top = left, y
	request.right, request.bottom = left + bar.width, y + node.height
	request.z, request.colour, request.texture = convertZ(z), QuadBatch.rgba(bar.r, bar.g, bar.b, bar.a * 0.25), 0
	request.uv0, request.uv1 = 0, 0xFFFFFFFF
	request.radius, request.band, request.hasBand = 0, 0, 0
	request.own, request.blur, request.border, request.spread = 0, 0, 0, 0

	clippedQuad(walkBatch, clip, request)

	request.left, request.top = left, top
	request.right, request.bottom = left + bar.width, top + thumb
	request.z, request.colour = convertZ(z + 1), QuadBatch.rgba(bar.r, bar.g, bar.b, bar.a)

	clippedQuad(walkBatch, clip, request)
end

--- What a box that scrolls shows of its children is what is inside it: the clip narrowed to it, and
--- the box its rounded corners belong to. It is a call of its own because it is rare -- most boxes
--- do not scroll -- and because it is the one thing a node does that makes a table.
---@param clip wonderland.plugin.UI.Clip
---@param node wonderland.Node
---@param x number
---@param y number
---@return wonderland.plugin.UI.Clip
local function scrollClip(clip, node, x, y)
	local left = clip.left > x and clip.left or x
	local top = clip.top > y and clip.top or y
	local right = x + node.width
	local bottom = y + node.height

	if right > clip.right then
		right = clip.right
	end

	if bottom > clip.bottom then
		bottom = clip.bottom
	end

	walkClipCount = walkClipCount + 1
	local below = walkClipPool[walkClipCount]

	if below == nil then
		below = {}
		walkClipPool[walkClipCount] = below
	end

	below.left, below.top, below.right, below.bottom = left, top, right, bottom

	-- A box that does not round its corners must not inherit them from the frame before this.
	below.radius = nil
	below.boxLeft, below.boxTop, below.boxRight, below.boxBottom = nil, nil, nil, nil

	if node.radius > 0 then
		below.radius = node.radius
		below.boxLeft, below.boxTop = x, y
		below.boxRight, below.boxBottom = x + node.width, y + node.height
	end

	return below
end

--- A node finishing after its children: the caret is placed from it if the field draws no line of
--- its own, and the scroll bar is drawn over the strip it reserved. Both are drawn here because
--- both are drawn over what the node's children drew.
---@param index number
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
local function finishNode(index, x, y, z, clip)
	local screen = walkScreen --[[@as wonderland.Layout.Screen]]
	local node = screen.refs[index]
	local here = pointers[node.element]

	if walkCaret ~= nil and here ~= nil and here == walkCaret.element and node.visible ~= 0
	and not walkCaret.placed then
		placeCaret(walkCaret, here, node, x + node.paddingLeft, y + node.paddingTop, z, clip, walkFontManager)
	end

	-- It is only there when there is something to scroll, which is what "shows up" means -- a list
	-- that fits has no bar.
	local bar = node.scrolls == 1 and screen.bars[index - 1] or nil

	if node.visible ~= 0 and bar ~= nil and bar.width > 0 and bar.max > 0 then
		scrollBarQuads(node, bar, x, y, z, clip)
	end
end

--- One node of the walk: what it draws over its parent, and the stack it leaves its children on. Its
--- children are pushed in the order the layout gave them, with the node's finishing entry below
--- them, so they are drawn before it is finished.
---@param index number
---@param x number
---@param y number
---@param z number
---@param clip wonderland.plugin.UI.Clip
---@param inside number # Whether the parent is inside the caret's field, as the stack kept it
---@param top number # The stack top to push from
local function enterNode(index, x, y, z, clip, inside, top)
	local screen = walkScreen --[[@as wonderland.Layout.Screen]]
	local node = screen.refs[index]
	local nodeX, nodeY = x + node.x, y + node.y
	local nodeZ = z

	if node.zIndex > nodeZ then
		nodeZ = node.zIndex
	end

	-- The element behind this node, which is what says whether it has a canvas of its own to draw
	-- and which field it belongs to. The caret's half of that is only looked at when there is a
	-- caret to place: a screen with no field focused has nothing to compare against.
	local here = pointers[node.element]
	local element = walkCaret ~= nil and here or nil
	local wasInside = inside ~= 0
	local isInside = wasInside or (walkCaret ~= nil and element ~= nil and element == walkCaret.element)
	local visible = node.visible ~= 0

	-- The colour of a caret is the field's, wherever in it the caret turns out to be placed from:
	-- one nothing named a colour for is drawn white, since a field whose text cannot be seen is one
	-- whose caret should at least be there.
	if not wasInside and walkCaret ~= nil and element ~= nil and element == walkCaret.element then
		if node.fgA == 0 then
			walkCaret.r, walkCaret.g, walkCaret.b, walkCaret.a = WHITE_R, WHITE_G, WHITE_B, WHITE_A
		else
			walkCaret.r, walkCaret.g, walkCaret.b, walkCaret.a = node.fgR, node.fgG, node.fgB, node.fgA
		end
	end

	-- Each kind of thing a node draws is a call of its own: the loop that walks the screen is the
	-- hot trace, and what only some nodes have -- a shadow, a canvas, a text run, a border -- is
	-- reached only for the nodes that have it rather than every kind merged into the one loop.
	if visible then
		if node.shadowA > 0 then
			shadowQuads(node, nodeX, nodeY, nodeZ, clip)
		end

		if node.paint ~= 0 then
			backgroundQuads(node, nodeX, nodeY, nodeZ, clip)
		end

		if here ~= nil and here.oncanvas ~= 0 then
			canvasQuads(here, node, nodeX, nodeY, nodeZ, clip)
		end

		if node.run ~= 0 then
			textQuads(node, element, isInside, nodeX, nodeY, nodeZ, clip)
		end

		borderQuads(node, nodeX, nodeY, nodeZ, clip)
	end

	local below = clip

	if node.scrolls ~= 0 then
		below = scrollClip(clip, node, nodeX, nodeY)
	end

	-- The caret is placed from the line of text a field draws, which is the first one inside it --
	-- what a caret is beside is the text, and where the app put the text is where it goes. A field
	-- that draws none is placed from its own content origin, which is what `finishNode` does.
	if isInside and visible and node.run ~= 0 and walkCaret ~= nil and not walkCaret.placed then
		placeCaret(walkCaret, assert(element), node, nodeX, nodeY, nodeZ, below, walkFontManager)
	end

	-- What is left of the node is drawn after its children, so the stack holds the node again
	-- with the ordinal of the next child to draw: the child itself is pushed over it. There is no
	-- loop over the children here -- a loop inside the one the screen is walked by is a loop the
	-- recorder cannot follow, which is a walk that runs in the interpreter.
	local count = node.childCount
	local pushed = top

	if count > 0 then
		local childIndices = screen.childIndices

		pushed = pushed + 1
		walkStackIndex[pushed] = index
		walkStackChild[pushed] = 1
		walkStackX[pushed], walkStackY[pushed], walkStackZ[pushed] = nodeX, nodeY, nodeZ
		walkStackInside[pushed] = isInside and 1 or 0
		walkStackClips[pushed] = below

		pushed = pushed + 1
		walkStackIndex[pushed] = childIndices[node.firstChild - 1]
		walkStackChild[pushed] = 0
		walkStackX[pushed], walkStackY[pushed], walkStackZ[pushed] = nodeX, nodeY, nodeZ
		walkStackInside[pushed] = isInside and 1 or 0
		walkStackClips[pushed] = below
	else
		finishNode(index, nodeX, nodeY, nodeZ, below)
	end

	return pushed
end

--- Walks the laid out screen, which is an array of nodes: a walk is an index and an offset, and
--- children are reached through the runs of child indices.
---
--- It is one loop over a stack rather than a call into itself: LuaJIT stops inlining a recursive
--- call at a handful of levels and gives up on the trace, which leaves the whole screen drawn in
--- the interpreter. One loop is one trace, whatever the depth of the screen, and each kind of work
--- it reaches is a call of its own so that the loop itself stays small enough to compile.
---@param clip wonderland.plugin.UI.Clip
---@param index number
---@param parentX number
---@param parentY number
---@param parentZ number?
---@param inField boolean? # Whether this node is inside the caret's field, which is where the caret is
local function generateNodeQuads(clip, index, parentX, parentY, parentZ, inField)
	local screen = walkScreen --[[@as wonderland.Layout.Screen]]
	walkStackReserve(screen.count + 2)

	local indexStack, xStack, yStack = walkStackIndex, walkStackX, walkStackY
	local childStack = walkStackChild
	local zStack, insideStack, clips = walkStackZ, walkStackInside, walkStackClips

	indexStack[1] = index
	childStack[1] = 0
	xStack[1], yStack[1], zStack[1] = parentX, parentY, parentZ or 0
	insideStack[1] = inField and 1 or 0
	clips[1] = clip

	walkClipCount = 0

	local top = 1

	while top > 0 do
		local entry = indexStack[top]
		local child = childStack[top]
		local entryX, entryY, entryZ = xStack[top], yStack[top], zStack[top]
		local entryInside, entryClip = insideStack[top], clips[top]

		top = top - 1

		if child == 0 then
			top = enterNode(entry, entryX, entryY, entryZ, entryClip, entryInside, top)
		else
			local node = screen.refs[entry]

			if child < node.childCount then
				-- This node is drawn already and has a child left: it goes back on the stack for
				-- after that child's own subtree, and the child goes over it.
				top = top + 1
				indexStack[top] = entry
				childStack[top] = child + 1
				xStack[top], yStack[top], zStack[top] = entryX, entryY, entryZ
				insideStack[top] = entryInside
				clips[top] = entryClip

				top = top + 1
				indexStack[top] = screen.childIndices[node.firstChild + child - 1]
				childStack[top] = 0
				xStack[top], yStack[top], zStack[top] = entryX, entryY, entryZ
				insideStack[top] = entryInside
				clips[top] = entryClip
			else
				finishNode(entry, entryX, entryY, entryZ, entryClip)
			end
		end
	end
end

--- The least time between frames of a window: a frame of its display, where the window can say how
--- fast that is -- a 144 Hz monitor is drawn at 144 frames a second -- and `frameInterval` where it
--- cannot. What the window says is asked once, and again after the window is resized.
---@param window wonderland.RenderWindow
---@return number
function UI:intervalOf(window)
	local rate = window.displayRate
	if rate == nil then
		rate = window.refreshRate ~= nil and window:refreshRate() or false
		window.displayRate = rate
	end
	return (rate and rate > 0) and 1 / rate or self.frameInterval
end

--- A frame is asked for, at most one for each frame the display has time to show. What the
--- question is asked about is a window, so what says when the last frame went out is kept with it.
--- A frame asked for before that time is not lost: what the screen says goes into the frame that
--- is still to come, and the event after this one asks again.
---@param window wonderland.RenderWindow
---@param forced boolean? # Whether the frame is the window's own, which is not held back
---@param self wonderland.plugin.UI
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
		if not forced and not window.frameAsked and at - (ctx.framedAt or 0) < self:intervalOf(window) then
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
---@param self wonderland.plugin.UI
function UI:event(event, _handler)
	local name = event.name

	if name == "redraw" then
		return self:frame(event.window)
	end

	-- A window coming back on screen -- from the tray, from being minimized -- has the frame it
	-- was showing before it went away and nothing since: what it needs is a frame of what is
	-- there now, asked for as the window's own rather than held back for coming too soon, so that
	-- it is not left blank until something else happens to it. A window the shell has just made
	-- is not this one: its map is claimed by the window plugin, which asks for its first frame by
	-- handing the app the message.
	if name == "map" or name == "restore" then
		self:present(event.window)
		return
	end

	if name == "resize" or name == "mouseMove" or name == "mouseLeave" or name == "mousePress"
	or name == "mouseRelease" or name == "focusOut" then
		-- A pointer that moved within what it was already over is not a frame: what the pointer
		-- picks is a style per element, and what the frame was built from is the set of elements it
		-- is over -- which the layout says it recorded as unchanged. The cursor shape is the
		-- window's own and is set as the event goes by, so it needs no frame either. A drag in
		-- progress, and an element that draws at the pointer, are the two that still want one: the
		-- first changes the screen on every event, the second is one frame of the screen already
		-- built with the walk gone over again.
		if name == "mouseMove" or name == "mouseLeave" then
			local ctx = self.layoutPlugin.contexts[event.window]

			if ctx ~= nil then
				if ctx.hoverChanged or ctx.barDrag ~= nil or ctx.dragging ~= nil or ctx.selecting
				or (ctx.pointer ~= nil and ctx.pointer.pressed) then
					local requestRedraw = self.requestRedraw --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)]]
					requestRedraw(self, event.window)
				elseif ctx.pointerDraw then
					ctx.mustDraw = true
					event.window.shouldRedraw = true
				end

				return
			end
		end

		if name == "resize" then -- Resize should actually invalidate layouts
			local ctx = self.layoutPlugin.contexts[event.window]
			if ctx then
				ctx.mustDraw = true
			end

			-- A window that changed size may be on another monitor, or a phone that changed its
			-- configuration may have changed its panel's rate: the rate is asked for again.
			local window = event.window --[[@as wonderland.RenderWindow]]
			if window ~= nil then window.displayRate = nil end
		end

		local requestRedraw = self.requestRedraw --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)]]
		requestRedraw(self, event.window, name == "resize")
	end
end

--- What a frame is remembered by: the field the caret is in, where it is, and what is selected
--- there. A caret that moved is a frame to build again and one that only blinked is not -- and a
--- selection that grew without the caret moving, which is what shift and an arrow key does at the
--- end of a line, is a frame of its own as well.
---
--- Compared field by field against what the frame the gpu has was walked with rather than as a key
--- built for the comparing: a key is a table and strings made every frame, which is memory the
--- collector has to take back while the screen is drawn.
---@param ctx wonderland.plugin.Layout.Context
---@param window wonderland.RenderWindow
---@param layoutPlugin wonderland.plugin.Layout
---@return boolean
local function caretMoved(ctx, window, layoutPlugin)
	local element, line, column, from, to = layoutPlugin:getCaret(window)

	if element == nil then
		return ctx.frameCaret == true
	end

	return ctx.frameCaret ~= true
	or ctx.frameCaretName ~= ctx.focusedName
	or ctx.frameCaretLine ~= line
	or ctx.frameCaretColumn ~= column
	or ctx.frameCaretFrom ~= from
	or ctx.frameCaretTo ~= to
end

--- The caret a frame was walked with, kept as the numbers the next frame is compared against. It is
--- the field the caret is for rather than the element: an element is built again every frame, and
--- only its name says it is the same caret.
---@param ctx wonderland.plugin.Layout.Context
---@param caret wonderland.plugin.UI.Caret?
local function rememberCaret(ctx, caret)
	ctx.frameCaret = caret ~= nil
	ctx.frameCaretName = ctx.focusedName

	if caret ~= nil then
		ctx.frameCaretLine, ctx.frameCaretColumn = caret.line, caret.column
		ctx.frameCaretFrom, ctx.frameCaretTo = caret.from, caret.to
	else
		ctx.frameCaretLine, ctx.frameCaretColumn = nil, nil
		ctx.frameCaretFrom, ctx.frameCaretTo = nil, nil
	end
end

--- The caret as this frame has it: which field it is for, where in it, and what is selected in it,
--- or nothing where no field has the keyboard. What is typed into the field is kept by handle, since
--- measuring it is what the caret's own place and the highlight are worked out from.
---@param window wonderland.RenderWindow
---@return wonderland.plugin.UI.Caret?
---@param self wonderland.plugin.UI
function UI:caretFor(window)
	local element, line, column, from, to = self.layoutPlugin:getCaret(window)

	if element == nil then
		return nil
	end

	return {
	element = element,
	value = element.inputValue,
	line = line,
	column = column,
	from = from,
	to = to,
	}
end

--- Whether a field's caret is drawn: a selection hides it. The highlight already says where the
--- typing would go -- at one end of it -- and a bar drawn over that end is a second thing to read
--- rather than a second thing said.
---@param element wonderland.Element?
---@param from number?
---@param to number?
---@return boolean
local function caretShown(element, from, to)
	return element ~= nil and (from == nil or to == nil or from >= to)
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
---@param self wonderland.plugin.UI
function UI:caretClick(window)
	local ctx = self.layoutPlugin.contexts[window]
	local click = ctx and ctx.caretClick

	if click == nil or ctx == nil or ctx.focusedName == nil or ctx.ui == nil or ctx.screen == nil then
		return
	end

	-- Taken whatever comes of it: a click that cannot be placed is a click that is done with, and
	-- one left behind would be put against a frame built later than the one it landed in.
	ctx.caretClick = nil

	local element = self.layoutPlugin:getCaret(window) --[[@as wonderland.Element]]

	if element == nil then
		return
	end

	local node, x, y, run = findFieldText(assert(ctx.screen), assert(ctx.root), 0, 0, element)

	if node == nil or x == nil or y == nil or run == nil then
		return
	end

	local line, column = caretAtPoint(run, node, x, y, click.x, click.y)
	local anchorLine, anchorColumn = nil, nil
	local started = ctx.selectFrom

	if started ~= nil then
		-- The other end of the selection is where the press was, which is measured against the same
		-- frame the caret is: a drag is one selection made from where it started to where the pointer
		-- is now.
		anchorLine, anchorColumn = caretAtPoint(run, node, x, y, started.x, started.y)

		-- Kept while the pointer is held, so that a drag that is still going keeps the end it
		-- started from, and let go of once it is up: a click that is over is a click that is done
		-- with, as the point is.
		if ctx.pointer == nil or not ctx.pointer.pressed then
			ctx.selectFrom = nil
		end
	end

	self.layoutPlugin:setCaret(window, line, column, anchorLine, anchorColumn)
end

--- The caret's clock: a caret is drawn for half a second and not for half a second, which is the
--- one thing in a screen that changes on its own. What comes of it is one quad, so the frame it
--- belongs to is not built again for it: see `UI:frame`.
---@param ctx wonderland.plugin.Layout.Context
---@return boolean blinked # Whether the caret came or went, which is a frame's worth of change
---@param self wonderland.plugin.UI
function UI:blink(ctx)
	local element, _, _, from, to = self.layoutPlugin:getCaret(ctx.window)

	if not caretShown(element, from, to) then
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
---@param self wonderland.plugin.UI
function UI:tick(window, handler)
	local ctx = self.layoutPlugin.contexts[window]

	if not ctx then
		return
	end

	local layout = self.layoutPlugin
	local at = now()
	local due = nil ---@type number?
	local message = nil

	-- A window that is not on screen draws nothing, so nothing that is only a drawing has to run
	-- for it: a caret that blinks and a gif that moves on are frames, and a hidden window is not
	-- given one. What the app asked to be called back for still runs -- a player in the tray keeps
	-- playing on the tick below.
	local isHidden = window.visible == false

	if ctx.repeatKey ~= nil and layout.keyRepeatInterval > 0 then
		if ctx.repeatAt == nil then
			-- A key that has just gone down, which is what having no next repeat yet means: what comes
			-- first is the wait before it repeats at all.
			ctx.repeatAt = at + layout.keyRepeatDelay
		end

		if at >= ctx.repeatAt then
			message = layout:key(window, assert(ctx.repeatKey), ctx.repeatMods, ctx.repeatTyped or assert(ctx.repeatKey))
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
				local requestRedraw = self.requestRedraw --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)]]
				requestRedraw(self, window, true)
			end
		end

		due = ctx.repeatAt
	end

	-- The caret, which is the other thing a screen does with no event behind it. What has the
	-- keyboard is not always a caret: a thing the keyboard was tabbed to that answers a click is
	-- a keyboard with nothing blinking under it, and a selection hides the caret it covers. A frame
	-- every half second for a caret that is not there is a screen drawing itself for nothing.
	if not isHidden and self.caretBlink > 0 then
		local element, _, _, from, to = self.layoutPlugin:getCaret(window)

		if caretShown(element, from, to) then
			local blink = (ctx.caretAt or at) + self.caretBlink

			if at >= blink then
				-- What is due is a frame, and it is the caret's own clock that has kept it rather
				-- than the frame's: the frame's time is what holds a frame back, so it is not asked
				-- through it. What comes of it is one quad of the frame the gpu already has -- see
				-- `UI:toggle` -- so the screen is not owed a rebuild for it: the frame is asked for
				-- and `UI:frame` toggles the quad the walk already placed.
				ctx.asked = true
				window.shouldRedraw = true
				blink = at + self.caretBlink
			end

			due = due ~= nil and math.min(due, blink) or blink
		end
	end

	-- A gif, which is the other thing a screen draws that changes with no event behind it. What
	-- frame of one is being shown is the clock's, and the frame is a texture and the part of a
	-- layer, which are what a style names: nothing short of a rebuild shows the next one. So a
	-- gif that moved on leaves the screen owed a frame, which the block below asks for at the
	-- display's own rate, and the time the one after it is due is what the loop is woken for.
	local shared = self.renderPlugin.sharedResources
	local assets = shared and shared.assets

	if not isHidden and assets ~= nil then
		if assets:advance(at) then
			ctx.owed = true
		end

		local frames = assets:due()

		if frames ~= nil then
			due = earliest(due, frames)
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
						due = earliest(due, at)
					else
						due = earliest(due, nextAt)
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
	-- no faster. A hidden window is not asked for one: what it owes is still owed when it is shown.
	if ctx.owed and not isHidden then
		local ready = (ctx.framedAt or 0) + self:intervalOf(window)

		if at >= ready then
			local requestRedraw = self.requestRedraw --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)]]
			requestRedraw(self, window, true)
		else
			due = earliest(due, ready)
		end
	end

	if due ~= nil then
		local setTimeout = handler.setTimeout --[[@as fun(self: winit.EventManager, seconds: number)]]
		setTimeout(handler, due - at)
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
---@param self wonderland.plugin.UI
function UI:walk(window, ctx)
	local fontManager = assert(self.renderPlugin.sharedResources).fontManager
	local batch = self.batch
	local caret = self:caretFor(window)

	-- The size the frame is drawn into: the surface under the window rather than the size the
	-- window says it is, which is what the quads are written against and what the clip is. See
	-- `wonderland.plugin.Render:size`.
	local width, height = self.renderPlugin:size(window)

	batch:reset()
	batch:setViewport(width, height)

	-- What a coordinate of this frame is worth in it, which every quad of it is written with: see
	-- `toNDCX`, which is a multiply because of these two.
	frameScaleX, frameScaleY = 2 / width, 2 / height

	-- What the walk is drawn with, put where each level of it reads it: see `generateNodeQuads`.
	walkBatch, walkScreen = batch, assert(ctx.screen)
	walkWidth, walkHeight = width, height
	walkFontManager, walkCaret, walkCanvas = fontManager, caret, self.canvas

	-- The clip the screen is drawn in is the frame itself, and one table of it serves every frame:
	-- a walk narrows a clip of its own where a box scrolls, but the frame's own is the same one.
	local frameClip = self.frameClip

	if frameClip == nil then
		frameClip = { left = 0, top = 0, right = width, bottom = height }
		self.frameClip = frameClip
	else
		frameClip.right, frameClip.bottom = width, height
	end

	generateNodeQuads(frameClip, assert(ctx.root), 0, 0, nil, nil)

	-- What the walk was handed is let go of once it is over, so a frame does not keep the screen
	-- before it alive through the walk's own names.
	walkScreen, walkCaret, walkCanvas = nil, nil, nil

	-- What the caret's quad is added to: the frame is the quads of the screen and then it, so a
	-- blink is this many of them and no more. A selection hides the caret, though its own highlight
	-- is still drawn -- see `caretShown`.
	if caret ~= nil and caret.placed and caretShown(caret.element, caret.from, caret.to) then
		ctx.caret = caret
	else
		ctx.caret = nil
	end

	ctx.caretBase = batch.quads

	-- A caret that has not blinked yet is a caret that is drawn: nothing has said it should not be,
	-- and the first thing a field that takes the keyboard does is show where the typing goes.
	if ctx.caret ~= nil and ctx.caretOn ~= false then
		addCaretQuad(batch, ctx.caret, width, height)
	end

	self.renderPlugin:setRenderData(window, batch)
	ctx.uploaded = true

	rememberCaret(ctx, caret)
end

--- The caret coming or going: the last quad of the frame the gpu has is the caret's, so this is
--- the frame without it or the frame with it again -- the quads are handed over and nothing is
--- measured, solved or walked. It is the whole of what a blink costs.
---@param window wonderland.RenderWindow
---@param ctx wonderland.plugin.Layout.Context
---@param self wonderland.plugin.UI
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
--- surface the gpu is not ready to draw into yet. And so is one a screen *presented*, because what
--- it is for is a frame whose new thing is not in the quads at all: see `UI:present`.
---@param window wonderland.RenderWindow
---@param self wonderland.plugin.UI
function UI:frame(window)
	local ctx = self.layoutPlugin.contexts[window]

	if not ctx then
		return
	end

	-- A window that is not on screen is not drawn: what it would show is nothing the compositor
	-- will show, and a present into a surface it has taken away is a present that blocks -- an app
	-- in the tray stops playing, because the loop it plays on is stopped in here. Nothing is lost
	-- by skipping it: the frame a window is shown with is asked for when it is mapped or restored,
	-- and it is a frame of the screen as it is then rather than the one it was left with. See
	-- `app.run`, which does not count such a window as owing one either.
	if window.visible == false then
		return
	end

	-- The on-screen keyboard follows the focus: up while a field has it, down once none does. A
	-- window with no keyboard of its own has no `setTextInput`.
	local typing = ctx.focusedName ~= nil
	if typing ~= (ctx.textInput == true) and window.setTextInput ~= nil then
		ctx.textInput = typing
		window:setTextInput(typing)
	end

	-- Where a click in a field put the caret, before anything is built out of it: the point is
	-- against the frame that was on screen when the pointer went down, and the caret it comes to is
	-- one of the things this frame draws.
	self:caretClick(window)

	-- An ask is answered by the frame that comes out of it, which is where the window is told the
	-- frame is ready: see `X11Window:acknowledgeSync`, which is what puts the ask away.
	local ownAsk = ctx.asked
	local asked = ownAsk or window.frameAsked
	local mustDraw = ctx.mustDraw

	ctx.asked, ctx.mustDraw = nil, nil

	-- What the events left for the screen, which is the only reason to look at the view again.
	local owed = ctx.owed or not ctx.uploaded

	ctx.owed = false

	-- What this frame draws into is taken before any of it is built: a screen laid out at the size
	-- of the last frame's target and drawn into this one's is a screen the compositor stretches,
	-- which during a resize is every frame of it. A frame the screen presented is drawn too, from
	-- the screen already built, so it needs a target as much as a rebuilt one does: without one the
	-- draw below has nothing to draw into and the frame is silently dropped.
	if (owed or mustDraw or not ctx.presented) and not self.renderPlugin:retarget(window) then
		-- Nothing was built or drawn, so what this frame was for is still owed. Forgetting it would
		-- leave the next frame that does get a target repainting the screen built before it: an app
		-- whose state changed while its window had no image (minimized, or an Android surface gone
		-- in the background) would come back showing the old state until something else changed.
		ctx.owed = ctx.owed or owed
		ctx.mustDraw = ctx.mustDraw or mustDraw
		ctx.asked = ctx.asked or ownAsk
		return
	end

	if owed then
		self.layoutPlugin:refreshView(window)
	end

	-- Where the caret is, which the frame's quads are remembered by as well as the screen: a caret
	-- that moved is a frame to build again, and one that only blinked is not.
	local moved = caretMoved(ctx, window, self.layoutPlugin)

	if moved then
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
		if assert(ctx.screen).changed or not ctx.uploaded or moved then
			built = true
		end
	end

	-- A frame the screen presented is one whose new thing is not in the solve: the shapes an element
	-- draws into the frame itself, a texture another renderer has just filled. What an element draws
	-- reads the app's state, so the frame is built again -- which is what calls those draws -- and
	-- the solve that came out the same is the same one it is built from.
	if built or (mustDraw and ctx.uploaded) then
		built = true
		local walk = self.walk --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, ctx: wonderland.plugin.Layout.Context)]]
		walk(self, window, ctx)
	end

	-- The caret coming or going is one quad of the frame the gpu already has -- which is a frame
	-- whether or not the screen was owed one, since the clock the caret blinks on is its own. A
	-- frame that was walked drew the caret as it is now, so there is nothing to put in or out.
	if blinked and not built then
		built = true
		self:toggle(window, ctx)
	end

	if built or blinked or mustDraw or not asked or not ctx.presented then
		ctx.presented = true
		ctx.framedAt = now()
		self.renderPlugin:draw(assert(self.renderPlugin:getContext(window)))
	end
end

--- A repaint that is not a frame: a window being registered, or a screen drawn by hand. The screen
--- is built and given to the gpu, and the frame it came out to is asked for, which is what a
--- window loop draws.
---
--- It is built whatever the solve came out to: what an app draws into the frame itself is in the
--- frame and not in the solve, so a screen with a canvas or a texture of somebody else's on it is
--- one whose frame is not the one the last solve drew.
---@param window wonderland.RenderWindow
---@param self wonderland.plugin.UI
function UI:refreshView(window)
	-- A click in a field is placed from the frame that was on screen when the pointer went down, so
	-- it is placed before this repaint builds the next one: see `UI:caretClick`.
	self:caretClick(window)
	self.layoutPlugin:refreshView(window)

	local ctx = self.layoutPlugin.contexts[window]

	if not ctx then
		return
	end

	---@cast ctx wonderland.plugin.Layout.Context
	ctx.owed = false

	-- What the frame is asked for by, which is what the gpu does not already have: the screen that
	-- came out, the first frame of a window, and the caret that moved in a screen that did not.
	local changed = assert(ctx.screen).changed
	local wanted = changed or not ctx.uploaded or caretMoved(ctx, window, self.layoutPlugin)

	-- Built whatever the solve came out to: what an element draws into a frame of its own -- the
	-- shapes of a canvas, a texture another renderer has just filled -- reads the app's state, and a
	-- solve that came out the same is not a frame that has nothing new in it.
	local walk = self.walk --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, ctx: wonderland.plugin.Layout.Context)]]
	walk(self, window, ctx)

	if wanted then
		local requestRedraw = self.requestRedraw --[[@as fun(self: wonderland.plugin.UI, window: wonderland.RenderWindow, forced: boolean?)]]
		requestRedraw(self, window)
	end
end

return UI
