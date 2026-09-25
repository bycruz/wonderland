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

This repository is the library, and it is one package. Reading a font and shaping a line of text are
not things it does itself: it hands both to `texter`, which is the machine's own text -- FreeType,
HarfBuzz and fribidi on linux and android, Uniscribe and GDI on windows, CoreText on macOS -- so
there is nothing compiled, fetched or shipped for text at all.

```lua
local wonderland = require("wonderland")

wonderland.app("読める"):run()
```

Nothing to add and nothing to remember: `texter` is a dependency of this package, and what reads a
font is the platform's reader whichever platform the app is running on. What that means for an app
is that a font of any kind -- outlines in CFF, a collection, a variable font, an emoji font -- is
read by the same library the desktop draws its own windows with, and a machine that has no such
library at all says so through `texter.why()` rather than drawing nothing.

`texter` is a checkout beside this one while it is unpublished, which is what this package's
`lde.json` says (`../texter/packages/texter`); when it has a version, that line is a version like any
other dependency's.

`examples/` holds an app and a todo list drawn with the core alone, and `src/` and `tests/` are the
library: `lde test` from the root of this repository runs its tests.

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

## Text

A style says what its text is drawn in, and what has to be there for it is a font:

```lua
-- Any family this machine has, by the name it has it under. One it does not have is drawn in the
-- machine's own sans rather than in nothing, so a screen that names a font still starts on a
-- machine without it.
local SCREEN = sty():fill():bg("#12141c"):fg("#edf0f7"):font("Inter")
local TITLE = sty():text("3xl"):font("Inter", { weight = "semibold" })
local CAPTION = sty():text("sm"):fg("#7d8697")
local BODY = sty():text(15)             -- a size is also just pixels
```

`:text` is a size from a scale -- `xs`, `sm`, `base`, `lg`, `xl`, `2xl` and up to `6xl` -- or a
number of pixels, and both are the same thing written two ways: `:text("lg")` is `:text(18)`. What
a style says about a font is the one thing about the text inside it: a family, a size, a weight or
a slant is inherited by everything drawn in the element, so naming a family once at the top of a
screen is every line on it, and a heading is the one element that says otherwise.

A family name is looked up in the fonts this machine has. A character the font an app named has no
glyph for -- a title in Japanese, a name in Cyrillic, a word of Arabic, an emoji -- is drawn from the
next font in the chain that has it: fontconfig's answer to which of a machine's fonts covers a
language, then a list of families a machine is likely to have, then the machine's own default. A
glyph is packed into the atlas the first time a line holding it is drawn, so what an app draws is not
limited to the characters anyone named in advance: a file name, a title, anything a person typed.

A line is shaped rather than spelled out: which glyph a character is drawn from, what a word joins
to, what is kerned against what and which way the line reads are decisions the font makes, and
`texter` asks it -- HarfBuzz on linux and android, Uniscribe on windows, CoreText on macOS. Arabic is
drawn joined and right to left, a ligature is one glyph of two characters, and an emoji of four bytes
is one glyph rather than four boxes. What a glyph came from is a *byte* of the string rather than a
character of it, which is what a caret, a click and a cut count in.

A line of two scripts is a line of two faces, so it is cut where the face changes and each piece is
shaped whole -- joining is a decision a font makes about the letters beside each other. A line that
mixes two directions is set the way most of what is in it is set; a bidi pass over the whole line is
not what this does.

An emoji is drawn as the picture its font states rather than as a letter: four bytes a pixel, in a
sheet of its own -- white sheets are what a shape is drawn through a text colour with.

Text is edited by character rather than by byte: a backspace takes the letter that was typed away, a
caret walks a character at a time, and a key that types a character of two bytes types all of it.

```lua
-- A line too wide for the box it is in is cut, with an ellipsis where it was cut. What it is cut
-- to is the room the box has, which is why the layout cuts it and not the app: in a row, a title
-- gets what is left over beside the duration after it.
div():style(sty():w(40)):children(text("a track's title"):style(sty():ellipsis()))
```

The letters are drawn by the machine's own text stack, through `texter`, reached through one seam:
`wonderland.font.reader`, which a caller may point somewhere else with `FontManager.setProvider`. A
reader is a table of a few functions -- open a file, answer with a face, shape a line, give back the
ink of a glyph -- so a test can be a reader of tables with no font file anywhere, and a reader that
shapes nothing is measured a character at a time rather than refused.

