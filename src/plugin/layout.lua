local bit = require("bit")
local UILayout = require("wonderland.layout")
local wonderlandElement = require("wonderland.element")

-- The elements of this frame, by the index a node holds, and the values an element can
-- only name: a handler, the string it draws. Both are the same arrays every repaint.
local pointers = wonderlandElement.pointers
local callbacks = wonderlandElement.callbacks
local TEXT_INPUT = wonderlandElement.TEXT_INPUT
local MULTILINE = wonderlandElement.MULTILINE
local SLIDE = wonderlandElement.SLIDE

--- Where a node ended up, and which element it is.
---@class wonderland.plugin.Layout.Hit
---@field element wonderland.Element
---@field node wonderland.Node
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

--- Where the pointer is and whether its button is held, which is what an element's hover and
--- active styles are picked from.
---@class wonderland.plugin.Layout.Pointer
---@field x number
---@field y number
---@field pressed boolean

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
---@field dragging wonderland.plugin.Layout.Drag? # The slider being dragged, while one is
---@field pointer wonderland.plugin.Layout.Pointer? # Where the pointer is, and whether it is held
---@field pointing boolean? # Whether the pointer cursor is the one for something clickable
---@field cursorPos number
---@field typed string? # What has been typed into the focused field since the frame that built it
---@field lastPressX any
---@field lastPressY any

---@class wonderland.plugin.Layout<Message>: wonderland.Plugin
---@field textPlugin wonderland.plugin.Text
---@field view fun(window: wonderland.RenderWindow): wonderland.Element<Message>
---@field contexts table<wonderland.RenderWindow, wonderland.plugin.Layout.Context>
local Layout = {}
Layout.__index = Layout

---@param view fun(window: wonderland.RenderWindow): wonderland.Element
---@param textPlugin wonderland.plugin.Text
function Layout.new(view, textPlugin) ---@return wonderland.plugin.Layout
	return setmetatable({ view = view, contexts = {}, textPlugin = textPlugin }, Layout)
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
		screen:solve(ctx.window.width, ctx.window.height, true)

		if screen:markPointer(pointer.x, pointer.y, pointer.pressed) then
			ctx.root = screen:fromElement(ctx.ui)
		end
	end

	screen:solve(ctx.window.width, ctx.window.height)

	return ctx.root
end

local function hasMouseUp(e) ---@param e wonderland.Element
	return e.onmouseup ~= 0
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


