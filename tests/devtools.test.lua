-- The panel over a screen: what it shows of the app it is over, and that what it draws is a screen
-- of the app's own kind. It is rendered offscreen like the ui is, and the pixels and what the panel
-- read are both asserted.
local test = require("lde-test")
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

-- A font is what any screen needs; the test skips where the machine has none.
local FONT_PATHS = {
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"Library/Fonts/Arial.ttf",
	"C:/Windows/Fonts/arial.ttf",
}

local fontPath = nil

for _, path in ipairs(FONT_PATHS) do
	local file = io.open(path, "rb")

	if file then
		file:close()
		fontPath = path
		break
	end
end

-- Rendering needs a gpu, and a build machine may not have one: say why and skip rather than fail.
local gpuErr = nil

if fontPath then
	local ok, err = pcall(function()
		local screen = wonderland.headless.new(function() return div() end, { width = 8, height = 8 })
		screen:close()
	end)

	if not ok then
		gpuErr = tostring(err)
		print("devtools tests skipped: " .. gpuErr)
	end
end

local canRender = fontPath ~= nil and gpuErr == nil

-- A screen of the app's own: a column of two rows, one of them named, so that a row of the panel's
-- tree has something to be labelled with.
local function anApp()
	return function()
		return div():style(sty():fill():column():gap(4):bg("#12141c")):children({
			div():style(sty():size(60, 20):bg("#262b38")):named("header"),
			div():style(sty():size(60, 20):bg("#426bd9")):named("button"):children("press me"),
		})
	end
end