```lua
local FontManager = require("wonderland.util.font_manager")

FontManager.setProvider(myReader)   -- myReader.open(path, index) -> face
```

What that replaced is stb_truetype: a header compiled into a shared library and shipped beside the
package, which read TrueType outlines and no others, so a font of Japanese whose outlines are CFF --
Noto Sans CJK, Source Han -- was skipped or drawn as a box. In its place is no reader at all: 日本語
comes out of the font the machine already has, and so do 中文, 한국어 and a font collection.

## Time and animation

Everything that happens on its own -- a caret blinking, a key repeating, a gif moving on -- is on
one clock, and an app can keep time by it as well:

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

`time.now()` is the clock itself: seconds that only go forwards, on the monotonic clock of the
machine rather than its wall clock, so a difference of two of them is how long passed between
them. It is what a frame being paced, a frame of video being due and a position in a file are all
measured against.

A frame a screen presents is built and drawn whatever it comes out to, which is what makes a screen
something outside wonderland can drive: the shapes an element draws with `:canvas` and the contents
of a texture another renderer fills are in the frame and not in the screen, so the solve coming out
the same is not the frame coming out the same. That is what an app that animates either of them is
asking for when it calls `self:every(1 / 60, ...)` or `self:present(window)` -- and a frame nothing
asked for, that comes out the same as the one on screen, is still skipped.

## Frames from anywhere

A picture is a file, and a frame of a video is not: a stream is what a decoder writes into, and
everything after the writing is what a gif already does -- a ring of layers the frames cycle
through, a picture a style names, and a frame that changed being a screen that changed.

```lua
local video = assets:stream({ width = 1920, height = 1080 })

-- Somewhere else, on whatever clock the decoder keeps:
video:frame(decodedFrame, 0.04)          -- seconds to show it for

local shown = video:current()

div():style(sty():size(shown.width, shown.height):image(shown.texture, shown.uv))
```

What a stream costs is the layers it cycles through and not the frames shown in them, so a video
of any length is a handful of pictures on the gpu, and a frame the decoder hands over is a copy
into the layer the frame before it is not being drawn from.

## Scrolling

A box that scrolls is a box that clips: the app holds the offset, and the library clips and moves
the content by it. What the library does with the offset is put it where the wheel and the bar go:

```lua
-- The wheel over the pane, and the pane's own bar being dragged, are one call. `by` is how far a
-- wheel asks the content to move, `to` is where a bar dragged puts it, and one of them is always
-- nothing. What the offset comes to is the app's -- one row of a list and one page of a document
-- are not the same distance -- so the app clamps it and hands it back.
div():style(PANE)
	:children(rows)
	:scroll(self.offset)
	:onScroll(function(by, to)
		return { type = "scroll", by = to and to - self.offset or (by or 0) * ROW_STEP }
	end)
```

A wheel goes to the innermost box under the pointer that scrolls, so a screen of panes scrolls the
one it is over and a box that does not scroll passes it on. A wheel over nothing that scrolls is
left for the app, which is where a screen that scrolls itself handles it.

## The pointer and the keyboard

A press is the button it was pressed with, and the buttons are not the same thing: the left one is
a click, and the one on the right is a menu.

```lua
-- A right press is a context menu where it was pressed, and is not a click: what answers a click
-- is not told about it, and the field that had the caret keeps it.
div():style(ROW)
	:onClick({ type = "open", id = track.id })
	:onContextMenu(function(x, y, width, height, modifiers)
		return { type = "menu", id = track.id, at = { x, y } }
	end)
```

What a mouse event carries about itself is thin -- a platform reports the wheel turning rather than
where, and a press rather than what was held -- so the modifiers a press is told about are the ones
the keyboard last said. A press and a release and a move are handed them, which is what a range of
rows taken with shift is written from.

Tab moves the keyboard from one thing to the next: a field, a thing that answers a click, a thing
that says what it looks like with the keyboard in it. A thing that answers a click is worked with
return or space when the keyboard is on it, so a screen is usable without a pointer at all.

```lua
div():style(BUTTON):named("play"):focus(sty():bright(1.2)):onClick({ type = "play" })
```

## The clipboard, and files dropped on a window

The clipboard is the system's, one per program, and a paste into a field is the library's: control
with C, V or X in the field that has the keyboard copies, pastes and cuts. A field has no selection,
so what it has to give is the whole of its value; what is pasted lands where the caret is, a field of
one line takes the first line of it, and a paragraph takes the lines it has room for.

