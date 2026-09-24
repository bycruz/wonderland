-- Screens are built by calling: an element is made, given a style and children, and
-- handed back for the next call.
--
--   div():style(card):children(text("Hello"), text("World"))
--
-- An element is a struct in one array that is handed out again every repaint, so a
-- screen is built out of memory that is already there: what the layout reads is a number
-- at a known offset rather than a table lookup by name. The values that cannot live in a
-- struct -- the strings, the handlers, whatever the app carries -- are handed out as
-- numbers as well, into the arrays of this frame's values, so a repaint allocates
-- whatever the app itself allocates and nothing on top of it.
--
-- That is also what makes an element a thing of the frame it was made in: a tree is built
-- by the view function every repaint and used in that repaint, and one kept across
-- repaints would be reading what the next repaint put there. The calls say so rather than
-- reading memory that is no longer theirs.
local bit = require("bit")
local ffi = require("ffi")
local style = require("wonderland.style")

local element = {}

ffi.cdef [[
	typedef struct {
		uint32_t baseStyle, hoverStyle, activeStyle, focusStyle;  // what it looks like
		uint32_t text, name, inputValue;  // strings of this frame, by handle
		uint32_t run;                // the line it measured into, by handle
		uint32_t childFirst, childCount, nextSibling;  // the children, as a chain
		uint32_t onclick, onmousemove, onmousedown, onmouseup, ondblclick, oninput, onsubmit;
		uint32_t userdata;           // whatever the app carries, by handle
		double scrollOffset;         // how far its content is scrolled up, 0 for not
		uint32_t fontId;             // the font its text is measured in, from the top down
		uint32_t flags;              // hovered, pressed, focused, takes typing
		uint32_t index;              // which element this is, from one
		uint32_t frame;              // the frame it belongs to
	} wl_element;
]]

-- What state an element is in. A hover or press style is used in place of the base one,
-- so this is what the layout reads to pick which style it is.
element.HOVERED, element.PRESSED, element.FOCUSED, element.TEXT_INPUT = 1, 2, 4, 8
element.SCROLLS = 16

--- One element, as the arena holds it. The language server cannot see an ffi.cdef, so the
--- fields are spelled out here: it is the only way to get them checked. The ones that
--- hold a number are a handle -- `text`, `name`, `run`, the handlers -- and are read
--- through the arrays the frame keeps, not as strings or functions.
---@class wonderland.Element<T>: ffi.cdata*
---@field baseStyle number # The slot of the style it is laid out and drawn with
---@field hoverStyle number # And the one used while the pointer is over it, 0 for none
---@field activeStyle number # And the one used while it is held down
---@field focusStyle number
---@field text number # The line it draws, by handle, 0 for none
---@field name number # Its own name, for input focus and for finding it
---@field inputValue number # What has been typed into it, by handle
---@field run number # The line it measured into, by handle
---@field childFirst number
---@field childCount number
---@field nextSibling number
---@field onclick number
---@field onmousemove number
---@field onmousedown number
---@field onmouseup number
---@field ondblclick number
---@field oninput number
---@field onsubmit number
---@field userdata number # Whatever the app carries, by handle
---@field fontId number
---@field scrollOffset number # How far its content is scrolled up, and what clips it to its box
---@field flags number
---@field index number
---@field frame number
---@field style fun(self: wonderland.Element, value: wonderland.StyleBuilder | wonderland.Style): wonderland.Element
---@field hover fun(self: wonderland.Element, value: wonderland.StyleBuilder | wonderland.Style): wonderland.Element
---@field active fun(self: wonderland.Element, value: wonderland.StyleBuilder | wonderland.Style): wonderland.Element
---@field focus fun(self: wonderland.Element, value: wonderland.StyleBuilder | wonderland.Style): wonderland.Element
---@field children fun(self: wonderland.Element, ...: wonderland.IntoElement | wonderland.IntoElement[]): wonderland.Element
---@field named fun(self: wonderland.Element, name: string): wonderland.Element
---@field data fun(self: wonderland.Element, data: any): wonderland.Element
---@field input fun(self: wonderland.Element, opts: wonderland.InputOpts<any>): wonderland.Element
---@field scroll fun(self: wonderland.Element, offset: number): wonderland.Element
---@field onMouseMove fun(self: wonderland.Element, message: any): wonderland.Element
---@field onClick fun(self: wonderland.Element, message: any): wonderland.Element
---@field onMouseDown fun(self: wonderland.Element, cons: fun(x: number, y: number, elementWidth: number, elementHeight: number): any): wonderland.Element
---@field onMouseUp fun(self: wonderland.Element, message: any): wonderland.Element
---@field onDoubleClick fun(self: wonderland.Element, message: any): wonderland.Element
local Element = {}
element.Element = Element

