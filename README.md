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

## Examples

You can run the examples in ./examples with:

```bash
lde run -C ./examples/app
```

```lua
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

-- A style is a value: write one once and hand it to everything that should look the same.
-- Text takes the colour and the font of the nearest element above it that names them.
-- `radius` is how round a box's corners are, in pixels: the corners are cut where the box is
-- drawn rather than built out of more geometry, so a round box is one quad like any other. And
-- `shadow(x, y, blur, color)` puts one behind the box: offset from it, faded out over `blur`
-- pixels, and black at a bit under half alpha when no colour is named.
local SCREEN = sty():column():align("center"):justify("center"):gap(16):bg("#12141c"):fg("#edf0f7")
local BUTTON = sty():row():align("center"):justify("center"):size(200, 44):bg("#426bd9"):radius(10):shadow(0, 4, 10)

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

## Controls

What a box *does* is a call on it, and what it *looks like* stays the app's: a slider is a track
you put a filled part in, and a field is a box you put the text in.

```lua
-- A slider reports where in itself it was pressed and dragged, between the two values you give
-- it. The filled part below is as wide as the value, as a share of the box it sits in.
div():style(TRACK)
	:slider({ value = self.volume, min = 0, max = 1, onchange = function(now)
		return { type = "volume", value = now }
	end })
	:children(div():style(sty():h(14):wrel(self.volume):bg("#4a6dbd")))

-- A field takes the keyboard from the click that focuses it, and the caret comes with it: it is
-- drawn where the value says, in the field's own colour, one line down for each line before the
-- one the typing is on. With `multiline` it is a paragraph: return breaks the line rather than
-- sending it, control with return is what sends it, and the caret moves between the lines and the
-- ends of them with the arrow keys, home and end.
div():style(NOTES)
	:input({ name = "notes", value = self.notes, multiline = true, oninput = function(value)
		return { type = "notes", value = value }
	end })
	:children(text(self.notes))
```

The caret is placed beside the line of text a field draws -- the first one inside it, wherever the
app put it, centred or padded -- or at the field's own content origin where it draws no text at all.
It blinks half a second on and half a second off, and that is the one thing in a screen that changes
on its own: the loop has no timer, so `winit.EventManager:setTimeout` is what the screen uses to say
when it wants waking, and a platform whose loop cannot be given a deadline has a caret that is woken
by its events instead. `screen.plugins.ui.caretBlink` is the time, and nought is a caret that stays.

Text with newlines in it is drawn as lines, for a `text` element as much as for a field, and each
line is aligned by its own width.

## Pictures

An image or a gif is loaded with the asset manager the view function is handed, and what comes back
is a texture and the part of it to draw, which is all a style needs to put it on a box.

```lua
function App:view(window, assets)
	-- A png, a jpeg, a tga, a qoi: whichever it is, what it is is what the bytes say.
	local logo = assets:image("assets/logo.png")

	return div():style(sty():size(logo.width, logo.height):image(logo.texture, logo.uv))
end
```

The decoding is [image](https://github.com/lde-org/image)'s, so png, jpeg, tga, bmp, psd, gif, hdr,
pic, pnm, qoi and ppm are read, and a file of one, two or three channels is widened to the four a
texture holds. A path is decoded once and remembered, so a view that names the same picture on every
repaint pays a lookup for it. A picture the app drew itself rather than read from a file goes through
`assets:upload(picture)`, and is the app's to keep. The same manager is on an app as `self.assets` and
on a headless screen as `screen.assets`; a screen wired up by hand makes one with
`wonderland.Assets.new(textureManager)`.

A gif comes back with every frame of it, and is played by the delay each frame carries:

```lua
local dance = assets:gif("assets/spinner.gif")
local frame = dance:current()

div():style(sty():size(frame.width, frame.height):image(frame.texture, frame.uv))
```

Which frame is current is the screen's own clock: a gif that has been asked for is advanced by
`wonderland.plugin.UI:tick`, the frame it moved on to is drawn by a repaint, and the loop is woken
for the time the frame after it is due -- so nothing but the app drawing it decides whether one is
playing. The frames are packed into as few layers of the texture array as they fit, a gif of small
frames being one layer for the whole of it, so a large or a long one wants a render plugin given
more: `textures = { size = 1024, layers = 64 }` in the render plugin's options.

## Plugins

The internals of wonderland consist of plugins.

For example, the window handling, rendering, layout engine and text rendering are all isolated plugins.

| plugin | what it owns |
| ------- | ------------ |
| window | the gpu instance, and a surface per window |
| render | the device, the frame buffers, the pictures, and a screenshot |
| text | measuring lines into runs the quad pass draws |
| layout | solving the screen, and turning events into messages |
| ui | the layout's quads, the diff that skips a frame that came out the same, and the caret |

A frame is built from the state the events left, and a frame the display asks for with nothing
behind it is a frame of what is already built: the view, the measure and the solve happen when
something changed, not once per frame. `UI.frameInterval` is the least time between frames, and a
window manager that asks for frames -- X11's sync request, which winit passes on -- is a display's
own clock and is not held back by it. A caret that blinks asks for its frames the same way: the end
of the loop's wait is the clock a screen with something to do on its own is given.

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
local screen = wonderland.headless.new(|window, assets| -> view(window, assets), { width = 800, height = 600, fontPath = "/path/to/font.ttf" })

screen:draw()
screen:save("ui.png") -- and ui.jpg, ui.qoi: the extension is what says the format

-- Events go in by hand, and whatever they produce comes back out.
screen:click(120, 40)
```

A headless screen is handed pictures the same way an app is: `screen.assets`, or the second
argument of the view function, which is what the first frame is built with -- the screen is still
being made when that happens.

You can also save screenshots from a windowed screen:

```lua
renderPlugin:saveScreenshot(ctx, "ui.png")
```
