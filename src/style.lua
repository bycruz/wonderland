-- What an element looks like and how it lays out, written as calls.
--
--   local card = sty():bg("#262b38"):pad(12):row()
--
-- A style is a value: fill one in once and hand the same one to every element that
-- should look the same.
--
--   div():style(card)
--
-- The calls live on a builder that fills in a plain table, and it is that table the
-- element is handed to the style arena. So a style is read by field (`style.bg`) and
-- nothing read from it can ever come back as a function, which is what a call reachable
-- as a field would do. The calls themselves are one lowercase word each.
--
-- What an element actually holds is a number: the slot the style occupies in one array.
-- A style is interned, so two styles that say the same thing are one slot -- a screen
-- that rebuilds an identical style every repaint adds nothing, and "is this the same
-- style" is a comparison of two numbers.
local bit = require("bit")
local ffi = require("ffi")

ffi.cdef [[
	// Under ffi.C because LuaJIT only knows the symbols it has been told about: this is
	// how two styles are compared, and how a whole frame is.
	int memcmp(const void *a, const void *b, size_t n);

	// A style, as the arena holds it. It is the same fields the layout reads, in the
	// arithmetic it works in: a colour the layout rounds to bytes is bytes here, one it
	// hands to the gpu as it is stays a double, and a size is a double because a fraction
	// in a float32 is not the fraction.
	typedef struct {
		double wantWidth, wantHeight;
		double bgR, bgG, bgB, bgA;
		double borderR, borderG, borderB, borderA;
		double u0, v0, u1, v1;
		int32_t gap, zIndex;
		int32_t paddingTop, paddingRight, paddingBottom, paddingLeft;
		int32_t marginTop, marginRight, marginBottom, marginLeft;
		int32_t top, left, right, bottom;
		int32_t borderTop, borderRight, borderBottom, borderLeft;
		uint32_t fgR, fgG, fgB, fgA;
		uint32_t texture, font;
		double bright;    // a multiplier on the colours, 1.0 for not one
		double radius;    // how round the corners are, in pixels, 0 for square ones
		int32_t shadowX, shadowY;  // where its shadow sits, and how far it fades out
		int32_t shadowBlur;
		uint8_t shadowR, shadowG, shadowB, shadowA;  // and what colour it is, 0 alpha for none
		uint32_t flags;   // which of the fields that have no neutral value were set
		uint8_t widthUnit, heightUnit, direction, align, justify, position, visible, paint;

		// Everything above is what a node is made of, in the order a node holds it, so a node
		// copies a style into itself in one go. Everything below is only ever looked at when a
		// box scrolls, which is why it is kept out of that copy -- and out of the nodes.
		int32_t barWidth, barLeast;
		double barR, barG, barB, barA;
	} wl_style;
]]

local style = {}

-- How a size is read: pixels, a share of what the parent has, or whatever is left over.
-- A style that names no size is a share of one, which is what makes a box fill what it
-- was given without saying so.
style.ABS, style.REL, style.AUTO = 1, 2, 3

-- What a style named, one bit each. A style that is used *instead of* another -- an element's
-- hover or active style -- only changes the fields it names; everything else is what the style
-- it stood in for says. Without this a hover style would have to say everything again, size and
-- padding included, and one that only named a background would take the whole screen.
local P = {
	width = 1,
	height = 2,
	gap = 4,
	z = 8,
	padding = 16,
	margin = 32,
	offset = 64,
	border = 128,
	bg = 256,
	fg = 512,
	texture = 1024,
	font = 2048,
	direction = 4096,
	align = 8192,
	justify = 16384,
	position = 32768,
	visible = 65536,
	bright = 131072,
	bar = 262144,
	radius = 524288,
	shadow = 1048576,
}

style.PRESENT = P

-- What a style that named no width or height says, and what it is painted with.
local PAINT = 2097152

