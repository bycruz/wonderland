-- wonderland and lupa, in one window: the 3d scene is an element of the screen, drawn by lupa into
-- a texture wonderland hands it, and everything around it -- the panel, the sliders, the text, the
-- layout -- is a wonderland screen. Run it with:
--
--   lde run -C ./examples/lupa
local wonderland = require("wonderland")
local Scene = require("wonderland-example-lupa.scene")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty
local time = wonderland.time

local SCREEN = sty():column():align("center"):justify("center"):gap(14):pad(20):fill():bg("#0b0d14"):fg("#e7ecf5")
local TITLE = sty():fg("#f2f5fa"):text("2xl")
local HINT = sty():fg("#7d8798"):text("sm")
-- safety: a `div` with no size is as big as what holds it, so a line of text is a `text` element
-- and a row of controls is as tall as what is in it: a screen of unsized boxes is one where every
-- child is the size of the screen.
local ROW = sty():row():align("center"):gap(12):h(20):w(440)
local TRACK = sty():row():wrel(1.0):h(18):pad(3):bg("#1a2030"):radius(9)

---@param value number # 0 to 1
---@return wonderland.Element
local function bar(value)
	return div():style(sty():h(12):wrel(value):bg("#3f6fe0"):radius(6))
end

---@type wonderland.App<{ scene: Scene?, spin: number, glow: number, shadows: boolean, last: number }>
local App = wonderland.app("Wonderland + lupa")

function App:init()
	self.spin = 0.25
	self.glow = 0.7
	self.shadows = true
	self.last = time.now()

	-- The scene is animated on the clock the screen is already on, and a call of it is a frame:
	-- what it changes is read by the frame the same tick draws.
	self:every(1 / 60, function()
		local now = time.now()
		local dt = math.min(now - self.last, 0.1)

		self.last = now

		if self.scene then
			self.scene.spin = self.spin
			self.scene.glow = self.glow
			self.scene:update(dt)
		end
	end)
end

function App:view()
	-- A texture belongs to the renderer a window brought, so the scene is made on the first frame
	-- rather than in `init`: what it is handed is this screen's device.
	if not self.scene then
		local render = self:getPlugin("render")

		self.scene = Scene.new(render, 760, 440)
	end

	local shadows = self.shadows and { shadows = true } or nil

	self.scene.light.lights[1].shadows = shadows

	-- The scene is a picture like any other, which is what makes it an element of this screen: the
	-- box, the corners and the shadow behind it are the screen's.
	local panel = sty():size(760, 440):radius(14):shadow(0, 14, 34, "#000000b0"):image(self.scene.surface)

	return div()
		:style(SCREEN)
		:children({
			text("A lupa scene on an element"):style(TITLE),
			div():style(panel):onClick("shadows"),
			text(self.shadows and "shadows on -- click the scene to turn them off"
				or "shadows off -- click the scene to turn them on"):style(HINT),
			div():style(ROW):children({
				text("turn"):style(HINT),
				div()
					:style(TRACK)
					:slider({ value = self.spin, min = 0, max = 1, onchange = function(value)
						return { type = "spin", value = value }
					end })
					:thumb()
					:children(bar(self.spin)),
			}),
			div():style(ROW):children({
				text("glow"):style(HINT),
				div()
					:style(TRACK)
					:slider({ value = self.glow, min = 0, max = 1, onchange = function(value)
						return { type = "glow", value = value }
					end })
					:thumb()
					:children(bar(self.glow)),
			}),
			text("the same gpu device, one command buffer each"):style(HINT),
		})
end

---@param message any
function App:update(message)
	if message == "shadows" then
		self.shadows = not self.shadows
	elseif type(message) == "table" and message.type == "spin" then
		self.spin = message.value
	elseif type(message) == "table" and message.type == "glow" then
		self.glow = message.value
	end
end

App:run()