--- A screen with the panel over it, drawn twice: the panel shows the screen the frame before it, so
--- the first frame is the app's own and the second is the one the panel is in.
---
--- The tool is put in the screen's event order here, which is what an app does with it by adding it
--- as a plugin: a screen wired by hand is wired the same way, one call at a time.
---@param opts wonderland.Devtools.Options?
---@return wonderland.Headless screen
---@return wonderland.Devtools tool
local function withPanel(opts)
	local tool = wonderland.devtools.new(opts)
	local screen = wonderland.headless.new(anApp(), { width = 400, height = 300, fontPath = fontPath })

	tool:build(screen)
	screen.order[#screen.order + 1] = tool
	screen:draw()
	screen:draw()

	return screen, tool
end

---@param pixels string
---@param width number
---@param x number
---@param y number
---@return number r
---@return number g
---@return number b
local function pixelAt(pixels, width, x, y)
	local first = (y * width + x) * 4 + 1

	return pixels:byte(first, first + 2)
end

test.skipIf(not canRender)("draws a panel over the app rather than instead of it", function()
	local screen, tool = withPanel()

	local pixels = assert(screen:getPixels())
	screen:close()

	test.truthy(tool.nodes > 0, "the panel walked the app's screen")

	-- The app is where it was: its own box is drawn where the panel is not, and the panel is drawn
	-- over the corner of it, which is the box the app's own header was given.
	local r, g, b = pixelAt(pixels, 400, 350, 60)
	test.equal(r, 0x12, "the app's own box is drawn under the panel")
	test.equal(g, 0x14)
	test.equal(b, 0x1c)

	local pr, pg, pb = pixelAt(pixels, 400, 12, 12)
	test.truthy(pr + pg + pb < 0x12 + 0x14 + 0x1c, "and the panel is drawn over the corner of it")
end)

-- What the panel is for: the screen the app came out to, as elements and nodes, and the numbers a
-- repaint of it costs.
test.skipIf(not canRender)("shows what the screen is made of", function()
	local screen, tool = withPanel()

	screen:close()

	-- The box the panel is drawn in is an element of the panel's own, which is why what the app
	-- built is counted before it is made.
	test.equal(tool.elements, 4, "the app's own elements are counted")
	test.greater(tool.nodes, 3, "and the nodes the layout made of them")
	test.truthy(tool.buildMs ~= nil and tool.buildMs >= 0, "and how long the view took is measured")
end)

-- The style shown is the one that came out of the cascade rather than the one the app wrote, which
-- is what tells a box that is not the size its own call asks for from one that is.
test.skipIf(not canRender)("shows the style of the box the pointer is over", function()
	local screen, tool = withPanel()

	-- The pointer is moved onto the second row, below the line of text in it: what is shown is the
	-- innermost box the pointer is inside, and inside a button with a label on it that is the label.
	screen:event({ name = "mouseMove", window = screen.window, x = 30, y = 43 })
	screen:draw()

	local picked = assert(tool.picked)
	local node = assert(screen.plugins.layout.contexts[screen.window].screen):node(picked)

	test.equal(node.width, 60, "the box under the pointer is the one shown")
	test.equal(node.height, 20)
	test.equal(node.bgR, 0x42, "with the colour it came out with")
	test.equal(node.bgB, 0xd9, "which is the one its style asked for")

	screen:close()
end)

-- The key it is given shows and hides it, and what it leaves behind is the app's own screen: a
-- panel that stayed in the frame of an app that is finished with it is a panel in a picture.
test.skipIf(not canRender)("shows and hides on its key", function()
	local screen, tool = withPanel({ key = "f12" })

	screen:event({ name = "keyPress", window = screen.window, key = "f12", modifiers = {} })
	screen:draw()

	test.falsy(tool.on, "the key hides it")

	local hidden = assert(screen:getPixels())
	local hr, hg, hb = pixelAt(hidden, 400, 12, 12)

	screen:event({ name = "keyPress", window = screen.window, key = "f12", modifiers = {} })
	screen:draw()

	test.truthy(tool.on, "and the key shows it again")

	local shown = assert(screen:getPixels())
	local sr, sg, sb = pixelAt(shown, 400, 12, 12)

	test.truthy(hr + hg + hb > sr + sg + sb, "with the panel over that corner and not without it")

	screen:close()
end)

-- An app adds its own plugins before the shell adds the ones a screen is made of, so the panel is
-- built while the layout it reads does not exist yet: a panel that looked for it in `build` and
-- kept the nothing it found is a panel that never draws, which is what an app written as the
-- example is would have been.
test.it("finds the plugins of a screen it was added before", function()
	local App = wonderland.app("Devtools")

	---@type wonderland.Devtools
	local tool = wonderland.devtools.new()

	App:plugin(tool)
	App:setup()

	test.truthy(App:getPlugin("layout") ~= nil, "the screen's plugins are there after setup")

	---@cast tool wonderland.Devtools
	tool:resolve()

	test.truthy(tool.layoutPlugin ~= nil, "which the panel finds when it comes to draw")
	test.truthy(tool.renderPlugin ~= nil, "the renderer with them")
	test.truthy(tool.uiPlugin ~= nil, "and the ui, which is what a frame is asked for through")
end)

-- What the panel wraps is the view the layout is wired with rather than the app's own, because an
-- app writes its view as a field of the app the panel was handed: one written after the panel was
-- added would be written over the panel rather than beside it, which is a screen with no panel on
-- it and nothing to say why.
test.it("wraps the view the layout builds with, not the app's own", function()
	local App = wonderland.app("Devtools")
	local tool = wonderland.devtools.new()
	local mine = function() return div() end

	App.view = mine
	App:plugin(tool)
	App:setup()

	---@cast tool wonderland.Devtools
	tool:resolve()

	local layout = assert(App.layoutPlugin)

	test.equal(App.view, mine, "the app's own view is still the app's")
	test.equal(layout.view, tool.wrapped, "and what the layout builds its screen with is the panel's")

	-- A view written after the panel was added is still the one that is read: what is wrapped asks
	-- the app for its view every frame, which is what wrapping the app's own field could not do.
	App.view = function() return div():style(sty():size(4, 4)) end

	test.equal(assert(App.layoutPlugin).view, tool.wrapped, "which the panel keeps either way")
end)

-- What the panel does not do: ask for a frame of its own for every move of the pointer. A frame per
-- move is one the display has not shown when the next move arrives, so a panel that asks for one
-- falls further behind the pointer the faster it is dragged, which is what a panel that follows the
-- pointer through the screen's own frames does not do.
test.skipIf(not canRender)("asks for no frame of its own as the pointer moves", function()
	local screen, tool = withPanel()
	local ui = screen.plugins.ui
	local present = ui.present
	local asked = 0

	---@param this wonderland.plugin.UI
	---@param window wonderland.RenderWindow
	local function presents(this, window)
		asked = asked + 1

		present(this, window)
	end

	ui.present = presents

	for at = 0, 20 do
		screen:event({ name = "mouseMove", window = screen.window, x = 10 + at * 4, y = 34 })
	end

	test.equal(asked, 0, "the panel asked for no frame of its own")

	-- And what it shows of the pointer is still the pointer: the frame the screen builds for the move
	-- is the one it is in.
	screen:draw()

	test.truthy(tool.picked ~= nil, "while what is under the pointer is still what is shown")

	screen:close()
end)

-- What the panel costs the app it is over, which is the one thing about a panel that the app pays
-- for: it is drawn in every frame the app draws, so its quads are the app's quads. What a screen of
-- a few hundred elements is drawn as is what says whether it is a panel that can be left on.
test.skipIf(not canRender)("costs the screen a bounded number of quads", function()
	local function aList()
		return function()
			local rows = {}

			for index = 1, 30 do
				rows[index] = div():style(sty():row():wrel(1.0):h(20):gap(4):pad(3)):children({
					div():style(sty():size(10, 10)):named("dot"),
					div():children("Row " .. index):named("label"),
				})
			end

			return div():style(sty():fill():column():gap(2):bg("#12141c")):children(rows)
		end
	end

	local screen = wonderland.headless.new(aList(), { width = 400, height = 300, fontPath = fontPath })
	local window = screen.window
	local render = screen.plugins.render

	screen:draw()

	local alone = assert(render:getContext(window)).quads
	local tool = wonderland.devtools.new()

	tool:build(screen)
	screen.order[#screen.order + 1] = tool
	screen:draw()

	local with = assert(render:getContext(window)).quads
	local screen_ = screen

	screen_:close()

	test.greater(alone, 50, "the screen draws quads of its own")
	test.truthy(with - alone < 700, "and the panel over it is a few hundred more of them")
end)

-- A panel is drawn in the screen it is over, so what it says is part of what a frame is: a panel
-- whose numbers answer differently every time it is built is a panel that makes every repaint a
-- frame of its own -- an upload, a submit and a wait for the display, for a pointer that moved and
-- nothing that changed. What it shows is read coarsely so that a screen doing the same thing is a
-- screen that comes out the same, and this is that: two frames with nothing between them.
test.skipIf(not canRender)("says the same thing while the app does the same thing", function()
	local screen = withPanel()

	-- The numbers it shows are averages, so the first frames are the panel arriving at them; on a
	-- software renderer the rate a frame comes at takes longer to settle, so what is looked for is
	-- one frame that came out the same as the one before it rather than a fixed count.
	local before, same = nil, false

	for _ = 1, 60 do
		screen:draw()

		local frame = assert(screen:getPixels())

		if before ~= nil and frame == before then
			same = true
			break
		end

		before = frame
	end

	screen:close()

	test.truthy(same, "a rebuild that changed nothing is the same pixels")
end)