--- One style, as the arena holds it: the fields the layout reads. The language server
--- cannot see an ffi.cdef, so they are spelled out here, which is the only way to get
--- them checked.
---@class wonderland.StyleSlot: ffi.cdata*
---@field wantWidth number
---@field wantHeight number
---@field bgR number
---@field bgG number
---@field bgB number
---@field bgA number
---@field borderR number
---@field borderG number
---@field borderB number
---@field borderA number
---@field u0 number
---@field v0 number
---@field u1 number
---@field v1 number
---@field gap number
---@field zIndex number
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
---@field borderTop number
---@field borderRight number
---@field borderBottom number
---@field borderLeft number
---@field fgR number
---@field fgG number
---@field fgB number
---@field fgA number
---@field texture number
---@field font number
---@field barWidth number
---@field barLeast number
---@field barR number
---@field barG number
---@field barB number
---@field barA number
---@field bright number
---@field radius number
---@field shadowX number
---@field shadowY number
---@field shadowBlur number
---@field shadowR number
---@field shadowG number
---@field shadowB number
---@field shadowA number
---@field flags number
---@field widthUnit number
---@field heightUnit number
---@field direction number
---@field align number
---@field justify number
---@field position number
---@field visible number
---@field paint number

---@alias wonderland.Color { r: number, g: number, b: number, a: number }

--- A size as an element writes it: a plain number of pixels is taken as absolute.
---@alias ScaleUnitInput number | { abs: number } | { rel: number } | "auto"
---@alias Direction "row" | "column"
---@alias Alignment "start" | "center" | "end"
---@alias Justify "start" | "center" | "end" | "space-between" | "space-around"
---@alias Visibility "visible" | "none"
--- A shadow drawn behind a box: offset from it, blurred by how far its edge fades, in pixels.
---@class wonderland.Shadow
---@field x number
---@field y number
---@field blur number
---@field color wonderland.Color

---@alias Padding { top: number?, bottom: number?, left: number?, right: number? }
---@alias Margin { top: number?, bottom: number?, left: number?, right: number? }
---@alias BorderStyle "solid" | "dashed" | "dotted" | "none"
---@alias Border { width: number?, style: BorderStyle?, color: wonderland.Color? }
---@alias Borders { top: Border?, bottom: Border?, left: Border?, right: Border? }

--- How an element is laid out, as the layout reads it. Every field is optional: the
--- element says what it wants and the solver fills in the rest.
---@class wonderland.LayoutStyle
---@field width ScaleUnitInput?
---@field height ScaleUnitInput?
---@field gap number?
---@field direction Direction?
---@field align Alignment?
---@field justify Justify?
---@field padding Padding?
---@field margin Margin?
---@field border Borders?
---@field zIndex number?
---@field visibility Visibility?
---@field top number?
---@field left number?
---@field right number?
---@field bottom number?
---@field position "relative" | "static"?

--- The style of an element: what it looks like and how it lays out, as plain fields.
---@class wonderland.VisualStyle
---@field bg wonderland.Color?
---@field bright number? # A multiplier on the colours: 1.0 as they are, 0 black
---@field radius number? # How round the corners of the box are, in pixels
---@field shadow wonderland.Shadow? # A shadow behind the box
---@field bar { width: number, least: number, color: wonderland.Color }? # A scroll bar
---@field bgImage Texture?
---@field bgImageUV { u0: number?, u1: number?, v0: number?, v1: number? }?
---@field fg wonderland.Color?
---@field font Font?

--- One table carries both, and that is what an element holds.
---@class wonderland.Style: wonderland.VisualStyle, wonderland.LayoutStyle
local Style = {}

