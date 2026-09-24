-- Solving a screen's geometry.
--
-- Every repaint lays the screen out again, so the nodes it is laid out into live in one
-- array that is filled in place rather than a table per node per repaint. The array is
-- grown to the largest screen seen and then reused, which is what makes a repaint cost
-- its arithmetic and nothing else.
--
-- Two arrays, in step:
--
--   nodes         one struct per element, in the order the elements were walked
--   childIndices  each node's children, one contiguous run per node
--
-- The second exists because a tree written into one array cannot have its children next
-- to it: a child's own subtree sits between it and its next sibling.
local bit = require("bit")
local ffi = require("ffi")
local style = require("wonderland.style")
local wonderlandElement = require("wonderland.element")

-- The element arena and the style arena are what the solver reads, so their arrays are
-- taken once: what the frame has written into them changes, which of them it is does not.
local pointers = wonderlandElement.pointers
local runs = wonderlandElement.runs
local HOVERED, PRESSED = wonderlandElement.HOVERED, wonderlandElement.PRESSED
local ABS, REL, AUTO = style.ABS, style.REL, style.AUTO
local PRESENT = style.PRESENT
local SCROLLS = wonderlandElement.SCROLLS
local WIDTH, HEIGHT = PRESENT.width, PRESENT.height

-- Which style array the nodes are read out of. It is replaced when the arena grows, and
-- the arena only grows while a screen is being *built* from a tree -- never while the
-- nodes are made from one -- so it is taken again at the start of each frame.
local styleArena = style.arena

ffi.cdef [[
	// Under ffi.C because LuaJIT only knows the symbols it has been told about: this is
	// how a whole frame is compared at once.
	int memcmp(const void *a, const void *b, size_t n);

	typedef struct {
		// The style this node was made with, in the same order and the same types as `wl_style`,
		// so that the whole of it is one ffi.copy: see the check below, which refuses to load if
		// the two ever disagree. Every field of a node being written one at a time is what made
		// the build long, and a build the recorder gives up on runs in the interpreter.
		//
		// A share of the space is a fraction, and a fraction in a float32 is not the fraction:
		// 0.7 becomes 0.69999999, which is 1.4e-5 of a 1200 pixel screen and enough to round a
		// position the wrong way. So the numbers the solver works in are doubles.
		double wantWidth, wantHeight;
		double bgR, bgG, bgB, bgA;     // what it is painted with, if anything
		double borderR, borderG, borderB, borderA;
		double u0, v0, u1, v1;         // and the part of its texture to use
		int32_t gap, zIndex;
		int32_t paddingTop, paddingRight, paddingBottom, paddingLeft;
		int32_t marginTop, marginRight, marginBottom, marginLeft;
		int32_t top, left, right, bottom;
		int32_t borderTop, borderRight, borderBottom, borderLeft;
		uint32_t fgR, fgG, fgB, fgA;   // text colour as bytes, 0 for nothing
		uint32_t texture, font;        // the texture it paints, and the font it is drawn in
		double bright;                 // a multiplier on the colours, 1.0 for not one
		double radius;                 // how round its corners are, in pixels, 0 for square
		int32_t shadowX, shadowY;      // where its shadow sits, how far it fades out, and
		int32_t shadowBlur;
		uint8_t shadowR, shadowG, shadowB, shadowA;  // what colour it is, 0 alpha for none
		uint32_t styleFlags;           // and which of that style's fields were set
		uint8_t widthUnit, heightUnit, direction, align, justify, position, visible, paint;

		// -- nothing above this line is the node's own: it is the style it was built from.

		uint32_t style;                // the slot it was styled with
		uint32_t scrolls;              // whether it clips its content to its own box
		double scroll;                 // and how far its content is moved up
		uint32_t run;                  // which run of the screen's runs to draw
		uint32_t runId;                // and which measured line that was
		uint32_t element;              // the element this came from, 1 based, 0 for none

		// how it came out
		double x, y;
		double width, height;
		uint32_t firstChild, childCount;
	} wl_node;
]]

