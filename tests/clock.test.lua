-- The clock, and the work an app asks to be called back on: a decoder with a frame ready, a player
-- reading where it is, a screen pacing itself to something other than the display.
local test = require("lde-test")
local wonderland = require("wonderland")
local UI = require("wonderland.plugin.ui")
local time = require("wonderland.time")

test.it("answers seconds that do not go backwards", function()
	local first = time.now()
	local second = time.now()

	test.equal(type(first), "number")
	test.truthy(second >= first, "a moment after another is not before it")
	test.greater(first, 0, "and it is a time rather than nought")
end)

test.it("reads a clock finer than a second", function()
	local first = time.now()
	local sum = 0

	for index = 1, 100000 do
		sum = sum + index
	end

	local second = time.now()

	test.truthy(second - first < 0.5,
		string.format("a hundred thousand adds is not half a second, and this said %f", second - first))
	test.greater(sum, 0)
end)

-- The tick is what a screen with no event behind it does, so what it is given here is the least it
-- can be asked with: a context for a window, which is what says it is a screen at all.
---@return wonderland.plugin.UI, table, winit.EventManager, { waited: number? }
local function aTickingScreen()
	local window = {}

	---@cast window wonderland.RenderWindow
	local contexts = { [window] = { window = window } }
	---@type any
	local layoutPlugin = {
		contexts = contexts,
		keyRepeatInterval = 0,
		getCaret = function()
			return nil
		end,
	}
	---@type any
	local renderPlugin = {}
	local ui = UI.new(layoutPlugin, renderPlugin)
	local waits = {}

	local handler = {
		setTimeout = function(_, seconds)
			waits.waited = seconds
		end,
	}

	---@cast handler winit.EventManager
	return ui, window, handler, waits
end

---@param ui wonderland.plugin.UI
---@param window winit.Window
---@param handler winit.EventManager
local function tick(ui, window, handler)
	ui:tick(window, handler)
end

test.it("asks a callback it was given, and waits for the time it asked for", function()
	local ui, window, handler, waits = aTickingScreen()
	local calls = 0

	ui:onTick(function()
		calls = calls + 1

		return 0.25
	end)

	tick(ui, window, handler)

	test.equal(calls, 1, "it is asked on the tick after it was asked for")
	test.truthy(waits.waited ~= nil, "and the loop is told when to come back")
	-- What a deadline comes to is a difference of two doubles on a clock counting from some fixed
	-- point, so what it is compared against is near enough to read rather than exact.
	test.truthy(assert(waits.waited) < 0.250001, "which is no later than it asked for: " .. tostring(waits.waited))

	tick(ui, window, handler)

	test.equal(calls, 1, "and not again before the time it asked to be left alone for")
end)

test.it("stops asking a callback that answers nothing", function()
	local ui, window, handler, _ = aTickingScreen()
	local calls = 0

	ui:onTick(function()
		calls = calls + 1
	end)

	tick(ui, window, handler)
	tick(ui, window, handler)

	test.equal(calls, 1, "one turn is what a callback that wants no more gets")
	test.equal(#ui.tickers, 0, "and it is dropped rather than asked again")
end)

test.it("asks a callback that wants to go on as soon as the loop comes round", function()
	local ui, window, handler, waits = aTickingScreen()
	local calls = 0

	ui:onTick(function()
		calls = calls + 1

		return 0
	end)

	tick(ui, window, handler)
	tick(ui, window, handler)

	test.equal(calls, 2, "a decoder reading a burst of frames is asked every turn")
	test.equal(waits.waited, 0, "and the loop waits for nothing at all")
end)

test.it("waits for the first of several callbacks to be due", function()
	local ui, window, handler, waits = aTickingScreen()

	ui:onTick(function()
		return 1.0
	end)
	ui:onTick(function()
		return 0.1
	end)

	tick(ui, window, handler)

	test.truthy(assert(waits.waited) < 0.100001, "the soonest of them is what the loop is woken for")
end)

test.it("stops asking a callback that was cancelled", function()
	local ui, window, handler, _ = aTickingScreen()
	local calls = 0
	local ticker = ui:onTick(function()
		calls = calls + 1

		return 1.0
	end)

	ticker.cancel()
	tick(ui, window, handler)

	test.equal(calls, 0, "what was cancelled before its first turn is never asked")
	test.equal(#ui.tickers, 0)
end)

test.it("takes the window it is for from the first it is asked about", function()
	local ui, window, handler, _ = aTickingScreen()
	local windows = {}

	ui:onTick(function(_, asked)
		windows[#windows + 1] = asked

		return 1.0
	end)

	local other = {}
	---@cast other wonderland.RenderWindow
	ui.layoutPlugin.contexts[other] = { window = other }

	tick(ui, window, handler)
	tick(ui, other, handler)

	test.equal(#windows, 1, "a callback is for one window, and it is the one it was first asked about")
	test.equal(windows[1], window)
end)

test.it("asks for a frame now, rather than at the display's own rate", function()
	local ui, window, _, _ = aTickingScreen()

	ui:present(window)

	test.equal(window.shouldRedraw, true, "a frame is asked for with nothing in the way of it")
end)

test.it("does not ask for a frame when the callback is the screen's own business", function()
	local ui, window, handler, _ = aTickingScreen()

	ui:onTick(function()
		return 1.0
	end)

	tick(ui, window, handler)

	test.falsy(window.shouldRedraw, "whether a callback is worth a frame is the app's answer")
end)

test.it("registers an app's own work, which is what a screen is then asked about", function()
	---@type wonderland.App
	local app = wonderland.app("Clock")
	app:setup()

	local calls = 0

	app:every(0.1, function()
		calls = calls + 1
	end)

	local ui = app.uiPlugin

	test.truthy(ui ~= nil, "the plugins a screen needs are there to be asked")
	test.equal(#assert(ui).tickers, 1, "and the callback went to the screen")

	local window = {}
	---@cast window wonderland.RenderWindow
	assert(ui).layoutPlugin.contexts[window] = { window = window }

	local waits = {}
	assert(ui):tick(window, { setTimeout = function(_, seconds) waits.waited = seconds end })

	test.equal(calls, 1, "which asks it on its own clock")
	test.equal(window.shouldRedraw, true, "and asks for the frame its work is drawn in")
end)

test.it("keeps work registered before there is a screen to give it to", function()
	---@type wonderland.App
	local app = wonderland.app("Clock")
	local calls = 0

	-- What an app does in its own setup, which runs before any window exists: the callback is kept
	-- and handed to the screen when the screen is made.
	app:onTick(function()
		calls = calls + 1
	end)

	test.equal(#app.pendingTicks, 1, "the registration is kept")

	app:setup()

	test.equal(#app.pendingTicks, 0, "and handed over once there is a screen")
	test.equal(#assert(app.uiPlugin).tickers, 1)
	test.equal(calls, 0, "which does not ask it yet: that is the loop's own clock")
end)

test.it("does not hand over work that was cancelled before there was a screen", function()
	---@type wonderland.App
	local app = wonderland.app("Clock")
	local ticker = app:onTick(function() end)

	ticker.cancel()
	app:setup()

	test.equal(#assert(app.uiPlugin).tickers, 0)
end)
