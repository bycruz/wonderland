-- What a screen is doing, drawn by the screen itself: the elements a frame was built from, the
-- layout they came out to, what a repaint costs, and the style of whatever the pointer is over.
--
--   local devtools = require("wonderland").devtools
--
--   App:plugin(devtools.new())        -- f12 shows it and hides it
--
-- Everything here is wonderland's own: the panels are elements, their text is text, the outlines
-- are a canvas, and what is shown of the app is the screen the app's own repaint solved. Nothing is
-- asked of the gpu, so a frame with the panel on is a frame and not a stall, which is what makes it
-- a thing an app can leave in while it is being written.
--
-- What it reads of the app is the frame before the one it is drawn in. A view is built before the
-- layout solves it, so the screen it walks is the last one solved: the numbers and the places are
-- the last frame's, and a window that has just changed size is shown at the size it was.
--
-- The elements a node came from are read out of the frame being built rather than the one walked,
-- because an element lives for one frame and a node remembers its place rather than itself. An app
-- whose view builds a different shape every frame is an app whose rows are the names of the
-- elements that were built in their places this frame, which in every screen that is not changing
-- under the pointer are the same ones.
local element = require("wonderland.element")
local time = require("wonderland.time")
local Quads = require("wonderland.util.quad_batch")
local style = require("wonderland.style")

local div, sty = element.div, element.sty

-- The key that shows and hides it, as winit names it: a function key, because an app's own screen
-- has nothing to do with one and a letter would be typed into whatever field is focused. The second
-- one is every box of the screen rather than the one being pointed at -- see `drawBounds`, which is
-- what the cost of a panel over a screen of a thousand elements is about.
local DEFAULT_KEY = "f12"
local DEFAULT_BOXES_KEY = "f11"

-- The rows of the tree that are drawn, and how far the picked row is kept from either end of them:
-- a screen with a thousand elements in it is a screen whose tree is looked at a row at a time, and
-- what is looked for is nearly always beside the node the pointer is on.
local ROWS = 12
local ABOVE = 4

local MARGIN = 8
local PANEL_W = 272
local PANEL_PAD = 7
local PANEL_BORDER = 1
local GAP = 1
local ROW_H = 16

-- How far a number in the panel has to move before the panel says it again: see `steady`.
local FPS_STEP = 5
local MS_STEP = 2
local MEMORY_STEP = 2

-- A panel: dark enough to be read over anything, and soft enough at the edge that what is under it
-- is still a screen rather than a hole.
--
-- One style a place rather than one style for the panel itself, because where a panel sits is part
-- of what a style says: a style shared by two of them is a style that puts both of them in one
-- place, and a builder written again every frame is a table a frame. These are moved by the frame
-- that draws them -- see `place` -- and a style that has not moved is a style interned as it is.
---@return wonderland.StyleBuilder
local function panelStyle()
	return sty():column():gap(GAP):pad(PANEL_PAD):radius(5):bg("#0b0d12fa"):fg("#c3cbdb")
		:border(PANEL_BORDER, "#2c3444"):z(1000)
end

local STATS = panelStyle()
local TREE = panelStyle()
local INSPECT = panelStyle()
-- A row is as tall as the panel says it is rather than as tall as what is in it: a box that names no
-- height is one that fills what holds it, so a panel of twenty rows of one line is twenty rows the
-- height of the whole panel without this -- which is what a panel with no room left in it looks
-- like. The height here and the height the panel is placed by are the one number.
local TITLE = sty():font("monospace"):text(12):weight("bold"):fg("#7fd4ff"):h(ROW_H)
local LINE = sty():font("monospace"):text(12):h(ROW_H)
local PICKED = sty():bg("#1d3a52"):fg("#eaf2ff"):radius(3):h(ROW_H)
local DIM = sty():fg("#7c8699"):h(ROW_H)
local BOUNDS = sty():fill():offset(0, 0):z(900)
local FULL = sty():fill():row():align("start"):justify("start")

-- The colours the boxes are outlined in, by how deep a node is: a screen is read by the eye
-- following the nesting, and two boxes at one depth are two boxes of one colour.
local DEPTH_COLOURS = {
	"#7fd4ff66",
	"#8affc066",
	"#ffd47966",
	"#ff8ab866",
	"#c0a0ff66",
}