-- The build is one long function by nature: every field of every node is written from the style
-- it was made with, and that is what makes a repaint a copy of a struct rather than a walk of a
-- tree of tables. It is long enough that the recorder gives up on it -- "trace too long" -- and a
-- loop it gives up on is a loop that runs in the interpreter, which measured ten times slower
-- than the same work compiled. So it is allowed to record more before it gives up, and this is
-- the only thing in the library that asks for that. The proper fix is a shorter function -- the
-- style of a node copied into it with one ffi.copy rather than a write per field -- and until
-- then this is the number that keeps the loop compiled.
jit.opt.start("maxrecord=12000")

-- What a scroll bar is told: how far there is to scroll, and how it is drawn. It lives beside the
-- nodes rather than in them because only a box that scrolls has one, and every field of a node is
-- written for every node of every frame -- which is what makes the build one long function, and a
-- function the recorder gives up on is a build that runs in the interpreter, ten times slower.
ffi.cdef [[
	typedef struct {
		double max;                    // how far the content goes past what the box shows
		int32_t width, least;          // the strip it takes, and the least a thumb of it is
		double r, g, b, a;
	} wl_bar;
]]

-- The two structs have to agree, field for field and type for type, for as many bytes as a node
-- copies: a field added to one and not the other would have every node reading a style's worth of
-- memory that does not line up, which shows up as a screen that draws nonsense. Checked once, at
-- load, so it is the library that refuses rather than a frame that comes out wrong.
for _, field in ipairs({ "wantWidth", "wantHeight", "bgR", "borderR", "u0", "gap", "zIndex", "paddingTop",
	"marginTop", "top", "left", "borderTop", "fgR", "texture", "font", "bright", "radius", "shadowX",
	"shadowBlur", "shadowA", "widthUnit", "paint" }) do
	assert(ffi.offsetof("wl_node", field) == ffi.offsetof("wl_style", field),
		"wl_node and wl_style disagree about " .. field .. ": the build copies one into the other")
end

assert(ffi.offsetof("wl_node", "styleFlags") == ffi.offsetof("wl_style", "flags"),
	"wl_node and wl_style disagree about their flags")

--- How many bytes of a style a node takes: all of it but the scroll bar's, which a box that
--- scrolls keeps beside its nodes.
local STYLE_COPY = ffi.offsetof("wl_style", "barWidth")

local nodeArray = ffi.typeof("wl_node[?]")
local barArray = ffi.typeof("wl_bar[?]")
local NODE_SIZE = assert(ffi.sizeof("wl_node"))

--- A position is put on a whole pixel. Glyph quads are exactly as wide as their ink, so
--- one that starts halfway across a pixel loses its last column, and a background edge
--- that lands between pixels is uneven. Sizes are left alone: they are shares of the
--- space, and rounding them would take the rounding error out of the layout.
---@param value number
---@return number
local function snap(value)
	return math.floor(value + 0.5)
end

local layout = {}

--- One node of a laid out screen, as the struct it is. The language server cannot see
--- an ffi.cdef, so the fields are spelled out here: it is the only way to get them checked.
---@class wonderland.Node: ffi.cdata*
---@field wantWidth number
---@field wantHeight number
---@field widthUnit number
---@field heightUnit number
---@field gap number
---@field paddingTop number
---@field paddingRight number
---@field paddingBottom number
---@field paddingLeft number
---@field marginTop number
---@field marginRight number
---@field marginBottom number
---@field marginLeft number
---@field top number
---@field left number
---@field right number
---@field bottom number
---@field zIndex number
---@field borderTop number
---@field borderRight number
---@field borderBottom number
---@field borderLeft number
---@field bgR number
---@field bgG number
---@field bgB number
---@field bgA number
---@field borderR number
---@field borderG number
---@field borderB number
---@field borderA number
---@field texture number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field style number
---@field styleFlags number
---@field bright number
---@field radius number
---@field shadowX number
---@field shadowY number
---@field shadowBlur number
---@field shadowR number
---@field shadowG number
---@field shadowB number
---@field shadowA number
---@field scrolls number
---@field scroll number
---@field fgR number
---@field fgG number
---@field fgB number
---@field fgA number
---@field font number
---@field run number
---@field runId number
---@field element number
---@field x number
---@field y number
---@field width number # Solved
---@field height number # Solved
---@field firstChild number
---@field childCount number
---@field direction number
---@field align number
---@field justify number
---@field position number
---@field visible number
---@field paint number