--- The caret of the field that has the keyboard: which element it is for, the line of it the
--- caret is on and how far along that line -- the two numbers a caret is drawn by, since the byte
--- it is at only says something to whoever has the value. Nothing is returned where no field has
--- the keyboard, which is a caret there is none of.
---@param window wonderland.RenderWindow
---@return wonderland.Element? element
---@return number? line # From nought, so a field of one line is always on line nought
---@return number? column # How many characters of that line come before the caret
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
	local line = 0

	for _ in value:sub(1, start - 1):gmatch("\n") do
		line = line + 1
	end

	return element, line, ctx.cursorPos - (start - 1)
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
		end
	elseif event.name == "mouseMove" then
		local ctx = self.contexts[event.window]
		if not ctx then return end

		setPointer(ctx, event.x, event.y)

		if ctx.dragging then
			return report(ctx.dragging, event.x, event.y)
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
				return handler(relX, relY, layout.node.width, layout.node.height)
			end
		end
	elseif event.name == "mousePress" then
		local ctx = self.contexts[event.window]
		setPointer(ctx, event.x, event.y, true)

		local info = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hasMouseDownOrClick)

		-- Update focus: set on text input click, clear otherwise
		if info and bit.band(info.element.flags, TEXT_INPUT) ~= 0 then
			ctx.focusedName = wonderlandElement.nameOf(info.element)
			ctx.cursorPos = #wonderlandElement.inputOf(info.element)
			ctx.typed = nil
		else
			ctx.focusedName = nil
			ctx.cursorPos = 0
		end

		if info then
			local now = os.clock()
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
				return pressed(relX, relY, info.node.width, info.node.height)
			end
		end
	elseif event.name == "keyPress" then
		local ctx = self.contexts[event.window]
		if ctx and ctx.focusedName then
			local element = findElementById(ctx.ui, ctx.focusedName)
			if element and bit.band(element.flags, TEXT_INPUT) ~= 0 then
				-- What is typed into is the value as it is now, which is not necessarily the one the
				-- last frame drew: a key is handled as it arrives, and a key held down arrives several
				-- times between two frames. Every key applied to the field the frame drew would apply
				-- it to the same value over and over -- a backspace held down taking the same
				-- character each time while the caret walks back, which is a caret that leaves the
				-- text behind rather than deleting it.
				local value = ctx.typed or wonderlandElement.inputOf(element)
				local cursor = ctx.cursorPos
				local key = event.key

				--- The value an edit left the field with, kept for the keys before the next frame and
				--- reported to the app.
				---@param edited string
				---@return any?
				local function edit(edited)
					ctx.typed = edited

					local handler = callbacks[element.oninput]

					return handler and handler(edited) or { type = "_inputRefresh" }
				end

				if key == "escape" then
					ctx.focusedName = nil
					ctx.cursorPos = 0
					return { type = "_inputRefresh" }
				elseif key == "return" then
					local submit = callbacks[element.onsubmit]

					-- A paragraph takes the break, and control with return is what sends it: a
					-- field that is one line has nothing to break, so return sends it.
					if bit.band(element.flags, MULTILINE) ~= 0
						and not (event.modifiers and event.modifiers.ctrl) then
						value = value:sub(1, cursor) .. "\n" .. value:sub(cursor + 1)
						ctx.cursorPos = cursor + 1
						return edit(value)
					elseif submit then
						return submit(value)
					end
				elseif key == "backspace" then
					if cursor > 0 then
						value = value:sub(1, cursor - 1) .. value:sub(cursor + 1)
						ctx.cursorPos = cursor - 1
						return edit(value)
					end
				elseif key == "delete" then
					if cursor < #value then
						value = value:sub(1, cursor) .. value:sub(cursor + 2)
						return edit(value)
					end
				elseif key == "left" then
					ctx.cursorPos = math.max(0, cursor - 1)
					return { type = "_inputRefresh" }
				elseif key == "right" then
					ctx.cursorPos = math.min(#value, cursor + 1)
					return { type = "_inputRefresh" }
				elseif key == "home" then
					ctx.cursorPos = lineStart(value, cursor) - 1
					return { type = "_inputRefresh" }
				elseif key == "end" then
					ctx.cursorPos = lineEnd(value, cursor)
					return { type = "_inputRefresh" }
				elseif key == "up" then
					ctx.cursorPos = lineAcross(value, cursor, -1)
					return { type = "_inputRefresh" }
				elseif key == "down" then
					ctx.cursorPos = lineAcross(value, cursor, 1)
					return { type = "_inputRefresh" }
				elseif event.modifiers and event.modifiers.ctrl then
					if key == "a" or key:byte(1) == 1 then
						ctx.cursorPos = #value
						return { type = "_inputRefresh" }
					end
				elseif key == "space" then
					value = value:sub(1, cursor) .. " " .. value:sub(cursor + 1)
					ctx.cursorPos = cursor + 1
					return edit(value)
				elseif #key == 1 and key:byte(1) >= 32 then
					value = value:sub(1, cursor) .. key .. value:sub(cursor + 1)
					ctx.cursorPos = cursor + 1
					return edit(value)
				end
			end
		end
	elseif event.name == "mouseRelease" then
		local ctx = self.contexts[event.window]
		setPointer(ctx, event.x, event.y, false)

		local drag = ctx.dragging

		if drag then
			ctx.dragging = nil
			return report(drag, event.x, event.y)
		end

		local info = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hasMouseUp)

		if info then
			local relX = event.x - info.absX
			local relY = event.y - info.absY
			return callbacks[info.element.onmouseup](relX, relY, info.node.width, info.node.height)
		end
	end
end

return Layout