---@class wonderland.Devtools.Options
---@field key string? # Which key shows it, "f12" by default
---@field boxesKey string? # And which key draws a box around every node, "f11" by default
---@field boxes boolean? # Whether every box starts drawn, which it does not
---@field on boolean? # Whether it starts shown: it does, which is why a plugin is added

---@class wonderland.Devtools.Node
---@field index number # Which node of the screen it is, by the place the screen keeps it in
---@field depth number
---@field x number # Where it came out, in the window
---@field y number
---@field node wonderland.Node

---@class wonderland.Devtools: wonderland.Plugin
---@field name string
---@field on boolean
---@field key string
---@field boxesKey string # Which key draws a box around every node rather than the one pointed at
---@field boxes boolean # Whether every box is being drawn, which is what a big screen pays for
---@field frameMs number # How long the last frame took to build and draw, in milliseconds
---@field took number? # And what the last few of those came to, which is what the panel shows
---@field fps number? # How many frames a second the last few came to, as they came out
---@field elements number # How many elements the app's own view built
---@field nodes number # And how many nodes the layout made of them
---@field picked number? # The node the pointer is over, which is what is being shown of it
---@field rows wonderland.Devtools.Node[] # The walk, as the rows this frame drew it from
---@field wrapper number? # The element the panel's own box is, which the app's root is told from
---@field wrapped fun(window: wonderland.RenderWindow): wonderland.Element? # What the layout builds its screen with, once it is the panel's
local Devtools = {}
Devtools.__index = Devtools

---@param opts wonderland.Devtools.Options?
---@return wonderland.Devtools
function Devtools.new(opts)
	opts = opts or {}

	return setmetatable({
		name = "devtools",
		key = opts.key or DEFAULT_KEY,
		boxesKey = opts.boxesKey or DEFAULT_BOXES_KEY,
		boxes = opts.boxes == true,
		on = opts.on ~= false,
		rows = {},
	}, Devtools)
end

-- ────────────────────────────────────────────────────────────────
-- what is read out of a node
-- ────────────────────────────────────────────────────────────────

--- A colour as the bytes a node keeps it in, which is what a stylesheet says as hex.
---@param r number
---@param g number
---@param b number
---@param a number
---@return string
local function hex(r, g, b, a)
	if a == 0 then
		return "none"
	end

	return string.format("#%02x%02x%02x%02x", r, g, b, a)
end

--- The four sides of a spacing, as the one thing a row of text has room for.
---@param top number
---@param right number
---@param bottom number
---@param left number
---@return string
local function box(top, right, bottom, left)
	if top == right and right == bottom and bottom == left then
		return tostring(top)
	end

	return string.format("%d %d %d %d", top, right, bottom, left)
end

--- How one value of a three way setting reads: what a row is aligned by, and which way a box stacks.
---@param value number
---@return string
local function placed(value)
	return value == 1 and "center" or (value == 2 and "end" or "start")
end

--- What a node is, as the one line a row of the tree has room for: the name it was given, else the
--- line it draws, else what it is made of.
---@param node wonderland.Node
---@return string
local function labelOf(node)
	local made = node.element ~= 0 and element.at(node.element) or nil

	if made ~= nil then
		local name = element.nameOf(made)

		if name ~= nil then
			return name
		end

		local line = element.textOf(made)

		if line ~= nil then
			line = line:gsub("%s+", " "):gsub("^%s+", "")

			if #line > 20 then
				line = line:sub(1, 19) .. "..."
			end

			return "\"" .. line .. "\""
		end

		local carried = element.dataOf(made)

		if type(carried) == "table" and carried.tag ~= nil then
			return tostring(carried.tag)
		end
	end

	if node.run ~= 0 then
		return "text"
	end

	-- Nothing named and nothing drawn: a box is what it is, and what it is known by is where it is
	-- in the tree rather than what it says.
	return node.paint ~= 0 and "box" or "div"
end

-- ────────────────────────────────────────────────────────────────
-- walking the app's screen
-- ────────────────────────────────────────────────────────────────

