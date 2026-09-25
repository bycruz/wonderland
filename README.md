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