```lua
-- What the program copies to and pastes from. It is handed to an app by `run`, so an app that
-- wants more than a field's worth of it -- a playlist, a path, a track's name -- has it here.
self.clipboard:setText(playlist)
local pasted = self.clipboard:getText()
```

Files dropped on a window go to the box they landed on, which is what a window that takes a track
from a file manager is:

```lua
div():style(PANE):onDrop(function(paths)
	return { type = "add", paths = paths }
end)
```

A window with no box for them hands the event to the app -- `App:event` is given `fileDrop` with its
paths -- which is what a screen that takes a file anywhere on it does. A headless screen has a
clipboard in memory, so a paste, a copy and a drop are all testable with no window and no desktop.

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

A picture is uploaded as the size it is, into a texture of its own, so a screen costs what the
pictures on it are and there is nothing to size before an app starts: a four thousand pixel
photograph next to an eight pixel icon costs the two of them and no more. What that gives up is one
draw call for the whole screen, which is bought back by the runs: the quads that share a picture are
drawn together, so a line of text is one call and a screen with two pictures on it is three.

A picture of any size is uploaded in bands -- rows of it, stacked as layers of its texture -- because
of how an upload reaches the gpu: it is staged through a window of host visible memory rather than
the whole card, and one the size of a large photograph is the one that fails on a machine whose
window is busy with other things. A band at a time, what one upload holds is bounded, and a twelve
megapixel photograph is six of them -- which is nothing an app has to think about, and nothing it
can see: a picture is drawn by one quad and sampled across its bands.

A gif comes back with every frame of it, and is played by the delay each frame carries:

```lua
local dance = assets:gif("assets/spinner.gif")
local frame = dance:current()

div():style(sty():size(frame.width, frame.height):image(frame.texture, frame.uv))
```

An animation is read a frame at a time rather than the whole of it at once. A gif of eighty frames
of a photograph is eighty frames of decoding and seventy megabytes, which read whole is a fifth of a
second before anything is drawn and all of it held from then on; read a frame at a time, the first
frame is on screen in a few milliseconds, the rest are decoded and uploaded as the clock reaches
them, and what a screen holds of a gif is the four layers those frames cycle through rather than
every frame of it. A frame that has moved on is a picture a quad names differently, which is what
says the screen changed.

Which frame is current is the screen's own clock: a gif that has been asked for is advanced by
`wonderland.plugin.UI:tick`, the frame it moved on to is drawn by a repaint, and the loop is woken
for the time the frame after it is due -- so nothing but the app drawing it decides whether one is
playing.

What is left to know is small: a picture is at most 8192 pixels a side, which is the renderer's
rather than the picture's, and a picture past it says so. A streamed animation is drawn from the
four layers its frames cycle through, so a screen that draws more of one animation at once than
that -- a strip of the whole of it, say -- is not what a stream is for: read the file with the
image package's `loadFrames` and `assets:upload` the frames it wants.

## What an app draws itself

A box draws shapes of its own with `:canvas`, which is handed a sink of primitives rather than a
texture to fill: what it draws is in the pixels of the element's content box, cut by whatever pane
the element is in, drawn over its own background, under its children, and at the depth everything
else of that element is drawn at.

```lua
div():style(sty():size(120, 120)):canvas(function(canvas)
	canvas:rect(0, 0, 40, 10, "#ff0000")          -- a hex string, a name, or a table of channels
	canvas:rect(0, 20, 40, 20, "#00ff00", 8)      -- the sixth argument rounds its corners
	canvas:circle(70, 70, 20, "#0000ff")          -- and the fifth says how many sides it is cut into
	canvas:line(0, 50, 40, 90, 4, "#ffffff")      -- a line, as thick as it is told
	canvas:polygon({ 60, 0, 100, 0, 80, 30 }, "#ffff00")
end)
```

That is what the bars, the meters, the progress and the plots of a screen are: the shapes a box's own
style has no word for. `canvas.width` and `canvas.height` are the room the element gives it, and a
canvas keeps nothing -- the callback is called for every frame the screen builds, and what it draws
is written into the frame being recorded -- so a screen that redraws its meters pays for the shapes
and for nothing else. A shape that curves back on itself is drawn as the fan of its corners, so a
spectrum or a waveform is one polygon per convex piece.

Everything past that is a picture, and a picture is where every renderer ends: a texture, made here
or made by something else, shown like any other -- which is what gives it the box it is put in, the
corners it is cut with, the pane it scrolls inside and the depth it is drawn at, all of them the
library's.

