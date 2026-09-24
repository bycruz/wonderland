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
---@field dragging wonderland.plugin.Layout.Drag? # The slider being dragged, while one is
---@field pointer wonderland.plugin.Layout.Pointer? # Where the pointer is, and whether it is held
---@field pointing boolean? # Whether the pointer cursor is the one for something clickable
---@field cursorPos number
---@field typed string? # What has been typed into the focused field since the frame that built it
---@field caretClick wonderland.plugin.Layout.Point? # Where a field was clicked, until the ui has placed the caret from it
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
---@field textPlugin wonderland.plugin.Text
---@field view fun(window: wonderland.RenderWindow): wonderland.Element<Message>
---@field contexts table<wonderland.RenderWindow, wonderland.plugin.Layout.Context>
---@field keyRepeatDelay number # The wait before a held key repeats, in seconds
---@field keyRepeatInterval number # And the time between the repeats after it, nought for none of them
local Layout = {}
Layout.__index = Layout

---@param view fun(window: wonderland.RenderWindow): wonderland.Element
---@param textPlugin wonderland.plugin.Text
function Layout.new(view, textPlugin) ---@return wonderland.plugin.Layout
	return setmetatable({
		view = view,
		contexts = {},
		textPlugin = textPlugin,
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

--- What a key types, where it types something a field takes: the text the keyboard made of the key,
--- which is not the key -- shift and 1 is the key 1 pressed and "!" typed -- or nothing, which is
--- every key that types nothing of its own and every key whose name is what it does. A character
--- that is not printable is not typed either: what a key makes of control belongs to whoever reads
--- the chord, and the chord is read here.
---@param event winit.Event
---@return string?
local function typedBy(event)
	local text = event.text

	if text ~= nil and #text == 1 and text:byte(1) >= 32 then
		return text
	end

	return nil
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
	local line = lineCount(value:sub(1, start - 1)) - 1

	return element, line, ctx.cursorPos - (start - 1)
end

--- The caret put where a line and a column of the value are, which is what a click in a field comes
--- to: the ui is what walks the text a field draws, so it is the ui that says which line and which
--- character of it a point is at, and the byte the caret is at is what that comes to. A column past
--- the end of its line is the end of that line, and a line the value does not have is nowhere: the
--- caret stays where it was rather than being put at a byte that is not there.
---@param window wonderland.RenderWindow
---@param line number
---@param column number
function Layout:setCaret(window, line, column)
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
	local start = 1

	for _ = 1, line do
		local break_ = value:find("\n", start, true)

		if not break_ then
			return
		end

		start = break_ + 1
	end

	ctx.cursorPos = math.min(start - 1 + column, lineEnd(value, start - 1))
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

	if not ctx or not ctx.focusedName then
		return nil
	end

	local element = findElementById(ctx.ui, ctx.focusedName)

	if element == nil or bit.band(element.flags, TEXT_INPUT) == 0 then
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

	if key == "escape" then
		ctx.focusedName = nil
		ctx.cursorPos = 0
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
	elseif modifiers and modifiers.ctrl then
		if key == "a" or key:byte(1) == 1 then
			ctx.cursorPos = #value
			return { type = "_inputRefresh" }
		end
	elseif key == "space" then
		value = value:sub(1, cursor) .. " " .. value:sub(cursor + 1)
		ctx.cursorPos = cursor + 1
		return edit(value)
	elseif #typed == 1 and typed:byte(1) >= 32 then
		-- A single character is typed, and what it is is what the key types rather than what the key
		-- is: shift and 1 is named 1 and types "!". A key that types nothing of its own is handed its
		-- own name as that, which is a key of one character or a key of none -- and a key of none is
		-- one with something else to do, which the branches above have already done.
		value = value:sub(1, cursor) .. typed .. value:sub(cursor + 1)
		ctx.cursorPos = cursor + #typed
		return edit(value)
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
			-- Where in what it holds the pointer is, which is not something the layout can work
			-- out: the text a field draws is the app's, and which line and which character of it a
			-- point is at comes from the run the ui walks. Until the ui has placed the caret from
			-- it, the caret is at the end of the value -- which is what a field that draws none
			-- gets, and what every click in one did before the ui knew about it.
			ctx.caretClick = { x = event.x, y = event.y }
			ctx.cursorPos = #wonderlandElement.inputOf(info.element)
			ctx.typed = nil
		else
			ctx.focusedName = nil
			ctx.cursorPos = 0
			ctx.caretClick = nil
		end

		-- A press is the hand leaving the keyboard: what was repeating stops, whether or not it
		-- was the field that was pressed.
		ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil

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

		if ctx and ctx.repeatKey == event.key and event.repeated ~= true then
			ctx.repeatKey, ctx.repeatMods, ctx.repeatAt, ctx.repeatTyped = nil, nil, nil, nil
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
