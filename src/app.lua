-- The app: the class an application is. The plugins a screen needs are already in it, so an
-- app says what its screen looks like and what a message does, and nothing else.
--
--   ---@class State
--   ---@field clicks number
--
--   ---@type State
--   local state = { clicks = 0 }
--
--   local App = wonderland.app("Wonderland")
--
--   function App:init() state.clicks = 0 end
--   function App:view() return div():style(SCREEN) end
--   function App:update(message) ... end
--
--   App:run()
--
-- The calls an app may define are the ones the shell makes -- `init`, `view`, `update` and
-- `event` -- and one it leaves out is simply not made. What the app knows about itself it
-- keeps beside it, in a table of its own: `self` is the app, and the fields an app puts on a
-- library type are fields the language server cannot check.
local winit = require("winit")
local Atlas = require("wonderland.font.stbtt")
local WindowPlugin = require("wonderland.plugin.window")
local RenderPlugin = require("wonderland.plugin.render")
local TextPlugin = require("wonderland.plugin.text")
local LayoutPlugin = require("wonderland.plugin.layout")
local UIPlugin = require("wonderland.plugin.ui")

local app = {}

--- What update is told when a window has been made. The plugins are attached to that window
--- before the app hears about it, so anything the app does with this message has a screen to
--- do it on.
---@type { type: "windowCreated" }
local WINDOW_CREATED = { type = "windowCreated" }

--- A window the shell created. winit owns the underlying window; `kind` is an
--- application-defined tag so an app can tell its own windows apart.
---@class wonderland.Window: winit.Window
---@field kind string? # Application-defined tag from the createWindow task

---@alias wonderland.Task
--- | { type: "createWindow", width: number?, height: number?, kind: string? }
--- | { type: "closeWindow" }

--- Something that adds itself to an app. It is handed the app when it is added, and asked for
--- a message on every event, in the order the plugins were added: the first one to return a
--- message is the one update hears from.
---@class wonderland.Plugin
---@field name string? # For an app that wants to find it again
---@field build (fun(self: wonderland.Plugin, app: wonderland.App): any?)? # Called when it is added
---@field event (fun(self: wonderland.Plugin, event: winit.Event, handler: winit.EventManager): any?)?

--- An application. `Extra` is what the app keeps on itself, so an app that has state says
--- what it is and `self` is then typed:
---
---   ---@type wonderland.App<{ clicks: number }>
---   local App = wonderland.app("Wonderland")
---
---   function App:init() self.clicks = 0 end
---
--- What an app keeps on itself is what the generic names: an app's own fields are the app's
--- own typing, and each `wonderland.app()` call is its own app, so two apps keep two of
--- everything. The four calls an app may define are fields here rather than methods, so
--- defining one is a definition of something the shell looks for.
---@class wonderland.App<Extra>: Extra
---@field title string
---@field font string? # A ttf to draw text with: the first one this machine is likely to have, otherwise
---@field pixelHeight number # How tall the font is baked
---@field characters string # And what it is baked for
---@field plugins wonderland.Plugin[] # In the order they were added
---@field init (fun(self: wonderland.App): any?)? # Once the shell has filled the app in
---@field view (fun(self: wonderland.App, window: wonderland.RenderWindow): wonderland.Element)? # What the screen looks like
---@field update (fun(self: wonderland.App, message: any, window: winit.Window): wonderland.Task?)? # What a message does
---@field event (fun(self: wonderland.App, event: winit.Event, handler: winit.EventManager): any?)? # Events no plugin claimed
---@field private installed boolean
-- The plugins the shell installed, kept as typed fields rather than looked up by name. They
-- are the shell's own: an app that wants one asks for it with `getPlugin`.
---@field windowPlugin wonderland.plugin.Window?
---@field renderPlugin wonderland.plugin.Render?
---@field textPlugin wonderland.plugin.Text?
---@field layoutPlugin wonderland.plugin.Layout?
---@field uiPlugin wonderland.plugin.UI?
local App = {}
App.__index = App

