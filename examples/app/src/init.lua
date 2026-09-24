-- The smallest app: a button, a slider and a field that takes a paragraph, so the controls an
-- element can be are in one screen.
--
--   lde run            from this directory, or lde run examples/app/src/init.lua
--
-- A style says what a box looks like; what it *does* is a call on it. `slider` and `input` are
-- the two the library drives: a slider reports where in itself it was dragged, and a field takes
-- the keyboard. What is drawn for either of them -- a track, a filled part, a caret -- is the
-- app's, which is why the slider below is a box with a child in it.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local SCREEN = sty():column():align("center"):justify("center"):gap(16):pad(24):fill():bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9"):radius(10)
	:shadow(0, 4, 10)
local TRACK = sty():row():wrel(1.0):h(20):pad(3):bg("#1b2029"):radius(10)
local NOTES = sty():row():wrel(1.0):h(90):pad(12):bg("#1b2029"):fg("#8d97a8"):radius(10)
	:shadow(0, 3, 8, "#00000070")

---@type wonderland.App<{ clicks: number, volume: number, notes: string }>
local App = wonderland.app("Wonderland")

function App:init()
	self.clicks = 0
	self.volume = 0.4
	self.notes = "a field that takes\nmore than one line"
end

function App:view()
	local times = self.clicks == 1 and "time" or "times"

	return div()
		:style(SCREEN)
		:children(
			{
				div()
					:style(BUTTON)
					:hover(sty():bright(1.35))
					:active(sty():bright(0.7))
					:children("Press me")
					:onClick("pressed"),
				"Pressed " .. self.clicks .. " " .. times,
			},
			-- The slider is a track with a filled part in it, and where it is dragged to is the
			-- app's to keep: the filled part is as wide as the value, as a share of the box, and
			-- the nub -- the part that is dragged -- is put where the value is by the layout,
			-- which is the one thing about it an app cannot work out for itself: how wide the box
			-- it was given came out.
			div()
				:style(TRACK)
				:slider({
					value = self.volume,
					min = 0,
					max = 1,
					onchange = function(value)
						return { type = "volume", value = value }
					end,
				})
				:children({
					div():style(sty():h(14):wrel(self.volume):bg("#4a6dbd"):radius(7)),
					div():style(sty():size(14, 14):bg("#c9d4e8"):radius(7)):thumb(),
				}),
			"Volume " .. string.format("%.2f", self.volume),
			-- A paragraph: return breaks the line rather than adding anything, and what is typed
			-- is the app's, as it is for a field of one line.
			div()
				:style(NOTES)
				:input({
					name = "notes",
					value = self.notes,
					multiline = true,
					oninput = function(value)
						return { type = "notes", value = value }
					end,
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
