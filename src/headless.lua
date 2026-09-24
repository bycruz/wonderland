-- A screen with no window behind it: the plugins are wired the same way, the render
-- plugin draws into an offscreen target instead of a swapchain, and events are handed
-- in by hand.
--
--   local screen = headless.new(function(window) return view end, { width = 800, height = 600 })
--   screen:draw()
--   screen:save("ui.png")
--
-- This is how a screen gets checked in a test, and how it gets rendered on a machine
-- with no display at all.
local Atlas = require("wonderland.font.stbtt")
local WindowPlugin = require("wonderland.plugin.window")
local RenderPlugin = require("wonderland.plugin.render")
local TextPlugin = require("wonderland.plugin.text")
local LayoutPlugin = require("wonderland.plugin.layout")
local UIPlugin = require("wonderland.plugin.ui")

-- The atlas holds one glyph per character, so a font is baked for printable ASCII.
local CHARACTERS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

local DEFAULT_PIXEL_HEIGHT = 18

--- The screen, as a function of the state it shows: this is what gets rendered.
---@alias wonderland.Headless.View fun(window: wonderland.RenderWindow): wonderland.Element

---@class wonderland.headless
---@field new fun(view: wonderland.Headless.View, opts: wonderland.Headless.Options): wonderland.Headless
local headless = {}

---@class wonderland.Headless.Options
---@field width number
---@field height number
---@field fontPath string? # A ttf or otf to rasterise the default font from
---@field onMessage fun(message: any)? # Called with every message the screen produces

---@class wonderland.Headless
---@field width number
---@field height number
---@field shouldRedraw boolean?
---@field window wonderland.RenderWindow # The stand-in the plugins lay out against
---@field plugins { window: wonderland.plugin.Window<any>, render: wonderland.plugin.Render, text: wonderland.plugin.Text, layout: wonderland.plugin.Layout<any>, ui: wonderland.plugin.UI }
---@field order wonderland.Plugin[] # The plugins, in the order an event goes down them
---@field handler winit.EventManager # What an event is handed with, which a screen with no loop does nothing with
---@field view wonderland.Headless.View
---@field onMessage fun(message: any)?
local Headless = {}
Headless.__index = Headless

---@param view wonderland.Headless.View
---@param opts wonderland.Headless.Options
---@return wonderland.Headless
function headless.new(view, opts)
	assert(view, "headless.new needs a view function")

	local self = setmetatable({
		width = opts.width,
		height = opts.height,
		view = view,
		onMessage = opts.onMessage,
		plugins = {},
	}, Headless)

	self.plugins.window = WindowPlugin.new({ type = "onWindowCreate" })
	self.plugins.render = RenderPlugin.new(self.plugins.window)
	self.plugins.text = TextPlugin.new(self.plugins.render)
	self.plugins.layout = LayoutPlugin.new(function(window)
		return self.view(window)
	end, self.plugins.text)
	self.plugins.ui = UIPlugin.new(self.plugins.layout, self.plugins.render)

	-- The same order the window shell asks the plugins in: an event goes down them, and the
	-- first message is the one the app hears, so a screen without a window behaves like one
	-- with. The layout is asked before the ui because it is the layout that knows where the
	-- pointer is, and a pointer that moved may be what a repaint is for.
	self.order = {
		self.plugins.window,
		self.plugins.render,
		self.plugins.text,
		self.plugins.layout,
		self.plugins.ui,
	}

	-- The window is only a size and a redraw flag: everything else a window offers is
	-- about being on screen, which this one is not. The plugins key their contexts on
	-- it, so it has to be the same table everywhere.
	self.window = { width = opts.width, height = opts.height, shouldRedraw = false }

	-- A window loop hands a handler to every event, and the plugins are written for one: a
	-- screen with no loop has none, so the events that would ask it for something do nothing.
	self.handler = {
		setMode = function() end,
		exit = function() end,
		close = function() end,
		requestRedraw = function() end,
	}
	self.plugins.render:registerHeadless(self.window)

	if opts.fontPath then
		local fontManager = assert(self.plugins.render.sharedResources).fontManager
		local atlas, err = Atlas.fromPath({ pixelHeight = DEFAULT_PIXEL_HEIGHT, characters = CHARACTERS },
			opts.fontPath)
		assert(atlas, err)

		fontManager:setDefault(fontManager:upload(atlas))
	end

	self.plugins.layout:register(self.window)

	return self
end

--- Solves the view again and draws it, so the offscreen target holds what a window
--- would be showing.
function Headless:draw()
	self.plugins.ui:refreshView(self.window)
	self.window.shouldRedraw = false

	local ctx = assert(self.plugins.render:getContext(self.window))
	self.plugins.render:draw(ctx)
end

--- The screen as RGBA with the top row first, which is what an image writer wants.
---@return string? pixels
---@return string? err
function Headless:getPixels()
	local ctx = assert(self.plugins.render:getContext(self.window))

	return self.plugins.render:getPixels(ctx)
end

---@param path string
---@return boolean? ok
---@return string? err
function Headless:save(path)
	local ctx = assert(self.plugins.render:getContext(self.window))

	return self.plugins.render:saveScreenshot(ctx, path)
end

--- Hands an event to the screen the way the window loop would, and passes whatever
--- message comes back to onMessage.
---@param event winit.Event
---@return any? message
function Headless:event(event)
	local message

	for _, plugin in ipairs(self.order) do
		if plugin.event then
			message = plugin:event(event, self.handler)

			if message then
				break
			end
		end
	end

	if message and self.onMessage then
		self.onMessage(message)
	end

	return message
end

--- Presses and releases the left button at a point, then draws again.
---@param x number
---@param y number
---@return any? message
function Headless:click(x, y)
	-- The events a window loop would hand over carry the window they happened in, and
	-- ours is the stand-in above: it is what the plugins key their contexts on.
	local window = self.window
	---@cast window winit.Window

	self:event({ name = "mousePress", window = window, x = x, y = y, button = 1 })
	local message = self:event({ name = "mouseRelease", window = window, x = x, y = y, button = 1 })

	self:draw()

	return message
end

function Headless:close()
	self.plugins.render:destroy(self.window)
end
return headless
