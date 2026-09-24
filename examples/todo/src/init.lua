-- A todo list: rows you can tick off, a field to add one, and how many are left.
--
--   lde run            from this directory, or lde run examples/todo/src/init.lua
--
-- The window, the gpu, the font and the plugins behind it are what wonderland.app installs, so
-- what is here is the screen and what a message does to it. Type in the field and press return
-- to add; click a row to tick it off; click the x to remove it.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- Styles are values: written once and handed to everything that should look the same. Hover and
-- active are the colours an element already has, lit: `bright(1.25)` is lighter, `bright(0.6)`
-- is darker, and neither says anything about size or padding.
-- What an element is given by default is a full share of its parent, so anything that should be
-- its own size says so: a height, a width, or `"auto"` for what the others leave. This screen is
-- a column, which is why the title and the field name a height and the list takes the rest.
local SCREEN = sty():column():fill():pad(24):gap(10):bg("#12141c"):fg("#e8ecf4")
local TITLE = sty():row():wrel(1.0):h(28):justify("space-between"):align("center")
-- "auto" is what the others leave rather than as much as the text needs, so a row that spreads
-- its children gives them a size to spread with.
local HEADING = sty():w(140):fg("#ffffff")
local COUNT = sty():w(90):justify("end"):fg("#7d8697")
-- The pane: as wide as the window, as tall as the window leaves for it, and with a bar drawn down
-- the strip that width is taken from. The bar is its width, the least its thumb may be, and the
-- colour the thumb and the fainter track are drawn in. It appears when there is more to show than
-- fits, which is what "shows up" means. Its height is kept up to date rather than written every
-- frame, because a style is interned by what it says and the same one interned again is work for
-- nothing.
local PANE = sty():column():wrel(1.0):gap(4):bar(8, 24, "#4a6dbd")

-- What a row takes, and what the rest of the window takes. The pane is what the window leaves for
-- it, and how far the list can scroll is its content less the pane -- all of which is the app's to
-- work out, because the offset is state. The library clips the pane to itself and moves the
-- content; an app whose screen fits would not need any of this.
local ROW_STEP = 40
local CHROME = 136
-- A radius is how round the corners of a box are, in pixels, and it is cut where the box is drawn:
-- a row stays one quad whatever its corners do. A box cut by the pane it scrolls in keeps them --
-- only what is left of it is drawn, and where it was cut it is cut square.
local ROW = sty():row():wrel(1.0):h(36):gap(12):pad(0, 12):align("center"):bg("#1b2029"):radius(8)
local TICK = sty():size(18, 18):align("center"):justify("center"):bg("#242a35"):fg("#a8b2c4"):radius(5)
-- The line itself, not a box around it: a text element is as tall as the line it measured into,
-- so the row's `align` has something to centre. A box round it would be as tall as the row, and
-- the line would sit at the top of it.
local LABEL = sty():w("auto")
local DONE = sty():w("auto"):fg("#5c6473")
local DELETE = sty():size(20, 20):align("center"):justify("center"):fg("#7d8697")
-- A shadow is behind the box, offset from it and faded out over its blur: it is what makes the
-- field look like it is above the list rather than another row in it.
local FIELD = sty():row():wrel(1.0):h(40):pad(0, 12):align("center"):bg("#1b2029"):fg("#8d97a8"):radius(10):shadow(0, 3, 8, "#00000070")
local EMPTY = sty():w("auto"):fg("#5c6473")

---@class Todo
---@field id number
---@field text string
---@field done boolean

---@type wonderland.App<{ todos: Todo[], draft: string, nextId: number, offset: number, paneHeight: number }>
local App = wonderland.app("Todos")

function App:init()
	self.todos = {
		{ id = 1, text = "click a row to tick it off", done = false },
		{ id = 2, text = "click the x to remove one", done = false },
		{ id = 3, text = "type below and press return", done = true },
	}
	self.draft = ""
	self.nextId = 4
	self.offset = 0
	self.paneHeight = 0
end

--- The height of the pane, and how far the list can scroll inside it.
---@param window wonderland.RenderWindow
---@return number, number
local function extent(self, window)
	local height = math.max(ROW_STEP, window.height - CHROME)
	local content = #self.todos * ROW_STEP - (ROW_STEP - 36)

	return height, math.max(0, content - height)
