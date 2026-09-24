-- The app shell: what an app defines, the plugins it is made of, and what a message does.
--
-- These are the parts that need no window: a plugin is added, an event goes down the plugins
-- in the order they were added, and what a message comes to is handed to the app.
local test = require("lde-test")
local wonderland = require("wonderland")

--- The handler the event loop hands an event over with, so an event can be sent by hand.
---@return winit.EventManager, { mode: string? }
local function handler()
	local seen = {}

	return {
		setMode = function(_, mode) seen.mode = mode end,
		exit = function() end,
		close = function() end,
	}, seen
end

---@param name string?
---@return winit.Event
local function anEvent(name)
	---@type winit.Event
	return { name = name or "resize" }
end

--- A window nothing is drawn in: these tests are about what a message does, not about what it
--- is drawn into.
---@return winit.Window
local function aWindow()
	local window = {}

	---@cast window winit.Window
	return window
end

--- A plugin of the smallest kind there is: it remembers the app it was added to, and answers
--- every event with the message it was made with.
---@param name string
---@param message any
---@return wonderland.Plugin, { app: wonderland.App?, event: string? }
local function plugin(name, message)
	local taken = {}

	return {
		name = name,
		build = function(_, app) taken.app = app end,
		event = function(_, event)
			taken.event = event.name
			return message
		end,
	}, taken
end

test.it("an app keeps its own state, which is what the generic names", function()
	---@type wonderland.App<{ clicks: number }>
	local app = wonderland.app("Wonderland")

	test.equal(app.title, "Wonderland")
	test.equal(#app.plugins, 0, "nothing is installed until it is run")
	test.falsy(app.init, "and nothing is set up until an app says so")

	local seen = 0
	app.init = function(self)
		self.clicks = 3
		seen = self.clicks
	end

	app:setup(nil)
	test.equal(seen, 3, "what init sets is set on the app")
end)

test.it("two apps are two apps: each has its own state, plugins and window", function()
	-- The state an app keeps is its own, so it is read back through the app's own calls.
	local pressed, otherPressed = nil, nil

	---@type wonderland.App<{ clicks: number }>
	local first = wonderland.app("first")

	first.init = function(self) self.clicks = 0 end
	first.press = function(self)
		self.clicks = self.clicks + 1
		pressed = self.clicks
	end

	---@type wonderland.App<{ clicks: number }>
	local second = wonderland.app("second")

	second.init = function(self) self.clicks = 0 end
	second.press = function(self)
		self.clicks = self.clicks + 1
		otherPressed = self.clicks
	end

	first:setup()
	second:setup(nil)

	first:press()
	test.equal(pressed, 1, "the first app counts its own presses")
	test.equal(otherPressed, nil, "and the second has not been pressed at all")

	second:press()
	test.equal(otherPressed, 1, "the second counts its own")
	test.equal(pressed, 1, "and the first is where it was")

	test.equal(first.title, "first")
	test.equal(second.title, "second")
	test.equal(#first.plugins, 5, "one has the plugins a screen needs")
	test.equal(#second.plugins, 0, "and the other was told it wants none")
	test.falsy(first.windowPlugin == second.windowPlugin, "no window, no renderer, nothing shared")
end)

test.it("the plugins a screen needs are installed by setup, in the order they hang off each other", function()
	local app = wonderland.app():setup()

	test.equal(#app.plugins, 5)
	test.equal(app.plugins[1].name, "window")
	test.equal(app.plugins[2].name, "render")
	test.equal(app.plugins[3].name, "text")
	test.equal(app.plugins[4].name, "layout")
	test.equal(app.plugins[5].name, "ui")
	test.equal(app:getPlugin("ui"), app.plugins[5])
	test.equal(app:getPlugin("nothing"), nil, "and one that is not there is nothing")
end)

test.it("a plugin is added after them, and told about the app", function()
	local mine, taken = plugin("mine")
	local app = wonderland.app():setup():plugin(mine)

	test.equal(#app.plugins, 6)
	test.equal(app.plugins[6], mine, "after the ones the shell installed")
	test.equal(taken.app, app)
end)

test.it("an app can say it wants none of them, and name its own", function()
	local mine = plugin("mine")
	local none = wonderland.app():setup(nil)
	local some = wonderland.app():setup(mine)

	test.equal(#none.plugins, 0, "nil names none of them")
	test.equal(#some.plugins, 1)
	test.equal(some.plugins[1], mine, "and a plugin names itself")
end)

test.it("init runs once the shell has filled the app's fields in", function()
	local seen = {}

	---@type wonderland.App<{ clicks: number }>
	local app = wonderland.app()
	app.init = function(self)
		seen.title = self.title
		seen.plugins = #self.plugins
		self.clicks = 7
		seen.clicks = self.clicks
	end

	app:setup()

	test.equal(seen.title, "Wonderland", "the shell's fields are there first")
	test.equal(seen.plugins, 5, "and so are its plugins")
	test.equal(seen.clicks, 7, "so what init sets is set on the app")
end)

test.it("an event goes down the plugins in order, and the first message is the one update gets", function()
	local first, firstTaken = plugin("first")
	local second, secondTaken = plugin("second", "from the second plugin")

	local app = wonderland.app():setup(first, second)
	local events, seen = handler()

	test.equal(app:dispatch(anEvent(), events), "from the second plugin")
	test.equal(firstTaken.event, "resize", "the first plugin was asked first, and said nothing")
	test.equal(secondTaken.event, "resize")
	test.equal(seen.mode, "wait", "and the loop is told to wait for the next event")
end)

test.it("the app's own event is handed what the plugins did not claim", function()
	local app = wonderland.app()
	local asked, seen = {}, {}

	app.event = function(_, event)
		seen[#seen + 1] = event.name
		return "mine"
	end

	app:setup({
		name = "keys",
		event = function(_, event)
			asked[#asked + 1] = event.name

			if event.name == "keyPress" then
				return "claimed"
			end
		end,
	})

	local events = handler()

	test.equal(app:dispatch(anEvent("keyPress"), events), "claimed", "a plugin claimed it, so the app is not asked")
	test.equal(#seen, 0)

	test.equal(app:dispatch(anEvent("resize"), events), "mine", "an event nothing claimed is the app's")
	test.equal(seen[1], "resize")
	test.equal(#asked, 2, "and the plugin was asked about both")
end)

test.it("a message is handed to the app, and what it returns is the task", function()
	local seen = {}

	local app = wonderland.app()
	app.update = function(_, message)
		seen[#seen + 1] = message
		return { type = "closeWindow" }
	end

	local task = app:handle("pressed", aWindow())

	test.equal(#seen, 1)
	test.equal(seen[1], "pressed")
	test.equal(task and task.type, "closeWindow")
end)

test.it("a view is empty until the app says what it looks like", function()
	local app = wonderland.app():setup(nil)

	---@diagnostic disable-next-line: param-type-mismatch
	test.equal(app:view(nil).childCount, 0)
end)