---@alias wonderland.IntoElement wonderland.Element | string

-- The calls live in their own table rather than on the element: a table is what an ffi
-- metatype is given for `__index`, and a field of a struct is read before it is asked
-- for, which is what keeps `element.index` a number and not a call that answers for it.
local methods = {}
methods.__index = methods

-- ────────────────────────────────────────────────────────────────
-- the arena
-- ────────────────────────────────────────────────────────────────

-- Elements are handed out of blocks that are never moved: growing the arena adds a block
-- rather than copying the one before it, because an element is a pointer the moment it is
-- returned and a pointer into memory that has moved is a bug that reads as garbage
-- later. A block is a few tens of kilobytes, one is enough for a screen of a few hundred
-- elements, and a screen that needs more is one more.
local BLOCK = 512 -- a power of two: the index picks its block with shifts
local SHIFT, MASK = 9, BLOCK - 1

-- Asserted because `ffi.sizeof` is a number the language server calls possibly-nothing.
local SIZE = assert(ffi.sizeof("wl_element"))

local blocks = {}
local pointers = {} -- the elements of this frame, by index, which is what a node holds
local count = 0
local frame = 1

-- The values of this frame that are not numbers: a string a line draws, a handler a click
-- sends, whatever an element carries. They are held by index and the index spaces are
-- shared, so an element's `text` and its `name` are two handles into the same array.
local strings, stringCount = {}, 0
local callbacks, callbackCount = {}, 0
local runs, runCount = {}, 0
local data, dataCount = {}, 0

---@param index number
---@return wonderland.Element
function element.at(index)
	return pointers[index]
end

---@param value string
---@return number
local function pushString(value)
	stringCount = stringCount + 1
	strings[stringCount] = value

	return stringCount
end

---@param value any
---@return number # 0 for nothing, which is what a handler that was never set is
local function pushCallback(value)
	if value == nil then
		return 0
	end

	callbackCount = callbackCount + 1
	callbacks[callbackCount] = value

	return callbackCount
end

--- One element, zeroed, which is what makes a slot handed out again look new: the array
--- is reused, so nothing here is zero because it is new.
---@return wonderland.Element
local function make()
	count = count + 1

	local block = bit.rshift(count - 1, SHIFT) + 1

	if blocks[block] == nil then
		blocks[block] = ffi.new("wl_element[?]", BLOCK)
	end

	local made = blocks[block][bit.band(count - 1, MASK)]

	ffi.fill(made, SIZE)
	made.index = count
	made.frame = frame

	pointers[count] = made

	return made
end

--- An element lives for the frame it was made in. This is the check that says so: what it
--- would otherwise read is the element the next frame has already put in its slot.
---@param self wonderland.Element
local function check(self)
	assert(self.frame == frame,
		"This element was made in an earlier frame: an element is built by the view function and used in the repaint it was built for")
end

--- Every repaint builds its tree again, so the frame starts empty: the elements are
--- handed out from the first block again and the values of the last frame are let go.
function element.beginFrame()
	frame = frame + 1
	count = 0

	for index = 1, stringCount do
		strings[index] = nil
	end

	for index = 1, callbackCount do
		callbacks[index] = nil
	end

	for index = 1, runCount do
		runs[index] = nil
	end

	for index = 1, dataCount do
		data[index] = nil
	end

	stringCount, callbackCount, runCount, dataCount = 0, 0, 0, 0
end

--- How many elements the frame has made, for a test that wants to know what a screen
--- costs.
---@return number
function element.count()
	return count
end

-- ────────────────────────────────────────────────────────────────
-- making one
-- ────────────────────────────────────────────────────────────────

--- There is one kind of element. A line of text is an element with a string on it and no
--- children, so nothing in the engine has to know what sort of element it is looking at.
---@return wonderland.Element
function Element.new()
	return make()
end

--- A box. It draws nothing until a style gives it something to draw, or a string gives
--- it a line to draw.
---@return wonderland.Element
function element.div()
	return make()
end