--- What the calls are made on, and what it fills in. The calls are declared here as
--- fields because that is the only way a language server sees them: they are not on the
--- style itself, which is what keeps a style readable by field.
---@class wonderland.StyleBuilder
---@field values wonderland.Style
---@field version number # Bumped by every call that fills a field in
---@field slot number # What this style interned to, and
---@field slotVersion number # the version it was interned at
---@field w fun(self: wonderland.StyleBuilder, value: ScaleUnitInput): wonderland.StyleBuilder
---@field h fun(self: wonderland.StyleBuilder, value: ScaleUnitInput): wonderland.StyleBuilder
---@field wrel fun(self: wonderland.StyleBuilder, fraction: number): wonderland.StyleBuilder
---@field hrel fun(self: wonderland.StyleBuilder, fraction: number): wonderland.StyleBuilder
---@field size fun(self: wonderland.StyleBuilder, width: ScaleUnitInput, height: ScaleUnitInput): wonderland.StyleBuilder
---@field fill fun(self: wonderland.StyleBuilder): wonderland.StyleBuilder
---@field flex fun(self: wonderland.StyleBuilder, value: Direction): wonderland.StyleBuilder
---@field row fun(self: wonderland.StyleBuilder): wonderland.StyleBuilder
---@field column fun(self: wonderland.StyleBuilder): wonderland.StyleBuilder
---@field gap fun(self: wonderland.StyleBuilder, value: number): wonderland.StyleBuilder
---@field align fun(self: wonderland.StyleBuilder, value: Alignment): wonderland.StyleBuilder
---@field justify fun(self: wonderland.StyleBuilder, value: Justify): wonderland.StyleBuilder
---@field pad fun(self: wonderland.StyleBuilder, all: number, second: number?, third: number?, fourth: number?): wonderland.StyleBuilder
---@field margin fun(self: wonderland.StyleBuilder, all: number, second: number?, third: number?, fourth: number?): wonderland.StyleBuilder
---@field border fun(self: wonderland.StyleBuilder, width: number, color: string | wonderland.Color): wonderland.StyleBuilder
---@field z fun(self: wonderland.StyleBuilder, value: number): wonderland.StyleBuilder
---@field hidden fun(self: wonderland.StyleBuilder): wonderland.StyleBuilder
---@field offset fun(self: wonderland.StyleBuilder, x: number, y: number): wonderland.StyleBuilder
---@field bg fun(self: wonderland.StyleBuilder, color: string | wonderland.Color): wonderland.StyleBuilder
---@field fg fun(self: wonderland.StyleBuilder, color: string | wonderland.Color): wonderland.StyleBuilder
---@field font fun(self: wonderland.StyleBuilder, font: Font): wonderland.StyleBuilder
---@field image fun(self: wonderland.StyleBuilder, texture: Texture, uv: { u0: number?, u1: number?, v0: number?, v1: number? }?): wonderland.StyleBuilder
---@field bright fun(self: wonderland.StyleBuilder, value: number): wonderland.StyleBuilder
---@field radius fun(self: wonderland.StyleBuilder, value: number): wonderland.StyleBuilder
---@field shadow fun(self: wonderland.StyleBuilder, x: number, y: number, blur: number, color: string | wonderland.Color?): wonderland.StyleBuilder
---@field bar fun(self: wonderland.StyleBuilder, width: number, least: number, color: string | wonderland.Color): wonderland.StyleBuilder
local methods = {}
methods.__index = methods

-- Asked for a colour by name, these are handed out as they are, so naming one costs
-- nothing and two styles that name the same one share it.
local NAMED = {
	white = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 },
	black = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
	red = { r = 1.0, g = 0.0, b = 0.0, a = 1.0 },
	green = { r = 0.0, g = 1.0, b = 0.0, a = 1.0 },
	blue = { r = 0.0, g = 0.0, b = 1.0, a = 1.0 },
	yellow = { r = 1.0, g = 1.0, b = 0.0, a = 1.0 },
	grey = { r = 0.5, g = 0.5, b = 0.5, a = 1.0 },
	gray = { r = 0.5, g = 0.5, b = 0.5, a = 1.0 },
	clear = { r = 0.0, g = 0.0, b = 0.0, a = 0.0 },
}

