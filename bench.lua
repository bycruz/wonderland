-- What a repaint costs, by screen size, for measuring changes to the pipeline.
--
--   lde run bench.lua                          -- the numbers
--   lde run bench.lua --profile                -- and a flat profile on exit
--   lde run bench.lua --jit                    -- and which hot code never compiled
--   ROWS=500 ROUNDS=200 lde run bench.lua      -- a bigger screen, fewer rounds
--
-- A repaint is what happens when anything changes: the view is built, the text on it is
-- measured, the layout solved, the frame written and uploaded. The numbers to watch are
-- the milliseconds (cpu, as the fastest of several batches) and the kilobytes (garbage,
-- which is what the collector then has to pay for).
io.stdout:setvbuf("line")

local wonderland = require("wonderland")
local div, sty = wonderland.div, wonderland.sty

-- Any font will do; a screen of text needs one.
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

local ROWS = tonumber(os.getenv("ROWS") or "0")
local ROUNDS = tonumber(os.getenv("ROUNDS") or "200")
local WARMUP = tonumber(os.getenv("WARMUP") or "50")
local BATCHES = tonumber(os.getenv("BATCHES") or "8")

-- A style is written once and shared, and a row's text inherits it, which is the shape
-- the pipeline is meant to be measured in.
local rowStyle = sty():row():wrel(1.0):h(20):bg("#262b38"):fg("#e6e6e6")
local screenStyle = sty():column()
local cardStyle = sty():column():justify("center"):align("center"):wrel(1.0):h(240):bg("#262b38"):fg("#99a3b8")
local buttonStyle = sty():row():justify("center"):align("center"):size(200, 44):bg("#426bd9")
local rootStyle = sty():fill():column():bg("#12141c")

---@param rows number
---@return fun(): wonderland.Element
local function list(rows)
	return function()
		local children = {}
		for index = 1, rows do
			children[index] = div():style(rowStyle):children(string.format("Row %d of the list", index))
		end

		return div():style(screenStyle):children(children)
	end
end

--- The shape of the example: a header, a card with a button on it, and a footer.
---@return fun(): wonderland.Element
local function example()
	return function()
		return div():style(rootStyle):children(
			div():style(sty():row():justify("center"):align("center"):wrel(1.0):hrel(0.18)):children("Wonderland"),
			div():style(sty():row():wrel(1.0):hrel(0.82)):children(
				div():style(cardStyle):children(
					"Press the button",
					div():style(buttonStyle):children("Click me"):onClick("pressed"),
					"Clicked 3 times"
				)
			)
		)
	end
end

---@param name string
---@param view fun(): wonderland.Element
local function measure(name, view)
	local screen = wonderland.headless.new(view, { width = 1200, height = 720, fontPath = fontPath })
	local ui = screen.plugins.ui
	local window = screen.window

	for _ = 1, WARMUP do
		ui:refreshView(window)
	end

	collectgarbage("collect")
	collectgarbage("stop")

	-- Repaints are timed in batches and the fastest is kept: a machine doing other things
	-- only ever makes a batch slower, so the fastest one is the one that came closest to
	-- the work itself. The garbage is counted once, since that does not depend on timing.
	local before = collectgarbage("count")
	local allocated = 0
	local best = math.huge

	for _ = 1, BATCHES do
		allocated = allocated + (collectgarbage("count") - before)
		before = collectgarbage("count")

		local start = os.clock()
		for _ = 1, ROUNDS do
			ui:refreshView(window)
		end
		best = math.min(best, (os.clock() - start) / ROUNDS * 1000)
	end

	collectgarbage("restart")

	print(string.format("  %-26s %7.3f ms   %8.1f KB   %d quads   %d runs", name, best,
		allocated / (ROUNDS * BATCHES), assert(screen.plugins.render:getContext(window)).quads,
		assert(screen.plugins.render:getContext(window)).runCount))

	screen:close()
end

print(string.format("a repaint, %d rounds in each of %d batches:", ROUNDS, BATCHES))

if ROWS > 0 then
	measure(ROWS .. " rows", list(assert(ROWS)))
else
	measure("the example's screen", example())
	measure("50 rows", list(50))
	measure("200 rows", list(200))
end
