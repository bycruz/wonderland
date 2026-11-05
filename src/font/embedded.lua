-- Fonts an app carries with it: the bytes of a face, named as a family, so that a style can ask for
-- one without a file existing beside the executable.
--
--   local name = wonderland.embedFont("brand-icons", require("brand.assets.icons"))
--   sty():font(name)
--
-- What is registered is the face's bytes; the reader turns them into a face when a style first
-- draws text in it. The name is what the style holds, and what the font manager asks this for before
-- it asks the machine's own fonts.
local embedded = {}

---@type table<string, string>
local faces = {}

--- Names a face by the bytes of a font file.
---@param name string
---@param content string
---@return string name
function embedded.register(name, content)
	assert(type(name) == "string" and name ~= "", "an embedded font needs a name")
	assert(type(content) == "string" and content ~= "", "an embedded font needs its bytes")

	faces[name] = content

	return name
end

--- The bytes registered under a name, or nothing where the machine's own fonts are what to ask.
---@param name string
---@return string? content
function embedded.get(name)
	return faces[name]
end

return embedded