--- A colour is a name, `#rrggbb`, `#rrggbbaa`, or the four channels themselves.
---@param value string | wonderland.Color
---@return wonderland.Color
local function toColor(value)
	if type(value) ~= "string" then
		return value
	end

	local named = NAMED[value]
	if named then
		return named
	end

	local hex = value:match("^#(%x+)$")
	assert(hex and (#hex == 6 or #hex == 8), "Not a colour: " .. value)

	local function channel(at)
		return tonumber(hex:sub(at, at + 1), 16) / 255
	end

	return { r = channel(1), g = channel(3), b = channel(5), a = #hex == 8 and channel(7) or 1.0 }
end

---@param all number
---@param second number?
---@param third number?
---@param fourth number?
---@return Padding
local function toSides(all, second, third, fourth)
	if second == nil then
		return { top = all, bottom = all, left = all, right = all }
	end

	if third == nil then
		return { top = all, bottom = all, left = second, right = second }
	end

	return { top = all, right = second, bottom = third, left = fourth }
end

---@return wonderland.StyleBuilder
function style.new()
	return setmetatable({ values = {}, version = 0, slot = 0, slotVersion = -1 }, methods)
end

---@param value ScaleUnitInput
---@return wonderland.StyleBuilder
function methods:w(value)
	self.values.width = value
	self.version = self.version + 1
	return self
end

---@param value ScaleUnitInput
---@return wonderland.StyleBuilder
function methods:h(value)
	self.values.height = value
	self.version = self.version + 1
	return self
end

--- A share of the space the parent has, rather than pixels.
---@param fraction number
---@return wonderland.StyleBuilder
function methods:wrel(fraction)
	self.values.width = { rel = fraction }
	self.version = self.version + 1
	return self
end

---@param fraction number
---@return wonderland.StyleBuilder
function methods:hrel(fraction)
	self.values.height = { rel = fraction }
	self.version = self.version + 1
	return self
end

---@param width ScaleUnitInput
---@param height ScaleUnitInput
---@return wonderland.StyleBuilder
function methods:size(width, height)
	self.values.width = width
	self.values.height = height
	self.version = self.version + 1
	return self
end

--- Take all of the space there is, which is the usual thing for a screen.
---@return wonderland.StyleBuilder
function methods:fill()
	self.values.width = { rel = 1.0 }
	self.values.height = { rel = 1.0 }
	self.version = self.version + 1
	return self
end

---@param value Direction
---@return wonderland.StyleBuilder
function methods:flex(value)
	self.values.direction = value
	self.version = self.version + 1
	return self
end

---@return wonderland.StyleBuilder
function methods:row()
	self.values.direction = "row"
	self.version = self.version + 1
	return self
end

---@return wonderland.StyleBuilder
function methods:column()
	self.values.direction = "column"
	self.version = self.version + 1
	return self
end

---@param value number
---@return wonderland.StyleBuilder
function methods:gap(value)
	self.values.gap = value
	self.version = self.version + 1
	return self
end

--- Across the axis the children are laid out on.
---@param value Alignment
---@return wonderland.StyleBuilder
function methods:align(value)
	self.values.align = value
	self.version = self.version + 1
	return self
end

--- Along the axis the children are laid out on.
---@param value Justify
---@return wonderland.StyleBuilder
function methods:justify(value)
	self.values.justify = value
	self.version = self.version + 1
	return self
end

--- One number for every side, two for vertical and horizontal, or all four.
---@param all number
---@param second number?
---@param third number?
---@param fourth number?
---@return wonderland.StyleBuilder
function methods:pad(all, second, third, fourth)
	self.values.padding = toSides(all, second, third, fourth)
	self.version = self.version + 1
	return self
end

---@param all number
---@param second number?
---@param third number?
---@param fourth number?
---@return wonderland.StyleBuilder
function methods:margin(all, second, third, fourth)
	self.values.margin = toSides(all, second, third, fourth)
	self.version = self.version + 1
	return self
end

--- A line on every side. The engine takes a table per side, which is still there for a
--- screen that wants one side of one box to differ.
---@param width number
---@param color string | wonderland.Color
---@return wonderland.StyleBuilder
function methods:border(width, color)
	local line = { width = width, style = "solid", color = toColor(color) }

	self.values.border = { top = line, bottom = line, left = line, right = line }
	self.version = self.version + 1
	return self
end

---@param value number
---@return wonderland.StyleBuilder
function methods:z(value)
	self.values.zIndex = value
	self.version = self.version + 1
	return self
end

--- Laid out, but not drawn.
---@return wonderland.StyleBuilder
function methods:hidden()
	self.values.visibility = "none"
	self.version = self.version + 1
	return self
end

--- Placed by hand, offset from where the layout would have put it, without taking up
--- room in it.
---@param x number
---@param y number
---@return wonderland.StyleBuilder
function methods:offset(x, y)
	self.values.position = "relative"
	self.values.left = x
	self.values.top = y
	self.version = self.version + 1
	return self
end

---@param color string | wonderland.Color
---@return wonderland.StyleBuilder
function methods:bg(color)
	self.values.bg = toColor(color)
	self.version = self.version + 1
	return self
end

---@param color string | wonderland.Color
---@return wonderland.StyleBuilder
function methods:fg(color)
	self.values.fg = toColor(color)
	self.version = self.version + 1
	return self
end

--- The colours an element is drawn with, lit differently: 1.0 is as they are, above is
--- brighter, below is darker, and 0 is black. It is what a hover or active style usually wants --
--- the colours it already has, glowing or pressed -- rather than a second set of them that has to
--- be kept in step with the first.
---@param value number
---@return wonderland.StyleBuilder
function methods:bright(value)
	self.values.bright = value
	self.version = self.version + 1
	return self
end

--- How round the corners of the box are, in pixels: 0 or nothing at all is square corners, and
--- a radius taller than the box it is asked for is drawn as a box that is round all the way
--- down its short side. The corners are cut in the shader rather than drawn as their own
--- geometry, so a round box is one quad and its edge is as smooth as the rest of the screen.
---@param value number
---@return wonderland.StyleBuilder
function methods:radius(value)
	self.values.radius = value
	self.version = self.version + 1
	return self
end

--- A shadow behind the box: where it sits, how far it fades out, and what colour it is. The
--- offset is in pixels, and positive goes down and right, the way the box's own `offset`
--- does. `blur` is how far the edge of it fades -- nought is a shadow with a hard edge -- and
--- the colour is anything a background takes, black at about half alpha if none is named.
---@param x number
---@param y number
---@param blur number
---@param color string | wonderland.Color?
---@return wonderland.StyleBuilder
function methods:shadow(x, y, blur, color)
	self.values.shadow = { x = x, y = y, blur = blur, color = toColor(color or "#00000066") }
	self.version = self.version + 1
	return self
end

--- A scroll bar for a box that scrolls, written down the right hand side of it and only drawn
--- when there is something to scroll. Its width is the strip it takes -- which the content gives
--- up, so nothing is drawn under it -- and the least height is how small the thumb may get, so a
--- list of a thousand lines still shows something to drag. The bar is drawn in the colour it is
--- given, and the track behind it in the same colour made fainter.
---@param width number
---@param least number # The least height a thumb of it is, in pixels
---@param color string | wonderland.Color
---@return wonderland.StyleBuilder
function methods:bar(width, least, color)
	self.values.bar = { width = width, least = least, color = toColor(color) }
	self.version = self.version + 1
	return self
end

--- Which uploaded texture text is drawn with.
---@param font Font
---@return wonderland.StyleBuilder
function methods:font(font)
	self.values.font = font
	self.version = self.version + 1
	return self
end

--- An uploaded texture across the box, and the part of it to use.
---@param texture Texture
---@param uv { u0: number?, u1: number?, v0: number?, v1: number? }?
---@return wonderland.StyleBuilder
function methods:image(texture, uv)
	self.values.bgImage = texture
	self.values.bgImageUV = uv
	self.version = self.version + 1
	return self
end

-- So that a style can say what it is in a debugger.
methods.__tostring = function(self)
	local values = self.values

	return string.format("<style %sx%s>", tostring(values.width or "auto"), tostring(values.height or "auto"))
end

-- ────────────────────────────────────────────────────────────────
-- the arena
-- ────────────────────────────────────────────────────────────────

-- Every distinct style lives in one array, and a style *is* the slot it lives in: what
-- an element holds, what the layout reads, and what the frame remembers are all numbers.
--
-- The array is handed out by index rather than by pointer, so it can grow under a screen
-- that is already built: nothing but a slot number is held. The buckets are a plain array
-- of the slots, sized to stay sparse, and a collision is settled by comparing the two
-- styles byte for byte -- which is also the whole of interning, since it is the same
-- comparison that says "this style is already here".
local CAPACITY = 64 -- styles are few, and this grows by being copied
local BUCKETS = 256 -- a power of two, so the hash keeps the bits it needs
local arena = ffi.new("wl_style[?]", CAPACITY)
local buckets = ffi.new("uint32_t[?]", BUCKETS)
local slots = 0

-- The struct a style is filled into before it is interned, or found to be there already.
-- Asserted into its type because the language server sees `ffi.new` as plain cdata, and a
-- stack of fields of a struct is what the check is for.
local scratch = ffi.new("wl_style")
---@cast scratch wonderland.StyleSlot

local SIZE = assert(ffi.sizeof("wl_style"))
local scratchBytes = ffi.cast("const uint8_t *", scratch)

--- A hash of the struct itself, so interning costs one pass over it and no allocation: a
--- Lua string key would be one more thing to throw away every repaint. It is written as
--- shifts and adds because a 32 bit multiply is not exact in a double.
---@return number
local function hashScratch()
	local hash = 2166136261

	for index = 0, SIZE - 1 do
		hash = bit.bxor(hash, scratchBytes[index])
		hash = bit.tobit(bit.lshift(hash, 5) - hash)
	end

	return hash
end

---@param value ScaleUnitInput
---@return number, number
local function unitOf(value)
	if value == "auto" then
		return style.AUTO, 0
	end

	if type(value) == "number" then
		return style.ABS, value
	end

	if type(value) == "table" then
		if value.abs then
			return style.ABS, value.abs
		end

		if value.rel then
			return style.REL, value.rel
		end
	end

	return style.ABS, 0
end

--- Fills the scratch struct from a style's fields. It is written into rather than read
--- where it is used, which is what turns a screen's worth of table lookups and string
--- comparisons into one copy of a struct per element.
---@param fields wonderland.Style
local function fill(fields)
	ffi.fill(scratch, SIZE)

	local flags = 0

	local width = fields.width
	if width ~= nil then
		scratch.widthUnit, scratch.wantWidth = unitOf(width)
		flags = flags + P.width
	else
		scratch.widthUnit, scratch.wantWidth = style.REL, 1.0
	end

	local height = fields.height
	if height ~= nil then
		scratch.heightUnit, scratch.wantHeight = unitOf(height)
		flags = flags + P.height
	else
		scratch.heightUnit, scratch.wantHeight = style.REL, 1.0
	end

	if fields.gap ~= nil then
		scratch.gap = fields.gap
		flags = flags + P.gap
	end

	if fields.zIndex ~= nil then
		scratch.zIndex = fields.zIndex
		flags = flags + P.z
	end

	if fields.direction ~= nil then
		scratch.direction = fields.direction == "column" and 1 or 0
		flags = flags + P.direction
	end

	if fields.align ~= nil then
		scratch.align = fields.align == "center" and 1 or (fields.align == "end" and 2 or 0)
		flags = flags + P.align
	end

	if fields.justify ~= nil then
		scratch.justify = fields.justify == "center" and 1
			or (fields.justify == "end" and 2
				or (fields.justify == "space-between" and 3 or (fields.justify == "space-around" and 4 or 0)))
		flags = flags + P.justify
	end

	if fields.position ~= nil then
		scratch.position = fields.position == "relative" and 1 or 0
		flags = flags + P.position
	end

	-- Always written: a style says nothing about being visible by being visible, which is what
	-- a box with no visibility of its own is. The bit is what says it named it, so a hover
	-- style that says nothing about it leaves the style it stands in for to say.
	scratch.visible = fields.visibility == "none" and 0 or 1

	if fields.visibility ~= nil then
		flags = flags + P.visible
	end

	local padding = fields.padding
	if padding then
		scratch.paddingTop, scratch.paddingRight = padding.top or 0, padding.right or 0
		scratch.paddingBottom, scratch.paddingLeft = padding.bottom or 0, padding.left or 0
		flags = flags + P.padding
	end

	local margin = fields.margin
	if margin then
		scratch.marginTop, scratch.marginRight = margin.top or 0, margin.right or 0
		scratch.marginBottom, scratch.marginLeft = margin.bottom or 0, margin.left or 0
		flags = flags + P.margin
	end

	if fields.top ~= nil or fields.left ~= nil or fields.right ~= nil or fields.bottom ~= nil then
		scratch.top, scratch.left = fields.top or 0, fields.left or 0
		scratch.right, scratch.bottom = fields.right or 0, fields.bottom or 0
		flags = flags + P.offset
	end

	local border = fields.border
	if border then
		flags = flags + P.border
	end

	if border then
		local top = border.top
		if top then
			scratch.borderTop = top.width or 0

			if top.color then
				scratch.borderR, scratch.borderG = top.color.r, top.color.g
				scratch.borderB, scratch.borderA = top.color.b, top.color.a
			end
		end

		scratch.borderRight = border.right and border.right.width or 0
		scratch.borderBottom = border.bottom and border.bottom.width or 0
		scratch.borderLeft = border.left and border.left.width or 0
	end

	local bg = fields.bg
	if bg then
		scratch.bgR, scratch.bgG, scratch.bgB, scratch.bgA = bg.r, bg.g, bg.b, bg.a
		scratch.paint = 1
		flags = flags + P.bg
	end

	local fg = fields.fg
	if fg then
		flags = flags + P.fg
		-- Rounded here rather than per node: the gpu takes a text colour as bytes.
		scratch.fgR = math.floor(fg.r * 255 + 0.5)
		scratch.fgG = math.floor(fg.g * 255 + 0.5)
		scratch.fgB = math.floor(fg.b * 255 + 0.5)
		scratch.fgA = math.floor(fg.a * 255 + 0.5)
	end

	local image = fields.bgImage
	if image then
		scratch.texture = image
		scratch.paint = 1
		flags = flags + P.texture

		local uv = fields.bgImageUV
		scratch.u0, scratch.v0 = uv and uv.u0 or 0, uv and uv.v0 or 0
		scratch.u1, scratch.v1 = uv and uv.u1 or 1, uv and uv.v1 or 1
	else
		scratch.u0, scratch.v0, scratch.u1, scratch.v1 = 0, 0, 1, 1
	end

	if fields.font ~= nil then
		scratch.font = fields.font
		flags = flags + P.font
	end

	local bar = fields.bar
	if bar then
		local color = assert(bar.color)

		scratch.barWidth, scratch.barLeast = bar.width, bar.least
		scratch.barR, scratch.barG = color.r, color.g
		scratch.barB, scratch.barA = color.b, color.a
		flags = flags + P.bar
	end

	-- A multiplier rather than a colour of its own: a hover style that says this is the element's
	-- own colours, lit differently, and it stays in step with them for nothing.
	scratch.bright = fields.bright or 1.0

	if fields.bright ~= nil then
		flags = flags + P.bright
	end

	-- Named by a style that stands in for another one, a radius is what the box it stands in for
	-- already had, so a hover style that only lights a card up does not square its corners off.
	scratch.radius = fields.radius or 0

	if fields.radius ~= nil then
		flags = flags + P.radius
	end

	-- A shadow is behind the box, so it is nothing at all until a style names one: the colour
	-- is rounded to bytes, like a text colour, and its alpha is what says whether there is one.
	local shadow = fields.shadow
	if shadow then
		local color = assert(shadow.color)

		scratch.shadowX, scratch.shadowY, scratch.shadowBlur = shadow.x, shadow.y, shadow.blur
		scratch.shadowR = math.floor(color.r * 255 + 0.5)
		scratch.shadowG = math.floor(color.g * 255 + 0.5)
		scratch.shadowB = math.floor(color.b * 255 + 0.5)
		scratch.shadowA = math.floor(color.a * 255 + 0.5)
		flags = flags + P.shadow
	end

	-- A style with a background is one that paints, whether or not it said anything else: a
	-- box that is drawn transparent is still a box that is drawn.
	if bit.band(flags, P.bg) ~= 0 or bit.band(flags, P.texture) ~= 0 then
		scratch.paint = 1
		flags = flags + PAINT
	end

	scratch.flags = flags
end

---@param count number
local function grow(count)
	local capacity = CAPACITY
	while capacity < count do
		capacity = capacity * 2
	end

	local bigger = ffi.new("wl_style[?]", capacity)
	ffi.copy(bigger, arena, slots * SIZE)
	arena = bigger
	style.arena = arena
end

--- The slot a style is, which is the whole of what an element holds of it. A style that
--- says the same thing as one already interned is that one: the comparison is the two
--- structs, so nothing has to be looked up twice.
---@param fields wonderland.Style
---@return number
local function intern(fields)
	fill(fields)

	local mask = BUCKETS - 1
	local at = bit.band(hashScratch(), mask)

	while true do
		local used = buckets[at]
		if used == 0 then
			local slot = slots
			slots = slots + 1

			if slots > CAPACITY then
				grow(slots)
			end

			ffi.copy(arena[slot], scratch, SIZE)
			buckets[at] = slot + 1

			return slot
		end

		local slot = used - 1
		if ffi.C.memcmp(arena[slot], scratch, SIZE) == 0 then
			return slot
		end

		at = bit.band(at + 1, mask)
	end
end

-- What the layout reads the styles of a screen out of. It is handed over as the array
-- rather than behind a call because a node reads one: a repaint is one array index per
-- element, not one call.
style.arena = arena

--- A style, once it is what the arena holds: what an element keeps is the slot, and this
--- is what that slot says. Mostly here for reading a style back in a test.
---@param slot number
---@return wonderland.StyleSlot
function style.at(slot)
	return arena[slot]
end

---@param value wonderland.StyleBuilder | wonderland.Style
---@return number # The slot
function style.intern(value)
	if getmetatable(value) == methods then
		-- A style written once and handed to every repaint is interned once: the builder
		-- knows what it last interned, and every call that fills a field in says so.
		local builder = value
		if builder.slotVersion == builder.version then
			return builder.slot
		end

		local slot = intern(builder.values)
		builder.slot, builder.slotVersion = slot, builder.version

		return slot
	end

	--- A table of fields written out by hand is interned as it is, every time: nothing
	--- tracks whether it changed, so nothing may assume it did not.
	---@cast value wonderland.Style
	return intern(value)
end

-- A style that names nothing, which is what an element with no style is read as. It is
-- the first thing interned, so it takes slot zero.
intern({})

return style
