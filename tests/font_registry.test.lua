-- Fonts: where a family name on this machine leads, checked against fonts written here rather than
-- against the ones that happen to be installed.
--
-- A test that asked this machine where DejaVu Sans is would pass on the machine it was written on
-- and fail on the next one, so every font below is built into a temporary directory: an offset
-- table, a `name` table and an `OS/2` table, which is the whole of what a scan reads. The glyphs a
-- real font keeps behind those tables are not part of the question.
--
-- The numbers a header is made of are packed by hand, in the big endian a font writes them in.
-- `string.pack` is Lua 5.3's and this LuaJIT does not backport it, and every field these fonts need
-- is two or four bytes wide, which is the whole of what the two helpers at the top do.
local ffi = require("ffi")
local test = require("lde-test")
local sfnt = require("wonderland.font.sfnt")
local Registry = require("wonderland.font.registry")

local isWindows = ffi.os == "Windows"

---@param value number
---@return string
local function be16(value)
	return string.char((value >> 8) & 0xFF, value & 0xFF)
end

---@param value number
---@return string
local function be32(value)
	return string.char((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
end

--- A string as the UTF-16 big endian that a Windows name record holds. What is written is a family
--- name, so the UTF-8 it is written as here is read out a character at a time rather than assumed
--- to be ASCII: one of the tests is about a name that is not.
---@param text string
---@return string
local function utf16(text)
	local out, at = {}, 1

	while at <= #text do
		local lead = text:byte(at)
		local code, width = lead, 1

		if lead >= 0xF0 then
			code, width = lead & 0x07, 4
		elseif lead >= 0xE0 then
			code, width = lead & 0x0F, 3
		elseif lead >= 0xC0 then
			code, width = lead & 0x1F, 2
		end

		for step = 1, width - 1 do
			code = (code << 6) | (assert(text:byte(at + step)) & 0x3F)
		end

		at += width
		out[#out + 1] = be16(code)
	end

	return table.concat(out)
end

--- A `name` table: one record per name, and the strings the records point at behind them. Every
--- record is written for the platform it names, in the encoding that platform calls its own -- one
--- for Windows and Unicode, nought for a Mac -- because how a name is read is decided by it.
---@param entries { id: number, text: string, platform: number? }[]
---@return string
local function nameTable(entries)
	local records, strings, offset = {}, {}, 0

	for _, entry in ipairs(entries) do
		local text = utf16(entry.text)
		local platform = entry.platform ?? 3

		records[#records + 1] = be16(platform) .. be16(platform == 1 and 0 or 1) .. be16(0x409)
			.. be16(entry.id) .. be16(#text) .. be16(offset)

		strings[#strings + 1] = text
		offset += #text
	end

	return be16(0) .. be16(#records) .. be16(6 + #records * 12)
		.. table.concat(records) .. table.concat(strings)
end

--- The tables of a font file, with the table directory in front of them and every table padded to
--- the four bytes a font starts one on.
---@param tables { tag: string, data: string }[]
---@return string
local function assemble(tables)
	local records, body, at = {}, {}, 12 + #tables * 16

	for _, table in ipairs(tables) do
		local data = table.data .. string.rep("\0", (4 - #table.data % 4) % 4)

		records[#records + 1] = table.tag .. be32(0) .. be32(at) .. be32(#table.data)
		body[#body + 1] = data
		at += #data
	end

	return "\0\1\0\0" .. be16(#tables) .. be16(0) .. be16(0) .. be16(0)
		.. table.concat(records) .. table.concat(body)
end

--- A font file with nothing in it but what a scan reads: what it is called, how heavy it is and
--- whether it is slanted.
---@param opts { family: string, subfamily: string?, typographicFamily: string?, typographicSubfamily: string?, weight: number?, italic: boolean?, macItalic: boolean?, os2: boolean?, head: boolean?, platform: number?, padding: number? }
---@return string
local function buildFont(opts)
	local subfamily = opts.subfamily ?? "Regular"
	local names = {
		{ id = 1, text = opts.family, platform = opts.platform },
		{ id = 2, text = subfamily, platform = opts.platform },
	}

	if opts.typographicFamily ~= nil then
		names[#names + 1] = { id = 16, text = opts.typographicFamily, platform = opts.platform }
		names[#names + 1] = { id = 17, text = opts.typographicSubfamily ?? subfamily, platform = opts.platform }
	end

	local tables = { { tag = "name", data = nameTable(names) } }

	if opts.os2 ~= false then
		-- usWeightClass at four bytes in and fsSelection at sixty-two, which is where the parser
		-- looks for them: what is between is the rest of the table, which is nothing here.
		tables[#tables + 1] = { tag = "OS/2", data = be16(4) .. be16(500) .. be16(opts.weight ?? 400)
			.. string.rep("\0", 56) .. be16(opts.italic ? 1 : 0) }
	end

	if opts.head ~= false then
		tables[#tables + 1] = { tag = "head", data = string.rep("\0", 44)
			.. be16(opts.macItalic ? 2 : 0) .. string.rep("\0", 8) }
	end

	if opts.padding ~= nil then
		tables[#tables + 1] = { tag = "glyf", data = string.rep("\0", opts.padding) }
	end

	return assemble(tables)
end

--- A collection: a header naming where each of the fonts inside it starts, which is what a `.ttc` on
--- a machine is -- the faces of a family in one file.
---@param fonts string[]
---@return string
local function buildCollection(fonts)
	local offsets, body, at = {}, {}, 12 + #fonts * 4

	for _, font in ipairs(fonts) do
		offsets[#offsets + 1] = be32(at)
		body[#body + 1] = font
		at += #font
	end

	return "ttcf" .. be32(0x00010000) .. be32(#fonts) .. table.concat(offsets) .. table.concat(body)
end

--- A command that has to work, on the shell the platform runs one with.
---@param command string
local function sh(command)
	local ok = os.execute(command)

	assert(ok == true or ok == 0, "the shell refused: " .. command)
end

---@param dir string
---@param name string
---@param data string
local function writeFile(dir, name, data)
	local handle = assert(io.open(dir .. "/" .. name, "wb"))

	handle:write(data)
	handle:close()
end

--- A directory of font files, made for one test and removed at the end of it. This is what makes
--- these tests hermetic: the machine's own fonts are at no path any of them looks at.
---@param files { name: string, data: string }[]
---@return string
local function fontsDir(files)
	local dir = os.tmpname()

	os.remove(dir)
	sh((isWindows and "mkdir " or "mkdir -p ") .. '"' .. dir .. '"')

	for _, file in ipairs(files) do
		writeFile(dir, file.name, file.data)
	end

	return dir
end

---@param dir string
local function removeDir(dir)
	sh((isWindows and "rmdir /s /q " or "rm -rf ") .. '"' .. dir .. '"')
end

test.it("reads the family and the subfamily a font gives itself", function()
	local dir = fontsDir({ { name = "Some.ttf", data = buildFont({ family = "Test Sans", subfamily = "Bold" }) } })
	local faces = Registry.new({ dirs = { dir } }):faces()

	test.equal(#faces, 1, "one file is one face")
	test.equal(faces[1].family, "Test Sans")
	test.equal(faces[1].subfamily, "Bold")
	test.equal(faces[1].index, 0, "a file that holds one font is asked for as its font nought")
	test.includes(faces[1].path, "Some.ttf")

	removeDir(dir)
end)

test.it("takes the typographic family over the family name", function()
	local dir = fontsDir({ { name = "InterSemiBold.ttf", data = buildFont({
		family = "Inter SemiBold",
		subfamily = "Regular",
		typographicFamily = "Inter",
		typographicSubfamily = "SemiBold",
	}) } })

	local face = Registry.new({ dirs = { dir } }):faces()[1]

	test.equal(face.family, "Inter", "the name a stylesheet writes, not the name the file is filed under")
	test.equal(face.subfamily, "SemiBold")

	removeDir(dir)
end)

test.it("reads a name written in UTF-16 and one written for the Mac", function()
	local dir = fontsDir({
		{ name = "Accented.ttf", data = buildFont({ family = "Int\xC3\xA9r" }) },
		{ name = "Mac.ttf", data = buildFont({ family = "Mac Sans", platform = 1 }) },
	})

	test.deepEqual(Registry.new({ dirs = { dir } }):families(), { "Int\xC3\xA9r", "Mac Sans" },
		"a UTF-16 record becomes UTF-8 and a Mac record from a font with no Windows one is still a name")

	removeDir(dir)
end)

test.it("reads the weight out of the OS/2 table", function()
	local dir = fontsDir({
		{ name = "Regular.ttf", data = buildFont({ family = "Heavy Sans", weight = 400 }) },
		{ name = "Bold.ttf", data = buildFont({ family = "Heavy Sans", weight = 700 }) },
	})

	local faces = Registry.new({ dirs = { dir } }):faces()

	test.equal(faces[1].weight, 400, "the index puts the lighter face of a family first")
	test.equal(faces[2].weight, 700)

	removeDir(dir)
end)

test.it("reads italic from the selection flags of OS/2", function()
	local dir = fontsDir({ { name = "Slanted.ttf", data = buildFont({ family = "Slanted Sans", italic = true }) } })
	local face = Registry.new({ dirs = { dir } }):faces()[1]

	test.truthy(face.italic, "bit nought of fsSelection is what a font sets to say it is italic")

	removeDir(dir)
end)

test.it("reads italic from the head table where a font has none in OS/2", function()
	local dir = fontsDir({ { name = "Older.ttf", data = buildFont({
		family = "Older Sans",
		os2 = false,
		macItalic = true,
	}) } })

	local face = Registry.new({ dirs = { dir } }):faces()[1]

	test.truthy(face.italic, "macStyle says the same thing for a font that was made before OS/2")
	test.equal(face.weight, 400, "and a font that says nothing about its weight is set in the regular one")

	removeDir(dir)
end)

test.it("indexes every font a collection holds", function()
	local dir = fontsDir({ { name = "Family.ttc", data = buildCollection({
		buildFont({ family = "Collected", subfamily = "Regular" }),
		buildFont({ family = "Collected", subfamily = "Bold", weight = 700 }),
	}) } })

	local registry = Registry.new({ dirs = { dir } })
	local faces = registry:faces()

	test.equal(#faces, 2, "two fonts in one file are two faces")
	test.equal(faces[1].index, 0, "the first of them is the font at the front of the file")
	test.equal(faces[2].index, 1)
	test.equal(faces[1].path, faces[2].path, "and both are drawn from the same file")

	local path, index = registry:path("Collected", { weight = 700 })

	test.equal(path, faces[1].path, "a lookup of the heavier of them")
	test.equal(index, 1, "says which font of the file to draw")

	removeDir(dir)
end)

test.it("skips a file whose tables cannot be believed rather than raising", function()
	local good = buildFont({ family = "Readable" })
	local dir = fontsDir({
		{ name = "Cut.ttf", data = good:sub(1, 10) },
		{ name = "Truncated.ttf", data = good:sub(1, 12 + 3 * 16) },
		{ name = "Garbled.ttf", data = "\0\1\0\0" .. be16(60000) .. string.rep("\0", 200) },
		{ name = "Noise.ttf", data = string.rep("this is not a font", 40) },
		{ name = "Fine.ttf", data = good },
	})

	local faces = Registry.new({ dirs = { dir } }):faces()

	test.equal(#faces, 1, "the one file that is a font is the one face")
	test.equal(faces[1].family, "Readable", "a file cut short or full of noise is skipped and not raised on")

	removeDir(dir)
end)

test.it("reads a font's header and not the font", function()
	local dir = fontsDir({ { name = "Big.ttf", data = buildFont({ family = "Big Sans", padding = 400000 }) } })
	local file = assert(io.open(dir .. "/Big.ttf", "rb"))
	local read = 0
	local reader = function(offset, length)
		if file:seek("set", offset) == nil then
			return nil
		end

		local data = file:read(length)

		read += #(data ?? "")

		return data
	end

	local names = assert(sfnt.names(reader, 0))

	test.equal(names.family, "Big Sans")
	test.less(read, 4096, "a font of four hundred thousand bytes is named out of the first few of them")

	file:close()
	removeDir(dir)
end)

test.it("takes the closest weight of a family", function()
	local dir = fontsDir({
		{ name = "Light.ttf", data = buildFont({ family = "Pickable", weight = 300 }) },
		{ name = "Bold.ttf", data = buildFont({ family = "Pickable", weight = 700 }) },
	})

	local registry = Registry.new({ dirs = { dir } })

	test.includes(assert(registry:path("Pickable")), "Light.ttf", "a weight nobody asked for is the regular one")
	test.includes(assert(registry:path("Pickable", { weight = 600 })), "Bold.ttf", "and one asked for is answered with the nearer face")
	test.includes(assert(registry:path("Pickable", { weight = 700 })), "Bold.ttf")

	removeDir(dir)
end)

test.it("prefers the italic face when italic is asked for, and the upright otherwise", function()
	local dir = fontsDir({
		{ name = "Upright.ttf", data = buildFont({ family = "Slanty" }) },
		{ name = "Slanted.ttf", data = buildFont({ family = "Slanty", subfamily = "Italic", italic = true }) },
	})

	local registry = Registry.new({ dirs = { dir } })

	test.includes(assert(registry:path("Slanty")), "Upright.ttf", "text that says nothing about style is set upright")
	test.includes(assert(registry:path("Slanty", { italic = true })), "Slanted.ttf", "and italic is asked for by asking")

	removeDir(dir)
end)

test.it("looks a family up however its name is written", function()
	local dir = fontsDir({ { name = "NotoSans.ttf", data = buildFont({ family = "Noto Sans" }) } })
	local registry = Registry.new({ dirs = { dir } })

	test.includes(assert(registry:path("noto sans")), "NotoSans.ttf", "case is not part of a family name")
	test.includes(assert(registry:path("NotoSans")), "NotoSans.ttf", "nor is the spacing, which the name of a file has none of")

	removeDir(dir)
end)

test.it("resolves a generic name to the machine's default", function()
	local dir = fontsDir({
		{ name = "Inter.ttf", data = buildFont({ family = "Inter" }) },
		{ name = "NotoSans.ttf", data = buildFont({ family = "Noto Sans" }) },
	})

	local registry = Registry.new({ dirs = { dir } })
	local default = assert(registry:default())

	test.includes(default, "NotoSans.ttf", "the default is the sans a machine is likely to have")
	test.equal(registry:path("sans-serif"), default, "and a generic sans is the default")
	test.equal(registry:path("system-ui"), default)
	test.equal(registry:path("ui-sans-serif"), default)

	removeDir(dir)
end)

test.it("resolves a generic serif and a generic monospace", function()
	local dir = fontsDir({
		{ name = "NotoSans.ttf", data = buildFont({ family = "Noto Sans" }) },
		{ name = "NotoSerif.ttf", data = buildFont({ family = "Noto Serif" }) },
		{ name = "NotoMono.ttf", data = buildFont({ family = "Noto Sans Mono" }) },
	})

	local registry = Registry.new({ dirs = { dir } })

	test.includes(assert(registry:path("serif")), "NotoSerif.ttf", "a generic serif is the serif a machine is likely to have")
	test.includes(assert(registry:path("monospace")), "NotoMono.ttf", "and a generic monospace is its monospace")
	test.includes(assert(registry:path("ui-monospace")), "NotoMono.ttf")

	removeDir(dir)
end)

test.it("names every family once, in order", function()
	local dir = fontsDir({
		{ name = "Zeta.ttf", data = buildFont({ family = "Zeta Sans" }) },
		{ name = "ZetaBold.ttf", data = buildFont({ family = "Zeta Sans", weight = 700 }) },
		{ name = "Alpha.ttf", data = buildFont({ family = "Alpha Sans" }) },
	})

	test.deepEqual(Registry.new({ dirs = { dir } }):families(), { "Alpha Sans", "Zeta Sans" },
		"a family of two weights is named once, and the names are in order")

	removeDir(dir)
end)

test.it("puts the family asked for first in the fallbacks and the default last", function()
	local dir = fontsDir({
		{ name = "Inter.ttf", data = buildFont({ family = "Inter" }) },
		{ name = "DejaVuSans.ttf", data = buildFont({ family = "DejaVu Sans" }) },
		{ name = "CJK.ttf", data = buildFont({ family = "Noto Sans CJK SC" }) },
		{ name = "Emoji.ttf", data = buildFont({ family = "Noto Color Emoji" }) },
	})

	local registry = Registry.new({ dirs = { dir } })
	local paths = registry:fallbacks("Inter")

	test.equal(#paths, 4, "the family, a font with the ranges it has nothing for, an emoji font, and the default")
	test.includes(paths[1], "Inter.ttf", "the family asked for is asked first")
	test.includes(paths[2], "CJK.ttf", "then a sans that has the script a latin font has not")
	test.includes(paths[3], "Emoji.ttf", "then a picture in place of a character")
	test.includes(paths[4], "DejaVuSans.ttf", "and the default is the last thing tried")

	removeDir(dir)
end)

test.it("asks for a script a latin font has nothing of, after the font of pictures", function()
	local dir = fontsDir({
		{ name = "Inter.ttf", data = buildFont({ family = "Inter" }) },
		{ name = "Emoji.ttf", data = buildFont({ family = "Noto Color Emoji" }) },
		{ name = "Arabic.ttf", data = buildFont({ family = "Noto Naskh Arabic" }) },
		{ name = "Hebrew.ttf", data = buildFont({ family = "Noto Sans Hebrew" }) },
	})

	local registry = Registry.new({ dirs = { dir } })
	local paths = registry:fallbacks("Inter")

	test.equal(#paths, 4, "the two scripts this machine has are asked for after the font of pictures")
	test.includes(paths[1], "Inter.ttf")
	test.includes(paths[2], "Emoji.ttf", "the font of pictures is asked before the scripts")
	test.includes(paths[3], "Arabic.ttf", "then the script a line of arabic is drawn with")
	test.includes(paths[4], "Hebrew.ttf", "and the next one")

	test.deepEqual(registry:fallbacks("No Such Family"),
		{ registry:default(), assert(paths[2]), assert(paths[3]), assert(paths[4]) },
		"and a family the machine does not have is still drawn in them")

	removeDir(dir)
end)

test.it("finds a script by the name of the family it is in, where no known family is here", function()
	local dir = fontsDir({
		{ name = "Inter.ttf", data = buildFont({ family = "Inter" }) },
		{ name = "Naskh.ttf", data = buildFont({ family = "Some Arabic Naskh" }) },
	})

	local registry = Registry.new({ dirs = { dir } })
	local paths = registry:fallbacks("Inter")

	test.equal(#paths, 2, "the family asked for and the script")
	test.includes(paths[2], "Naskh.ttf",
		"a family whose own name says which script it is for is what a machine nobody listed is asked about")

	removeDir(dir)
end)

test.it("keeps a path out of the fallbacks twice asked for", function()
	local dir = fontsDir({ { name = "DejaVuSans.ttf", data = buildFont({ family = "DejaVu Sans" }) } })
	local registry = Registry.new({ dirs = { dir } })

	test.deepEqual(registry:fallbacks("DejaVu Sans"), { registry:faces()[1].path },
		"a family that is the default is in the list once")

	test.equal(#registry:fallbacks("No Such Family"), 1, "and a family the machine does not have at all is the default alone")

	removeDir(dir)
end)

test.it("looks only where it was pointed", function()
	local dir = fontsDir({ { name = "Only.ttf", data = buildFont({ family = "Only Sans" }) } })
	local registry = Registry.new({ dirs = { dir } })
	local faces = registry:faces()

	test.equal(#faces, 1, "the platform's own font directories are not looked at when dirs are given")
	test.truthy(faces[1].path:find(dir, 1, true) ~= nil, "the one face is the file that was written")
	test.equal(registry:default(), faces[1].path, "and the default is a font from there")
	test.equal(registry:path("DejaVu Sans"), faces[1].path,
		"so a family this machine is likely to have is answered from the directory as well")

	removeDir(dir)
end)

test.it("looks under a filesystem root for the platform's font directories", function()
	local root = os.tmpname()
	local nested = root .. "/usr/share/fonts/dejavu"

	os.remove(root)

	-- cmd takes no -p, and one directory of a tree is the tree.
	sh((isWindows and "mkdir " or "mkdir -p ") .. '"' .. nested .. '"')
	writeFile(nested, "Rooted.ttf", buildFont({ family = "Rooted Sans" }))

	local faces = Registry.new({ roots = { root } }):faces()

	test.equal(#faces, 1, "a root is walked where it keeps fonts, and a font two directories down is found")
	test.equal(faces[1].family, "Rooted Sans")

	removeDir(root)
end)

test.it("takes a root that is a directory of fonts for what it is", function()
	local root = fontsDir({ { name = "Plain.ttf", data = buildFont({ family = "Plain Sans" }) } })
	local faces = Registry.new({ roots = { root } }):faces()

	test.equal(#faces, 1, "a root with none of the platform's directories under it is a font directory")
	test.equal(faces[1].family, "Plain Sans")

	removeDir(root)
end)

test.it("drops what it found when it is told to look again", function()
	local dir = fontsDir({ { name = "First.ttf", data = buildFont({ family = "First Sans" }) } })
	local registry = Registry.new({ dirs = { dir } })

	test.equal(#registry:faces(), 1)
	test.includes(assert(registry:path("First Sans")), "First.ttf")

	writeFile(dir, "Second.ttf", buildFont({ family = "Second Sans" }))

	test.equal(#registry:faces(), 1, "a scan that has been made is not made again")

	registry:clear()

	test.equal(#registry:faces(), 2, "and one that has been dropped is")
	test.includes(assert(registry:path("Second Sans")), "Second.ttf",
		"which is what a font installed while an app runs needs")

	removeDir(dir)
end)

test.it("answers nothing where there is no font and no default", function()
	local dir = fontsDir({})
	local registry = Registry.new({ dirs = { dir } })

	test.deepEqual(registry:families(), {}, "a directory with no fonts in it has no families")
	test.equal(registry:default(), nil, "and so it has no default")
	test.equal(registry:path("Inter"), nil, "which makes a family name nothing is a name with no file")
	test.deepEqual(registry:fallbacks("Inter"), {}, "and a fallback list with nothing in it")

	removeDir(dir)
end)

test.it("does not mind a directory that is not there", function()
	local registry = Registry.new({ dirs = { "/no/such/font/directory" } })

	test.equal(#registry:faces(), 0)
	test.equal(registry:path("Inter"), nil)
end)
