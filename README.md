# wonderland

A cross platform UI library for LuaJIT.

Screens are values: you describe an element tree, wonderland solves it into boxes,
and the app shell draws them in a window.

## Backends

| Backend | Windows | Linux | macOS |
| ------- | ------- | ----- | ----- |
| OpenGL  | ✅      | ✅    | ❌    |
| Vulkan  | ✅      | ✅    | ❌    |

The window and renderer come from [winit](https://github.com/bycruz/winit) and
[hood](https://github.com/bycruz/hood), so the platforms they support are the ones
wonderland runs on. Vulkan is the default; set `OPENGL=1` to run on OpenGL instead,
and build with the same setting so the shaders match.

## Installation

Use this package with the [lde](https://lde.sh/) package manager.

```bash
lde add wonderland
```

## Example

```lua
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

-- A style is a value: write one once and hand it to everything that should look the same.
-- Text takes the colour and the font of the nearest element above it that names them.
local SCREEN = sty():column():align("center"):justify("center"):gap(16):bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9")

-- One app, and what it keeps on itself: another wonderland.app() call would be another app
-- with its own clicks and its own window. The generic is the app's own state.
---@type wonderland.App<{ clicks: number }>
local App = wonderland.app("Wonderland")

function App:init()
	self.clicks = 0
end

-- The screen, as a function of the state it shows. A string is a child like any other, so the
-- count is handed over as one and needs no element of its own.
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

-- A click comes back as the message the element was given. Setting the state is all there is
-- to do: the screen is laid out and drawn again.
function App:update(message)
	if message == "pressed" then
		self.clicks = self.clicks + 1
	end
end

App:run()
```

## Plugins

The internals of wonderland consist of plugins.

For example, the window handling, rendering, layout engine and text rendering are all isolated plugins.

| plugin | what it owns |
| ------- | ------------ |
| window | the gpu instance, and a surface per window |
| render | the device, the frame buffers, and a screenshot |
| text | measuring lines into runs the quad pass draws |
| layout | solving the screen, and turning events into messages |
| ui | the layout's quads, and the diff that skips a frame that came out the same |

These are used by your app implicitly when you :run() without any arguments.

You can write your own, giving you access to the internals of wonderland like removing default plugins, interacting with them, or using the `event` to access raw window handling events.

```lua
local app = wonderland.app("Wonderland"):plugin({
	name = "quit",

	build = function(self, app)
		self.render = app:getPlugin("render")
	end,

	-- Asked on every event, after the plugins before it. Returning a message is what makes
	-- it one, and the first plugin to do that is the one update hears from.
	event = function(self, event)
		if event.name == "keyPress" and event.key == "q" then
			return { type = "closeWindow" }
		end
	end,
})
```

Whatever the plugins do not claim is handed to the app's own `event`, which is how an app
extends the ones it was given rather than replacing them:

```lua
function App:event(event, handler)
	if event.name == "keyPress" then
		return { type = "quit" }
	end
end
```

Running an app with the plugins named instead of none of them is how an app that draws with
something else says so -- `run(nil)` is an app with no plugins at all, and no window either
unless it makes one:

```lua
App:run(nil)
App:run(myPlugin, myOtherPlugin)
```

## Headless

You can make wonderland render headless and save the output to a file.

```lua
local screen = wonderland.headless.new(|window| -> view(window), { width = 800, height = 600, fontPath = "/path/to/font.ttf" })

screen:draw()
screen:save("ui.png")

-- Events go in by hand, and whatever they produce comes back out.
screen:click(120, 40)
```

You can also save screenshots from a windowed screen:

```lua
renderPlugin:saveScreenshot(ctx, "ui.png")
```
