local bit = require("bit")
local UILayout = require("wonderland.layout")
local style = require("wonderland.style")
local utf8 = require("wonderland.font.utf8")
local wonderlandElement = require("wonderland.element")
local time = require("wonderland.time")

-- The elements of this frame, by the index a node holds, and the values an element can
-- only name: a handler, the string it draws. Both are the same arrays every repaint.
local pointers = wonderlandElement.pointers
local strings = wonderlandElement.strings
local callbacks = wonderlandElement.callbacks
local TEXT_INPUT = wonderlandElement.TEXT_INPUT
local MULTILINE = wonderlandElement.MULTILINE
local SLIDE = wonderlandElement.SLIDE

--- Where a node ended up, and which element it is.
---@class wonderland.plugin.Layout.Hit
---@field element wonderland.Element
---@field node wonderland.Node
---@field index number # The node, by the place the screen keeps it in
---@field depth number # How deep in the tree it is, which is what says which of two is innermost
---@field absX number
---@field absY number

-- The nodes are an array, so a walk is an index and an offset rather than a tree of
-- tables. Children are reached through the runs of child indices the layout keeps.

---@param screen wonderland.Layout.Screen
---@param index number
---@param x number
---@param y number
---@param parentX number
---@param parentY number
---@param acceptFn? fun(element: wonderland.Element): boolean
---@return wonderland.plugin.Layout.Hit?
local function findElementAtPosition(screen, index, x, y, parentX, parentY, acceptFn)
	local node = screen:node(index)
	local absX, absY = parentX + node.x, parentY + node.y

	-- A box that scrolls shows only what is inside it, so what is scrolled out of it is not there
	-- to be clicked either.
	if node.scrolls ~= 0 and (x < absX or x > absX + node.width or y < absY or y > absY + node.height) then
		return nil
	end

	-- Always recurse into children: relative-positioned children may extend outside their
	-- parent's bounds.
	for at = 0, node.childCount - 1 do
		local child = screen.childIndices[node.firstChild + at - 1]
		local found = findElementAtPosition(screen, child, x, y, absX, absY, acceptFn)

		if found and (not acceptFn or acceptFn(found.element)) then
			return found
		end
	end

	if x >= absX and x <= absX + node.width and y >= absY and y <= absY + node.height then
		local element = pointers[node.element]

		if not acceptFn or acceptFn(element) then
			return { element = element, node = node, absX = absX, absY = absY }
		end
	end

	return nil
end

---@param screen wonderland.Layout.Screen
---@param index number
---@param results table<wonderland.Element, wonderland.plugin.Layout.Hit>
local function findElementsAtPosition(screen, index, x, y, parentX, parentY, results)
	local node = screen:node(index)
	local absX, absY = parentX + node.x, parentY + node.y

	if x >= absX and x <= absX + node.width and y >= absY and y <= absY + node.height then
		local element = pointers[node.element]

		results[element] = { element = element, node = node, absX = absX, absY = absY }
	end

	if node.scrolls ~= 0 and (x < absX or x > absX + node.width or y < absY or y > absY + node.height) then
		return
	end

	-- Always recurse: relative-positioned children may extend outside parent bounds
	for at = 0, node.childCount - 1 do
		findElementsAtPosition(screen, screen.childIndices[node.firstChild + at - 1], x, y, absX, absY, results)
	end
end

--- The chain of boxes a point is inside, from the one at the root to the innermost one that
--- holds it: what a wheel is offered, and what a press on a scroll bar is measured against. A box
--- that scrolls shows only what is inside it, so a point outside one is inside nothing it holds --
--- which is the same answer a click gets.
---@param screen wonderland.Layout.Screen
---@param index number
---@param x number
---@param y number
---@param parentX number
---@param parentY number
---@param depth number
---@param into wonderland.plugin.Layout.Hit[]
local function chainAtPosition(screen, index, x, y, parentX, parentY, depth, into)
	local node = screen:node(index)
	local absX, absY = parentX + node.x, parentY + node.y
	local inside = x >= absX and x <= absX + node.width and y >= absY and y <= absY + node.height

	if inside then
		into[#into + 1] = {
			element = pointers[node.element],
			node = node,
			index = index,
			depth = depth,
			absX = absX,
			absY = absY,
		}
	end

	if node.scrolls ~= 0 and not inside then
		return
	end

	for at = 0, node.childCount - 1 do
		chainAtPosition(screen, screen.childIndices[node.firstChild + at - 1], x, y, absX, absY, depth + 1, into)
	end
end

--- A scroll bar being dragged: the box it belongs to, how far into the thumb it was taken hold
--- of, and what the box has to say about being scrolled.
---@class wonderland.plugin.Layout.BarDrag
---@field hit wonderland.plugin.Layout.Hit
---@field grab number
---@field thumb number
---@field max number
---@field change any

--- Where the pointer is and whether its button is held, which is what an element's hover and
--- active styles are picked from.
---@class wonderland.plugin.Layout.Pointer
---@field x number
---@field y number
---@field pressed boolean

--- A point in a window, which is what a click in a field leaves behind for the ui to place the
--- caret from: the layout knows which field was clicked, and the ui knows where the text of it is.
---@class wonderland.plugin.Layout.Point
---@field x number
---@field y number

---@class wonderland.plugin.Layout.Context
---@field lastPressTime any
---@field lastPressElement any
---@field window wonderland.RenderWindow
---@field ui wonderland.Element?
---@field screen wonderland.Layout.Screen? # The laid out screen
---@field root number?
---@field uploaded boolean? # Whether the gpu has been given a frame for this window yet
---@field asked boolean? # Whether the screen is what asked for the next frame
---@field owed boolean? # Whether a frame it asked for was held back, waiting for the display
---@field framedAt number? # When the last frame of this window went out, on the clock frames are paced by
---@field caretOn boolean? # Whether the caret is drawn in this frame, which is what it blinks
---@field caretAt number? # And when it last came or went
---@field frameKey string? # What the caret was when the gpu was last given a frame: where it is, not whether it shows
---@field caretBase number? # How many quads the frame's screen is, which is what the caret's is added to
---@field caret wonderland.plugin.UI.Caret? # Where the caret was last placed, and what it is drawn as
---@field presented boolean? # And whether the gpu has drawn one for it
---@field focusedName string?
---@field modifiers winit.KeyModifiers? # What the keyboard last said was held, which mouse events do not carry
---@field barDrag wonderland.plugin.Layout.BarDrag? # The scroll bar being dragged, while one is
---@field dragging wonderland.plugin.Layout.Drag? # The slider being dragged, while one is
---@field pointer wonderland.plugin.Layout.Pointer? # Where the pointer is, and whether it is held
---@field pointing boolean? # Whether the pointer cursor is the one for something clickable
---@field cursorPos number
---@field anchorPos number? # The other end of the selection, from nought: nothing where there is none
---@field typed string? # What has been typed into the focused field since the frame that built it
---@field caretClick wonderland.plugin.Layout.Point? # Where a field was clicked, until the ui has placed the caret from it
---@field selectFrom wonderland.plugin.Layout.Point? # Where a selection was started, until the ui has placed its other end
---@field selecting boolean? # Whether the pointer is down in a field, which is what a drag selects with
---@field repeatKey string? # The key held down in the focused field, which is what the library repeats
---@field repeatMods winit.KeyModifiers? # And the modifiers it went down with
---@field repeatAt number? # When the next one of them is due, on the ui's clock: nothing of it means the hold has just begun
---@field repeatTyped string? # And what the key it is repeating types, which is not always the key: see `typedBy`
---@field lastPressX any
---@field lastPressY any