--- What a screen is laid out against. A real window has more than this and a headless
--- screen has less; both are laid out by their size, the redraw flag is how the ui asks for
--- another frame, and the cursor is there to be pointed with when there is one.
---@alias wonderland.RenderWindow { width: number, height: number, shouldRedraw: boolean?, setCursor: (fun(self: any, shape: string))?, resetCursor: (fun(self: any))? }

---@class wonderland.layout
---@field new fun(capacity: number?): wonderland.Layout.Screen
---@field screen fun(element: wonderland.Element, width: number, height: number): wonderland.Layout.Screen

---@class wonderland.Layout.Screen
---@field nodes wonderland.Node[] # The node array itself
---@field childIndices ffi.cdata* # uint32_t, one run per node
---@field bars ffi.cdata* # `wl_bar` per node, for the ones that scroll
---@field count number # Nodes in use
---@field childCount number # Child indices in use
---@field capacity number
---@field runs wonderland.font.Run[] # And the measured line each text node draws
---@field changed boolean # Whether this frame is different from the one the gpu has
---@field private last ffi.cdata* # The frame the gpu was last given
---@field private lastCount number
---@field private lastChildren number
---@field root number # 1 based index of the root
local Screen = {}
Screen.__index = Screen

--- A screen's storage, kept between repaints and grown when a bigger screen arrives.
---@param capacity number? # Roughly how many nodes to start with
---@return wonderland.Layout.Screen
function layout.new(capacity)
	capacity = capacity or 256

	return setmetatable({
		nodes = nodeArray(capacity),
		childIndices = ffi.new("uint32_t[?]", capacity),
		bars = barArray(capacity),
		barNone = ffi.new("wl_bar"),
		last = nodeArray(capacity),
		capacity = capacity,
		count = 0,
		childCount = 0,
		lastCount = 0,
		lastChildren = 0,
		changed = true,
		runs = {},
		root = 0,
	}, Screen)
end

---@param nodes number
function Screen:reserve(nodes)
	if nodes <= self.capacity then
		return
	end

	local capacity = self.capacity
	while capacity < nodes do
		capacity = capacity * 2
	end

	-- Growing happens while a screen is being built, so what is already in the arrays has
	-- to come along, and the runs of child indices move with their nodes.
	local nodes_ = nodeArray(capacity)
	local childIndices = ffi.new("uint32_t[?]", capacity)
	local bars = barArray(capacity)

	if self.count > 0 then
		ffi.copy(nodes_, self.nodes, self.count * NODE_SIZE)
	end

	if self.childCount > 0 then
		ffi.copy(childIndices, self.childIndices, self.childCount * ffi.sizeof("uint32_t"))
	end

	if self.count > 0 and self.bars ~= nil then
		ffi.copy(bars, self.bars, self.count * ffi.sizeof("wl_bar"))
	end

	self.nodes = nodes_
	self.childIndices = childIndices
	self.bars = bars
	self.last = nodeArray(capacity)
	self.lastCount = 0
	self.capacity = capacity
end

