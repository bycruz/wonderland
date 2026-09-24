-- Where the fonts on a machine are, and the walk that reads what they are called.
--
--   local scan = require("wonderland.font.scan")
--   local dirs = scan.dirs({})                 -- this machine's own font directories
--   local faces = scan.faces(dirs)             -- one record a font, by the name it is found by
--
-- A desktop has a few hundred font files and an app that names a family wants the one that is it.
-- What a file is called is in its header, and a font is megabytes of outlines behind a two-kilobyte
-- header, so the header is what is read: a walk of a machine's font directories is a few hundred
-- seeks of a few kilobytes rather than a few hundred megabytes of reading.
--
-- Reading a directory is the one thing the C library does not spell the same way on two platforms,
-- which is the whole of the ffi below: everything above it is the walk, and everything after it is
-- the header parser in `wonderland.font.sfnt`.
local ffi = require("ffi")
local sfnt = require("wonderland.font.sfnt")

local scan = {}

--- One face of one font file, as a walk finds it: which file, which font in it, and what it says it
--- is called. The class is the registry's, because a face is what a lookup answers with.
---@class wonderland.font.Face
---@field path string
---@field family string
---@field subfamily string
---@field weight number # As CSS counts it: 100 to 900
---@field italic boolean
---@field index number # Which face of the file, nought for a file that holds one

local isWindows = ffi.os == "Windows"
local is64Bit = ffi.arch:find("64") ~= nil
local SEP = isWindows and "\\" or "/"

-- Reading a directory is the one thing the C library does not spell the same way twice: the name of
-- an entry sits at a different offset in every `struct dirent`, so the layout is written out per
-- platform. A layout that is guessed wrong reads a name that is not a file, which is a font skipped
-- -- the same thing that happens to a file which cannot be parsed.
local entry = "uint32_t ino; int32_t off; uint16_t reclen; uint8_t type; char name[256];"

if ffi.os == "OSX" then
	entry = "uint64_t ino; uint64_t seek; uint16_t reclen; uint16_t namlen; uint8_t type; char name[1024];"
elseif is64Bit then
	entry = "uint64_t ino; int64_t off; uint16_t reclen; uint8_t type; char name[256];"
end

ffi.cdef(([[
	typedef struct wl_dir wl_dir;
	struct wl_dirent { %s };
	wl_dir *opendir(const char *path);
	struct wl_dirent *readdir(wl_dir *dir);
	int closedir(wl_dir *dir);

	// Windows spells the same thing as a pattern rather than a directory, and writes the entry into
	// the struct it was handed instead of returning a pointer to one.
	struct wl_find_data {
		uint32_t attributes, createdLow, createdHigh, accessedLow, accessedHigh;
		uint32_t writtenLow, writtenHigh, sizeHigh, sizeLow, reserved0, reserved1;
		char name[260];
		char shortName[14];
	};

	intptr_t FindFirstFileA(const char *pattern, struct wl_find_data *data);
	int FindNextFileA(intptr_t find, struct wl_find_data *data);
	int FindClose(intptr_t find);
]]):format(entry))

--- A directory entry as the C library writes it, which the language server cannot see.
---@class wonderland.font.ffi.dirent: ffi.cdata*
---@field name string

local kernel32 = isWindows and ffi.load("kernel32") or nil

-- How deep under a font directory the walk goes: fonts sit a directory or two down everywhere, and a
-- directory that links back to one above it is a walk with no end to it.
local MAX_DEPTH = 12

-- What a font file is called, which is all there is to go on before its header is read.
local FONT_FILES = { [".ttf"] = true, [".otf"] = true, [".ttc"] = true, [".otc"] = true }

