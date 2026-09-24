-- What fontconfig says a name is, where the machine has fontconfig.
--
--   local fontconfig = require("wonderland.font.fontconfig")
--   local path, index = fontconfig.match("sans-serif")
--
-- A stylesheet writes names where a family would go -- "sans-serif", "system-ui" -- and which font
-- those come to is what a desktop was set to draw text in. No list of family names can know that, and
-- fontconfig is what does: it is the machine's own answer, and every machine with a desktop on it has
-- one.
--
-- Everything here is guarded. Fontconfig is not on every machine -- a server, a container, a Windows
-- or a macOS desktop -- and one that is there can still be handed a name it cannot parse. A machine
-- without it answers nothing at all, and what answers instead is the scan in `wonderland.font.scan`,
-- which knows the family names a machine is likely to have.
local ffi = require("ffi")

local fontconfig = {}

ffi.cdef [[
	typedef struct wl_fc_pattern wl_fc_pattern;

	int FcInit(void);
	wl_fc_pattern *FcNameParse(const char *name);
	int FcConfigSubstitute(void *config, wl_fc_pattern *pattern, int kind);
	void FcDefaultSubstitute(wl_fc_pattern *pattern);
	wl_fc_pattern *FcFontMatch(void *config, wl_fc_pattern *pattern, int *result);
	int FcPatternGetString(wl_fc_pattern *pattern, const char *object, int index, unsigned char **value);
	int FcPatternGetInteger(wl_fc_pattern *pattern, const char *object, int index, int *value);
	void FcPatternDestroy(wl_fc_pattern *pattern);
]]

-- The name a linker resolves for a build and the name a runtime package installs are not the same
-- one: the first is a symlink that only a machine which builds against the library has.
local FONTCONFIG = { "fontconfig", "libfontconfig.so.1", "libfontconfig.1.dylib", "libfontconfig-1.dll" }

local library = nil

for _, name in ipairs(FONTCONFIG) do
	local ok, loaded = pcall(ffi.load, name)

	if ok then
		library = loaded
		break
	end
end

--- What fontconfig says a name is: the family pattern the name makes, and the font the machine's own
--- configuration matches it to. Which font "sans-serif" is is what a desktop was set to, and no list
--- of family names can know that.
---
--- All of it is guarded: fontconfig is not on every machine, and one that is there can still be
--- handed a name it cannot parse. A machine without it answers nothing, and the scan answers.
---@param name string
---@return string? path
---@return number? index
function fontconfig.match(name)
	if library == nil or library.FcInit() == 0 then return nil, nil end

	local ok, path, index = pcall(function()
		local pattern = library.FcNameParse(name)

		if pattern == nil then return nil, nil end

		-- A pattern of one family is not a font: what turns "sans-serif" into one is the desktop's
		-- substitutions, which also fill in the weight and the slant that were not named. Matching
		-- without them answers with whatever the first font in the configuration happens to be,
		-- which is how a Type 1 file from an X11 directory becomes a machine's default sans.
		library.FcConfigSubstitute(nil, pattern, 0)
		library.FcDefaultSubstitute(pattern)

		local result = ffi.new("int[1]")
		local matched = library.FcFontMatch(nil, pattern, result)
		local file, spot = ffi.new("unsigned char *[1]"), ffi.new("int[1]")
		local path, index = nil, nil

		if matched ~= nil then
			if library.FcPatternGetString(matched, "file", 0, file) == 0 then path = ffi.string(file[0]) end
			if library.FcPatternGetInteger(matched, "index", 0, spot) == 0 then index = tonumber(spot[0]) end

			library.FcPatternDestroy(matched)
		end

		library.FcPatternDestroy(pattern)

		return path, index
	end)

	if not ok then return nil, nil end

	return path, index
end

return fontconfig
