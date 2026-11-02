-- A file tree: folders that open and shut, the file that is chosen shown beside them, a sidebar
-- that is dragged wider, and the keyboard to walk the tree with.
--
--   lde run examples/tree/src/init.lua
--
-- It is here because an outline of rows with one of them chosen is the shape most screens are made
-- of, and because a tree is where what wonderland gives and what an app does meet: the indentation
-- is padding, the chevron is a line of text, the chosen row is a background, how far the pane
-- scrolls is the app's, and the one thing that is not the app's is the width of the sidebar, which
-- is dragged -- see `:resize`, whose edge is grabbed inside the box it resizes.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- ────────────────────────────────────────────────────────────────
-- what it looks like
-- ────────────────────────────────────────────────────────────────

local SCREEN = sty():row():fill():bg("#0e1117"):fg("#c6cede")

-- The sidebar is as wide as the app says it is, and that one number is the style: a style is
-- interned by what it says, so the width is written again only when it changes -- writing it every
-- frame would intern the same style every frame for nothing.
--
-- The padding on the right is the strip the width is dragged by: the press is on the box's own edge
-- and the box is what is resized, so the strip is kept clear of what is inside it -- a pane that
-- scrolls draws its bar on its own right edge, and the bar is pressed before the edge is.
local SIDEBAR = sty():column():hrel(1.0):pad(0, 10, 0, 0):bg("#151a23")
local TREE = sty():column():fill():gap(2)
local PANE = sty():column():fill():pad(24):gap(8)

-- Lines of text and not boxes around them: a text element is as tall as the line it measured
-- into, while a box that names no height is as tall as what it was given -- a box round a line is
-- as tall as the pane, and the line after it is drawn on top of it.
local TITLE = sty():fg("#e6ecf7")
local LINE = sty():fg("#93a0b6")

local ROW_H = 22
local ROW_STEP = ROW_H + 2
local INDENT = 14

-- A row that is further in is the same row with more padding, and a row that is chosen is the same
-- row on a background: both are the row's box rather than its children's, so one style per depth is
-- what a screen of them needs -- written once and kept, since a new style every frame is a new style
-- interned every frame.
local ROWS, CHOSEN = {}, {}

---@param depth number
---@param chosen boolean
---@return wonderland.StyleBuilder
local function rowStyle(depth, chosen)
	local family = chosen and CHOSEN or ROWS
	local style = family[depth]

	if style == nil then
		style = sty():row():wrel(1.0):h(ROW_H):gap(6):align("center"):radius(6):pad(0, 6, 0, 6 + depth
			* INDENT)

		if chosen then
			style:bg("#26334e")
		end

		family[depth] = style
	end

	return style
end

-- What the pointer over a row does to it is light everything it is drawn with, which is one style
-- for every row at every depth: a hover style is only what it says, so the one it is over says
-- "brighter" and the row's own colours are what is lit.
local HOVER = sty():bright(1.4)

local CHEVRON = sty():w(12):justify("center"):fg("#7f8ca3")
local DIR_NAME = sty():w("auto"):ellipsis():fg("#dfe6f2")
local FILE_NAME = sty():w("auto"):ellipsis():fg("#a7b3c7")
local SIZE = sty():w(56):justify("end"):fg("#5b667a")

-- ────────────────────────────────────────────────────────────────
-- the tree
-- ────────────────────────────────────────────────────────────────

---@class Entry
---@field name string
---@field dir boolean
---@field open boolean? # Whether a folder's children are shown, which is the tree's own state
---@field children Entry[]?
---@field weight number? # Roughly how many kilobytes a file is, worked out when it was read

