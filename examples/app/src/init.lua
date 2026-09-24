local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local SCREEN = sty():column():align("center"):justify("center"):gap(16):pad(24):fill():bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9"):radius(10):shadow(0, 4, 10)
local TRACK = sty():row():wrel(1.0):h(20):pad(3):bg("#1b2029"):radius(10)
local NOTES = sty():row():wrel(1.0):h(90):pad(12):bg("#1b2029"):fg("#8d97a8"):radius(10):shadow(0, 3, 8, "#00000070")

---@type wonderland.App<{ clicks: number, volume: number, notes: string }>
local App = wonderland.app("Wonderland")

function App:init()
	self.clicks = 0
	self.volume = 0.4
	self.notes = "a field that takes\nmore than one line"
end

function App:view(window, assets)
	-- A gif is drawn a frame at a time: what the asset manager hands back is the frame the clock is
	-- on, which is a texture and the part of it to draw. Asking for it again on the next repaint
	-- costs a lookup, and the screen is asked for again when the frame after this one is due.
	local dance = assets:gif("assets/spinner.gif")
	local frame = dance:current()
	local times = self.clicks == 1 and "time" or "times"

	return div()
		:style(SCREEN)
		:children(
			{
				div():style(sty():size(frame.width, frame.height):image(frame.texture, frame.uv)),
				div()
					:style(BUTTON)
					:hover(sty():bright(1.35))
					:active(sty():bright(0.7))
					:children("Press me")
					:onClick("pressed"),
				"Pressed " .. self.clicks .. " " .. times,
			},
			div()
				:style(TRACK)
				:slider({
					value = self.volume,
					min = 0,
					max = 1,
					onchange = |value| -> { type = "volume", value = value },
				})
				:children({
					div():style(sty():h(14):wrel(self.volume):bg("#4a6dbd"):radius(7)),
					div():style(sty():size(14, 14):bg("#c9d4e8"):radius(7)):thumb(),
				}),
			"Volume " .. string.format("%.2f", self.volume),
			div()
				:style(NOTES)
				:input({
					name = "notes",
					value = self.notes,
					multiline = true,
					maxLines = 4,
					grow = true,
					oninput = |value| -> { type = "notes", value = value }
				})
				:children(text(self.notes):style(sty():fg("#c8d2e0")))
		)
end

function App:update(message, _window)
	if message == "pressed" then
		self.clicks = self.clicks + 1
	elseif type(message) == "table" and message.type == "volume" then
		self.volume = message.value
	elseif type(message) == "table" and message.type == "notes" then
		self.notes = message.value
	end
end

App:run()
