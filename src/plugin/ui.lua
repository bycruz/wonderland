local ffi = require("ffi")
local QuadBatch = require("wonderland.util.quad_batch")

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
local UI = {}
UI.__index = UI

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
local function generateNodeQuads(batch, screen, clip, index, parentX, parentY, windowWidth, windowHeight, parentZ,
	fontManager)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local z = math.max(node.zIndex, parentZ or 0)

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

	for at = 0, node.childCount - 1 do
		generateNodeQuads(batch, screen, below, screen.childIndices[node.firstChild + at - 1], x, y, windowWidth,
			windowHeight, z, fontManager)
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

		-- A frame the window manager asked for is the display's own time: one that was held back
		-- for coming too soon is the one that goes out then, so what a window shows is the state
		-- its events left rather than the state they left a frame ago.
		if not forced and not window.frameAsked and at - (ctx.framedAt or 0) < self.frameInterval then
			ctx.owed = true
			return
		end

		ctx.owed = false
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

--- The screen the state says, built for the gpu: this is where a repaint starts. It is the frame
--- that asks for it, once for each frame, which is what keeps the build off the events: see
--- `wonderland.plugin.UI:event`.
---@param window wonderland.RenderWindow
---@return boolean changed # Whether what the gpu has is not this frame
function UI:build(window)
	self.layoutPlugin:refreshView(window)

	local ctx = self.layoutPlugin.contexts[window]

	-- Nothing to draw for a window no screen was made in.
	if not ctx then
		return false
	end

	-- The font a line is drawn in is looked up only when there is a line to draw, so a
	-- screen without text does not need a font at all.
	local fontManager = assert(self.renderPlugin.sharedResources).fontManager

	local screen = assert(ctx.screen)

	-- A repaint whose screen came out the same as the one the gpu already has needs no
	-- quads built and nothing uploaded: that is the whole point of the layout being one
	-- flat array of plain data. The first frame is always built, whatever it says, because
	-- a window that has never been given a frame has nothing to show.
	if not (screen.changed or not ctx.uploaded) then
		return false
	end

	self.batch:reset()
	self.batch:setViewport(window.width, window.height)
	generateNodeQuads(self.batch, screen, { left = 0, top = 0, right = window.width, bottom = window.height },
		assert(ctx.root), 0, 0, window.width, window.height, nil, fontManager)

	self.renderPlugin:setRenderData(window, self.batch)
	ctx.uploaded = true

	return true
end

--- One frame of a window: the screen the state says, built, and then drawn -- which is the whole
--- of what a window that nothing has happened to does when it is asked to draw again.
---
--- A frame the *screen* asked for that came out the same as the one already on screen is not
--- drawn: a pointer that moved across an element that does not change for it, a message that
--- changed nothing the screen shows, and a window drawn again for a frame that is already there
--- are frames that would show nothing new, and drawing one spends the display's time on it --
--- which is time the events behind it spend queued. A frame the *window* asked for is drawn
--- whatever it comes out to, because what it is for is a window that lost what it was showing:
--- an expose, a surface the gpu is not ready to draw into yet.
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

	if not (self:build(window) or not asked or not ctx.presented) then
		return
	end

	ctx.presented = true
	ctx.framedAt = now()
	self.renderPlugin:draw(assert(self.renderPlugin:getContext(window)))
end

--- A repaint that is not a frame: a window being registered, or a screen drawn by hand. The
--- screen is built, and the frame it came out to is asked for, which is what a window loop draws.
---@param window wonderland.RenderWindow
function UI:refreshView(window)
	if self:build(window) then
		self:requestRedraw(window)
	end
end

return UI
