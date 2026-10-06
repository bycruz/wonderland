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
```

```lua
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local SCREEN = sty():column():align("center"):justify("center"):gap(16):bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9"):radius(10):shadow(0, 4, 10)

--- Use this type to explicitly type the apps state for full e2e typing
---@type wonderland.App<{ clicks: number }>
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

## Devtools

A panel over the app's own screen, drawn by the screen itself: what the frame came out to, what it
cost, and the style of whatever the pointer is over. `f12` shows and hides it, `f11` draws a box
around every element rather than around the one under the pointer, and it is left out of an app that
is finished.

```lua
App:plugin(wonderland.devtools.new())     -- f12, and the panel starts shown
```

It shows the box of the element under the pointer, the numbers a repaint comes to -- elements,
nodes, quads, runs, the bytes of instance data, lua's own memory, the frame's milliseconds and its
rate -- the tree of the screen indented by depth with each node's size, and the resolved style of
the node under the pointer: its box and place, its padding, margin and gap, its direction and
alignment, its colours, radius, blur, shadow and texture, and whether it scrolls.

```lua
div():style(BOX)
	:children("hover me")

-- The panel over it reads: box 240x80 at 16,120  pad 8 margin 0 gap 4  row align start justify
-- start in flow  bg #1b202cff fg #e6e6ffff  border none radius 6 blur 0  ...
```

What it reads is the frame before the one it is drawn in, since a screen is solved before its frame
is handed over. A node whose box is not the size its own call asked for is what it is looked at for:
a box that names no height fills what holds it, and the panel is where that is visible.

The panel is part of the screen it is over, so it is rebuilt in the frames the app's own events ask
for and costs the app a few hundred quads a frame -- which is why the box of every element is a key
of its own rather than what is drawn by default: a box is four lines as wide as the window, and a
screen of a thousand elements is four thousand of them over the app's every frame.

