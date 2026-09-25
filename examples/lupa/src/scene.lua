-- A lupa scene drawn on an element of a wonderland screen.
--
-- What the two libraries share is the gpu. lupa is handed wonderland's device and a texture of
-- wonderland's to draw into, and wonderland shows that texture like any other picture: the box it
-- is put in, the corners it is cut with, the shadow behind it and the depth it is drawn at are all
-- the screen's. What lupa draws is what it always draws -- its own command buffer, its own submit,
-- on the queue both of them are on -- and what it costs a frame is one pass.
--
-- See `wonderland.plugin.Render:target` for the texture and lupa's README for the drawing.
local Draw = require("lupa.draw")

---@class Scene
---@field surface wonderland.Surface # What the element shows
---@field spin number # How fast the scene turns, in turns a second
---@field glow number # How strong the warm light beside it is, 0 to 1
local Scene = {}
Scene.__index = Scene

local TAU = math.pi * 2
local STEPS = 6

---@param render wonderland.plugin.Render
---@param width number
---@param height number
---@return Scene
function Scene.new(render, width, height)
	local this = setmetatable({ spin = 0.25, glow = 0.7, phase = 0, light = nil }, Scene)

	-- The texture comes first, because the callback a frame is drawn in is recorded with it: what
	-- that callback draws is this scene, which is why it is made before the draw that can draw it.
	this.surface = render:target(width, height, { draw = function()
		this:render()
	end })

	this.draw = Draw.new(nil, {
		device = render:getDevice(),
		target = this.surface,
	})

	-- safety: the lights are read rather than kept by lupa, so one table is built here and changed
	-- in place as a slider moves
	this.light = {
		-- safety: a scene whose ambient is dark reads as black whatever the sun is doing, and one
		-- lit only by the sun has no shape in its shadows
		ambient = { 0.52, 0.56, 0.66 },
		lights = {
			{ dir = { x = -0.30, y = -0.80, z = -0.45 }, color = { 1, 1, 0.98 }, shadows = true },
			{ pos = { x = 3.6, y = 2.8, z = -1.4 }, radius = 20, color = { 1, 0.6, 0.28 } },
		},
	}

	return this
end

--- Moves the scene on by the time that passed. What is animated is the clock, so the scene is the
--- same wherever it is drawn from: the frame that draws it only reads what this left.
---@param dt number # Seconds since the last call
function Scene:update(dt)
	self.phase = self.phase + dt * self.spin * TAU
end

--- Draws one frame of the scene into the texture the element shows.
function Scene:render()
	local draw = self.draw
	local phase = self.phase

	draw:beginFrame()
	draw:setClearColor(0.05, 0.07, 0.12)

	-- A camera that orbits the scene rather than one that watches it from one place: what makes a
	-- 3d scene read as one on a flat screen is the sides of things going past.
	draw:setCamera({
		position = { x = math.sin(phase * 0.25) * 11, y = 6.2, z = math.cos(phase * 0.25) * 11 },
		target = { x = 0, y = 1.5, z = 0 },
		fov = math.pi / 3.4,
	})

	self.light.lights[2].color = { 1, 0.60, 0.28 * (0.4 + self.glow) }
	self.light.lights[2].radius = 10 + self.glow * 14
	draw:setLighting(self.light)

	-- The floor, which is what the shadows and the warm light are read against: without it a scene
	-- of shapes floats in nothing and has no scale.
	draw:setColor(0.44, 0.47, 0.56, 1)
	draw:plane(0, 0, 0, 30, 30)

	-- The tower: each block turned further than the one under it, which is what makes it a shape
	-- rather than a stack of cubes.
	for step = 0, 4 do
		draw:pushModel()
		draw:rotate(phase * (0.3 + step * 0.25), 0, 1, 0)
		draw:setColor(0.45 + step * 0.11, 0.55 + step * 0.06, 0.95 - step * 0.09, 1)
		draw:cube(0, 0.36 + step * 0.62, 0, 0.62)
		draw:popModel()
	end

	-- The ring: cubes up and down as they go round, and every one of them turned to face out.
	for step = 1, STEPS do
		local angle = phase + step * (TAU / STEPS)

		draw:pushModel()
		draw:translate(math.cos(angle) * 4.4, 0.5 + math.sin(angle * 2 + phase) * 0.35,
			math.sin(angle) * 4.4)
		draw:rotate(-angle, 0, 1, 0)
		draw:setColor(1, 0.72, 0.32, 1)
		draw:cube(0, 0, 0, 0.7)
		draw:popModel()
	end

	-- And one sphere over the middle of it, which is the only thing in the scene that is not a box:
	-- it is what the light and the shadow map are for.
	draw:pushModel()
	draw:translate(0, 4.4 + math.sin(phase * 1.7) * 0.5, 0)
	draw:setColor(0.92, 0.95, 1.0, 1)
	draw:sphere(0, 0, 0, 0.9)
	draw:popModel()

	-- safety: the shadow passes draw the records made before this and nothing after it, so the
	-- call is what says which shapes cast
	draw:endShadowCasters()
	draw:endFrame()
end

return Scene