--- An app with the plugins a screen needs, which are installed when it is run: what they are
--- is not something an app has to think about.
---@generic Extra
---@param title string?
---@return wonderland.App<Extra>
function app.new(title)
	return setmetatable({
		title = title or "Wonderland",
		font = Atlas.find(),
		pixelHeight = 18,
		characters = Atlas.ASCII,
		plugins = {},
	}, App)
end

--- Adds a plugin, after everything already in the app: it is the app's own, so it is asked
--- for a message after the ones the shell installed.
---@param plugin wonderland.Plugin
---@return wonderland.App
function App:plugin(plugin)
	self.plugins[#self.plugins + 1] = plugin

	if plugin.build then
		plugin:build(self)
	end

	return self
end

---@param name string
---@return wonderland.Plugin?
function App:getPlugin(name)
	for _, plugin in ipairs(self.plugins) do
		if plugin.name == name then
			return plugin
		end
	end
end

-- The screen, as the plugins it is made of. Each is handed the one before it, because the
-- window owns the gpu instance, the renderer owns the device, text is measured into that, the
-- layout needs the text, and the ui is the layout's quads in the renderer.
---@param self wonderland.App
local function screenPlugins(self)
	self.windowPlugin = WindowPlugin.new(WINDOW_CREATED)
	self.renderPlugin = RenderPlugin.new(self.windowPlugin)
	self.textPlugin = TextPlugin.new(self.renderPlugin)
	self.layoutPlugin = LayoutPlugin.new(function(w) return self:view(w) end, self.textPlugin)
	self.uiPlugin = UIPlugin.new(self.layoutPlugin, self.renderPlugin)

	-- Named as well, so an app that wants the renderer, or to replace one of these, can ask
	-- for it by name.
	self.windowPlugin.name, self.renderPlugin.name = "window", "render"
	self.textPlugin.name, self.layoutPlugin.name, self.uiPlugin.name = "text", "layout", "ui"
end

--- Everything a screen needs, before the event loop starts: the plugins, and then the app's
--- own `init`, once the shell has filled its fields in. `run` does this; it is here for an app
--- that wants the plugins and no loop, and for a test.
---@param ... wonderland.Plugin? # The plugins to run: none of them names the defaults, nil names none
---@return wonderland.App
function App:setup(...)
	if self.installed then
		return self
	end

	self.installed = true

	if select("#", ...) == 0 then
		screenPlugins(self)

		self:plugin(assert(self.windowPlugin))
		self:plugin(assert(self.renderPlugin))
		self:plugin(assert(self.textPlugin))
		self:plugin(assert(self.layoutPlugin))
		self:plugin(assert(self.uiPlugin))
	else
		for index = 1, select("#", ...) do
			local plugin = select(index, ...)

			if plugin then
				self:plugin(plugin)
			end
		end
	end

	if self.init then
		self:init()
	end

	return self
end

--- The screen, as a function of the state it shows. Empty by default: an app that has not said
--- what its screen looks like draws nothing.
---@param _window wonderland.RenderWindow
---@return wonderland.Element
function App:view(_window)
	return require("wonderland").div()
end

--- A window being made is where the plugins attach to it: the gpu, the font, the screen.
---@param window winit.Window
function App:created(window)
	window:setTitle(self.title)

	local render = self.renderPlugin
	local layout = self.layoutPlugin

	if render then
		render:register(window)

		if self.font then
			local fonts = assert(render.sharedResources).fontManager
			local atlas = assert(Atlas.fromPath({ pixelHeight = self.pixelHeight, characters = self.characters },
				self.font))

			fonts:setDefault(assert(fonts:upload(atlas)))
		end
	end

	if layout then
		layout:register(window)
	end
end

--- Events go down the plugins in the order they were added, and whatever none of them claimed
--- is handed to the app's own `event`, if it has one. The first message either of them hands
--- back is the one update is given.
---
--- The shell does nothing with an event itself: a window being drawn is the ui plugin's, and one
--- that changed size is the ui plugin's too, so this is a walk down the plugins and then, for
--- whatever none of them claimed, the app.
---@param event winit.Event
---@param handler winit.EventManager
---@return any
function App:dispatch(event, handler)
	handler:setMode("wait")

	for _, plugin in ipairs(self.plugins) do
		if plugin.event then
			local message = plugin:event(event, handler)

			if message then return message end
		end
	end

	if self.event then
		return self:event(event, handler)
	end
end

--- A message is what an event came to: the app does what it does with it, and the frame that
--- shows what it did is asked for -- not built, because a frame is built once however many
--- events asked for one, and a drag is hundreds of them. See `app.run`: the loop is what turns
--- what the events asked for into the frames that come out of it. A screen that comes out the
--- same as the one before it is not uploaded, so a frame that changed nothing costs the layout
--- and no more.
---@param message any
---@param window winit.Window
---@return wonderland.Task?
function App:handle(message, window)
	if type(message) == "table" and message.type == "windowCreated" then
		self:created(window)
	end

	local task = self.update and self:update(message, window)

	if self.uiPlugin then
		self.uiPlugin:requestRedraw(window)
	end

	return task
end

--- Runs the app: the plugins, the app's own `init`, and then the window and its event loop.
--- Called with no plugins it is the screen's own; with `nil` it is none of them, which is how
--- an app that wires its own screen, or has no window at all, says so.
---@param ... wonderland.Plugin?
function App:run(...)
	self:setup(...)

	return app.run(self)
end

-- The event loop, the main window, and the two calls it makes on the app: an event goes down
-- the plugins and comes back as a message, and the message goes to the app.
--
-- Nothing is torn down when the loop ends. Giving the gpu's resources back takes real time --
-- a texture array, a swapchain, a device -- and an app whose last window has closed is on its
-- way out, where the process ending is what reclaims them and costs nothing. A screen that is
-- not the end of the process is the case that wants it, and says so: see `RenderPlugin:destroy`
-- and `wonderland.headless`'s `close`.
---@param self wonderland.App
function app.run(self)
	local eventLoop = winit.EventLoop.new()
	winit.Window.fromEventLoop(eventLoop)

	-- Whether events are coming in faster than the loop can take them one at a time, which is what
	-- decides whether the loop waits for the next event or takes what is already queued. Only an
	-- event that came to something counts: a pointer being moved is an event either way, and an
	-- event that changed nothing is one the loop should wait out rather than take more of.
	local flowed = false

	eventLoop:run(function(event, handler)
		-- A frame is a screen, and a screen is built once for it: what an event does is what the
		-- app does with the message it came to, and what it leaves behind is the frame the loop
		-- draws next. See `App:handle`, which is where that frame is asked for.
		local message = self:dispatch(event, handler)

		if message and event.window then
			flowed = true
		end

		if message then
			local task = self:handle(message, event.window)

			if task then
				if task.type == "createWindow" then
					local w = winit.Window.new(eventLoop, task.width or 800, task.height or 600)
					---@cast w wonderland.Window
					if task.kind then w.kind = task.kind end
					eventLoop:register(w)
				elseif task.type == "closeWindow" and event.window then
					handler:close(event.window)
				end
			end
		end

		if event.name == "aboutToWait" then
			-- Whether the loop waits for the next event or takes what is already queued. Waiting is
			-- what an idle window does, and it is what keeps a screen that nothing has happened to
			-- from spinning. Taking what is queued is what a burst is for, and a pointer being
			-- dragged across a window is one: its events are taken in one go, so the frame that
			-- comes out of them is the pointer where it is now rather than a frame per event, each
			-- one drawn -- and each one waiting for the display -- from a state already behind the
			-- one the event after it left. That is what makes a drag lag behind the pointer, and
			-- what a wheel turned hard was made to stop doing.
			handler:setMode(flowed and "poll" or "wait")
			flowed = false
		end
	end)
end

return app
