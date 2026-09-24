local hood = require("hood")
local backend = require("wonderland.backend")

---@class wonderland.plugin.Window.Context
---@field window winit.Window
---@field surface hood.Surface

---@class wonderland.plugin.Window<Message>: wonderland.Plugin, { onWindowCreate: Message }
---@field mainCtx wonderland.plugin.Window.Context?
---@field contexts table<winit.Window, wonderland.plugin.Window.Context>
---@field onWindowCreate unknown
---@field instance hood.Instance
local WindowPlugin = {}
WindowPlugin.__index = WindowPlugin

---@param onWindowCreate unknown
function WindowPlugin.new(onWindowCreate)
	local isDebug = os.getenv("DEBUG") and true or false

	local instance = hood.Instance.new({ backend = backend.name, flags = isDebug and { "validate" } or {} })

	return setmetatable({ contexts = {}, instance = instance, onWindowCreate = onWindowCreate }, WindowPlugin)
end

---@param window winit.Window
function WindowPlugin:register(window)
	local surface = self.instance:createSurface(window)

	local windowCtx = {
		window = window,
		surface = surface,
	}

	self.mainCtx = self.mainCtx or windowCtx
	self.contexts[window] = windowCtx
end

function WindowPlugin:getContext(window) ---@return wonderland.plugin.Window.Context?
	return self.contexts[window]
end

---@param event winit.Event
---@param handler winit.EventManager
function WindowPlugin:event(event, handler)
	-- onWindowCreate is not passed the window as the update will be triggered
	-- with the new window anyway.
	if event.name == "map" and not self:getContext(event.window) then
		self:register(event.window)
		return self.onWindowCreate
	elseif event.name == "create" then
		self:register(event.window)
		return self.onWindowCreate
	elseif event.name == "windowClose" then
		local ctx = self:getContext(event.window)
		if ctx == self.mainCtx then
			handler:exit()
		else
			self.contexts[event.window] = nil
			handler:close(event.window)
		end
	end
end

return WindowPlugin