-- How a key that is held repeats: the wait before it starts at all, and how long there is between
-- the ones after it. The wait is what tells one key from a hold of it -- a key that lingers as long
-- as this is a key someone is holding -- so it is the wait a keyboard has for its own repeats rather
-- than anything shorter: a tap that ended up typing twice because a hand was slow to come off the
-- key is a worse thing than a hold that takes half a second to start. A display's own setting is half a second and then a rate slow enough to watch
-- -- twenty-five a second, on a keyboard set up as most are -- so a backspace held down takes a
-- character at a time at a rate the eye follows rather than one that reads as "it is deleting".
--
-- The interval is two frames' time, which is a character every other frame at a display's sixty a
-- second: even to look at, because every one of them lands on a frame that was going to be drawn
-- anyway, and slower than the keyboard's own rate rather than faster -- a hold that takes a line
-- before it can be watched going is a worse thing to do to a field than a slow repeat is. Nought
-- for the interval turns the library's repeat off, and a held key is then whatever the keyboard
-- itself does with it.
local KEY_REPEAT_DELAY = 0.5
local KEY_REPEAT_INTERVAL = 1 / 30

-- The keys a held key repeats, by name: what moves the caret and what takes a character away, which
-- is what is done over and over while one is held down.
local REPEATS = {
	backspace = true,
	delete = true,
	left = true,
	right = true,
	up = true,
	down = true,
}