-- The fields of a style that stands in for another one: what it names is written over what the
-- style it stands in for said. It is a call of its own because it is the rare path -- an element
-- the pointer is over -- and the common one is a copy of one style and no more.
---@param given wonderland.StyleSlot
---@param node wonderland.Node
local function applyOver(given, node)
	local present = given.flags

	if bit.band(present, PRESENT.width) ~= 0 then
		node.widthUnit, node.wantWidth = given.widthUnit, given.wantWidth
	end

	if bit.band(present, PRESENT.height) ~= 0 then
		node.heightUnit, node.wantHeight = given.heightUnit, given.wantHeight
	end

	if bit.band(present, PRESENT.gap) ~= 0 then
		node.gap = given.gap
	end

	if bit.band(present, PRESENT.z) ~= 0 then
		node.zIndex = given.zIndex
	end

	if bit.band(present, PRESENT.direction) ~= 0 then
		node.direction = given.direction
	end

	if bit.band(present, PRESENT.align) ~= 0 then
		node.align = given.align
	end

	if bit.band(present, PRESENT.justify) ~= 0 then
		node.justify = given.justify
	end

	if bit.band(present, PRESENT.position) ~= 0 then
		node.position = given.position
	end

	if bit.band(present, PRESENT.visible) ~= 0 then
		node.visible = given.visible
	end

	if bit.band(present, PRESENT.padding) ~= 0 then
		node.paddingTop, node.paddingRight = given.paddingTop, given.paddingRight
		node.paddingBottom, node.paddingLeft = given.paddingBottom, given.paddingLeft
	end

	if bit.band(present, PRESENT.margin) ~= 0 then
		node.marginTop, node.marginRight = given.marginTop, given.marginRight
		node.marginBottom, node.marginLeft = given.marginBottom, given.marginLeft
	end

	if bit.band(present, PRESENT.offset) ~= 0 then
		node.top, node.left, node.right, node.bottom = given.top, given.left, given.right, given.bottom
	end

	if bit.band(present, PRESENT.border) ~= 0 then
		node.borderTop, node.borderRight = given.borderTop, given.borderRight
		node.borderBottom, node.borderLeft = given.borderBottom, given.borderLeft
		node.borderR, node.borderG = given.borderR, given.borderG
		node.borderB, node.borderA = given.borderB, given.borderA
	end

	if bit.band(present, PRESENT.bg) ~= 0 then
		node.bgR, node.bgG, node.bgB, node.bgA = given.bgR, given.bgG, given.bgB, given.bgA
	end

	if bit.band(present, PRESENT.fg) ~= 0 then
		node.fgR, node.fgG, node.fgB, node.fgA = given.fgR, given.fgG, given.fgB, given.fgA
	end

	if bit.band(present, PRESENT.texture) ~= 0 then
		node.texture = given.texture
		node.u0, node.v0, node.u1, node.v1 = given.u0, given.v0, given.u1, given.v1
	end

	if bit.band(present, PRESENT.bright) ~= 0 then
		node.bright = given.bright
	end

	if bit.band(present, PRESENT.radius) ~= 0 then
		node.radius = given.radius
	end

	if bit.band(present, PRESENT.shadow) ~= 0 then
		node.shadowX, node.shadowY, node.shadowBlur = given.shadowX, given.shadowY, given.shadowBlur
		node.shadowR, node.shadowG = given.shadowR, given.shadowG
		node.shadowB, node.shadowA = given.shadowB, given.shadowA
	end
end

--- What a node is drawn with, lit differently: a multiplier over the colours it already has, so
--- a hover style can say "brighter" instead of naming a second set of colours that has to be kept
--- in step with the first. Transparency is not a colour and is left alone.
---@param node wonderland.Node
local function lighten(node)
	local bright = node.bright

	node.bgR, node.bgG, node.bgB = math.min(1.0, node.bgR * bright), math.min(1.0, node.bgG * bright),
		math.min(1.0, node.bgB * bright)
	node.borderR, node.borderG = math.min(1.0, node.borderR * bright), math.min(1.0, node.borderG * bright)
	node.borderB = math.min(1.0, node.borderB * bright)

	-- A text colour is bytes, so it is rounded to one and stops at white.
	node.fgR = math.min(255, math.floor(node.fgR * bright + 0.5))
	node.fgG = math.min(255, math.floor(node.fgG * bright + 0.5))
	node.fgB = math.min(255, math.floor(node.fgB * bright + 0.5))
end

