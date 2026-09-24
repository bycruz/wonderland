-- wonderland: a UI library, from declaring a screen to running it.
--
--   local wonderland = require("wonderland")
--   local div, sty = wonderland.div, wonderland.sty
--
--   wonderland.app({
--       view = function() return div():style(sty():fill()) end,
--       update = function(message) end,
--   }):run()
--
--   wonderland.div       make an element
--   wonderland.text      make a line of text
--   wonderland.sty       make a style
--   wonderland.Layout    lay a screen of elements out, with no window needed
--   wonderland.Element   the type those builders make
--   wonderland.app(opts) an app: the window and the plugins a screen needs, installed
--   wonderland.run(app)  run one, if you would rather not call `app:run()`
--   wonderland.headless  the same screen with no window, for tests and screenshots
local app = require("wonderland.app")
local element = require("wonderland.element")
local style = require("wonderland.style")

---@class wonderland
---@field div fun(): wonderland.Element
---@field text fun(value: string): wonderland.Element
---@field sty fun(): wonderland.StyleBuilder
---@field Layout wonderland.layout
---@field Element wonderland.Element
---@field headless wonderland.headless
---@field app fun(title: string?): wonderland.App
---@field run fun(app: wonderland.App)
local wonderland = {
	div = element.div,
	text = element.text,
	sty = style.new,

	Layout = require("wonderland.layout"),
	Element = element.Element,
	headless = require("wonderland.headless"),
	app = app.new,
	run = app.run,
}

return wonderland