--- Whether a key is one a hold repeats: what it does is done again and again while it is held, as
--- opposed to what happens once. A character is one of them -- holding a letter is typing it, and
--- what a screen should do with that is tell the field at the rate it can show rather than at the
--- rate the keyboard manages -- and so is what moves the caret or takes a character away. What is
--- not: return, which sends what is in the field, and a chord held with control, which is a command
--- rather than a letter.
---@param key string
---@param modifiers winit.KeyModifiers?
---@param typed string? # What the key types, where it types something: see `typedBy`
---@return boolean
local function repeats(key, modifiers, typed)
	if modifiers ~= nil and modifiers.ctrl then
		return false
	end

	if REPEATS[key] then
		return true
	end

	-- A key that types a character is one, whatever it is called: what it does is what a hold does
	-- over and over. A key named at length that types nothing is a key of its own -- an arrow, a
	-- function key, return -- and none of those is a character.
	if typed ~= nil then
		return true
	end

	return key == "space" or (#key == 1 and key:byte(1) >= 32)
end

---@class wonderland.plugin.Layout<Message>: wonderland.Plugin
---@field clipboard winit.Clipboard? # Where a paste comes from and a copy goes, where the app has one
---@field textPlugin wonderland.plugin.Text
---@field view fun(window: wonderland.RenderWindow): wonderland.Element<Message>
---@field contexts table<wonderland.RenderWindow, wonderland.plugin.Layout.Context>
---@field keyRepeatDelay number # The wait before a held key repeats, in seconds
---@field keyRepeatInterval number # And the time between the repeats after it, nought for none of them
local Layout = {}
Layout.__index = Layout

---@param view fun(window: wonderland.RenderWindow): wonderland.Element
---@param textPlugin wonderland.plugin.Text
---@param view fun(window: wonderland.RenderWindow): wonderland.Element
---@param textPlugin wonderland.plugin.Text
---@param renderPlugin wonderland.plugin.Render? # What a screen is drawn into, which is the size it is laid out at
function Layout.new(view, textPlugin, renderPlugin) ---@return wonderland.plugin.Layout
	return setmetatable({
		view = view,
		contexts = {},
		textPlugin = textPlugin,
		renderPlugin = renderPlugin,
		keyRepeatDelay = KEY_REPEAT_DELAY,
		keyRepeatInterval = KEY_REPEAT_INTERVAL,
	}, Layout)
end

---@param window wonderland.RenderWindow
function Layout:register(window)
	self.contexts[window] = { window = window, focusedName = nil, cursorPos = 0, screen = UILayout.new() }
	self:refreshView(window)
end

---@param window wonderland.RenderWindow
---@return string?
function Layout:getFocusedId(window)
	local ctx = self.contexts[window]
	return ctx and ctx.focusedName
end

---@param window wonderland.RenderWindow
---@return number
function Layout:getCursorPos(window)
	local ctx = self.contexts[window]
	return ctx and ctx.cursorPos or 0
end

---@param window wonderland.RenderWindow
---@param id string?
function Layout:setFocus(window, id)
	local ctx = self.contexts[window]
	if not ctx then return end
	ctx.focusedName = id
	ctx.cursorPos = 0
	ctx.typed = nil
	ctx.caretClick = nil
	ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil
end

---@param window wonderland.RenderWindow
function Layout:refreshView(window)
	local ctx = self.contexts[window]

	-- A window that was never registered, or one whose last event has already been handled, has
	-- no screen to solve: asking for a repaint of it is not a reason to fall over.
	if not ctx then
		return
	end

	-- The tree the last repaint built is let go of before this one is built, which is what
	-- lets a repaint build a screen out of the memory it already has. It is measured, then
	-- laid out into the screen's array, which is reused from one repaint to the next.
	wonderlandElement.beginFrame()
	local screen = assert(ctx.screen)

	ctx.ui = self.textPlugin:measure(self.view(window))
	ctx.root = screen:fromElement(ctx.ui)

	-- What the app says the field holds is the truth again: what has been typed since the last frame
	-- is a value the app has not been told about yet, and by this frame it has.
	ctx.typed = nil

	-- What the pointer is over is worked out from the boxes a solve produced, and a style kept for
	-- the pointer may lay an element out differently -- so a screen where one of them is used is
	-- built and solved again with it. Only the last solve is compared against the frame the gpu
	-- has, which is what says whether a frame is needed at all: a first solve counted as a frame
	-- would make every frame look like a change of the last one.
	--
	-- Both of those are only worth it when there is a pointer to have a state about: a screen
	-- nobody is pointing at solves once, which is most frames and every frame of a benchmark.
	local pointer = ctx.pointer

	if pointer then
		local width, height = self:size(ctx.window)

		screen:solve(width, height, true)

		if screen:markPointer(pointer.x, pointer.y, pointer.pressed) then
			ctx.root = screen:fromElement(ctx.ui)
		end
	end

	local width, height = self:size(ctx.window)

	screen:solve(width, height)

	-- A line too wide for the room it has is cut to that room, which is a question only the solve
	-- can answer: how much room a box has is what the layout worked out, and the line it holds was
	-- measured before any of it. What a cut line is is part of what a node is, so the screen is
	-- solved again -- the same solve, of boxes whose lines are now the ones they draw.
	if self:cutLines(screen, assert(ctx.root), width) then
		screen:solve(width, height)
	end

	return ctx.root
end

--- One node of the walk below: a line too wide for the room the node has is cut to that room, and
--- its children are walked with the room they have left.
---
--- What the room is is not the node's own width. A line of text in a box is as wide as the line is,
--- so a row whose title is long is a row the title takes over: what it may have is the room its
--- parent leaves it, and -- in a row -- what is left of that before the child after it, which is
--- what a title beside a duration is. That is a question about where everything came out, so it is
--- asked of the solve: see `Layout:cutLines`.
---@param screen wonderland.Layout.Screen
---@param index number
---@param parentX number
---@param parentY number
---@param right number # Where the room this node may use ends, absolute
---@param fontManager FontManager
---@return boolean cut
local function cutInto(screen, index, parentX, parentY, right, fontManager)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local cut = false

	if node.run ~= 0 and bit.band(node.styleFlags, style.PRESENT.ellipsis) ~= 0 then
		local element = pointers[node.element]
		local font = element.fontId ~= 0 and fontManager:get(element.fontId)
		local text = element.text ~= 0 and strings[element.text]
		local room = math.min(node.width, right - x) - node.paddingLeft - node.paddingRight

		if font ~= nil and text ~= nil and room > 0 then
			local run = font:getRun(text, room)

			if run ~= screen.runs[node.run] then
				screen.runs[node.run] = run
				node.runId = run.id
				cut = true

				-- A line that was cut is as wide as it was cut to, so that what comes after it is
				-- placed against what is drawn rather than against what would not fit: the row is
				-- solved again, and the duration beside a title moves to the title's new end.
				if bit.band(node.styleFlags, style.PRESENT.width) == 0 then
					node.widthUnit, node.wantWidth = style.ABS, run.width
				end
			end
		end
	end

	-- What is left for a child: the node's own content edge, and -- in a row -- the place the next
	-- child was given, which is where this one stops being drawn over.
	local contentRight = x + node.width - node.paddingRight
	local isRow = node.direction == 0

	for at = 0, node.childCount - 1 do
		local child = screen.childIndices[node.firstChild + at - 1]
		local limit = contentRight

		if isRow and at < node.childCount - 1 then
			limit = math.min(contentRight, x + screen:node(screen.childIndices[node.firstChild + at]).x)
		end

		if cutInto(screen, child, x, y, math.min(right, limit), fontManager) then
			cut = true
		end
	end

	return cut
end

--- Lines too wide for the room they have, cut to it with an ellipsis where they were cut: what a
--- title in a list of them is. Only a node that asked for it is cut -- see `:ellipsis` -- and the
--- line it is cut to is kept by the font, which holds a line by the string and the width it was
--- cut to, so a repaint of the same screen measures nothing.
---@param screen wonderland.Layout.Screen
---@param root number # The node the screen was built from
---@param width number # The window, which is the room the screen itself has
---@return boolean cut # Whether any line was, which is what wants the screen solved again
function Layout:cutLines(screen, root, width)
	local shared = self.renderPlugin and self.renderPlugin.sharedResources
	local fontManager = shared and shared.fontManager

	if fontManager == nil then
		return false
	end

	return cutInto(screen, root, 0, 0, width, fontManager)
end

--- The size a screen of this window is solved at: the surface it is drawn into rather than the
--- size the window says it is, which is what keeps a screen being resized from being drawn into a
--- surface of another size and stretched to fit. See `wonderland.plugin.Render:size`.
---@param window wonderland.RenderWindow
---@return number width
---@return number height
function Layout:size(window)
	local render = self.renderPlugin

	if render then
		return render:size(window)
	end

	return window.width, window.height
end

local function hasMouseUp(e) ---@param e wonderland.Element
	return e.onmouseup ~= 0
end

local function hasDrop(e) ---@param e wonderland.Element
	return e.ondrop ~= 0
end

local function hasContextMenu(e) ---@param e wonderland.Element
	return e.oncontextmenu ~= 0
end

local function hasMouseDownOrClick(e) ---@param e wonderland.Element
	return bit.band(e.flags, TEXT_INPUT) ~= 0 or bit.band(e.flags, SLIDE) ~= 0
		or e.onmousedown ~= 0 or e.onclick ~= 0 or e.ondblclick ~= 0
end

---@param element wonderland.Element
---@param id string
---@return wonderland.Element?
local function findElementById(element, id)
	if wonderlandElement.nameOf(element) == id then return element end

	local child = element.childFirst

	while child ~= 0 do
		local childElement = pointers[child]
		local found = findElementById(childElement, id)

		if found then return found end

		child = childElement.nextSibling
	end

	return nil
end

local DOUBLE_CLICK_THRESHOLD = 0.3 -- seconds

--- What a box that scrolls says about being scrolled: a handler that is asked, or a message that is
--- the answer as it is. Which of the two it is is what an element was given -- see `:onScroll`.
---@param handler any
---@param by number? # How far a wheel asks the content to move
---@param to number? # Or where a bar dragged puts it
---@return any? message
local function scrollMessage(handler, by, to)
	if handler == nil then
		return nil
	end

	if type(handler) == "function" then
		return handler(by, to)
	end

	return handler
end

--- What a box is asked when it is pressed with a button that is not the left one: a context menu.
---@param handler any
---@param x number
---@param y number
---@param width number
---@param height number
---@param modifiers winit.KeyModifiers?
---@return any? message
local function contextMessage(handler, x, y, width, height, modifiers)
	if handler == nil then
		return nil
	end

	if type(handler) == "function" then
		return handler(x, y, width, height, modifiers)
	end

	return handler
end

--- What a box is asked when files are dropped on it: the paths, and where in the box they landed.
---@param handler any
---@param paths string[]
---@param x number
---@param y number
---@return any? message
local function dropMessage(handler, paths, x, y)
	if handler == nil then
		return nil
	end

	if type(handler) == "function" then
		return handler(paths, x, y)
	end

	return handler
end

--- The box a wheel is for: the innermost box under the pointer that scrolls, or that has said it
--- takes the wheel itself. A box that does not scroll passes it to the box it sits in, which is
--- what makes a list of rows scroll when the pointer is over one of the rows.
---@param ctx wonderland.plugin.Layout.Context
---@param x number
---@param y number
---@return wonderland.plugin.Layout.Hit?
local function wheelTarget(ctx, x, y)
	local chain = {}

	chainAtPosition(assert(ctx.screen), assert(ctx.root), x, y, 0, 0, 0, chain)

	local found = nil

	for _, hit in ipairs(chain) do
		if (hit.node.scrolls ~= 0 or hit.element.onscroll ~= 0) and (found == nil or hit.depth >= found.depth) then
			found = hit
		end
	end

	return found
end

--- The bar of a box that scrolls, as this reads it: how tall the thumb is, where its top is, and
--- how wide the strip it is drawn in is. It is worked out the way the ui draws it, so that the bar
--- a person takes hold of is the bar they see -- see `wonderland.plugin.UI`.
---@param screen wonderland.Layout.Screen
---@param hit wonderland.plugin.Layout.Hit
---@return number? thumb
---@return number? top
---@return number? width
local function barOf(screen, hit)
	local bar = screen.bars[hit.index - 1]

	if not bar or bar.width <= 0 or bar.max <= 0 then
		return nil, nil, nil
	end

	local node = hit.node
	local thumb = node.height * (node.height / (node.height + bar.max))

	if thumb < bar.least then
		thumb = bar.least
	end

	if thumb > node.height then
		thumb = node.height
	end

	local span = node.height - thumb
	local at = math.min(math.max(node.scroll / bar.max, 0), 1)

	return thumb, hit.absY + (span > 0 and at * span or 0), bar.width
end

--- Every element a keyboard can be put on, in the order a screen is read in: the fields, and the
--- things that answer a click or say what they look like with the keyboard in them. All of them by
--- name, because a name is what the focus is kept as.
---@param element wonderland.Element
---@param into wonderland.Element[]
local function collectFocusable(element, into)
	local takes = bit.band(element.flags, TEXT_INPUT) ~= 0 or element.onclick ~= 0 or element.focusStyle ~= 0

	if takes and element.name ~= 0 then
		into[#into + 1] = element
	end

	local child = element.childFirst

	while child ~= 0 do
		local childElement = pointers[child]

		collectFocusable(childElement, into)
		child = childElement.nextSibling
	end
end


--- Where the pointer is. It is one table per window rather than one per event, because a
--- pointer moves: what changes is what it says.
---@param ctx wonderland.plugin.Layout.Context
---@param x number
---@param y number
---@param pressed boolean?
local function setPointer(ctx, x, y, pressed)
	local pointer = ctx.pointer

	if not pointer then
		pointer = { x = x, y = y, pressed = false }
		ctx.pointer = pointer
	end

	pointer.x, pointer.y = x, y

	if pressed ~= nil then
		pointer.pressed = pressed
	end
end

--- A slider being dragged: what to tell about it, the box it is measured along, and the two
--- values its ends are. The callback is held rather than the element, because an element is
--- built again every frame and its callbacks are the frame's, while a drag goes on across them.
--- What the pointer is measured against is where the middle of the nub sits at the low end of the
--- slider: a nub is what the pointer grabs, so a pointer at a nub's middle is the value that nub
--- is at, and one whose box has no nub is measured from the end of the box.
---@class wonderland.plugin.Layout.Drag
---@field change fun(value: number): any
---@field x number # Where the pointer is measured from, absolute
---@field y number
---@field span number # And how far along from there the high end of the slider is
---@field vertical boolean # Whether a slider that stacks down is dragged up and down
---@field min number
---@field max number
---@field value number? # The value it reported last, which is what says a change is a change

--- Where a pointer is along a dragged slider, as the value that sits there: the two ends of the
--- box are the two ends of the slider, and a pointer past either of them is as far as it goes.
---@param drag wonderland.plugin.Layout.Drag
---@param x number
---@param y number
---@return number
local function valueAt(drag, x, y)
	local span = drag.span > 0 and drag.span or 1
	local along = ((drag.vertical and y or x) - (drag.vertical and drag.y or drag.x)) / span
	local fraction = math.min(math.max(along, 0), 1)

	return drag.min + fraction * (drag.max - drag.min)
end

--- What a drag says: the value the pointer is at, and only when it is not the one it was at
--- last. A slider held past one of its ends is a slider whose value is not changing, and a
--- callback told the same value a hundred times is the app building a screen a hundred times for
--- a frame that says what the one before it said -- which, with a pointer held down and moved
--- away, is a window that stops answering.
---@param drag wonderland.plugin.Layout.Drag
---@param x number
---@param y number
---@return any? message
local function report(drag, x, y)
	local value = valueAt(drag, x, y)

	if value == drag.value then
		return nil
	end

	drag.value = value
	return drag.change(value)
end

--- The box a press on a slider is measured in, as the drag that goes with it: the box less its
--- padding and its borders, which is the space a slider stacks its own children in, and less the
--- nub as well when there is one, since the nub's own ends are the ends of the slider. The nub is
--- the child the layout put where the value is, so the two agree on where a value is by both
--- being worked out the same way: see the nub in `solveNode`.
---@param screen wonderland.Layout.Screen
---@param hit wonderland.plugin.Layout.Hit
---@param element wonderland.Element
---@return wonderland.plugin.Layout.Drag
local function dragFor(screen, hit, element)
	local node = hit.node
	local across = node.direction == 0
	local lead = across and node.paddingLeft or node.paddingTop
	local trail = across and node.paddingRight or node.paddingBottom
	local borders = across and (node.borderLeft + node.borderRight) or (node.borderTop + node.borderBottom)
	local nub = 0

	for at = 0, node.childCount - 1 do
		local child = screen.nodes[screen.childIndices[node.firstChild + at - 1] - 1]

		if child.thumb ~= 0 then
			nub = across and child.width or child.height
			break
		end
	end

	return {
		change = callbacks[element.onchange],
		x = hit.absX + lead + (across and nub / 2 or 0),
		y = hit.absY + lead + (across and 0 or nub / 2),
		span = (across and node.width or node.height) - lead - trail - borders - nub,
		vertical = not across,
		min = element.min,
		max = element.max,
	}
end

--- What a value typed into a field is made of: one line until a break is typed into it.
---@param value string
---@param at number # Where the caret is: from nought, before the first byte, to its length
---@return number # The byte the line the caret is on starts at
local function lineStart(value, at)
	local before = value:sub(1, at)
	local break_ = before:find("\n[^\n]*$")

	return break_ and break_ + 1 or 1
end

---@param value string
---@param at number
---@return number # And the byte that line ends at, which is the end of the value on the last one
local function lineEnd(value, at)
	local break_ = value:find("\n", at + 1, true)

	return break_ and break_ - 1 or #value
end

--- Whether a byte is part of a word: the ASCII letters, digits and underscore, and every byte of a
--- character that is not ASCII, since a word in another language is a word.
---@param byte number?
---@return boolean
local function isWordByte(byte)
	return byte ~= nil and (byte >= 0x80 or byte == 0x5F
		or (byte >= 0x30 and byte <= 0x39)
		or (byte >= 0x41 and byte <= 0x5A)
		or (byte >= 0x61 and byte <= 0x7A))
end

---@param byte number?
---@return boolean
local function isSpace(byte)
	return byte ~= nil and (byte == 0x20 or (byte >= 0x09 and byte <= 0x0D))
end

--- Where a key that walks or takes away by words goes from a caret: back over the space between two
--- words and then over the word itself, which is a run of word bytes or a run of punctuation.
---@param value string
---@param at number # How many bytes come before the caret, from nought
---@return number
local function wordBack(value, at)
	local back = utf8.back(value, at)

	while back > 0 and isSpace(value:byte(back + 1)) do
		back = utf8.back(value, back)
	end

	local word = isWordByte(value:byte(back + 1))

	while back > 0 do
		local byte = value:byte(back + 1)

		if isSpace(byte) or isWordByte(byte) ~= word then
			break
		end

		back = utf8.back(value, back)
	end

	return back
end

--- Where a key that walks by words goes forwards from a caret: to the end of the word it is in, and
--- to the end of the next one where it is not in a word.
---@param value string
---@param at number
---@return number
local function wordForward(value, at)
	local ahead, length = at, #value

	while ahead < length and not isWordByte(value:byte(ahead + 1)) do
		ahead = utf8.forward(value, ahead)
	end

	while ahead < length and isWordByte(value:byte(ahead + 1)) do
		ahead = utf8.forward(value, ahead)
	end

	return ahead
end

--- What a key types where it types something a field takes -- shift and 1 is the key 1 pressed and
--- "!" typed -- or nothing, for a key that types nothing of its own.
---
--- A character is one to four bytes, so what is refused is a key that types nothing printable rather
--- than a key that types more than one byte.
---@param event winit.Event
---@return string?
local function typedBy(event)
	local text = event.text

	if text == nil or #text == 0 then
		return nil
	end

	for at = 1, #text do
		local byte = text:byte(at)

		if byte < 32 or byte == 127 then
			return nil
		end
	end

	return text
end

--- How many lines a value is: one, and one more for every break in it. What a field is held to is
--- counted in lines, and a value of no breaks is one line however long it is.
---@param value string
---@return number
local function lineCount(value)
	local count = 1

	for _ in value:gmatch("\n") do
		count = count + 1
	end

	return count
end

--- The caret moved a line up or down, keeping how far into its line it was. It stays where it is
--- at either end of the value, which is what having no line above or below it means. A caret is
--- the gap before a byte, so how far into a line it is counts from the gap before the line.
---@param value string
---@param at number
---@param by number
---@return number
local function lineAcross(value, at, by)
	local start = lineStart(value, at)
	local column = at - (start - 1)

	if by < 0 then
		if start == 1 then return at end

		-- Up: the line above ends at the byte before the break that ended it.
		local above = start - 2
		local aboveStart = lineStart(value, above)

		return math.min(aboveStart - 1 + column, above)
	end

	local stop = lineEnd(value, at)

	if stop >= #value then return at end

	local belowStart = stop + 2
	local belowStop = lineEnd(value, belowStart)

	return math.min(belowStart - 1 + column, belowStop)
end


--- The caret of the field that has the keyboard: which element it is for, the line of it the caret is
--- on and how many bytes of that line come before it, and the bytes the selection covers where there
--- is one. Nothing is returned where no field has the keyboard.
---@param window wonderland.RenderWindow
---@return wonderland.Element? element
---@return number? line # From nought, so a field of one line is always on line nought
---@return number? column # How many bytes of that line come before the caret
---@return number? from # The first byte of the value a selection covers, where there is one
---@return number? to
function Layout:getCaret(window)
	local ctx = self.contexts[window]

	if not ctx or not ctx.focusedName or ctx.ui == nil then
		return nil, nil, nil
	end

	local element = findElementById(ctx.ui, ctx.focusedName)

	if element == nil or bit.band(element.flags, TEXT_INPUT) == 0 then
		return nil, nil, nil
	end

	local value = wonderlandElement.inputOf(element)
	local start = lineStart(value, ctx.cursorPos)
	local line = lineCount(value:sub(1, start - 1)) - 1
	local limit = #value
	local anchor = math.min(math.max(ctx.anchorPos or ctx.cursorPos, 0), limit)
	local at = math.min(math.max(ctx.cursorPos, 0), limit)

	if anchor == at then
		return element, line, ctx.cursorPos - (start - 1)
	end

	return element, line, ctx.cursorPos - (start - 1), math.min(anchor, at), math.max(anchor, at)
end

--- A press on a scroll bar, as the message it comes to: the bar is the box's own, so what it does
--- is scroll that box. Taking hold of the thumb drags it; pressing the track beside it takes the
--- thumb to the pointer, which is what a track is for.
---@param ctx wonderland.plugin.Layout.Context
---@param x number
---@param y number
---@return any? message
function Layout:barPress(ctx, x, y)
	local chain = {}

	chainAtPosition(assert(ctx.screen), assert(ctx.root), x, y, 0, 0, 0, chain)

	local screen = assert(ctx.screen)

	-- The innermost bar under the pointer, because a box that scrolls may hold another one.
	for at = #chain, 1, -1 do
		local hit = chain[at]
		local thumb, top, width = barOf(screen, hit)

		if thumb ~= nil and top ~= nil and width ~= nil and hit.element.onscroll ~= 0
			and x >= hit.absX + hit.node.width - width then
			local bar = assert(screen.bars[hit.index - 1])

			-- A press on the thumb takes hold of it where it was pressed, so it does not jump
			-- under the pointer; a press on the track takes the thumb to the pointer, which is
			-- what says which part of the content is being asked for.
			local grab = y - top

			if grab < 0 or grab > thumb then
				grab = math.floor(thumb / 2)
			end

			local span = hit.node.height - thumb
			local position = (y - grab - hit.absY) / (span > 0 and span or 1)

			ctx.barDrag = {
				hit = hit,
				grab = grab,
				thumb = thumb,
				max = bar.max,
				change = callbacks[hit.element.onscroll],
			}

			return scrollMessage(ctx.barDrag.change, nil, math.min(math.max(position, 0), 1) * bar.max)
		end
	end

	return nil
end

--- The first few lines of a string, which is what a paste into a field with lines to spare is.
---@param text string
---@param lines number
---@return string
local function firstLines(text, lines)
	local at, seen = 1, 1

	while seen < lines do
		local newline = text:find("\n", at, true)

		if newline == nil then
			return text
		end

		seen = seen + 1
		at = newline + 1
	end

	local last = text:find("\n", at, true)

	return last ~= nil and text:sub(1, last - 1) or text
end

--- What control and a key does with the clipboard, in the field that has the keyboard: what is
--- copied, cut and pasted over is the selection, and the whole of what the field holds where there
--- is no selection -- which is all a field with nothing selected has to give.
---
--- A field of one line takes the first line of what was pasted, because a paste of a paragraph
--- into a name is a name; a paragraph takes the lines it has room for, since a limit on a
--- paragraph is a limit on what it holds. Nothing is written to the clipboard by a field with
--- nothing in it, and a paste of nothing is no edit at all.
---@param element wonderland.Element
---@param ctx wonderland.plugin.Layout.Context
---@param key string
---@param value string
---@param cursor number
---@param from number # The first byte a selection covers, or the caret where there is none
---@param to number
---@param edit fun(edited: string): any?
---@return any? message
function Layout:clipboardKey(element, ctx, key, value, cursor, from, to, edit)
	local clipboard = self.clipboard

	if clipboard == nil then
		return nil
	end

	if key == "c" or key == "x" then
		if value == "" then
			return nil
		end

		clipboard:setText(from < to and value:sub(from + 1, to) or value)

		if key == "c" then
			return nil
		end

		-- Cutting is copying and then not having it, and a field with nothing selected has only the
		-- whole of its value to cut.
		ctx.anchorPos = nil
		ctx.cursorPos = from

		return edit(from < to and (value:sub(1, from) .. value:sub(to + 1)) or "")
	end

	local pasted = clipboard:getText()

	if pasted == nil or pasted == "" then
		return nil
	end

	if bit.band(element.flags, MULTILINE) == 0 then
		pasted = pasted:match("^[^\n]*")
	end

	if element.maxLines > 0 then
		local kept = value:sub(1, from) .. value:sub(to + 1)
		local room = element.maxLines - lineCount(kept) + 1

		if room < 1 then
			return nil
		end

		pasted = firstLines(pasted, room)
	end

	if pasted == nil or pasted == "" then
		return nil
	end

	-- What is pasted lands where the caret is, over a selection where there is one: replacing a
	-- selection is what a paste into a field with one is for.
	ctx.anchorPos = nil
	ctx.cursorPos = from + #pasted

	return edit(value:sub(1, from) .. pasted .. value:sub(to + 1))
end

--- The keyboard put on the next thing that can be focused, which is what tab is for: a screen with
--- no pointer in it is a screen a person still has to be able to fill in. It wraps at the end,
--- because a screen is a cycle of the things on it rather than a line, and what comes after the
--- last one is the first.
---
--- What a field is left holding is its value with the caret at the end of it, which is where a
--- focus that arrived by keyboard has been: tabbing into a field is what a person does to replace
--- what is in it.
---@param ctx wonderland.plugin.Layout.Context
---@param backwards boolean?
---@return any? message
function Layout:focusNext(ctx, backwards)
	if ctx.ui == nil then
		return nil
	end

	local focusable = {}

	collectFocusable(ctx.ui, focusable)

	if #focusable == 0 then
		return nil
	end

	local at = 0

	for index, element in ipairs(focusable) do
		if wonderlandElement.nameOf(element) == ctx.focusedName then
			at = index
			break
		end
	end

	local next = at + (backwards and -1 or 1)

	if next < 1 then
		next = #focusable
	elseif next > #focusable then
		next = 1
	end

	local element = focusable[next]

	ctx.focusedName = wonderlandElement.nameOf(element)
	ctx.cursorPos = #wonderlandElement.inputOf(element)
	ctx.anchorPos = nil
	ctx.typed = nil
	ctx.caretClick = nil
	ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil

	return { type = "_inputRefresh" }
end

--- Where a line and a column of the value come to, as a byte of it: the line the value is split into
--- by its breaks, and the column from the start of that line, clamped to what the line holds.
---@param value string
---@param line number
---@param column number
---@return number? at
local function byteAt(value, line, column)
	local start = 1

	for _ = 1, line do
		local break_ = value:find("\n", start, true)

		if not break_ then
			return nil
		end

		start = break_ + 1
	end

	return math.min(start - 1 + column, lineEnd(value, start - 1))
end

--- The caret put where a line and a column of the value are, which is what a click in a field comes
--- to. The ui walks the text the field draws, so it says which line a point is on and which byte of
--- it the point is at. A column past the end of its line is the end of it, and a line the value does
--- not have leaves the caret where it was.
---
--- The other end of a selection is a line and a column of its own, which is where a drag started:
--- the two ends are put in one call so that neither is read against a value the other has moved.
---@param window wonderland.RenderWindow
---@param line number
---@param column number # How many bytes of that line come before the caret
---@param anchorLine number? # And where the other end of a selection is, where one was made
---@param anchorColumn number?
function Layout:setCaret(window, line, column, anchorLine, anchorColumn)
	local ctx = self.contexts[window]

	if not ctx or not ctx.focusedName or ctx.ui == nil then
		return
	end

	local element = findElementById(ctx.ui, ctx.focusedName)

	if element == nil or bit.band(element.flags, TEXT_INPUT) == 0 then
		return
	end

	-- The value as the keys before this frame have left it, as everywhere else a key is handled.
	local value = ctx.typed or wonderlandElement.inputOf(element)
	local at = byteAt(value, line, column)

	if at == nil then
		return
	end

	ctx.cursorPos = at

	if anchorLine ~= nil then
		ctx.anchorPos = byteAt(value, anchorLine, anchorColumn or 0)
	end
end

--- What a key does to the field that has the keyboard, as the message the app is told. It is one
--- call rather than the body of an event handler because one key is handled more than once: the
--- display repeats a held key, and so does the library -- see `Layout:event`, which says what is
--- repeating, and `UI:tick`, which is what has the clock -- and every one of those is the same key
--- doing the same thing to the value the one before it left.
---@param window wonderland.RenderWindow
---@param key string # The key itself, which is what a named key is handled as
---@param modifiers winit.KeyModifiers?
---@param typed string # What the key types, which is what a field takes of it and not always the key: the key itself where it types nothing of its own
---@return any? message
function Layout:key(window, key, modifiers, typed)
	local ctx = self.contexts[window]

	if not ctx then
		return nil
	end

	-- Tab is the one key that is not about what has the keyboard but about which thing has it, so
	-- it is answered before anything is looked up -- and it works with nothing focused at all,
	-- which is where a window starts.
	if key == "tab" then
		return self:focusNext(ctx, modifiers ~= nil and modifiers.shift == true)
	end

	if not ctx.focusedName then
		return nil
	end

	local element = findElementById(ctx.ui, ctx.focusedName)

	if element == nil then
		return nil
	end

	-- A thing that answers a click and is not a field is worked by the keyboard as well as by the
	-- pointer when it is the thing the keyboard is on: return or space takes it.
	if bit.band(element.flags, TEXT_INPUT) == 0 then
		if (key == "return" or key == "space") and element.onclick ~= 0 then
			return callbacks[element.onclick]
		end

		return nil
	end

	-- What is typed into is the value as it is now, which is not necessarily the one the last frame
	-- drew: a key is handled as it arrives, and a key held down arrives several times between two
	-- frames. Every key applied to the field the frame drew would apply it to the same value over
	-- and over -- a backspace held down taking the same character each time while the caret walks
	-- back, which is a caret that leaves the text behind rather than deleting it.
	local value = ctx.typed or wonderlandElement.inputOf(element)
	local cursor = ctx.cursorPos

	--- The value an edit left the field with, kept for the keys before the next frame and
	--- reported to the app.
	---@param edited string
	---@return any?
	local function edit(edited)
		ctx.typed = edited

		local handler = callbacks[element.oninput]

		return handler and handler(edited) or { type = "_inputRefresh" }
	end

	--- The bytes a selection covers, from the earlier end, clamped to what the value holds: the
	--- caret and the anchor, whichever way round they are. A selection of nothing is one byte twice,
	--- which is no selection at all.
	---@return number from
	---@return number to
	local function selected()
		local anchor = ctx.anchorPos
		local limit = #value

		if anchor == nil then
			return math.min(cursor, limit), math.min(cursor, limit)
		end

		anchor = math.min(math.max(anchor, 0), limit)

		local at = math.min(math.max(cursor, 0), limit)

		return math.min(anchor, at), math.max(anchor, at)
	end

	--- What is typed lands where the caret is, over a selection where there is one: a selection is
	--- what a person made to replace it.
	---@param text string
	---@return any?
	local function typeIn(text)
		local from, to = selected()

		ctx.anchorPos = nil
		ctx.cursorPos = from + #text

		return edit(value:sub(1, from) .. text .. value:sub(to + 1))
	end

	--- A stretch of the value taken out, with the caret where it was taken from. Every edit that
	--- takes something away goes through this, so a selection is taken away as one thing and the
	--- anchor goes with it.
	---@param from number
	---@param to number
	---@return any?
	local function cutOut(from, to)
		ctx.anchorPos = nil
		ctx.cursorPos = from

		return edit(value:sub(1, from) .. value:sub(to + 1))
	end

	--- The caret moved, which is what every key that walks it does: on its own it puts the caret and
	--- forgets the selection, and with shift held it keeps the other end of it where it was, which is
	--- how a selection is made with the keyboard.
	---@param at number
	---@return any?
	local function moveTo(at)
		if modifiers ~= nil and modifiers.shift == true then
			if ctx.anchorPos == nil then
				ctx.anchorPos = cursor
			end
		else
			ctx.anchorPos = nil
		end

		ctx.cursorPos = at

		return { type = "_inputRefresh" }
	end

	if key == "escape" then
		ctx.focusedName = nil
		ctx.cursorPos = 0
		ctx.anchorPos = nil
		return { type = "_inputRefresh" }
	elseif key == "return" then
		local submit = callbacks[element.onsubmit]

		-- A paragraph takes the break, and control with return is what sends it: a
		-- field that is one line has nothing to break, so return sends it.
		if bit.band(element.flags, MULTILINE) ~= 0 and not (modifiers and modifiers.ctrl) then
			-- Up to the lines the field is held to: a paragraph with a limit on it is one whose
			-- last line is the last line, so a break typed at the end of it is a key that does
			-- nothing rather than a line that is drawn past the box it was given.
			local most = element.maxLines

			if most > 0 and lineCount(value) >= most then
				return nil
			end

			return typeIn("\n")
		elseif submit then
			return submit(value)
		end
	elseif key == "backspace" then
		-- A selection is taken away as one thing, and a character otherwise: a backspace that took
		-- one byte would leave half of a letter behind.
		local from, to = selected()

		if from < to then
			return cutOut(from, to)
		end

		local back = utf8.back(value, cursor)

		if back < cursor then
			return cutOut(back, cursor)
		end
	elseif key == "delete" then
		local from, to = selected()

		if from < to then
			return cutOut(from, to)
		end

		local ahead = utf8.forward(value, cursor)

		if ahead > cursor then
			return cutOut(cursor, ahead)
		end
	elseif key == "left" then
		-- With control it walks a word rather than a character, which is the same key either way.
		return moveTo(modifiers ~= nil and modifiers.ctrl == true
				and wordBack(value, cursor)
			or utf8.back(value, cursor))
	elseif key == "right" then
		return moveTo(modifiers ~= nil and modifiers.ctrl == true
				and wordForward(value, cursor)
			or utf8.forward(value, cursor))
	elseif key == "home" then
		return moveTo(lineStart(value, cursor) - 1)
	elseif key == "end" then
		return moveTo(lineEnd(value, cursor))
	elseif key == "up" then
		return moveTo(lineAcross(value, cursor, -1))
	elseif key == "down" then
		return moveTo(lineAcross(value, cursor, 1))
	elseif modifiers and modifiers.ctrl then
		if key == "w" then
			-- The word before the caret, or the selection where there is one: what control and w is
			-- in every editor there is.
			local from, to = selected()

			if from < to then
				return cutOut(from, to)
			end

			local back = wordBack(value, cursor)

			if back < cursor then
				return cutOut(back, cursor)
			end
		elseif key == "a" or key:byte(1) == 1 then
			-- Select all: the caret at the end of the value and the other end of the selection at
			-- the start of it.
			ctx.anchorPos, ctx.cursorPos = 0, #value

			return { type = "_inputRefresh" }
		elseif key == "v" or key == "c" or key == "x" then
			local from, to = selected()

			return self:clipboardKey(element, ctx, key, value, cursor, from, to, edit)
		end
	elseif key == "space" then
		return typeIn(" ")
	elseif typed ~= nil and typed:byte(1) >= 32 and (typed ~= key or #key == 1) then
		-- What is typed is what the key types rather than what it is named: shift and 1 is named 1 and
		-- types "!". A key that types nothing was handed its own name as what it types, so a name of
		-- more than one character is a key this does not handle rather than something typed.
		return typeIn(typed)
	end
end

---@generic Message
---@param self wonderland.plugin.Layout<Message>
---@param event winit.Event
---@return Message?
function Layout:event(event)
	if event.name == "focusOut" then
		-- The pointer is not in this window any more, so nothing is under it.
		local ctx = self.contexts[event.window]

		if ctx then
			ctx.pointer = nil

			-- The window does not have the keyboard any more either, so a key that was held down in
			-- it is not held down in it: what repeats stops, and a key released while the window is
			-- away comes back as a release that nothing is repeating.
			ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil
		end
	elseif event.name == "mouseMove" then
		local ctx = self.contexts[event.window]
		if not ctx then return end

		setPointer(ctx, event.x, event.y)

		if ctx.barDrag ~= nil then
			local drag = ctx.barDrag
			local hit = drag.hit
			local span = hit.node.height - drag.thumb
			local at = (event.y - drag.grab - hit.absY) / (span > 0 and span or 1)
			local to = math.min(math.max(at, 0), 1) * drag.max

			return scrollMessage(drag.change, nil, to)
		end

		if ctx.dragging then
			return report(ctx.dragging, event.x, event.y)
		end

		-- A pointer held down in a field is a selection being made: where it is now is the caret, and
		-- where the press was is the other end of it. The point is left for the ui, which is what
		-- knows where the text of the field is: see `UI:caretClick`.
		if ctx.selecting then
			ctx.caretClick = { x = event.x, y = event.y }

			return nil
		end

		---@type table<wonderland.Element, wonderland.plugin.Layout.Hit>
		local hoveredElements = {}
		findElementsAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hoveredElements)

		local anyWithMouseDown = false
		for el, _ in pairs(hoveredElements) do
			if bit.band(el.flags, TEXT_INPUT) ~= 0 or bit.band(el.flags, SLIDE) ~= 0
				or el.onmousedown ~= 0 or el.onclick ~= 0 then
				anyWithMouseDown = true
				break
			end
		end

		-- A screen with no window has no cursor to point with, so it is asked for rather than
		-- assumed -- and only asked when the answer changed. Setting a cursor is a round trip
		-- to the server, and one per mouse move is time the pointer spends waiting.
		local window = ctx.window
		if window.setCursor and anyWithMouseDown ~= ctx.pointing then
			ctx.pointing = anyWithMouseDown

			if anyWithMouseDown then
				window:setCursor("hand2")
			elseif window.resetCursor then
				window:resetCursor()
			end
		end

		for el, layout in pairs(hoveredElements) do
			local handler = callbacks[el.onmousemove]

			if handler then
				local relX = event.x - layout.absX
				local relY = event.y - layout.absY
				return handler(relX, relY, layout.node.width, layout.node.height, ctx.modifiers)
			end
		end
	elseif event.name == "mousePress" then
		local ctx = self.contexts[event.window]
		setPointer(ctx, event.x, event.y, true)

		-- A press is the hand leaving the keyboard: what was repeating stops, whether or not it
		-- was the field that was pressed.
		ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil

		-- Which button it was is what says what a press means. A platform that does not name one
		-- -- one of them does not -- is a press of the left one, which is what every press meant
		-- before any of them were named.
		local button = event.button or 1

		-- The button that is not the left one is a menu where the pointer is, and nothing else:
		-- what answers a click is not told about it, and the keyboard stays where it was.
		if button == 3 then
			local pressed = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0,
				hasContextMenu)

			if pressed then
				return contextMessage(callbacks[pressed.element.oncontextmenu], event.x - pressed.absX,
					event.y - pressed.absY, pressed.node.width, pressed.node.height, ctx.modifiers)
			end

			return nil
		end

		if button ~= 1 then
			return nil
		end

		-- A press on a scroll bar is a press on the box the bar belongs to rather than on what is
		-- drawn under it: the bar is over the strip it reserved, and what is behind it is not
		-- something anyone was aiming at.
		local bar = self:barPress(ctx, event.x, event.y)

		if bar ~= nil then
			return bar
		end

		local info = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hasMouseDownOrClick)

		-- Update focus: set on text input click, clear otherwise
		if info and bit.band(info.element.flags, TEXT_INPUT) ~= 0 then
			ctx.focusedName = wonderlandElement.nameOf(info.element)
			-- Where in what it holds the pointer is, which is not something the layout can work
			-- out: the text a field draws is the app's, and which line and which character of it a
			-- point is at comes from the run the ui walks. Until the ui has placed the caret from
			-- it, the caret is at the end of the value -- which is what a field that draws none
			-- gets, and what every click in one did before the ui knew about it.
			ctx.caretClick = { x = event.x, y = event.y }
			-- Where the press was is the other end of the selection a drag makes: a press that is
			-- let go of where it landed is a caret, and one that is dragged is a selection.
			ctx.selectFrom = { x = event.x, y = event.y }
			ctx.selecting = true
			ctx.anchorPos = nil
			ctx.cursorPos = #wonderlandElement.inputOf(info.element)
			ctx.typed = nil
		else
			ctx.focusedName = nil
			ctx.cursorPos = 0
			ctx.caretClick = nil
			ctx.selectFrom = nil
			ctx.selecting = nil
			ctx.anchorPos = nil
		end

		if info then
			local now = time.now()
			local isDblClick = (info.element.ondblclick ~= 0)
				and ctx.lastPressElement == info.element
				and ctx.lastPressTime
				and (now - ctx.lastPressTime) <= DOUBLE_CLICK_THRESHOLD
				and ctx.lastPressX == event.x
				and ctx.lastPressY == event.y

			ctx.lastPressElement = info.element
			ctx.lastPressTime = now
			ctx.lastPressX = event.x
			ctx.lastPressY = event.y

			if isDblClick then
				ctx.lastPressElement = nil
				ctx.lastPressTime = nil
				return callbacks[info.element.ondblclick]
			end

			if info.element.onclick ~= 0 then
				return callbacks[info.element.onclick]
			end

			if bit.band(info.element.flags, SLIDE) ~= 0 then
				-- The box is kept, not the pointer's place in it: a drag goes on where the pointer
				-- goes, and it is measured along the box it started in.
				local drag = dragFor(assert(ctx.screen), info, info.element)

				ctx.dragging = drag
				return report(drag, event.x, event.y)
			end

			local pressed = callbacks[info.element.onmousedown]

			if pressed then
				local relX = event.x - info.absX
				local relY = event.y - info.absY
				return pressed(relX, relY, info.node.width, info.node.height, ctx.modifiers)
			end
		end
	elseif event.name == "mouseScroll" then
		local ctx = self.contexts[event.window]

		-- A wheel arrives without a place in the window -- the platform reports that it turned,
		-- not where -- so it goes to the box the pointer was last seen in. A window the pointer
		-- has never been in has no box for it, and the app's own event handler is what hears it.
		if ctx and ctx.pointer ~= nil and (event.dy ~= 0 or event.dx ~= 0) then
			local hit = wheelTarget(ctx, ctx.pointer.x, ctx.pointer.y)

			if hit ~= nil and hit.element.onscroll ~= 0 then
				-- How far a wheel asks the content to move is the app's to work out: a row of a
				-- list and a page of a document are not the same distance, and what the platform
				-- reports is the wheel turning rather than the distance.
				return scrollMessage(callbacks[hit.element.onscroll], event.dy ~= 0 and event.dy or event.dx, nil)
			end
		end
	elseif event.name == "fileDrop" then
		local ctx = self.contexts[event.window]

		-- Files dropped on a window go to the innermost box under where they landed that asked for
		-- them, and a window with no box for them hands the event to the app -- which is what a
		-- screen that takes a file anywhere on it does.
		if ctx then
			local hit = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0,
				hasDrop)

			if hit then
				return dropMessage(callbacks[hit.element.ondrop], event.paths or {}, event.x - hit.absX,
					event.y - hit.absY)
			end
		end
	elseif event.name == "keyPress" then
		local ctx = self.contexts[event.window]

		-- A press the keyboard says is one of its own repeats is not a key: what it repeats is the key
		-- the clock is already repeating, and taking it as well would be the two rates added together
		-- -- a hold that takes two characters at some moments and one at others. A keyboard repeating
		-- a key it is holding sends a release and then the press of that repeat together, so which
		-- presses are its own is not something that can be worked out from what arrives: it is what
		-- the keyboard is asked -- see the keyboard in winit, which marks the press of a repeat.
		if self.keyRepeatInterval > 0 and event.repeated == true and ctx ~= nil
			and ctx.repeatKey == event.key then
			return nil
		end

		-- What the key types is what it does to the field, and the key itself is what it types where it
		-- types nothing of its own: a named key is one of those, and is handled as itself.
		local typed = typedBy(event) or event.key
		local message = self:key(event.window, event.key, event.modifiers, typed)

		-- What is held, as the keyboard last said: a mouse event does not carry the modifiers, and
		-- a menu or a range of rows is what the modifiers were asked about.
		ctx.modifiers = event.modifiers

		-- What is held down from here: the key the ui is to repeat, at the rate it was given. A press
		-- of a key is a press of it whatever the clock was doing -- a key pressed again while the
		-- clock is repeating the same one is a key of its own, and the wait before it repeats starts
		-- here rather than going on with the hold before it.
		if ctx then
			ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil

			if repeats(event.key, event.modifiers, typed) and ctx.focusedName then
				-- What is repeated is the key, and what it does over again is what it typed: a held
				-- shift and 1 is "!" over and over rather than 1, and the name is what a release of
				-- the key is matched against.
				ctx.repeatKey, ctx.repeatMods = event.key, event.modifiers
				ctx.repeatTyped = typed
			end
		end

		return message
	elseif event.name == "keyRelease" then
		-- The key is up, so what was repeating stops with it: a key that is let go of does not repeat
		-- once more, and nothing else has to arrive to say so. A release the keyboard says is one of
		-- its own repeats is not a key coming up -- the key is still held -- so that one is what the
		-- hold goes on through: see the keyboard in winit, which is what tells them apart.
		local ctx = self.contexts[event.window]

		if ctx then
			ctx.modifiers = event.modifiers

			if ctx.repeatKey == event.key and event.repeated ~= true then
				ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil
			end
		end
	elseif event.name == "mouseRelease" then
		local ctx = self.contexts[event.window]
		setPointer(ctx, event.x, event.y, false)

		local button = event.button or 1

		if button ~= 1 then
			return nil
		end

		if ctx.barDrag ~= nil then
			ctx.barDrag = nil

			return nil
		end

		if ctx.selecting then
			ctx.selecting = nil

			-- The last place the pointer was is a move of its own: a selection dragged to where the
			-- pointer was let go of is the one a person made, and the release does not move it.
			ctx.caretClick = { x = event.x, y = event.y }

			return nil
		end

		local drag = ctx.dragging

		if drag then
			ctx.dragging = nil
			return report(drag, event.x, event.y)
		end

		local info = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hasMouseUp)

		if info then
			local relX = event.x - info.absX
			local relY = event.y - info.absY
			local released = callbacks[info.element.onmouseup]

			if released then
				return released(relX, relY, info.node.width, info.node.height, ctx.modifiers)
			end
		end
	end
end

return Layout