---@param element wonderland.Element
---@return number # The node the element became
function Screen:add(element)
	self.count = self.count + 1
	self:reserve(self.count)

	-- For the frame, not for the node: the arena is only replaced while a tree is being
	-- built, and this runs after that.
	local node = self.nodes[self.count - 1]

	-- What it is drawn and laid out with. A style is a slot in the arena, so "which style
	-- does the pointer make this" is two numbers the element holds, and what that style
	-- says is one struct the layout reads: no table lookups by name, and no comparing
	-- strings to find out which way a box stacks.
	local flags = element.flags
	local over = 0

	if bit.band(flags, PRESSED) ~= 0 and element.activeStyle ~= 0 then
		over = element.activeStyle
	elseif bit.band(flags, HOVERED) ~= 0 and element.hoverStyle ~= 0 then
		over = element.hoverStyle
	end

	local given = styleArena[element.baseStyle]

	-- The arrays are reused, so nothing is zero because it is new: every field is written
	-- from the style whether the style named it or not, which is also why a style that
	-- names nothing is a slot like any other -- the layout has one path through here.
	-- The whole style in one copy: the node's first fields are laid out as a style is, so this is
	-- the work of thirty writes in one call, and the reason the build is short enough for the
	-- recorder. Everything below is the node's own.
	ffi.copy(node, given, STYLE_COPY)

	node.element = element.index
	node.style = over ~= 0 and over or element.baseStyle
	node.x, node.y, node.width, node.height = 0, 0, 0, 0
	node.firstChild, node.childCount = 0, 0
	node.run, node.runId = 0, 0

	-- A box that scrolls shows only what is inside it: how far its content is moved up is the
	-- app's, and snapped to a whole pixel so the text in it stays crisp.
	node.scrolls = bit.band(element.flags, SCROLLS) ~= 0 and 1 or 0
	node.scroll = snap(element.scrollOffset)

	-- A bar is taken out of the content rather than drawn over it, so nothing is under the strip it
	-- is in. A box that does not scroll has no bar, whatever its style says -- and no bar is
	-- written for it either, since the nodes the frame is not longer than keep theirs.
	if node.scrolls ~= 0 then
		local bar = self.bars[self.count - 1]

		bar.max = 0
		bar.width, bar.least = given.barWidth, given.barLeast
		bar.r, bar.g, bar.b, bar.a = given.barR, given.barG, given.barB, given.barA

		if bar.width > 0 then
			node.paddingRight = node.paddingRight + bar.width
		end
	end

	-- A style kept for the pointer stands in for the base one and says what it names: what it
	-- does not name is what the base style says, so a hover style that only names a background
	-- leaves the size, the padding and the direction alone. It is written after the base style
	-- rather than before it, because what it says is what wins.
	local worn = over ~= 0 and styleArena[over]

	if worn then
		node.styleFlags = bit.bor(node.styleFlags, bit.band(worn.flags, 0xffff))
		applyOver(worn, node)
	end

	-- Brightness is the one thing that is not a field of the frame's own: it is applied to the
	-- colours the node ends up with, whichever style said it, and the children inherit the
	-- result because they are built from the node after this.
	if node.bright ~= 1.0 then
		lighten(node)
	end

	return self.count
end

--- A line of text is the size of the line it measured into, unless the style named a size
--- of its own, and the run is kept for the quad pass to draw the glyphs of. Kept out of
--- `add` because only a text element reaches it, and because a trace of a function this
--- long is one the recorder gives up on -- and a trace it gives up on is a loop that runs
--- a reference allocation at a time.
---@param screen wonderland.Layout.Screen
---@param node wonderland.Node
---@param index number
---@param run wonderland.font.Run
local function sizeToRun(screen, node, index, run)
	screen.runs[index] = run
	node.run, node.runId = index, run.id

	if bit.band(node.styleFlags, WIDTH) == 0 then
		node.widthUnit, node.wantWidth = ABS, run.width
	end

	if bit.band(node.styleFlags, HEIGHT) == 0 then
		node.heightUnit, node.wantHeight = ABS, run.height
	end
end

--- Builds the nodes for an element tree, depth first, and the runs of child indices that
--- go with them.
---@param element wonderland.Element
---@param fgR number? # What the elements above this one draw text in
---@param fgG number?
---@param fgB number?
---@param fgA number?
---@param font number? # And the font they draw it with
---@return number # The node the element became
function Screen:build(element, fgR, fgG, fgB, fgA, font)
	local node = self:add(element)
	local entry = self.nodes[node - 1]

	-- Text properties are inherited; everything else is not, because a background belongs
	-- to the box that has it rather than to everything inside it.
	if entry.fgA == 0 then
		entry.fgR, entry.fgG, entry.fgB, entry.fgA = fgR or 0, fgG or 0, fgB or 0, fgA or 0
	end

	-- The font a line is drawn in is the one it was measured in. It is resolved from the
	-- base style rather than the one the pointer picked, because that is the font the run
	-- was measured with: a style that changes it would be drawing glyphs baked for
	-- another one.
	local base = styleArena[element.baseStyle]
	local named = base.font ~= 0 and base.font or element.fontId
	entry.font = (named ~= 0 and named or font or 0) + 1

	-- Most elements draw no line at all, so the walk for one is only made when there is
	-- one to find.
	local measured = runs[element.run]

	if measured ~= nil then
		sizeToRun(self, entry, node, measured)
	end

	local firstChild = self.childCount + 1
	local count = element.childCount

	self.childCount = self.childCount + count
	entry.firstChild = firstChild
	entry.childCount = count

	-- The children are one chain, and the run of child indices is filled in the order the
	-- chain hands them over, which is the order they were added in.
	local child = element.childFirst

	for index = 1, count do
		local childElement = pointers[child]
		local childNode = self:build(childElement, entry.fgR, entry.fgG, entry.fgB, entry.fgA, entry.font)

		self.childIndices[firstChild + index - 2] = childNode
		child = childElement.nextSibling
	end

	return node
