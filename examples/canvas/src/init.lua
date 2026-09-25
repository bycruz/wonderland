-- A canvas effect, with no pictures and no shaders behind it: every shape on the panel is a call
-- of `:canvas`. Run it with:
--
--   lde run -C ./examples/canvas
--
-- Clicking the panel cycles what it draws -- a spectrum, a spectrum in the round, and a trace.
local wonderland = require("wonderland")
local Effect = require("wonderland-example-canvas.effect")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty
local time = wonderland.time

local SCREEN = sty():column():align("center"):justify("center"):gap(16):pad(20):fill():bg("#080a10"):fg("#e7ecf5")
-- safety: a `div` with no size is as big as what holds it, so a line of text is a `text` element:
-- one of those is the size of the line it measured, and a screen of lines is laid out by them.
local TITLE = sty():fg("#f2f5fa"):text("2xl")
local HINT = sty():fg("#7d8798"):text("sm")
local PANEL = sty():size(900, 420):bg("#0d1018"):radius(16):shadow(0, 14, 34, "#000000b0")

---@type wonderland.App<{ effect: Effect, last: number }>
local App = wonderland.app("Wonderland canvas")

function App:init()
	self.effect = Effect.new(72)
	self.last = time.now()

	-- An effect is drawn on the clock the screen is already on: every call of this is a frame.
	self:every(1 / 60, function()
		local now = time.now()
		local dt = math.min(now - self.last, 0.1)

		self.last = now
		self.effect:update(dt)
	end)
end

function App:view()
	return div()
		:style(SCREEN)
		:children({
			text("A canvas draws this"):style(TITLE),
			div()
				:style(PANEL)
				:canvas(function(canvas)
					self.effect:draw(canvas)
				end)
				:onClick("mode"),
			text("click the panel: it is drawing a " .. self.effect:modeName()):style(HINT),
			text("no textures, no shaders, no state in the canvas"):style(HINT),
		})
end

---@param message any
function App:update(message)
	if message == "mode" then
		self.effect.mode = self.effect.mode % 3 + 1
	end
end

App:run()