---@param name string
---@return Entry
local function file(name)
	-- What a file weighs is what it says on the right of its row, and a tree that shows one is the
	-- app's own arithmetic: a real one would ask the disk, once, when it read the folder.
	return { name = name, dir = false, weight = 1 + (#name * 37) % 400 }
end

---@param name string
---@param children Entry[]
---@param open boolean?
---@return Entry
local function folder(name, children, open)
	return { name = name, dir = true, open = open, children = children }
end

---@type Entry[]
local TREE_OF_FILES = {
	folder("src", {
		folder("font", { file("atlas.lua"), file("reader.lua"), file("font.lua") }),
		folder("plugin", { file("layout.lua"), file("ui.lua"), file("text.lua"), file("render.lua") }),
		file("element.lua"),
		file("style.lua"),
		file("layout.lua"),
	}, true),
	folder("examples", {
		folder("tree", { file("init.lua") }),
		file("todo.lua"),
	}, true),
	folder("tests", { file("headless.test.lua"), file("interaction.test.lua") }),
	file("README.md"),
	file("LICENSE"),
}

--- What a file says when it is chosen, which is not what a tree is about: what a file holds is the
--- app's, and this one holds no files at all -- the rows are a tree, and a tree is what a screen
--- built out of them looks like.
---@param entry Entry
local function bodyOf(entry)
	return {
		"-- " .. entry.name,
		"local wonderland = require(\"wonderland\")",
		"",
		"-- A tree is rows, and a row is a box: what is drawn here is what a folder holds, and",
		"-- what a file holds is what an app that reads files would show.",
		"return {}",
	}
end

-- ────────────────────────────────────────────────────────────────
-- the app
-- ────────────────────────────────────────────────────────────────

---@class TreeRow
---@field entry Entry
---@field depth number
---@field parent Entry?

---@class TreeMessage
---@field type string
---@field at number
---@field by number
---@field to number
---@field size number

---@class Tree: wonderland.App
---@field rows TreeRow[] # What the tree shows: every folder that is open and what is in it
---@field at number # Which of them is chosen, 0 for none
---@field width number # How wide the sidebar is, in pixels, as it was last dragged to
---@field offset number # And how far the rows are scrolled up inside it
---@field widthDrawn number # How wide the sidebar was when its style was last written, so that a
---                            frame that is not a resize writes nothing
local App = wonderland.app("Files")

function App:init()
	self.rows = {}
	self.at = 0
	self.width = 240
	self.offset = 0
	self.widthDrawn = 0
	self:flatten()
	self:choose(1)
end

--- The rows the tree shows, as the folders that are open and what is in them. It is worked out when
--- the tree changes rather than every frame, because which folders are open is state and not what a
--- frame looks like -- a screen of a hundred rows would otherwise walk the tree sixty times a second
--- to find out what it already knew.
---@param self Tree
function App:flatten()
	local rows = {}
	local chosen = self.rows[self.at] and self.rows[self.at].entry
	local at = 0

	---@param entries Entry[]
	---@param depth number
	---@param parent Entry?
	local function walk(entries, depth, parent)
		for _, entry in ipairs(entries) do
			rows[#rows + 1] = { entry = entry, depth = depth, parent = parent }

			if entry == chosen then
				at = #rows
			end

			if entry.dir and entry.open then
				walk(entry.children or {}, depth + 1, entry)
			end
		end
	end

	walk(TREE_OF_FILES, 0, nil)

	self.rows = rows
	self.at = at
end

--- Chooses a row, which is what a press on it does and what walking the tree with the keyboard
--- does: a folder that is chosen is not opened by being chosen, and a file that is chosen is what
--- the pane beside the tree shows.
---@param self Tree
---@param at number
function App:choose(at)
	if self.rows[at] == nil then
		return
	end

	self.at = at
end

--- The chosen row's entry, where there is one.
---@param self Tree
---@return Entry?
function App:chosen()
	---@type TreeRow[]
	local rows = self.rows
	local row = rows[self.at]

	return row and row.entry
end

--- How tall the tree's pane is: the sidebar is as tall as the window and the pane fills it, so
--- what the rows are scrolled inside is the window's own height. It is worked out here rather than
--- asked of the layout because what is scrolled where is state, and state is the app's.
---@param window wonderland.RenderWindow
local function paneHeight(window)
	return window.height
end

--- Keeps the chosen row inside the pane, which is what walking a tree with the keyboard needs and
--- what the library cannot do: the rows are the app's, so where they are is the app's.
---@param self Tree
---@param window wonderland.RenderWindow
function App:reveal(window)
	---@type TreeRow[]
	local rows = self.rows
	local row = rows[self.at]

	if row == nil then
		return
	end

	local top = (self.at - 1) * ROW_STEP
	local height = paneHeight(window)

	if top < self.offset then
		self.offset = top
	elseif top + ROW_H > self.offset + height then
		self.offset = top + ROW_H - height
	end
end

--- How far the rows can be scrolled, which is what is left of them past the pane.
---@param self Tree
---@param window wonderland.RenderWindow
---@return number
function App:most(window)
	return math.max(0, #self.rows * ROW_STEP - (ROW_STEP - ROW_H) - paneHeight(window))
end

function App:view(window)
	-- The width the sidebar was dragged to, written into the style it is drawn with -- and only when
	-- it is not the width the style already says.
	if self.widthDrawn ~= self.width then
		self.widthDrawn = self.width
		SIDEBAR:w(self.width)
	end

	local chosen = self:chosen()

	---@type TreeRow[]
	local rows = self.rows

	for at, row in ipairs(rows) do
		local entry = row.entry

		rows[at] = div()
			:style(rowStyle(row.depth, at == self.at))
			:hover(HOVER)
			:onClick({ type = "pick", at = at })
			:children({
				-- A chevron is a line of text like any other: the font has the two glyphs, and a row
				-- that is not a folder has nothing there rather than a second kind of row.
				div():style(CHEVRON):children(entry.dir and (entry.open and "▾" or "▸") or ""),
				text(entry.name):style(entry.dir and DIR_NAME or FILE_NAME),
				div():style(SIZE):children(entry.dir and (#(entry.children or {}) .. " items")
					or ((entry.weight or 0) .. " KB")),
			})
	end

	local lines = {}

	if chosen ~= nil and not chosen.dir then
		for index, line in ipairs(bodyOf(chosen)) do
			lines[index] = text(line):style(LINE)
		end
	end

	return div():style(SCREEN):children({
		-- The sidebar resizes by its right edge, which is grabbed inside it: what is reported is how
		-- wide the sidebar is asked to be, and it is the app that is that width -- the frame after
		-- the message is the one drawn at it.
		div():style(SIDEBAR)
			:resize({
				edge = "right",
				grab = 8,
				min = 160,
				max = 420,
				onchange = |size| -> { type = "resize", size = size },
			})
			:children(div():style(TREE)
				:scroll(self.offset)
				:children(rows)
				-- The wheel over the rows and the bar beside them are one call: what a wheel asks
				-- for is a distance and what a bar asks for is a place, and one of the two is always
				-- nothing.
				:onScroll(function(by, to)
					if to then
						return { type = "scrollTo", to = to }
					end

					return { type = "scroll", by = (by or 0) * ROW_STEP }
				end)),
		div():style(PANE):children({
			text(chosen ~= nil and chosen.name or "nothing chosen"):style(TITLE),
			div():style(sty():column():gap(2)):children(lines),
		}),
	})
end

--- What the keyboard does with the tree: the keys a tree is walked with, and nothing else -- a key
--- the app has no use for is no message at all, which is what leaves it to whatever else wants it.
function App:event(event)
	if event.name ~= "keyPress" then
		return nil
	end

	if event.key == "down" then
		return { type = "step", by = 1 }
	elseif event.key == "up" then
		return { type = "step", by = -1 }
	elseif event.key == "right" then
		return { type = "open" }
	elseif event.key == "left" then
		return { type = "shut" }
	elseif event.key == "return" or event.key == "space" then
		return { type = "use" }
	end
end

---@param message TreeMessage
function App:update(message, window)
	local kind = type(message) == "table" and message.type
	---@type TreeRow[]
	local rows = self.rows
	local row = rows[self.at]

	if kind == "pick" then
		-- A press takes the row it landed on and does what that row is for: a folder opens or shuts,
		-- and a file is what the pane beside the tree shows -- which it already is by being taken.
		self:choose(message.at)

		local picked = self.rows[self.at]

		if picked ~= nil and picked.entry.dir then
			picked.entry.open = not picked.entry.open
			self:flatten()
		end
	elseif kind == "step" then
		-- Walking the tree moves the choice and takes it as it goes, which is what a keyboard
		-- cursor in a tree is: what is chosen is where the keyboard is.
		local at = math.min(math.max(self.at + message.by, 1), #self.rows)

		self:choose(at)
	elseif kind == "open" then
		-- Right: a folder that is shut opens, a folder that is open steps into itself, and a file
		-- is already what is shown.
		if row ~= nil and row.entry.dir and not row.entry.open then
			row.entry.open = true
			self:flatten()
		else
			self:choose(math.min(self.at + 1, #self.rows))
		end
	elseif kind == "shut" then
		-- Left: a folder that is open shuts, and anything else steps back out to the folder it is
		-- in -- which is where a tree is walked from and to.
		if row ~= nil and row.entry.dir and row.entry.open then
			row.entry.open = false
			self:flatten()
		elseif row ~= nil and row.parent ~= nil then
			for at, other in ipairs(self.rows) do
				if other.entry == row.parent then
					self:choose(at)
					break
				end
			end
		end
	elseif kind == "use" then
		if row ~= nil and row.entry.dir then
			row.entry.open = not row.entry.open
			self:flatten()
		end
	elseif kind == "scroll" then
		self.offset = math.min(self:most(window), math.max(0, self.offset + message.by))
	elseif kind == "scrollTo" then
		self.offset = math.min(self:most(window), math.max(0, message.to))
	elseif kind == "resize" then
		self.width = message.size
	end

	-- The one the keyboard moved to may be past what the pane shows, and a tree the keyboard walks
	-- off the bottom of is a tree that is not being walked.
	if kind == "step" or kind == "open" or kind == "shut" or kind == "pick" then
		self:reveal(window)
	end

	local most = self:most(window)

	if self.offset > most then
		self.offset = most
	end
end

App:run()