end

--- Solves a node into the space its parent gave it, laying its children out as it goes.
--- The arithmetic is the layout: sizes are the space a node asked for, and the children
--- are placed along and across the axis they are stacked on.
---@param index number
---@param parentWidth number
---@param parentHeight number
---@param mainOverride number? # Size to use along the axis the parent stacks on
---@param overrideIsRow boolean? # Which axis that is
local function solveNode(screen, index, parentWidth, parentHeight, mainOverride, overrideIsRow)
	local node = screen.nodes[index - 1]

	if node.visible == 0 then
		node.x, node.y, node.width, node.height = 0, 0, 0, 0

		return
	end

	local isRow = node.direction == 0

	if mainOverride then
		-- The size is given along the axis the parent stacks on, which is not necessarily
		-- the axis this node stacks its own children on.
		if overrideIsRow then
			node.widthUnit, node.wantWidth = ABS, mainOverride
		else
			node.heightUnit, node.wantHeight = ABS, mainOverride
		end

	end

	local availableWidth = parentWidth - node.marginLeft - node.marginRight
	local availableHeight = parentHeight - node.marginTop - node.marginBottom

	local width = node.widthUnit == AUTO and availableWidth
		or (node.widthUnit == REL and node.wantWidth * availableWidth)
		or node.wantWidth

	local height = node.heightUnit == AUTO and availableHeight
		or (node.heightUnit == REL and node.wantHeight * availableHeight)
		or node.wantHeight

	local borderWidth = node.borderLeft + node.borderRight
	local borderHeight = node.borderTop + node.borderBottom

	local contentWidth = width - node.paddingLeft - node.paddingRight - borderWidth
	local contentHeight = height - node.paddingTop - node.paddingBottom - borderHeight

	local containerMain = isRow and contentWidth or contentHeight
	local containerCross = isRow and contentHeight or contentWidth
	local count = node.childCount
	local first = node.firstChild

	-- What the children ask for along the main axis, and how many of them want whatever
	-- is left over.
	local totalMain = 0
	local visibleChildren = 0
	local autoCount = 0

	for at = 0, count - 1 do
		local child = screen.nodes[screen.childIndices[first + at - 1] - 1]

		if child.position == 1 then
			-- Placed by hand, so it takes no room in the flow.
		else
			local childUnit = isRow and child.widthUnit or child.heightUnit
			local childWant = isRow and child.wantWidth or child.wantHeight

			if childUnit == 3 then
				autoCount = autoCount + 1
			else
				totalMain = totalMain + (childUnit == 2 and childWant * containerMain or childWant)
				visibleChildren = visibleChildren + 1
			end
		end
	end

	local totalGaps = math.max(0, count - 1) * node.gap
	local remaining = containerMain - totalMain - totalGaps
	local autoSpace = autoCount > 0 and (remaining / autoCount) or 0

	-- Solve the children, then place them.
	for at = 0, count - 1 do
		local childIndex = screen.childIndices[first + at - 1]
		local child = screen.nodes[childIndex - 1]
		local childUnit = isRow and child.widthUnit or child.heightUnit

		solveNode(screen, childIndex, contentWidth, contentHeight, childUnit == AUTO and autoSpace or nil, isRow)
	end

	totalMain = 0
	visibleChildren = 0

	for at = 0, count - 1 do
		local child = assert(screen.nodes[screen.childIndices[first + at - 1] - 1])

		if (child.width > 0 or child.height > 0) and child.position ~= 1 then
			local childMainMargin = isRow and (child.marginLeft + child.marginRight)
				or (child.marginTop + child.marginBottom)

			totalMain = totalMain + (isRow and child.width or child.height) + childMainMargin
			visibleChildren = visibleChildren + 1
		end
	end

	totalGaps = math.max(0, visibleChildren - 1) * node.gap
	totalMain = totalMain + totalGaps
	local freeSpace = containerMain - totalMain

	local offset = 0
	local spacing = node.gap

	if node.justify == 1 then
		offset = freeSpace / 2
	elseif node.justify == 2 then
		offset = freeSpace
	elseif node.justify == 3 and count > 1 then
		spacing = spacing + freeSpace / (count - 1)
	elseif node.justify == 4 and count > 0 then
		local unit = freeSpace / count
		offset = unit / 2
		spacing = spacing + unit
	end

	local placed = 0

	for at = 0, count - 1 do
		local child = screen.nodes[screen.childIndices[first + at - 1] - 1]
		local shown = child.width > 0 or child.height > 0

		if shown and child.position == 1 then
			-- At the parent's content origin, moved by its own offset.
			if isRow then
				child.x = snap(node.paddingLeft + child.x)
				child.y = snap(node.paddingTop + child.y)
			else
				child.y = snap(node.paddingTop + child.y)
				child.x = snap(node.paddingLeft + child.x)
			end
		elseif shown then
			placed = placed + 1
			local last = placed == visibleChildren

			local mainPos = offset + (isRow and node.paddingLeft or node.paddingTop)
			local childMain = (isRow and child.x or child.y) + mainPos

			if isRow then
				child.x = snap(childMain)
			else
				child.y = snap(childMain)
			end

			offset = offset + (isRow and child.width or child.height) + (last and 0 or spacing)

			local crossOffset = (isRow and node.paddingTop or node.paddingLeft)
				+ (isRow and child.y or child.x)
			local childCrossMargin = isRow and (child.marginTop + child.marginBottom)
				or (child.marginLeft + child.marginRight)
			local cross = crossOffset

			if node.align == 1 then
				cross = crossOffset + (containerCross - (isRow and child.height or child.width) - childCrossMargin) / 2
			elseif node.align == 2 then
				cross = crossOffset + containerCross - (isRow and child.height or child.width) - childCrossMargin
			end

			if isRow then
				child.y = snap(cross)
			else
				child.x = snap(cross)
			end

		end

	end

	-- What is scrolled is shifted, and its own children come with it: their places are relative to
	-- it, so moving it moves the lot. How far it is shifted is what the content came out to less
	-- what the box shows -- which is only known once every child is placed -- so an offset past
	-- the end of the content draws the end rather than a hole. What the app keeps is its own.
	if node.scrolls ~= 0 then
		local most = math.max(0, offset - containerMain)

		-- Both ends, not just the far one: an offset below the start would put the content below
		-- the box and the thumb above it, and a thumb above its box is a bar that walks out of
		-- the pane as it is scrolled -- which is what a bar that would not stay put looked like.
		local scroll = math.min(math.max(node.scroll, 0), most)

		-- Kept, not just used: the bar is drawn from this, and an offset the app is still holding
		-- would walk the thumb out of the box its content was correctly clamped inside.
		node.scroll = scroll
		screen.bars[index - 1].max = most

		if scroll > 0 then
			for at = 0, count - 1 do
				local child = screen.nodes[screen.childIndices[first + at - 1] - 1]

				if isRow then
					child.x = child.x - scroll
				else
					child.y = child.y - scroll
				end
			end
		end
	end

	local x = node.marginLeft
	local y = node.marginTop

	if node.position == 1 then
		if node.left ~= 0 then
			x = x + node.left
		elseif node.right ~= 0 then
			x = x - node.right
		end

		if node.top ~= 0 then
			y = y + node.top
		elseif node.bottom ~= 0 then
			y = y - node.bottom
		end
	end

	node.width, node.height = width, height
	node.x, node.y = snap(x), snap(y)