--- The names in a directory, or nothing where the path is not one. A walk asks this to tell a
--- directory from a file, so a tree of fonts is walked without asking the filesystem twice.
---@param path string
---@return string[]?
local function listDir(path)
	if isWindows then
		local data = ffi.new("struct wl_find_data")
		local find = kernel32.FindFirstFileA(path .. "\\*", data)

		if find == -1 then return nil end

		local names = {}

		repeat
			local name = ffi.string(data.name)

			if name ~= "." and name ~= ".." then names[#names + 1] = name end
		until kernel32.FindNextFileA(find, data) == 0

		kernel32.FindClose(find)

		return names
	end

	local dir = ffi.C.opendir(path)

	if dir == nil then return nil end

	local names, spot = {}, ffi.C.readdir(dir)

	while spot ~= nil do
		---@cast spot wonderland.font.ffi.dirent
		local name = ffi.string(spot.name)

		if name ~= "." and name ~= ".." then names[#names + 1] = name end

		spot = ffi.C.readdir(dir)
	end

	ffi.C.closedir(dir)

	return names
end

--- Where each platform keeps fonts, the system's own and the user's. What a registry is handed when
--- the caller did not say where to look.
---@return string[]
local function platformDirs()
	local home = os.getenv("HOME") ?? ""

	-- A font a user installed without being an administrator goes to a directory of theirs rather
	-- than into the system's.
	if isWindows then
		local root = os.getenv("SystemRoot") or "C:\\Windows"
		local appData = os.getenv("LOCALAPPDATA")

		return appData ~= nil
			? { root .. "\\Fonts", appData .. "\\Microsoft\\Windows\\Fonts" }
			: { root .. "\\Fonts" }
	end

	-- The Supplemental directories on a Mac are under these and are walked with them.
	if ffi.os == "OSX" then
		return { "/System/Library/Fonts", "/Library/Fonts", "/Network/Library/Fonts",
			home .. "/Library/Fonts" }
	end

	local data = os.getenv("XDG_DATA_HOME")
	local dirs = { "/usr/share/fonts", "/usr/local/share/fonts", "/usr/share/X11/fonts",
		data ?? (home .. "/.local/share/fonts"), home .. "/.fonts" }

	-- A sandboxed app -- a flatpak, a snap -- sees the machine's filesystem under /run/host and not
	-- at the root, so the machine's own fonts are at none of the paths above.
	if listDir("/run/host/fonts") ~= nil then dirs[#dirs + 1] = "/run/host/fonts" end

	return dirs
end

-- Where fonts are, relative to the root of a filesystem: what a root handed to a registry is walked
-- for, since a root is a filesystem and not a font directory.
local PLATFORM_PATHS = { "usr/share/fonts", "usr/local/share/fonts", "usr/share/X11/fonts",
	"Windows/Fonts", "System/Library/Fonts", "Library/Fonts" }

--- Adds the font directories under a filesystem root, or the root itself where it has none of them,
--- which is what makes a registry pointed at a root and one pointed at a directory mean one thing.
---@param root string
---@param dirs string[]
local function addUnder(root, dirs)
	local found = false

	for _, relative in ipairs(PLATFORM_PATHS) do
		local dir = root .. SEP .. (relative:gsub("/", SEP))

		if listDir(dir) ~= nil then
			dirs[#dirs + 1] = dir
			found = true
		end
	end

	if not found then dirs[#dirs + 1] = root end
end

--- Where a registry looks, given what it was made with. Directories of its own replace the
--- platform's, which is the whole of what makes a scan something a test can depend on.
---@param opts { dirs: string[]?, roots: string[]? }?
---@return string[] dirs
---@return boolean isPlatform
function scan.dirs(opts)
	if opts == nil or (opts.dirs == nil and opts.roots == nil) then return platformDirs(), true end

	local dirs = {}

	for _, dir in ipairs(opts.dirs ?? {}) do dirs[#dirs + 1] = dir end
	for _, root in ipairs(opts.roots ?? {}) do addUnder(root, dirs) end

	return dirs, false
end

--- The reads of one open file, as the header parser wants them: it seeks, which is what keeps a font
--- file from being read whole to learn its name.
---@param file file*
---@return wonderland.font.Reader
local function readerOf(file)
	return function(offset, length)
		if file:seek("set", offset) == nil then return nil end

		return file:read(length)
	end
end

--- Every face of one font file, added to the index. A file that is not a font, that is cut off, or
--- that holds no name to be found by is skipped rather than raised: a font directory holds whatever
--- has been put in it, and a file nothing can read is a font missing from a list, not a crash.
---@param path string
---@param faces wonderland.font.Face[]
local function indexFile(path, faces)
	local file = io.open(path, "rb")

	if file == nil then return end

	local reader = readerOf(file)
	local offsets = sfnt.offsets(reader)

	if offsets ~= nil then
		for at, offset in ipairs(offsets) do
			local names = sfnt.names(reader, offset)

			if names ~= nil then
				faces[#faces + 1] = { path = path, family = names.family, subfamily = names.subfamily,
					weight = names.weight, italic = names.italic, index = at - 1 }
			end
		end
	end

	file:close()
end

--- Walks a directory and everything under it, indexing every font file. A listing that was handed in
--- is used rather than made again: a directory is listed once, and what comes back says both what is
--- in it and that it is a directory at all.
---@param dir string
---@param faces wonderland.font.Face[]
---@param entries string[]?
---@param level number
local function walk(dir, faces, entries, level)
	local names = entries ?? listDir(dir)

	if names == nil or level > MAX_DEPTH then return end

	for _, name in ipairs(names) do
		local path = dir .. SEP .. name
		local inside = listDir(path)

		if inside ~= nil then
			walk(path, faces, inside, level + 1)
		elseif FONT_FILES[((name:match("%.[^%.]+$") or ""):lower())] then
			indexFile(path, faces)
		end
	end
end

--- Every face of every font under these directories, added to the list given where there is one: a
--- registry keeps one index of a machine -- several directories of it, and a directory listed once
--- however many paths lead to it -- so what a walk finds goes into the list it is already holding.
---
--- The order is the filesystem's, which is not something two runs agree on: what sorts them is the
--- registry, which is where what a lookup answers with is decided.
---@param dirs string[]
---@param into wonderland.font.Face[]?
---@return wonderland.font.Face[]
function scan.faces(dirs, into)
	local faces = into or {}

	for _, dir in ipairs(dirs) do
		walk(dir, faces, nil, 0)
	end

	return faces
end

return scan
