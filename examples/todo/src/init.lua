-- A todo list: rows you can tick off, a field to add one, and how many are left.
--
--   lde run            from this directory, or lde run examples/todo/src/init.lua
--
-- The window, the gpu, the font and the plugins behind it are what wonderland.app installs, so
-- what is here is the screen and what a message does to it. Type in the field and press return
-- to add; click a row to tick it off; click the x to remove it.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

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
local LIST = sty():column():wrel(1.0):h("auto"):gap(4)
local ROW = sty():row():wrel(1.0):h(36):gap(12):pad(0, 12):align("center"):bg("#1b2029")
local TICK = sty():size(18, 18):align("center"):justify("center"):bg("#242a35"):fg("#a8b2c4")
local LABEL = sty():w("auto")
local DONE = sty():w("auto"):fg("#5c6473")
local DELETE = sty():size(20, 20):align("center"):justify("center"):fg("#7d8697")
local FIELD = sty():row():wrel(1.0):h(40):pad(0, 12):align("center"):bg("#1b2029"):fg("#8d97a8")
local EMPTY = sty():w("auto"):fg("#5c6473")

---@class Todo
---@field id number
---@field text string
---@field done boolean

---@type wonderland.App<{ todos: Todo[], draft: string, nextId: number }>
local App = wonderland.app("Todos")

function App:init()
	self.todos = {
		{ id = 1, text = "click a row to tick it off", done = false },
		{ id = 2, text = "click the x to remove one", done = false },
		{ id = 3, text = "type below and press return", done = true },
	}
	self.draft = ""
	self.nextId = 4
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
				div():style(todo.done and DONE or LABEL):children(todo.text),
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

	if typed == "" then
		typed = "what needs doing?"
	end

	if focused then
		typed = typed .. "|"
	end

	return div():style(SCREEN):children(
		div():style(TITLE):children(
			div():style(HEADING):children("Todos"),
			div():style(COUNT):children(leftOver(self.todos))
		),
		div():style(LIST):children(children),
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
function App:update(message)
	local kind = type(message) == "table" and message.type

	if kind == "draft" then
		self.draft = message.value
	elseif kind == "add" then
		-- Whitespace is not a todo, and a todo is not whitespace around one.
		local text = message.value:match("^%s*(.-)%s*$")

		if text ~= "" then
			self.todos[#self.todos + 1] = { id = self.nextId, text = text, done = false }
			self.nextId = self.nextId + 1
			self.draft = ""
		end
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
end

App:run()
