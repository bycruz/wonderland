-- Fonts: which file on this machine a family name comes to.
--
--   local fonts = require("wonderland.font.registry").new()
--   local path, index = fonts:path("Inter", { weight = 700 })
--
-- Drawing text wants a font file and a face inside it, and what an app has to say is a family and a
-- weight. This walks the font directories, reads the header of every font file it finds, and answers
-- with the face closest to what was asked for.
--
-- The walk happens on the first lookup and never in the constructor: an app that names a font wants
-- one, and a scan of the machine's font directories is not something to spend on an app that has not
-- drawn text yet. What is read of a file is its header rather than the file -- a desktop has a few
-- hundred fonts, and reading them whole to learn their names is a couple of hundred megabytes for
-- what the first kilobyte of each says -- and what the scan found is kept, so the second lookup of a
-- family costs a table index.
--
-- A registry can be pointed at directories of its own, and that replaces the platform's entirely. It
-- is what makes a scan something a test can depend on, and what an app that ships its own fonts
-- wants. Fontconfig is asked where the machine has it, for the names that are not families at all:
-- "sans-serif" names what a desktop is set to draw text in, and fontconfig is what knows.
--
-- Where the fonts are and what a name that is not a family comes to are two questions of their own,
-- and they are two modules of their own: `wonderland.font.scan` walks the directories and
-- `wonderland.font.fontconfig` asks the machine. What is left here is the index they fill and the
-- lookup a name comes to.
local fontconfig = require("wonderland.font.fontconfig")
local scan = require("wonderland.font.scan")

--- What a lookup came to. A lookup that came to nothing is remembered as well, so that asking for a
--- font the machine does not have is a table index rather than another walk of the index.
---@class wonderland.font.Lookup
---@field path string?
---@field index number?


