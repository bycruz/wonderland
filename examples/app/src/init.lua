local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local SCREEN = sty():column():align("center"):justify("center"):gap(16):bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9")

---@type wonderland.App<{ clicks: number }>
local App = wonderland.app("Wonderland")

function App:init()
	self.clicks = 0
end

function App:view()
	local times = self.clicks == 1 and "time" or "times"

	return div()
		:style(SCREEN)
		:children(
			div()
				:style(BUTTON)
				:hover(sty():bright(1.35))
				:active(sty():bright(0.7))
				:children("Press me")
				:onClick("pressed"),
			"Pressed " .. self.clicks .. " " .. times
		)
end

function App:update(message)
	if message == "pressed" then
		self.clicks = self.clicks + 1
	end
end

App:run()