end

---@param id number
---@return Todo?, number?
local function find(todos, id)
	for index, todo in ipairs(todos) do
		if todo.id == id then
			return todo, index
		end
	end
end

---@return string
local function leftOver(todos)
	local count = 0

	for _, todo in ipairs(todos) do
		if not todo.done then
			count = count + 1
		end
	end

	return count == 1 and "1 left" or count .. " left"
end

---@param window wonderland.RenderWindow
---@return wonderland.Element
function App:view(window)
	local height = extent(self, window)

	if self.paneHeight ~= height then
		self.paneHeight = height
		PANE:h(height)
	end

	local focused = App.layoutPlugin ~= nil and App.layoutPlugin:getFocusedId(window) == "new"
	local children = {}

	-- One row per todo. A row is a box with a handler on it, so clicking anywhere on it that is
	-- not the x ticks it off: the deepest element with a handler is the one that gets it.
	for _, todo in ipairs(self.todos) do
		local row = div()
			:style(ROW)
			:hover(sty():bright(1.25))
			:onClick({ type = "toggle", id = todo.id })
			:children(
				div():style(TICK):children(todo.done and "x" or ""),
				text(todo.text):style(todo.done and DONE or LABEL),
				div()
					:style(DELETE)
					:hover(sty():bright(1.8))
					:onClick({ type = "remove", id = todo.id })
					:children("x")
			)

		children[#children + 1] = row
	end

	if #self.todos == 0 then
		children[#children + 1] = div():style(EMPTY):children("nothing to do")
	end

	-- What has been typed, and a caret where the end of it is while the field has the keyboard.
	local typed = self.draft

	if typed == "" and not focused then
		typed = "what needs doing?"
	end

	return div():style(SCREEN):children(
		div():style(TITLE):children(
			div():style(HEADING):children("Todos"),
			div():style(COUNT):children(leftOver(self.todos))
		),
		div():style(PANE)
			:scroll(self.offset)
			:children(children)
			-- The wheel over the list, and the list's own bar being dragged, are one call: what a
			-- wheel asks for is a distance and what a bar asks for is a place, and one of the two
			-- is always nothing. The offset is this app's, so the app is what clamps it.
			:onScroll(function(by, to)
				if to then
					return { type = "scrollTo", to = to }
				end

				return { type = "scroll", by = (by or 0) * ROW_STEP }
			end),
		div()
			:style(FIELD)
			:input({
				name = "new",
				value = self.draft,
				oninput = |value| -> { type = "draft", value = value },
				onsubmit = |value| -> { type = "add", value = value },
			})
			:children(typed)
	)
end

---@param message any
---@param window wonderland.RenderWindow
function App:update(message, window)
	local kind = type(message) == "table" and message.type

	if kind == "draft" then
		self.draft = message.value
	elseif kind == "add" then
		-- Whitespace is not a todo, and a todo is not whitespace around one.
		local trimmed = message.value:match("^%s*(.-)%s*$")

		if trimmed ~= "" then
			self.todos[#self.todos + 1] = { id = self.nextId, text = trimmed, done = false }
			self.nextId = self.nextId + 1
			self.draft = ""
		end
	elseif kind == "scroll" then
		-- Clamped where it is changed. The library clamps what it draws, so a drifting offset
		-- still looks right -- but the app is the one holding it, and one let past the end of the
		-- list has to be scrolled all the way back before anything moves.
		local _, most = extent(self, window)

		self.offset = math.max(0, math.min(most, self.offset + message.by))
	elseif kind == "scrollTo" then
		-- Where the bar was dragged to, which is a place in the list rather than a distance.
		local _, most = extent(self, window)

		self.offset = math.max(0, math.min(most, message.to))
	elseif kind == "toggle" then
		local todo = find(self.todos, message.id)

		if todo then
			todo.done = not todo.done
		end
	elseif kind == "remove" then
		local _, index = find(self.todos, message.id)

		if index then
			table.remove(self.todos, index)
		end
	end

	-- The list may have lost its last row, and the pane does not scroll past what is left.
	local _, most = extent(self, window)

	if self.offset > most then
		self.offset = most
	end
end

App:run()