end

--- What the pointer is doing, worked out from the boxes the solve produced: everything the
--- point is inside is hovered, so an element that has a box around others is hovered with them,
--- and everything it is inside while the button is held is pressed.
---
--- Returns whether any of them is drawn differently for it, which is what says the screen has
--- to be built again: a style that only changes what an element looks like still changes the
--- frame, and the frame is what the gpu is given or not given.
---@param screen wonderland.Layout.Screen
---@param index number
---@param x number
---@param y number
---@param parentX number
---@param parentY number
---@param pressed boolean
---@return boolean marked
local function markNode(screen, index, x, y, parentX, parentY, pressed)
	local node = screen.nodes[index - 1]
	local absX, absY = parentX + node.x, parentY + node.y
	local marked = false

	local inside = x >= absX and x <= absX + node.width and y >= absY and y <= absY + node.height

	-- What a box that scrolls has scrolled out of it is not drawn, hovered, or pressed either.
	if node.scrolls ~= 0 and not inside then
		return marked
	end

	for at = 0, node.childCount - 1 do
		if markNode(screen, screen.childIndices[node.firstChild + at - 1], x, y, absX, absY, pressed) then
			marked = true
		end
	end

	if node.visible == 0 or not inside then
		return marked
	end

	local element = pointers[node.element]

	-- The styles an element keeps for the pointer are its own, and whether one of them is used
	-- for the state it is in is what a second build would change.
	if element.hoverStyle ~= 0 or (pressed and element.activeStyle ~= 0) then
		marked = true
	end

	wonderlandElement.hovering(element, true)

	if pressed then
		wonderlandElement.pressing(element, true)
	end

	return marked