--- A line of text, sized by the font it is drawn in. It is an element like any other, so
--- a string handed to `children` becomes one of these.
---@param value string
---@return wonderland.Element
function element.text(value)
	local line = make()
	line.text = pushString(value)

	return line
end

---@param value wonderland.IntoElement
---@return wonderland.Element
local function intoElement(value)
	local kind = type(value)

	if kind == "string" then
		return element.text(value)
	end

	-- A type test rather than a message built for every child: this runs for every child
	-- of every element of every repaint, and a message that is only needed when the call
	-- fails is a message that is not built when it does not. What it is is checked by
	-- reading it: `wl_element` has the fields and nothing else does.
	if kind ~= "cdata" or not ffi.istype("wl_element", value) then
		error("Cannot convert value to Element: " .. tostring(value), 2)
	end

	---@cast value wonderland.Element

	-- Checked here rather than where it is read, because this is where an element of an
	-- older frame arrives: it would otherwise be linked into the tree and read as whatever
	-- the frame that owns the slot has put there.
	check(value)

	return value
end

---@param value wonderland.IntoElement
---@return wonderland.Element
function element.from(value)
	return intoElement(value)
end

---@param self wonderland.Element
---@return wonderland.Element? # The child it should follow, if it has one
local function lastChild(self)
	local index = self.childFirst
	if index == 0 then
		return nil
	end

	local child = pointers[index]
	while child.nextSibling ~= 0 do
		child = pointers[child.nextSibling]
	end

	return child
end

---@param parent wonderland.Element
---@param after wonderland.Element?
---@param child wonderland.Element
---@return wonderland.Element # The child, so the next one knows what to follow
local function link(parent, after, child)
	if after then
		after.nextSibling = child.index
	else
		parent.childFirst = child.index
	end

	parent.childCount = parent.childCount + 1

	return child
end

-- ────────────────────────────────────────────────────────────────
-- the calls
-- ────────────────────────────────────────────────────────────────

--- What it looks like and how it lays out. One style can be shared by every element
--- that should look the same, and the same style written twice is interned once.
---@param value wonderland.StyleBuilder | wonderland.Style
---@return wonderland.Element
function methods:style(value)
	check(self)
	self.baseStyle = style.intern(value)

	return self
end

--- Used instead of the base style while the pointer is over the element. Changing how
--- the element looks costs a repaint but no upload, since the frame is compared before
--- the gpu is given it. Text is measured before this is known, so a hover style that
--- names a font does not re-measure the line.
---@param value wonderland.StyleBuilder | wonderland.Style
---@return wonderland.Element
function methods:hover(value)
	check(self)
	self.hoverStyle = style.intern(value)

	return self
end

--- Used instead of the base style while the pointer is held down on the element.
---@param value wonderland.StyleBuilder | wonderland.Style
---@return wonderland.Element
function methods:active(value)
	check(self)
	self.activeStyle = style.intern(value)

	return self
end

---@param value wonderland.StyleBuilder | wonderland.Style
---@return wonderland.Element
function methods:focus(value)
	check(self)
	self.focusStyle = style.intern(value)

	return self
end

--- Adds children, in the order they are given. A string becomes a text element, and a
--- table of elements is taken apart, so a list built in a loop can be passed as one.
---@param ... wonderland.IntoElement | wonderland.IntoElement[]
---@return wonderland.Element
function methods:children(...)
	check(self)

	local after = lastChild(self)

	for index = 1, select("#", ...) do
		local value = select(index, ...)

		if type(value) == "table" then
			for _, nested in ipairs(value) do
				after = link(self, after, intoElement(nested))
			end
		else
			after = link(self, after, intoElement(value))
		end
	end

	return self
end

---@param name string
---@return wonderland.Element
function methods:named(name)
	check(self)
	self.name = pushString(name)

	return self
end

--- Anything the element wants to carry: the message a click sends, a row's own data.
---@param value any
---@return wonderland.Element
function methods:data(value)
	check(self)
	dataCount = dataCount + 1
	data[dataCount] = value
	self.userdata = dataCount

	return self
end

---@generic T
---@param message T
---@return wonderland.Element
function methods:onMouseMove(message)
	check(self)
	self.onmousemove = pushCallback(message)

	return self
end

---@generic T
---@param message T
---@return wonderland.Element
function methods:onClick(message)
	check(self)
	self.onclick = pushCallback(message)

	return self
end

---@generic T
---@param cons fun(x: number, y: number, elementWidth: number, elementHeight: number): T
---@return wonderland.Element
function methods:onMouseDown(cons)
	check(self)
	self.onmousedown = pushCallback(cons)

	return self