--- The app's own part of the screen, as rows: every node of it, in the order it is drawn, with how
--- deep it is and where it came out.
---
--- The panel's own box is the root of the screen while this is showing, and the app's tree is its
--- first child, so the walk starts at that child rather than at the root -- which is also what
--- leaves the panel out of what the panel is showing.
---@param self wonderland.Devtools
---@param screen wonderland.Layout.Screen
---@param index number
---@param depth number
---@param parentX number
---@param parentY number
local function collect(self, screen, index, depth, parentX, parentY)
	local node = screen:node(index)
	local x, y = parentX + node.x, parentY + node.y
	local count = self.nodes + 1

	self.nodes = count

	-- The rows are kept from frame to frame rather than made again: a panel is drawn over every
	-- repaint of the app it is over, and a table a node of it would be a table a frame.
	local row = self.rows[count]

	if row == nil then
		row = {}
		self.rows[count] = row
	end

	row.index, row.depth, row.x, row.y, row.node = index, depth, x, y, node

	for at = 0, node.childCount - 1 do
		collect(self, screen, screen.childIndices[node.firstChild + at - 1], depth + 1, x, y)
	end
end

--- The innermost node of the app whose box the pointer is inside: what a click would land on if
--- nothing about it were asked for, which is what an app is looking at when it asks why the thing
--- it is pointing at is not the thing it means.
---@param screen wonderland.Layout.Screen
---@param index number
---@param x number
---@param y number
---@param parentX number
---@param parentY number
---@return number? picked
local function pick(screen, index, x, y, parentX, parentY)
	local node = screen:node(index)
	local absX, absY = parentX + node.x, parentY + node.y

	-- Backwards, so that the last of two boxes at one place is the one a draw would have over the
	-- other: what is picked is what is on top rather than what was built first.
	for at = node.childCount - 1, 0, -1 do
		local found = pick(screen, screen.childIndices[node.firstChild + at - 1], x, y, absX, absY)

		if found ~= nil then
			return found
		end
	end

	if x >= absX and x <= absX + node.width and y >= absY and y <= absY + node.height then
		return index
	end
end

--- Where the app's own tree begins, given the screen the last frame solved: the root itself, or its
--- first child when the root is the panel's own box. Which of the two it is is told by the element
--- the root was built from, since the panel's box is built after every element of the app's.
---@param self wonderland.Devtools
---@param screen wonderland.Layout.Screen
---@param root number
---@return number
local function appRootOf(self, screen, root)
	local node = screen:node(root)

	if self.wrapper ~= nil and node.element == self.wrapper and node.childCount > 0 then
		-- The run a node's children are kept in starts at the place the node says, counted from one,
		-- and the array is counted from nought: see `Screen:child`.
		return screen.childIndices[node.firstChild - 1]
	end

	return root
end

-- ────────────────────────────────────────────────────────────────
-- what is drawn
-- ────────────────────────────────────────────────────────────────