```lua
function App:view()
	-- Made once, on a frame rather than in `init`: a texture belongs to the renderer a window
	-- brought, and `draw` is what fills it -- handed the frame's own command encoder, the view to
	-- draw into and the size of it.
	if not self.meter then
		self.meter = self:getPlugin("render"):target(512, 256, { draw = function(encoder, view, width, height)
			encoder:beginRendering({ colorAttachments = { { texture = view, op = { type = "clear" } } } })
			-- the app's own pipeline, its own vertex buffers, its own draw calls
			encoder:endRendering()
		end })
	end

	return div():style(sty():size(256, 128):image(self.meter))
end
```

A target is recorded into the frame's own command buffer, before the pass the screen is drawn in, so
nothing is waited for and nothing is submitted twice: what the app drew is on screen in the frame it
drew it in. `draw` runs for every frame the screen draws, and an app whose scene moves is one that
asks for those frames itself -- `self:every(1 / 60, ...)`, as the example does -- since a screen that
nothing asked anything of, and that came out the same as the one on screen, is not drawn again.

A texture of somebody else's is shown by handing it over instead, which is where a renderer built on
[hood](https://github.com/bycruz/hood) -- or anything else that leaves its output in a texture --
ends:

```lua
local surface = render:texture(texture)       -- a hood.Texture, of the size it says it is
div():style(sty():size(256, 128):image(surface))
```

Both come back as a surface: the slot in the renderer's pictures, the texture, a view of it as the
array the shader samples, and the format it is in where that is known. Both are given back with
`render:release(surface)`, which frees a texture this library made and leaves one of the app's own
alone. A target is `rgba8unorm` unless another format is named, since that is the format a picture is
sampled in and the one a pipeline of the app's compiles against.

## Plugins

The internals of wonderland consist of plugins.

For example, the window handling, rendering, layout engine and text rendering are all isolated plugins.

| plugin | what it owns |
| ------- | ------------ |
| window | the gpu instance, and a surface per window |
| render | the device -- made when a window is first registered -- the frame buffers, the pictures an app draws, and a screenshot |
| text | measuring lines into runs the quad pass draws, in the font a style asks for |
| layout | solving the screen, cutting the lines that do not fit, and turning events into messages |
| ui | the layout's quads, the diff that skips a frame that came out the same, the caret, and the clock an app asks to be called back on |

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

## What is not here yet

wonderland draws a screen and takes what a person does to it. What an application of more than a
screen needs is mostly not this library's, and some of it is nobody's yet:

| | |
| - | - |
| Sound | `treble`, a cross platform audio library for LuaJIT (`lde add treble`): a player mixes and plays with it, and `wonderland.time` is what its position is read against |
| Shaping and bidi | Arabic, Hebrew, Devanagari and Thai: `texter` shapes those lines with the machine's own shaper, and what is left is wonderland's layout drawing a shaped line -- its glyphs, its clusters and the face each run of it belongs to -- rather than a character at a time |
| Colour emoji, on windows and macOS | On linux and android an emoji is drawn in the colours of its font: `texter` paints the graph a COLR v1 font states and hands a CBDT, sbix or COLR v0 one over as its picture, and a sheet of the atlas holds it as it is. On windows and macOS what a reader hands over is coverage -- GDI's outline call has no colour in it, and CoreText is drawn into a grey context here -- so an emoji is its shape in the colour of the text, and what would fix it is DirectWrite and a colour bitmap context respectively |
| Video and audio decoding | nothing in the lde registry: a decoder is a binding to be written, and what it hands over is a frame for `assets:stream` |
| Tags and a library | `id3`, Vorbis comments, mp4 atoms and cover art: a parser to be written, or a decoder that already has them |
| Threads | lde has none, and reading a file on the thread that draws is a screen that stutters: a decoder that is a C library brings its own, otherwise it is `lua-llthreads2` |
| The clipboard, files dragged onto a window, a file dialog | not in winit's backends either, so a platform layer to be written |
| Fullscreen, window sizes and icons | the same: winit has the window, and not yet these |
| Media keys, the system's own controls, tray icons, notifications | a platform layer per platform: MPRIS on linux, SMTC on windows |
| macOS | winit has an X11 and a Win32 backend and no third: wonderland runs where winit does |
| Text as a document | an input method, wrapping, and a text view: a field takes typing, selects with the keys and the pointer, cuts and pastes, and draws a line of either direction |
