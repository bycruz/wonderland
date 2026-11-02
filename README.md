# wonderland

A cross platform UI library for LuaJIT with no dependencies, focused on efficiency.

## Backends

| Backend | Windows | Linux | macOS |
| ------- | ------- | ----- | ----- |
| OpenGL  | ✅      | ✅    | ❌    |
| Vulkan  | ✅      | ✅    | ❌    |


## Installation

Set up [lde](https://lde.sh/).

```bash
lde add wonderland
```

## Examples

You can run the examples in ./examples with:

```bash
lde run -C ./examples/app        # the tour: text, a field, a slider, a gif, a scroller
lde run -C ./examples/canvas     # a spectrum drawn by hand, every shape a `:canvas` call
lde run -C ./examples/lupa       # a lupa 3d scene, drawn on an element of the screen
lde run -C ./examples/tree       # a file tree: rows, a sidebar dragged wider, the keyboard
lde run -C ./examples/todo       # a list with a field, a scroller and a bar
```

```lua
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local SCREEN = sty():column():align("center"):justify("center"):gap(16):bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9"):radius(10):shadow(0, 4, 10)

--- Declare what the app keeps on itself as a class that extends `wonderland.App`: `self` is
--- then typed in every method the app defines.
---@class MyApp: wonderland.App
---@field clicks number
local App = wonderland.app("Wonderland")

function App:init()
	self.clicks = 0
end

function App:view()
	local times = self.clicks == 1 and "time" or "times"

	return div():style(SCREEN):children(
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
```

## Memory

What a screen costs, reported by the app itself:

```bash
lde run mem.lua                    # a screen the shape of a music player, then the numbers
MEM_HEADLESS=1 lde run mem.lua     # without a window, so no swapchain is in the numbers
TRACKS=2000 lde run mem.lua        # a longer list, to see what a row costs
```

```bash
lde run software.lua               # what a cpu renderer would cost to draw, with no gpu driver at all
```

It prints the resident set split into what the app owns, what is driver and library code, and what
is the window's shared memory, the proportional share of it, and the same by file -- which is where
the surprising part usually is. On a machine with a software vulkan driver installed (lavapipe,
which links libLLVM) a vulkan app pays fifty megabytes of llvm code pages before it has drawn
anything, because the loader enumerates every driver when an instance is made; `VK_DRIVER_FILES`
says which ones to load. What the library itself holds is small and countable: the frame's arrays
are tens of kilobytes, a measured row of text is about a kilobyte, and a glyph sheet is a megabyte
of pixels.

## Timing

Everything renders as little as it possibly needs. For example, a still frame will never re-render unless your mouse moves to cause a hover event.

This applies to things like caret blinks, a gif playing (streaming images), which a timing system is needed for, to induce re-renders asynchronously.

```lua
local time = require("wonderland").time

function App:init()
	-- Called every second, and the screen is drawn again after each call.
	self:every(1.0, function()
		self:updateClock()
	end)

	-- Or on the clock itself, where the callback says when it wants to be asked again. What comes
	-- back is seconds, nothing at all for never again, and nought to be asked as soon as the loop
	-- comes round -- which is how a decoder reads a burst of frames out of a file.
	self:onTick(function(at, window)
		local frame = self.decoder:frameAt(at)

		if frame then
			self.video:frame(frame)
			self:present(window)          -- a frame now, rather than at the display's rate
			return frame.delay
		end

		return 0.01
	end)
end
```

## Streaming Images

You can asynchronously stream a set of images to transition between, useful for playing gifs, or videos for a media player.
It holds a ring of layers that are cycled through for efficiency while still streaming them for minimal memory usage.

```lua
local video = assets:stream({ width = 1920, height = 1080 })

video:frame(decodedFrame, 0.04)          -- seconds to show it for

local shown = video:current()

div():style(sty():size(shown.width, shown.height):image(shown.texture, shown.uv))
```

## Lists and trees

A list is rows, and a row is a box: the indentation of an outline is padding, a chevron is a line of
text, the row that is chosen is a background, and the row under the pointer is `:hover`. What a
list needs that is not a style is only how far it is scrolled -- which is state, and therefore the
app's: `:scroll(offset)` moves what is inside the box and clips it to the box, and `:onScroll` says
what a wheel or a bar asked for. `examples/tree` is a file tree built out of exactly this.

Every row is an element and a node on every frame, shown or not, so a list of a thousand rows is a
thousand of each. A screen whose list is long enough for that to matter builds the rows that show
and `:hidden()`s the rest, or keeps its own window of them: what is off the end of the box is
clipped away at draw time, which is not the same as not being built.

## Resizing

A box that is dragged wider or taller says so with `:resize`, which is `:slider`'s idea again: the
library reports where the pointer is, and the app is what keeps the number.

```lua
local wide = 240

div():style(sidebar:width(wide)):resize({
	edge = "right",                                 -- which edge is dragged, and which way it grows
	grab = 8,                                       -- how near that edge a press counts as being on it
	min = 160,
	max = 420,
	onchange = |size| -> { type = "resized", size = size },
})
```

What is reported is the size the box is asked to be, in pixels: the size it was when the edge was
taken, plus how far the pointer has come since, held between `min` and `max`. It is a size rather
than a difference because what the box is drawn at is the app's -- the style of the frame after the
message is the one that is that size -- and it is reported only when it changes, so a pointer held
still is not a screen built again.

The edge is grabbed *inside* the box, so the strip it is grabbed by is part of the box and is taken
out of whatever is laid out in it. A pane that scrolls draws its bar on its own right edge, and the
bar is pressed before the edge is, so a sidebar that resizes and scrolls keeps its bar off the strip
with its own padding -- see the sidebar in `examples/tree`.

A press on an edge is a press on the edge rather than a press on the box, so a row that is clicked
and an edge that is dragged are not the same press. The pointer over an edge is drawn as the cursor
for it where the platform has one: a window that lists what it draws in `cursors` is asked for
`sizewe` or `sizens`, and a window that lists nothing keeps the cursor it had -- a shape asked for by
a name a backend does not know is one it falls over on rather than one it draws.

## Devtools

A panel over the app's own screen, drawn by the screen itself: what the frame came out to, what it
cost, and the style of whatever the pointer is over. `f12` shows and hides it, `f11` draws a box
around every element rather than around the one under the pointer, and it is left out of an app that
is finished.

```lua
App:plugin(wonderland.devtools.new())     -- f12, and the panel starts shown
```

It shows the box of the element under the pointer, the numbers a repaint comes to -- elements,
nodes, styles, quads, runs, the bytes of instance data, lua's own memory, the frame's milliseconds
and its rate -- the tree of the screen indented by depth with each node's size, and the resolved
style of the node under the pointer: its box and place, its padding, margin and gap, its direction
and alignment, its colours, radius, blur, shadow and texture, and whether it scrolls.

```lua
div():style(BOX)
	:children("hover me")

-- The panel over it reads: box 240x80 at 16,120  pad 8 margin 0 gap 4  row align start justify
-- start in flow  bg #1b202cff fg #e6e6ffff  border none radius 6 blur 0  ...
```

What it reads is the frame before the one it is drawn in, since a screen is solved before its frame
is handed over. Two numbers are what a screen is looked at for. A node whose box is not the size its
own call asked for: a box that names no height fills what holds it, and the panel is where that is
visible. And `styles`, which is how many styles the screen holds and is meant to sit at a few dozen:
a style is written once and shared, so a screen that builds one from a value -- a width that follows
a pointer, a colour that follows a clock -- makes a new one every time that value is a new number,
and the panel is where a number that only goes up is visible. What changes every frame wants a
`wonderland.Canvas` rather than a style.

The panel is part of the screen it is over, so it is rebuilt in the frames the app's own events ask
for and costs the app a few hundred quads a frame -- which is why the box of every element is a key
of its own rather than what is drawn by default: a box is four lines as wide as the window, and a
screen of a thousand elements is four thousand of them over the app's every frame.