end

---@generic T
---@param message T
---@return wonderland.Element
function methods:onMouseUp(message)
	check(self)
	self.onmouseup = pushCallback(message)

	return self
end

---@generic T
---@param message T
---@return wonderland.Element
function methods:onDoubleClick(message)
	check(self)
	self.ondblclick = pushCallback(message)

	return self
end

--- How far a box's content is scrolled up. It is what an app keeps, because it is state: the
--- library clips the box to itself, moves the content by this much, and answers a click by what
--- it lands on, and how far is up to the app -- which is what the wheel does, and where a scroll
--- bar is drawn from. A box that scrolls and does not clip would draw its content over whatever
--- is under it, so the two are one call.
---@param offset number
---@return wonderland.Element
function methods:scroll(offset)
	check(self)
	self.flags = bit.bor(self.flags, element.SCROLLS)
	self.scrollOffset = offset or 0

	return self
end

---@class wonderland.InputOpts<T>
---@field name string
---@field value string
---@field oninput fun(value: string): T
---@field onsubmit fun(value: string): T

--- Takes the keyboard, and sends what is typed. It is called `input` rather than `textInput`
--- because a field of an element is read before a call is asked for, and it is the call an app
--- makes.
---@generic T
---@param opts wonderland.InputOpts<T>
---@return wonderland.Element
function methods:input(opts)
	check(self)
	self.flags = bit.bor(self.flags, element.TEXT_INPUT)
	self.name = pushString(opts.name)
	self.inputValue = pushString(opts.value or "")
	self.oninput = pushCallback(opts.oninput)
	self.onsubmit = pushCallback(opts.onsubmit)

	return self
end

-- A style is built the same way, so sty() is reached through here rather than making
-- every caller require two modules.
element.sty = style.new

-- ────────────────────────────────────────────────────────────────
-- what the frame's values are, by handle
-- ────────────────────────────────────────────────────────────────

-- The arrays themselves, so a pass over a screen reads a handle where it wants the value
-- and pays no call for it. They are the same tables every frame: what changes is how far
-- into them the frame has written.
element.strings, element.callbacks, element.runs, element.data, element.pointers = strings, callbacks, runs, data,
	pointers

--- A measured line, kept for this frame, and the handle an element holds of it. A run is
--- interned by the font that measured it, so measuring the same line again is a lookup.
---@param run wonderland.font.Run
---@return number
function element.pushRun(run)
	runCount = runCount + 1
	runs[runCount] = run

	return runCount
end

--- Says what an element draws, for a tree measured by hand rather than by the text
--- plugin: a test laying a line out without a font.
---@param self wonderland.Element
---@param run wonderland.font.Run
function element.setRun(self, run)
	check(self)
	self.run = element.pushRun(run)
end

--- The measured line an element draws, if it draws one.
---@param self wonderland.Element
---@return wonderland.font.Run?
function element.runOf(self)
	return self.run ~= 0 and runs[self.run] or nil
end

--- What the pointer is doing to an element, which is what the layout picks a style by.
---@param self wonderland.Element
---@param on boolean
function element.hovering(self, on)
	self.flags = on and bit.bor(self.flags, element.HOVERED)
		or bit.band(self.flags, bit.bnot(element.HOVERED))
end

---@param self wonderland.Element
---@param on boolean
function element.pressing(self, on)
	self.flags = on and bit.bor(self.flags, element.PRESSED)
		or bit.band(self.flags, bit.bnot(element.PRESSED))
end

--- The line an element draws, if it draws one.
---@param self wonderland.Element
---@return string?
function element.textOf(self)
	return self.text ~= 0 and strings[self.text] or nil
end

--- The element's own name, if it has one.
---@param self wonderland.Element
---@return string?
function element.nameOf(self)
	return self.name ~= 0 and strings[self.name] or nil
end

--- What has been typed into an element that takes typing.
---@param self wonderland.Element
---@return string
function element.inputOf(self)
	return self.inputValue ~= 0 and strings[self.inputValue] or ""
end

--- Whatever the app carries on an element.
---@param self wonderland.Element
---@return any
function element.dataOf(self)
	return self.userdata ~= 0 and data[self.userdata] or nil
end

-- Which is what makes an element answer its own calls while a field of it is still read
-- as the number it holds.
ffi.metatype("wl_element", methods)

return element