--- The box of every node of the app, over it: what the layout came out to, as places rather than as
--- something to read.
---@param self wonderland.Devtools
---@param canvas wonderland.Canvas
--- The box of the node the pointer is over, and -- where they are asked for -- of every node of the
--- app: what the layout came out to, as places rather than as something to read.
---
--- The one box is what the panel costs by default, and the cost of the other is why: a box is four
--- lines, the lines of a wide one are as wide as the window, and a screen of a thousand elements is
--- four thousand of them over the screen of every frame -- which is the panel being slower than the
--- app it is over rather than a panel that is being looked at. A box a frame is one the pointer
--- moved to, and one frame of that is a panel that follows the pointer rather than queues behind it.
---@param self wonderland.Devtools
---@param canvas wonderland.Canvas
local function drawBounds(self, canvas)
	for _, row in ipairs(self.rows) do
		local node = row.node
		local picked = row.index == self.picked

		if node.width > 0 and node.height > 0 and (picked or self.boxes) then
			local colour = picked and "#ffd479cc" or DEPTH_COLOURS[row.depth % #DEPTH_COLOURS + 1]
			local right, bottom = row.x + node.width, row.y + node.height

			canvas:line(row.x, row.y, right, row.y, 1, colour)
			canvas:line(row.x, bottom, right, bottom, 1, colour)
			canvas:line(row.x, row.y, row.x, bottom, 1, colour)
			canvas:line(right, row.y, right, bottom, 1, colour)

			-- What the box left for its contents, which is the half of a layout that the box itself
			-- does not show: what any child of it was given to draw in.
			if picked and node.paddingTop + node.paddingBottom + node.paddingLeft + node.paddingRight > 0 then
				local left, top = row.x + node.paddingLeft, row.y + node.paddingTop

				canvas:line(left, top, right - node.paddingRight, top, 1, "#ff8ab899")
				canvas:line(left, bottom - node.paddingBottom, right - node.paddingRight,
					bottom - node.paddingBottom, 1, "#ff8ab899")
			end
		end
	end
end

--- A panel, as the box a list of rows is put in: the style is the one of the three places it sits
--- in, which is where and how big it is as well as how it looks.
---@param style wonderland.StyleBuilder
---@param rows string[]
---@param picked number? # Which row is the one being pointed at, where one of them is
---@return wonderland.Element
local function panel(style, rows, picked)
	---@type wonderland.Element[]
	local lines = {}

	for at, line in ipairs(rows) do
		lines[at] = div():style(at == picked and PICKED or (at == 1 and TITLE or LINE)):children(line)
	end

	return div():style(style):children(lines)
end

--- What a list of rows comes to on screen, which is what the panel under it is placed by.
---@param rows string[]
---@return number
local function panelHeight(rows)
	-- The border is inside the box the row heights are added to, so it is a part of the height that
	-- is not a row: a panel without it here is a panel whose last row is two pixels into its edge.
	return #rows * ROW_H + math.max(#rows - 1, 0) * GAP + PANEL_PAD * 2 + PANEL_BORDER * 2
end

--- A number as it is shown: what it was last shown as, unless it has moved far enough to be worth
--- saying again.
---
--- What a panel costs the app it is over is a frame every time one of its numbers changes -- see
--- `statsRows` -- so a number that does not matter is a number that says the same thing until it is
--- a different number rather than nearly the same one. Rounding alone does not do that: an average
--- that sits on the rounding is a number that flips between two of them, which is a frame an app
--- pays for out of a digit.
---@param shown number? # What it was shown as, where it has been shown at all
---@param value number # What it is now
---@param step number # How far it has to move to be worth showing again
---@return number
local function steady(shown, value, step)
	if shown == nil or math.abs(value - shown) >= step then
		return value
	end

	return shown
end

--- What a repaint comes to, as the numbers that say whether a screen is worth what it costs.
---
--- What a frame came to is the frame before this one, because a frame's numbers are written when it
--- is handed over and the screen of the next one is built before that: what the panel shows is the
--- last frame that went out, which is the one an app being looked at is being asked about.
---
--- The numbers are held still on purpose. What a panel is drawn in is the screen it is over, and a
--- screen whose frame comes out the same as the last one is one nothing is drawn for: a panel that
--- says "0.42 ms" on one frame and "0.41" on the next is a panel that makes every repaint a frame of
--- its own -- an upload, a submit and a wait for the display, for a pointer that moved and nothing
--- that changed. A rate read to five, a frame to a couple of milliseconds and lua to a couple of
--- megabytes is a panel that says the same thing as long as the app is doing the same thing, and
--- says it again when it is not -- which is what an app that repaints on every pointer event needs.
---@param self wonderland.Devtools
---@param window wonderland.RenderWindow
---@return string[]
local function statsRows(self, window)
	local render = self.renderPlugin and self.renderPlugin:getContext(window) or nil
	local quads = render and render.quads or 0
	local runs = render and render.runCount or 0

	self.quads, self.runs = quads, runs
	self.shownFps = steady(self.shownFps, self.fps or 0, FPS_STEP)
	self.shownMs = steady(self.shownMs, self.took or 0, MS_STEP)
	self.shownMemory = steady(self.shownMemory, collectgarbage("count") / 1024, MEMORY_STEP)

	return {
		string.format("%s   boxes %s", self.on and "hide " .. self.key or "show " .. self.key,
			self.boxes and "on " .. self.boxesKey or self.boxesKey),
		string.format("%.0f fps   %.0f ms", self.shownFps, self.shownMs),
		string.format("elements %d   nodes %d   styles %d", self.elements, self.nodes, style.count()),
		string.format("quads %d   runs %d", quads, runs),
		string.format("instances %.0f KB   lua %.0f MB", quads * Quads.INSTANCE_SIZE / 1024,
			self.shownMemory),
	}
end

--- The node the pointer is over, as what it is and everything the layout gave it: the style that
--- came out of the cascade rather than the one the app wrote, which is what the two are told apart
--- by when a box is not the size its own call says it is.
---@param self wonderland.Devtools
---@return string[]
local function styleRows(self)
	local found = nil

	for _, row in ipairs(self.rows) do
		if row.index == self.picked then
			found = row
			break
		end
	end

	if found == nil then
		return { "pointer", "nothing under it" }
	end

	local node = found.node
	local what = node.paint ~= 0 and "box" or ""

	if node.run ~= 0 then
		what = what .. "text"
	end

	if what == "" then
		-- A box that paints nothing of its own and draws no line of its own is one that only holds
		-- others: the layout it came out to is the whole of what it is, which is what a row is.
		what = "container"
	end

	return {
		"pointer   " .. labelOf(node),
		string.format("%s   %dx%d   at %d,%d   z%d", what, node.width, node.height, found.x, found.y,
			node.zIndex),
		string.format("pad %s   margin %s   gap %d", box(node.paddingTop, node.paddingRight,
			node.paddingBottom, node.paddingLeft), box(node.marginTop, node.marginRight,
			node.marginBottom, node.marginLeft), node.gap),
		string.format("%s   align %s   justify %s   %s", node.direction == 0 and "row" or "column",
			placed(node.align), placed(node.justify), node.position == 1 and "offset" or "in flow"),
		string.format("bg %s   fg %s", hex(node.bgR, node.bgG, node.bgB, node.bgA),
			hex(node.fgR, node.fgG, node.fgB, node.fgA)),
		string.format("border %s   radius %.0f   blur %.0f", hex(node.borderR, node.borderG,
			node.borderB, node.borderA), node.radius, node.blur),
		string.format("shadow %d,%d %.0f   texture %d   scroll %.0f", node.shadowX, node.shadowY,
			node.shadowBlur, node.texture, node.scroll),
		string.format("%s%s   paint %s   visible %s", node.scrolls ~= 0 and "clipping" or "static",
			node.thumb ~= 0 and " thumb" or "", node.paint ~= 0 and "yes" or "no",
			node.visible ~= 0 and "yes" or "no"),
	}
end

--- The app's own tree, as rows of it: what was built, how big it came out, and where it landed.
---
--- The rows shown are the ones around the picked node, so that a screen of a thousand elements shows
--- the part of itself the pointer is in rather than its first twenty nodes, and a picked row is kept
--- down the panel rather than at its top: what is beside a node is what a tree is read for, and most
--- of a hand's reach is above the row it is pointing at.
---@param self wonderland.Devtools
---@param fits number # How many rows the room the panel has takes
---@return string[]
---@return number? # Which of the rows is the picked one, where it is one of them
local function treeRows(self, fits)
	local rows, count = self.rows, self.nodes
	local first, picked = 1, nil

	for at = 1, count do
		if rows[at].index == self.picked then
			first = math.max(1, math.min(at - ABOVE, count - fits + 1))
			break
		end
	end

	---@type string[]
	local lines = {}

	for at = first, math.min(first + fits - 1, count) do
		local row = rows[at]

		if row.index == self.picked then
			picked = #lines + 1
		end

		lines[#lines + 1] = string.format("%s%s  %dx%d", string.rep(" ", row.depth * 2),
			labelOf(row.node), row.node.width, row.node.height)
	end

	if #lines == 0 then
		lines[1] = "no screen yet"
	end

	return lines, picked
end

--- Everything the panel is, over the app's own screen: the boxes it came out to, the numbers, the
--- tree, and the style of whatever the pointer is on.
---@param self wonderland.Devtools
---@param window wonderland.RenderWindow
---@param tree wonderland.Element?
---@return wonderland.Element?
function Devtools:overlay(window, tree)
	self:resolve()

	local layout = self.layoutPlugin
	local ctx = layout and layout.contexts[window] or nil
	local screen = ctx and ctx.screen or nil
	local root = ctx and ctx.root or nil

	if not self.on or screen == nil or root == nil then
		return tree
	end

	self.nodes = 0

	local appRoot = appRootOf(self, screen, root)

	collect(self, screen, appRoot, 0, 0, 0)

	if ctx.pointer ~= nil then
		-- What the pointer is over, kept from the last frame that had it over something: a panel is
		-- read by pointing at a box and then looking at what it says, and a pointer that has to leave
		-- the box to be read of it is one the panel would be forgetting what it was asked.
		local over = pick(screen, appRoot, ctx.pointer.x, ctx.pointer.y, 0, 0)

		self.picked = over or self.picked
	end

	-- The rate frames are coming at, measured between the frames this panel is built in: a screen
	-- built on demand has no rate of its own while nothing is happening, and the last one it had is
	-- what it is shown with -- which is what a still screen is, and not a screen that is slow.
	local framedAt = ctx.framedAt

	if framedAt ~= nil and self.framedAt ~= nil and framedAt > self.framedAt then
		local rate = 1 / (framedAt - self.framedAt)

		self.fps = self.fps and self.fps * 0.8 + rate * 0.2 or rate
	end

	if framedAt ~= nil then
		self.framedAt = framedAt
	end

	-- And what a frame comes to, smoothed the way the rate is: one frame that took longer than the
	-- rest is not what a screen costs, and a number that answers differently every frame is one the
	-- panel would redraw the app for. See `statsRows`.
	local took = self.frameMs or self.buildMs

	if took ~= nil then
		self.took = self.took and self.took * 0.8 + took * 0.2 or took
	end

	-- The numbers of a frame are written after its screen is built, so a panel drawn in the first
	-- frame of a window is a panel of a frame that has not been handed over yet, and the numbers it
	-- read are nought. One more frame is asked for, which is the one that has them: it is asked for
	-- once, because what a frame came to does not change by being asked for again.
	if ctx.uploaded ~= true then
		self:selfPresent(window)
	end

	-- The size the screen was solved at rather than the size the window says it is, which is what
	-- the places the panel is drawing at are in: see `wonderland.plugin.Render:size`, which is what
	-- the layout solved against as well.
	local width, height = 0, 0

	if self.renderPlugin ~= nil then
		width, height = self.renderPlugin:size(window)
	else
		width, height = window.width or 0, window.height or 0
	end

	local stats = statsRows(self, window)
	local style = styleRows(self)
	local statsHeight = panelHeight(stats)
	local styleHeight = panelHeight(style)
	local treeY = MARGIN + statsHeight + MARGIN
	local room = math.max(ROW_H + PANEL_PAD * 2, height - treeY - styleHeight - MARGIN * 2)
	local fits = math.max(1, math.min(ROWS, math.floor((room - PANEL_PAD * 2 + GAP) / (ROW_H + GAP))))
	local treeLines, pickedRow = treeRows(self, fits)
	local inspectY = math.max(treeY, height - styleHeight - MARGIN)

	-- Where each of them sits, which is the one thing about a panel that changes with the window:
	-- a style that says the same thing as it did last frame is interned as it is and costs a hash.
	STATS:offset(MARGIN, MARGIN):size(PANEL_W, statsHeight)
	TREE:offset(MARGIN, treeY):size(PANEL_W, panelHeight(treeLines))
	INSPECT:offset(MARGIN, inspectY):size(PANEL_W, styleHeight)

	-- The box is made before what it holds, which is what says which element of the frame it is:
	-- everything the app's view made was made before it, and every panel of it is made after.
	local box = div()

	self.wrapper = element.count()

	box:style(FULL):children({
		tree,
		-- What a canvas is drawn with is handed the canvas alone, and what it draws is this panel's
		-- own walk of the app: the one closure a frame, over whatever the walk found.
		div():style(BOUNDS):canvas(function(canvas) drawBounds(self, canvas) end),
		panel(STATS, stats),
		panel(TREE, treeLines, pickedRow),
		panel(INSPECT, style),
	})

	return box
end

-- ────────────────────────────────────────────────────────────────
-- the plugin
-- ────────────────────────────────────────────────────────────────

--- The plugins the panel reads: the layout, for the screen the app came out to, the renderer, for
--- what a repaint cost, and the ui, for a frame asked for now -- and the view the layout builds that
--- screen with, which is where the panel puts itself.
---
--- Asked for again rather than kept from `build`, because an app adds its own plugins before the
--- shell adds the ones a screen is made of: `App:plugin(devtools.new())` is written before
--- `App:run()`, and the layout it reads does not exist yet. It is a walk of a handful of plugins
--- until the first frame, and of nothing at all after it.
function Devtools:resolve()
	local app = self.app

	if app ~= nil and app.getPlugin ~= nil then
		self.layoutPlugin = self.layoutPlugin or app:getPlugin("layout")
		self.renderPlugin = self.renderPlugin or app:getPlugin("render")
		self.uiPlugin = self.uiPlugin or app:getPlugin("ui")
	end

	local layout = self.layoutPlugin

	if layout == nil or layout.view == nil or layout.view == self.wrapped then
		return
	end

	-- The view the layout is wired with is wrapped rather than the app's own, because the app's own
	-- is a field of the app: an app writes `function App:view()` -- on the table the panel was
	-- handed as an app -- and one written after the panel was added would be written over the panel
	-- rather than beside it. What the layout holds is the shell's own function, which asks the app
	-- for its view every frame, so wrapping it is the one place the app cannot overwrite and the
	-- one place a view written later is still read from.
	local inner = layout.view

	self.wrapped = function(window)
		local started = time.now()
		local built = inner(window)

		-- Everything the app's view made, which is what the panel's own elements are told from:
		-- they are made from here on, and a node made after this is one of theirs.
		self.elements = element.count()

		local box = self:overlay(window, built)

		self.buildMs = (time.now() - started) * 1000

		return box
	end

	layout.view = self.wrapped

	-- What a frame costs, which is the one number a screen cannot read out of itself: it is timed
	-- around the frame the ui builds and hands over, since that is where the screen is walked, its
	-- lines measured and its quads uploaded. The ui's own call is wrapped rather than the app's,
	-- because an app writes its calls as fields of the app the panel was handed, and one written
	-- after the panel was added would be written over it.
	local ui = self.uiPlugin

	if ui ~= nil and ui.frame ~= nil and self.framedUi ~= ui then
		local frame = ui.frame

		self.framedUi = ui

		---@param this wonderland.plugin.UI
		---@param window wonderland.RenderWindow
		ui.frame = function(this, window)
			local started = time.now()

			frame(this, window)

			self.frameMs = (time.now() - started) * 1000
		end
	end
end

---@param app wonderland.App
function Devtools:build(app)
	self.app = app
	self:resolve()
end

--- A frame asked for now: what showing and hiding the panel is, since the screen the app's own
--- events would ask for is the screen the panel was not in.
---@param window winit.Window?
function Devtools:selfPresent(window)
	self:resolve()

	local ui = self.uiPlugin

	if ui ~= nil and window ~= nil then
		---@cast window wonderland.RenderWindow
		ui:present(window)
	end
end

---@param event winit.Event
---@param handler winit.EventManager
function Devtools:event(event, handler)
	self:resolve()

	-- The names are winit's own, which is what the shell hands down: a key is a `keyPress`, since
	-- what a keyboard says is a press and a release rather than the down and up of a button.
	--
	-- The resolve above is what has the panel in place before the first frame of a window: what a
	-- window being made comes to is an event, and the screen is registered with it after the events
	-- of it have gone down the plugins.
	--
	-- Nothing is asked for on a pointer moving, though what the panel says of the pointer changes as
	-- it does. A screen is built for a move either way -- the ui asks for one, because where the
	-- pointer is is what a hover style and a press are about -- and the panel is part of that
	-- screen: what comes of the move is in the frame that was already coming. A frame asked for
	-- *per move* is one the display has not shown yet when the next move arrives, so each of them
	-- waits for the one before it and the panel falls further behind the pointer the faster it is
	-- dragged -- which is what asking for a frame nothing else wanted costs.
	if event.name == "keyPress" and event.key == self.key then
		self.on = not self.on

		self:selfPresent(event.window)
	elseif event.name == "keyPress" and event.key == self.boxesKey then
		self.boxes = not self.boxes

		self:selfPresent(event.window)
	end
end

--- `wonderland.devtools`: a plugin, because what it shows is a screen, and a screen is what the
--- plugins make of an app.
return {
	new = Devtools.new,
}