end

--- Solves the screen, and works out whether anything about it actually changed.
---
--- Nodes are one flat array of plain data, so "is this the same screen as last time" is
--- a comparison of memory: an app that repainted because something might have changed
--- pays for the layout and nothing else. What the gpu was given is kept alongside.
--- A solve made part of the way through a frame is not that frame: the pointer's state is worked
--- out from the boxes a solve produced, and a screen where something is drawn differently for the
--- pointer is solved again. The first of those must not be what the frame is compared against,
--- or every frame would look like a change of the one before it.
---@param width number
---@param height number
---@param provisional boolean? # A solve that is not the frame the gpu will be given
---@return wonderland.Layout.Screen
function Screen:solve(width, height, provisional)
	solveNode(self, self.root, width, height)

	if provisional then
		return self
	end

	local bytes = self.count * NODE_SIZE

	local same = bytes > 0 and ffi.C.memcmp(self.last, self.nodes, bytes) == 0

	if os.getenv("WL_DIFF_DEBUG") then
		local asString = bytes > 0 and ffi.string(self.last, bytes) == ffi.string(self.nodes, bytes)
		print(string.format("solve: count %d/%d bytes %d memcmpSame %s stringSame %s", self.count, self.lastCount,
			bytes, tostring(same), tostring(asString)))
	end

	self.changed = self.count ~= self.lastCount
		or self.childCount ~= self.lastChildren
		or not same

	if self.changed then
		ffi.copy(self.last, self.nodes, bytes)
		self.lastCount, self.lastChildren = self.count, self.childCount
	end

	return self
end

---@param element wonderland.Element
---@return number
local function countElements(element)
	local total = 1
	local child = element.childFirst

	while child ~= 0 do
		local childElement = pointers[child]

		total = total + countElements(childElement)
		child = childElement.nextSibling
	end

	return total
end

---@param element wonderland.Element
---@return number # The root node
function Screen:fromElement(element)
	-- The style array is taken again here, since a screen built a moment ago may have
	-- interned a style it did not have and moved it.
	styleArena = style.arena

	-- Room is taken before anything is written: growing the array moves it, and a node
	-- held across the move would be written into memory that is no longer the screen.
	self:reserve(countElements(element))

	self.count = 0
	self.childCount = 0

	self:build(element, nil, nil, nil, nil, nil)

	self.root = 1

	return self.root
end

--- What is under the pointer, and whether it is drawn differently for it.
---@param x number
---@param y number
---@param pressed boolean
---@return boolean # Whether any element it marked has a style for that state
function Screen:markPointer(x, y, pressed)
	return self.count > 0 and markNode(self, self.root, x, y, 0, 0, pressed) or false
end

---@param index number
---@return wonderland.Node
function Screen:node(index)
	return self.nodes[index - 1]
end

---@param index number
---@param child number # Which child, from one
---@return wonderland.Node
function Screen:child(index, child)
	local node = self.nodes[index - 1]

	return self.nodes[self.childIndices[node.firstChild + child - 2] - 1]
end

--- Lays a screen of elements out at a size, without a window or a gpu. Handy for
--- checking geometry, and it is what the example does.
---@param element wonderland.Element
---@param width number
---@param height number
---@return wonderland.Layout.Screen
function layout.screen(element, width, height)
	local screen = layout.new()
	screen:fromElement(element)
	screen:solve(width, height)

	return screen
end

return layout
