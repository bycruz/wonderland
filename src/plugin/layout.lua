local bit = require("bit")
local UILayout = require("wonderland.layout")
local wonderlandElement = require("wonderland.element")

-- The elements of this frame, by the index a node holds, and the values an element can
-- only name: a handler, the string it draws. Both are the same arrays every repaint.
local pointers = wonderlandElement.pointers
local callbacks = wonderlandElement.callbacks
local TEXT_INPUT = wonderlandElement.TEXT_INPUT

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
---@field focusedName string?
---@field pointer wonderland.plugin.Layout.Pointer? # Where the pointer is, and whether it is held
---@field pointing boolean? # Whether the pointer cursor is the one for something clickable
---@field cursorPos number
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
	return bit.band(e.flags, TEXT_INPUT) ~= 0
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

		---@type table<wonderland.Element, wonderland.plugin.Layout.Hit>
		local hoveredElements = {}
		findElementsAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hoveredElements)

		local anyWithMouseDown = false
		for el, _ in pairs(hoveredElements) do
			if bit.band(el.flags, TEXT_INPUT) ~= 0 or el.onmousedown ~= 0 or el.onclick ~= 0 then
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
				local value = wonderlandElement.inputOf(element)
				local cursor = ctx.cursorPos
				local key = event.key

				if key == "escape" then
					ctx.focusedName = nil
					ctx.cursorPos = 0
					return { type = "_inputRefresh" }
				elseif key == "return" then
					local submit = callbacks[element.onsubmit]

					if submit then
						return submit(value)
					end
				elseif key == "backspace" then
					if cursor > 0 then
						value = value:sub(1, cursor - 1) .. value:sub(cursor + 1)
						ctx.cursorPos = cursor - 1
						local typed = callbacks[element.oninput]
						if typed then return typed(value) end
					end
				elseif key == "delete" then
					if cursor < #value then
						value = value:sub(1, cursor) .. value:sub(cursor + 2)
						local typed = callbacks[element.oninput]
						if typed then return typed(value) end
					end
				elseif key == "left" then
					ctx.cursorPos = math.max(0, cursor - 1)
					return { type = "_inputRefresh" }
				elseif key == "right" then
					ctx.cursorPos = math.min(#value, cursor + 1)
					return { type = "_inputRefresh" }
				elseif key == "home" then
					ctx.cursorPos = 0
					return { type = "_inputRefresh" }
				elseif key == "end" then
					ctx.cursorPos = #value
					return { type = "_inputRefresh" }
				elseif event.modifiers and event.modifiers.ctrl then
					if key == "a" or key:byte(1) == 1 then
						ctx.cursorPos = #value
						return { type = "_inputRefresh" }
					end
				elseif key == "space" then
					value = value:sub(1, cursor) .. " " .. value:sub(cursor + 1)
					ctx.cursorPos = cursor + 1
					local typed = callbacks[element.oninput]
					if typed then return typed(value) end
				elseif #key == 1 and key:byte(1) >= 32 then
					value = value:sub(1, cursor) .. key .. value:sub(cursor + 1)
					ctx.cursorPos = cursor + 1
					local typed = callbacks[element.oninput]
					if typed then return typed(value) end
				end
			end
		end
	elseif event.name == "mouseRelease" then
		local ctx = self.contexts[event.window]
		setPointer(ctx, event.x, event.y, false)

		local info = findElementAtPosition(assert(ctx.screen), assert(ctx.root), event.x, event.y, 0, 0, hasMouseUp)

		if info then
			local relX = event.x - info.absX
			local relY = event.y - info.absY
			return callbacks[info.element.onmouseup](relX, relY, info.node.width, info.node.height)
		end
	end
end

return Layout