---@param index table<string, wonderland.font.Face[]>
---@param key string
---@param face wonderland.font.Face
local function addFace(index, key, face)
	local list = index[key]

	if list == nil then
		list = {}
		index[key] = list
	end

	list[#list + 1] = face
end

--- A family name with its spaces taken out, which is how the name of a font file is written and so
--- how a caller that read one asks for it: "NotoSans" for "Noto Sans".
---@param family string
---@return string
local function foldSpaces(family)
	return (family:gsub("%s+", ""))
end

--- The face of a family that comes closest to a weight and a slant. The slant is settled first and
--- the weight gives way to it, which is what a browser does and what an app asking for italic means:
--- italic text is set in italic wherever the machine can set it, at whatever weight that leaves it,
--- and the upright is for a family that has no italic at all.
---@param faces wonderland.font.Face[]
---@param weight number
---@param isItalic boolean
---@return wonderland.font.Face?
local function closest(faces, weight, isItalic)
	local wanted = isItalic

	for _ = 1, 2 do
		local best, bestDistance = nil, nil

		for _, face in ipairs(faces) do
			local distance = math.abs(face.weight - weight)

			if face.italic == wanted and (bestDistance == nil or distance < bestDistance) then
				best, bestDistance = face, distance
			end
		end

		if best ~= nil then return best end

		wanted = not wanted
	end
end

--- The order of the index: family, then weight, then upright before italic, then path. A machine
--- hands its font files back in whatever order its filesystem lists them, and two machines with the
--- same fonts should draw the same text -- and a test should not depend on which of two files the
--- filesystem happened to mention first.
---@param a wonderland.font.Face
---@param b wonderland.font.Face
---@return boolean
local function inOrder(a, b)
	local left, right = a.family:lower(), b.family:lower()

	if left ~= right then return left < right end
	if a.weight ~= b.weight then return a.weight < b.weight end
	if a.italic ~= b.italic then return not a.italic end
	if a.subfamily ~= b.subfamily then return a.subfamily < b.subfamily end
	if a.path ~= b.path then return a.path < b.path end

	return a.index < b.index
end

-- The families a machine is likely to have of each kind, best first: what a generic name comes to
-- where there is no fontconfig to ask, and what a machine that names no font is drawn in. A machine
-- with none of them is answered with the first family whose own name says the kind -- "Noto Sans CJK
-- SC" for a script, "Noto Color Emoji" for a picture -- so these are preferences, not requirements.
local PREFERRED = {
	sans = { "Noto Sans", "DejaVu Sans", "Liberation Sans", "Segoe UI", "Arial", "Helvetica",
		"Cantarell", "Ubuntu", "Roboto", "Inter", "Open Sans", "Source Sans 3", "FreeSans" },
	serif = { "Noto Serif", "DejaVu Serif", "Liberation Serif", "Times New Roman", "Georgia",
		"FreeSerif", "Nimbus Roman" },
	monospace = { "Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", "Consolas", "Menlo",
		"Monaco", "Courier New", "FreeMono", "Hack", "JetBrains Mono" },
	cjk = { "Noto Sans CJK SC", "Noto Sans CJK TC", "Noto Sans CJK JP", "Noto Sans CJK KR",
		"Noto Sans SC", "Noto Sans TC", "Noto Sans JP", "Noto Sans KR", "Source Han Sans SC",
		"WenQuanYi Zen Hei", "Microsoft YaHei", "PingFang SC", "Malgun Gothic", "Meiryo",
		"Droid Sans Fallback" },
	emoji = { "Noto Color Emoji", "Apple Color Emoji", "Segoe UI Emoji", "Twemoji Mozilla",
		"Symbola" },
}

-- The names a stylesheet writes where a family would go. They name a kind of font rather than a
-- font, and which file they come to is the machine's answer.
local GENERIC = {
	["sans-serif"] = "sans", ["system-ui"] = "sans", ["ui-sans-serif"] = "sans",
	serif = "serif", ["ui-serif"] = "serif",
	monospace = "monospace", ["ui-monospace"] = "monospace",
}


---@class Registry
---@field private dirs string[] # Where fonts are looked for
---@field private isPlatform boolean # Whether those are this machine's own directories
---@field private index wonderland.font.Face[]? # What the last scan found, in order
---@field private familyList string[] # The distinct families in it
---@field private byFamily table<string, wonderland.font.Face[]> # By family, case folded
---@field private byName table<string, wonderland.font.Face[]> # And by it with the spaces out
---@field private memo table<string, wonderland.font.Lookup> # What a lookup came to, by its tuple
---@field private defaultLookup wonderland.font.Lookup? # And what the default came to
local Registry = {}
Registry.__index = Registry

--- A registry over a machine's fonts, or over directories of the caller's. Nothing is looked for
--- here: the index is built by the first lookup that needs it.
---@param opts { dirs: string[]?, roots: string[]? }?
---@return Registry
function Registry.new(opts)
	local dirs, isPlatform = scan.dirs(opts)

	return setmetatable({ dirs = dirs, isPlatform = isPlatform, familyList = {}, byFamily = {},
		byName = {}, memo = {} }, Registry)
end

--- Every face on this machine, in order: by family, then by weight, then upright before italic. This
--- is the scan, kept, and the first call that needs a font is what builds it.
---@return wonderland.font.Face[]
function Registry:faces()
	local known = self.index

	if known ~= nil then return known end

	local faces, families, seen = {}, {}, {}

	for _, dir in ipairs(self.dirs) do
		if seen[dir] == nil then
			seen[dir] = true
			scan.faces({ dir }, faces)
		end
	end

	table.sort(faces, inOrder)

	self.index = faces
	self.familyList = families
	self.byFamily = {}
	self.byName = {}
	self.memo = {}

	for _, face in ipairs(faces) do
		local folded = face.family:lower()

		if families[#families] ~= face.family then families[#families + 1] = face.family end

		addFace(self.byFamily, folded, face)
		addFace(self.byName, foldSpaces(folded), face)
	end

	return faces
end

--- Every family on this machine, once each, in order.
---@return string[]
function Registry:families()
	self:faces()

	return self.familyList
end

--- Drops what was found, so that the next lookup looks again: a font installed while an app is
--- running is a font the next scan finds.
function Registry:clear()
	self.index = nil
	self.defaultLookup = nil
	self.familyList = {}
	self.byFamily = {}
	self.byName = {}
	self.memo = {}
end

--- The face of a family: the family itself, then the same name with its spaces taken out.
---@param family string
---@param weight number
---@param isItalic boolean
---@return wonderland.font.Face?
function Registry:familyFace(family, weight, isItalic)
	self:faces()

	local folded = family:lower()
	local candidates = self.byFamily[folded] or self.byName[foldSpaces(folded)]

	if candidates == nil then return nil end

	return closest(candidates, weight, isItalic)
end

--- The face of the first family of a list that is on this machine, and where none of the listed
--- names is, of the first family whose own name says what was wanted: a machine with a font nobody
--- listed still has a font that says which script or which use it is for.
---@param families string[]
---@param marker string
---@param weight number
---@param isItalic boolean
---@return wonderland.font.Face?
function Registry:firstNamed(families, marker, weight, isItalic)
	for _, family in ipairs(families) do
		local face = self:familyFace(family, weight, isItalic)

		if face ~= nil then return face end
	end

	for _, family in ipairs(self:families()) do
		if family:lower():find(marker, 1, true) ~= nil then
			local face = self:familyFace(family, weight, isItalic)

			if face ~= nil then return face end
		end
	end
end

--- What fontconfig says a name is, where this machine has fontconfig and where this registry is
--- looking at the machine's own font directories.
---
--- A registry that was pointed at directories of its own was pointed at them to be asked about those
--- and not about the machine: a test that hands one two fonts it wrote itself would otherwise be
--- handed the system's sans every time, which is the one thing it is written not to depend on.
---@param name string
---@return string? path
---@return number? index
function Registry:platformMatch(name)
	if not self.isPlatform then return nil, nil end

	return fontconfig.match(name)
end

--- The file an app that names no font is drawn in: the machine's own sans-serif, which is
--- fontconfig's answer where the machine has fontconfig -- it knows what the desktop is set to --
--- and this file's own reading of the font directories where it has none.
---@return string? path
---@return number? index
function Registry:default()
	local known = self.defaultLookup

	if known ~= nil then return known.path, known.index end

	local path, index = self:platformMatch("sans-serif")

	if path == nil then
		-- A family a machine is likely to have as its sans, then any family that says sans, then
		-- anything at all: a font a screen can draw is better than one it cannot.
		local face = self:firstNamed(PREFERRED.sans, "sans", 400, false) or closest(self:faces(), 400, false)

		if face ~= nil then path, index = face.path, face.index end
	end

	self.defaultLookup = { path = path, index = index }

	return path, index
end

--- The file a generic name comes to. Serif and monospace are the machine's answer as much as the
--- default is, but there is no one family they are: fontconfig knows which serif a desktop chose,
--- and a machine without it is answered from the families a machine is likely to have.
---@param kind string
---@param weight number
---@param isItalic boolean
---@return string? path
---@return number? index
function Registry:generic(kind, weight, isItalic)
	if kind == "sans" then return self:default() end

	local path, index = self:platformMatch(kind)

	if path ~= nil then return path, index end

	local face = self:firstNamed(PREFERRED[kind], kind == "monospace" ? "mono" : kind, weight, isItalic)

	if face ~= nil then return face.path, face.index end

	return self:default()
end

--- Where the file for a family is, and which face of it, at a weight and a slant.
---
--- The order is the order a stylesheet means: the family itself, then the family with its spaces
--- taken out -- which is how the name of a font file is written, and so how a caller that read one
--- asks for it -- then the generic names, which are not families at all, and then the machine's
--- default, which is what an app naming a font it does not have is drawn in rather than nothing.
--- Nothing matched and no default is no answer, which is nothing rather than an error: a caller with
--- no font draws no text.
---@param family string
---@param opts { weight: number?, italic: boolean? }?
---@return string? path
---@return number? index
function Registry:path(family, opts)
	local weight = opts?.weight ?? 400
	local isItalic = opts?.italic ?? false
	local key = family .. "\0" .. weight .. (isItalic ? "\1" : "\0")
	local known = self.memo[key]

	if known ~= nil then return known.path, known.index end

	local face = self:familyFace(family, weight, isItalic)
	local generic = GENERIC[family:lower()]
	local path, index = nil, nil

	if face ~= nil then
		path, index = face.path, face.index
	elseif generic ~= nil then
		path, index = self:generic(generic, weight, isItalic)
	end

	if path == nil then path, index = self:default() end

	self.memo[key] = { path = path, index = index }

	return path, index
end

--- The files to try, in order, when drawing text: the family that was asked for, then a sans with
--- the ranges a latin font has nothing for, then an emoji font, then the machine's default. A face
--- that is not on this machine is simply not in the list.
---
--- Nothing here is asked whether it has a character. That is a question about one code point and one
--- face, asked as a run is drawn: the face that has the character draws it, and the list moves on
--- where none does. This is the order worth asking in, and a caller that asks each face in turn
--- needs no map of what any of them holds.
---@param family string
---@return string[]
function Registry:fallbacks(family)
	local paths, seen = {}, {}

	---@param path string?
	local function keep(path)
		if path ~= nil and seen[path] == nil then
			seen[path] = true
			paths[#paths + 1] = path
		end
	end

	keep(self:path(family))
	keep(self:firstNamed(PREFERRED.cjk, "cjk", 400, false)?.path)
	keep(self:firstNamed(PREFERRED.emoji, "emoji", 400, false)?.path)
	keep(self:default())

	return paths
end

return Registry
