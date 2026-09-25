-- A scope drawn by hand: what a canvas is for. There is no audio behind this -- the levels are a
-- few sines beating against each other -- but what it draws is what a spectrum analyser draws, and
-- every shape of it is a `wonderland.Canvas` call.
--
-- What an app keeps is its own state: this holds the levels, the peak caps and the phase, and the
-- canvas it is drawn with is handed out again every frame. Clicking cycles what it draws.
local BANDS = 72

---@class Effect
---@field levels number[] # How tall each band is, 0 to 1
---@field peaks number[] # The cap that fell last, which is what makes a spectrum read as one
---@field wave number[] # A sample per band, -1 to 1
---@field phase number
---@field mode number
---@field hue number
local Effect = {}
Effect.__index = Effect

local MODES = { "spectrum", "radial", "waveform" }
local TAU = math.pi * 2

---@param bands number?
---@return Effect
function Effect.new(bands)
	local count = bands or BANDS
	local this = setmetatable({
		levels = {},
		peaks = {},
		wave = {},
		phase = 0,
		mode = 1,
		hue = 0.58,
	}, Effect)

	for index = 1, count do
		this.levels[index], this.peaks[index], this.wave[index] = 0, 0, 0
	end

	return this
end

---@return string # What it is drawing now, for a screen to say
function Effect:modeName()
	return MODES[self.mode]
end

--- Moves every band on by the time that passed.
---@param dt number
function Effect:update(dt)
	local count = #self.levels

	self.phase = self.phase + dt
	self.hue = (0.58 + math.sin(self.phase * 0.13) * 0.14) % 1

	-- The signal: a low band that pulses like a kick, a mid that wanders, and a high band that
	-- hisses -- which is three sines, one of them wrapped in a fast one. A real one comes from a
	-- decoder; see `treble` for what a player is read with.
	local beat = math.max(0, math.sin(self.phase * 1.6)) ^ 6

	for index = 1, count do
		local at = index / count
		local level = beat * math.exp(-at * 3.4)
			+ math.exp(-((at - 0.45) ^ 2) * 26) * (0.45 + 0.35 * math.sin(self.phase * 2.3 + index * 0.4))
			+ 0.16 * math.abs(math.sin(self.phase * 5.1 + index * 1.7)) * at
			+ 0.05

		level = math.min(1, math.max(0, level))

		-- safety: a band that falls as fast as the signal does reads as noise, and one that never
		-- falls reads as a painting: what is held is the cap above it, not the band
		local held = self.levels[index]
		self.levels[index] = level > held and level or held + (level - held) * math.min(1, dt * 9)
		self.peaks[index] = level > self.peaks[index] and level or math.max(0, self.peaks[index] - dt * 0.45)
		self.wave[index] = math.sin(self.phase * 2.4 + at * 9) * 0.5
			+ math.sin(self.phase * 0.7 + at * 23) * 0.3
			+ math.sin(self.phase * 3.1 - at * 4) * 0.2
	end
end

---@param level number
---@param towards number
---@return wonderland.Color
function Effect:colour(level, towards)
	local r, g, b = 0.20 + level * 0.80, 0.55 + level * 0.35, 1.0 - level * 0.45

	if towards > 0 then
		-- safety: a shape of a canvas is drawn as it is over what is under it -- there is no
		-- blending -- so a reflection is the colour mixed towards the panel it is on
		local k = 1 - towards
		r, g, b = r * k + 0.03 * towards, g * k + 0.04 * towards, b * k + 0.07 * towards
	end

	return { r, g, b, 1 }
end

--- Draws the frame's shapes: what an element's `:canvas` callback is handed.
---@param canvas wonderland.Canvas
function Effect:draw(canvas)
	local count = #self.levels
	local width, height = canvas.width, canvas.height
	local mode = MODES[self.mode]

	-- The grid the scope sits on, which is what makes a level readable as a level.
	for at = 0, math.floor(width / 48) do
		canvas:line(at * 48 + 0.5, 0, at * 48 + 0.5, height, 1, { 0.16, 0.20, 0.30, 1 })
	end

	if mode == "radial" then
		local middleX, middleY = width * 0.5, height * 0.5
		local least = math.min(width, height) * 0.22
		local most = math.min(width, height) * 0.46

		canvas:circle(middleX, middleY, least * (0.9 + self.levels[1] * 0.2), { 0.10, 0.14, 0.22, 1 })

		for index = 1, count do
			local angle = index / count * TAU + self.phase * 0.4
			local level = self.levels[index]
			local reach = least + level * (most - least)

			canvas:line(middleX + math.cos(angle) * least, middleY + math.sin(angle) * least,
				middleX + math.cos(angle) * reach, middleY + math.sin(angle) * reach,
				math.max(2, 2 * TAU * least / count), self:colour(level, 0))
		end

		return
	end

	local baseline = height * 0.62
	local step = width / count

	if mode == "waveform" then
		-- The trace, as a line per sample: a canvas has no line strip, and a chain of them is the
		-- same picture with nothing to keep between frames.
		local previousX, previousY = 0, baseline - self.wave[1] * height * 0.22

		for index = 2, count do
			local x = (index - 1) * step
			local y = baseline - self.wave[index] * height * 0.22

			canvas:line(previousX, previousY, x, y, 3, self:colour(self.levels[index], 0))

			previousX, previousY = x, y
		end

		-- And under it, the levels themselves, small: a trace is what a scope shows beside a
		-- spectrum rather than instead of one.
		for index = 1, count do
			local level = self.levels[index]
			local x, barWidth = (index - 1) * step, math.max(1, step - 2)

			canvas:rect(x, height - level * height * 0.22, barWidth, level * height * 0.22,
				self:colour(level, 0.35))
		end

		return
	end

	-- The spectrum, mirrored about the baseline: a bar up, its reflection down, and the cap over
	-- it that says how high the band has been.
	for index = 1, count do
		local level = self.levels[index]
		local x, barWidth = (index - 1) * step, math.max(1, step - 2)
		local reach = level * baseline * 0.86

		canvas:rect(x, baseline - reach, barWidth, reach, self:colour(level, 0))
		canvas:rect(x, baseline + 2, barWidth, reach * 0.42, self:colour(level, 0.55))
		canvas:rect(x, baseline - self.peaks[index] * baseline * 0.86 - 3, barWidth, 3,
			{ 0.95, 0.98, 1, 1 })
	end

	canvas:rect(0, baseline, width, 2, { 0.35, 0.55, 0.95, 1 })
end

return Effect
