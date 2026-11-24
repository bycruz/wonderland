-- What a page like a music library costs to build, solve, walk and draw: a column of rows that
-- scrolls under a top bar and over a bottom one, four cards a row, each card a picture, two lines
-- and a small round button.
--
--   lde run bench/scroll.lua                 -- every mode
--   MODE=idle lde run bench/scroll.lua       -- one of them
--   FRAMES=120 lde run bench/scroll.lua      -- fewer frames
--   STAGE=walk lde run bench/scroll.lua      -- build, measure, layout, solve, refresh, walk, present, draw
--   TEXT=0 lde run bench/scroll.lua          -- a page of boxes with no lines of text in them
--   ROWS=200 CARDS=2 lde run bench/scroll.lua -- another shape of page
--
-- The kilobytes are counted with the collector stopped, so they are what one frame hands it. The
-- milliseconds are the mean, the 95th percentile and the worst of the frames measured.
io.stdout:setvbuf("line")

local wonderland = require("wonderland")
local div, sty = wonderland.div, wonderland.sty

local FONT_PATHS = {
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/Library/Fonts/Arial.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
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

assert(fontPath, "no font found: add one to FONT_PATHS in this file")

local ROWS = tonumber(os.getenv("ROWS") or "110")
local CARDS = tonumber(os.getenv("CARDS") or "4")
local FRAMES = tonumber(os.getenv("FRAMES") or "240")
local WARMUP = tonumber(os.getenv("WARMUP") or "40")
local MODE = os.getenv("MODE")
-- Whether the cards carry lines of text: a page with none is what the cost of a box of its own is.
local TEXT = os.getenv("TEXT") ~= "0"
-- A frame is the view built, measured, solved, walked and drawn: these stop at one of the last
-- four, which is how the kilobytes are told apart.
local STAGE = os.getenv("STAGE") or "draw"

local rootStyle = sty():fill():column():bg("#12141c")
local topStyle = sty():row():align("center"):gap(12):pad(12):wrel(1.0):h(56):bg("#1b1e28")
local topTitle = sty():text(18):weight(700):fg("#ffffff")
local bottomStyle = sty():row():align("center"):justify("center"):gap(24):wrel(1.0):h(64):bg("#1b1e28")
local bottomText = sty():text(11):fg("#8b93a7")
local pageStyle = sty():column():wrel(1.0):hrel(1.0):bg("#12141c")
local rowStyle = sty():row():wrel(1.0):gap(8):pad(6)
local cardStyle = sty():column():wrel(0.25):gap(4):pad(8):radius(8):bg("#1b1e28")
local imageStyle = sty():wrel(1.0):h(72):radius(6):bg("#2c3350")
local titleStyle = sty():text(14):weight(600):fg("#e6e9f2")
local subtitleStyle = sty():text(11):fg("#8b93a7")
local buttonStyle = sty():row():justify("center"):align("center"):size(28, 28):radius(14):bg("#426bd9")
local buttonText = sty():text(12):fg("#ffffff")
local lineStyle = sty():text(13):fg("#c8cede")

--- One card: a picture, a title, a subtitle and a small round button.
---@param index number
local function card(index)
	local image = div():style(imageStyle)
	local button = div():style(buttonStyle)

	if TEXT then
		button:children(div():style(buttonText):children("+"))

		return div():style(cardStyle):children(
			image,
			div():style(titleStyle):children(string.format("Album %d", index)),
			div():style(subtitleStyle):children(string.format("Artist %d - %d tracks", index,
				index % 17 + 1)),
			button
		)
	end

	return div():style(cardStyle):children(image, button)
end

--- The page: a toolbar, a scrolling list of rows of cards, and a bar of controls under it.
---@param state { offset: number }
local function libraryPage(state)
	return function()
		local rows = {}
		local index = 0

		for row = 1, ROWS do
			local cards = {}
			for column = 1, CARDS do
				index = index + 1
				cards[column] = card(index)
			end
			rows[row] = div():style(rowStyle):children(cards)
		end

		return div():style(rootStyle):children(
			div():style(topStyle):children(
				div():style(topTitle):children("Library"),
				div():style(subtitleStyle):children("110 albums")
			),
			div():style(pageStyle):scroll(state.offset):children(rows),
			div():style(bottomStyle):children(
				div():style(bottomText):children("Home"),
				div():style(bottomText):children("Search"),
				div():style(bottomText):children("Library"),
				div():style(bottomText):children("Settings")
			)
		)
	end
end

--- A screen of nothing but lines, which is the other thing a page of text costs.
---@param state { offset: number }
local function textPage(state)
	return function()
		local lines = {}
		for index = 1, ROWS * 2 do
			lines[index] = div():style(lineStyle):children(
				string.format("Line %d of the list, a title that goes on for a while - 3:41", index))
		end

		return div():style(rootStyle):children(
			div():style(topStyle):children(div():style(topTitle):children("Text")),
			div():style(pageStyle):scroll(state.offset):children(lines)
		)
	end
end

---@param name string
---@param factory fun(state: { offset: number }): fun(): wonderland.Element
---@param step number? # How far the page moves each frame, nil for a still page
local function measure(name, factory, step)
	local state = { offset = tonumber(os.getenv("OFFSET") or "") or 0 }
	local screen = wonderland.headless.new(factory(state), { width = 1080, height = 720, fontPath = fontPath })
	local window = screen.window
	local view = factory(state)
	local elements = require("wonderland.element")

	local layoutCtx = screen.plugins.layout.contexts[window]
	local layoutScreen = layoutCtx and layoutCtx.screen

	local stage
	if STAGE == "layout" then
		stage = function()
			elements.beginFrame()
			local tree = view()
			screen.plugins.text:measure(tree)
			layoutScreen.root = layoutScreen:fromElement(tree)
		end
	elseif STAGE == "solve" then
		stage = function()
			elements.beginFrame()
			local tree = view()
			screen.plugins.text:measure(tree)
			layoutScreen.root = layoutScreen:fromElement(tree)
			layoutScreen:solve(1080, 720)
		end
	elseif STAGE == "build" then
		stage = function()
			elements.beginFrame()
			view()
		end
	elseif STAGE == "measure" then
		stage = function()
			elements.beginFrame()
			screen.plugins.text:measure(view())
		end
	elseif STAGE == "refresh" then
		stage = function()
			screen.plugins.layout:refreshView(window)
		end
	elseif STAGE == "present" then
		-- A frame asked for with nothing in the view changed: what the window asks for, which walks
		-- the screen again -- what an element draws itself is in the frame and not in the solve -- and
		-- draws it, and builds nothing.
		stage = function()
			local ctx = screen.plugins.layout.contexts[window]
			ctx.mustDraw = true
			window.frameAsked = true
			screen.plugins.ui:frame(window)
		end
	elseif STAGE == "walk" then
		stage = function()
			screen.plugins.layout:refreshView(window)
			screen.plugins.ui:walk(window, screen.plugins.layout.contexts[window], nil)
		end
	else
		stage = function()
			screen:draw()
		end
	end

	for _ = 1, WARMUP do
		stage()
	end

	collectgarbage("collect")
	collectgarbage("stop")

	local times = {}
	local startHeap = collectgarbage("count")

	for frame = 1, FRAMES do
		if step then
			state.offset = state.offset + step
		end
		local start = os.clock()
		stage()
		times[frame] = (os.clock() - start) * 1000
	end

	local allocated = collectgarbage("count") - startHeap
	collectgarbage("restart")
	collectgarbage("collect")

	table.sort(times)
	local sum = 0
	for _, time in ipairs(times) do
		sum = sum + time
	end
	local mean = sum / FRAMES
	local p95 = times[math.max(1, math.floor(FRAMES * 0.95))]
	local worst = times[FRAMES]

	local ctx = assert(screen.plugins.render:getContext(window))

	print(string.format(
		"  %-18s %7.3f ms mean  %7.3f ms p95  %7.3f ms worst  %8.1f KiB/frame  %4d quads  %2d runs  heap %5.1f MB",
		name .. " [" .. STAGE .. "]", mean, p95, worst, allocated / FRAMES, ctx.quads, ctx.runCount,
		collectgarbage("count") / 1024))

	screen:close()

	return allocated / FRAMES

	-- The page is rebuilt each frame from the same elements, so the view that comes out of it is
	-- the one the step asks for: the list is where the offset says it is, and nothing is kept
	-- from the frame before.
end

print(string.format("a frame of a library page, %d rows of %d cards, %d frames:", ROWS, CARDS, FRAMES))

local modes = {
	{ "scroll", libraryPage, 40 },
	{ "idle", libraryPage, nil },
	{ "text scroll", textPage, 40 },
	{ "text idle", textPage, nil },
}

if MODE then
	local wanted = MODE:gsub("%s+", " ")
	for _, mode in ipairs(modes) do
		if mode[1] == wanted then
			measure(mode[1], mode[2], mode[3])
		end
	end
else
	for _, mode in ipairs(modes) do
		measure(mode[1], mode[2], mode[3])
	end
end
