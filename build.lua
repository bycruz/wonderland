-- Build script for wonderland.
--
-- Two things happen here: stb_truetype is compiled, and the shaders are embedded
-- as Lua strings so the runtime needs no asset files.
local build = require("lde-build")

local isWindows = jit.os == "Windows"
local isMac = jit.os == "OSX"
local isMsvc = build.target:find("msvc") ~= nil
local sep = string.sub(package.config, 1, 1)

-- A pinned revision, so a build does not move under the project.
local STB_TRUETYPE = "https://raw.githubusercontent.com/nothings/stb/"
	.. "6e9f34d5429cf16790ec43c9bac3f1ee4ad1f760/stb_truetype.h"

-- stb_truetype is a single header library: the header itself is compiled into a
-- shared library, which src/stbtt.lua loads from beside itself.
local STBTT_NAME = isWindows and "stbtt.dll" or (isMac and "libstbtt.dylib" or "libstbtt.so")

build:write("stb_truetype.h", build:fetch(STB_TRUETYPE))

-- One invocation compiles the header and links it, the way a single header
-- library is meant to be built. -x c is what makes clang treat it as C.
local args = { "-x", "c", "-O2" }

if isWindows then
	-- The header hides its symbols otherwise, and an MSVC linked DLL exports
	-- nothing without being told to.
	args[#args + 1] = "-DSTBTT_DEF=__declspec(dllexport)"
else
	args[#args + 1] = "-fPIC"
end

args[#args + 1] = "-DSTB_TRUETYPE_IMPLEMENTATION"

if isMac then
	args[#args + 1] = "-dynamiclib"
	args[#args + 1] = "-Wl,-dead_strip"
elseif isMsvc then
	args[#args + 1] = "-shared"
	args[#args + 1] = "-Wl,/OPT:REF"
else
	args[#args + 1] = "-shared"
	args[#args + 1] = "-Wl,--gc-sections"
end

args[#args + 1] = "-o"
args[#args + 1] = STBTT_NAME
args[#args + 1] = "stb_truetype.h"

if not isWindows then
	args[#args + 1] = "-lm"
end

build:cc(args)

-- hood's OpenGL backend compiles GLSL itself, so it takes the source text, while
-- vulkan takes SPIR-V. The runtime picks the flavor off the same variable, so a
-- build has to agree with the run: vulkan unless OPENGL is set.
local isVulkan = os.getenv("OPENGL") == nil

local escapes = {
	[34] = '\\"',
	[92] = "\\\\",
	[9] = "\\t",
	[10] = "\\n",
	[13] = "\\r"
}

--- Escapes quotes, backslashes and control characters so that both GLSL source and
--- binary SPIR-V survive as a Lua string literal.
---@param data string
---@return string
local function toLuaLiteral(data)
	return (data:gsub("[%z\1-\31\\\"]", function(char)
		return escapes[char:byte()] or string.format("\\%03d", char:byte())
	end))
end

--- main.vert.glsl becomes shaders/main/vert/glsl.lua, required as
--- wonderland.shaders.main.vert.glsl, with the SPIR-V flavor beside it under
--- vulkan.
---@param name string # base of the .glsl file
---@param stage "vert" | "frag" | "comp"
local function embedShader(name, stage)
	local source = "shaders" .. sep .. name
	local module = "shaders" .. sep .. (name:gsub("%.", sep))
	local flavors = { "glsl" }

	if isVulkan then
		build:sh(string.format('glslc -fshader-stage=%s "%s.glsl" -o "%s.spv"', stage, source, source))
		flavors[#flavors + 1] = "spv"
	end

	for _, flavor in ipairs(flavors) do
		local content = build:read(source .. "." .. flavor)
		build:write(module .. sep .. flavor .. ".lua", 'return "' .. toLuaLiteral(content) .. '"')
	end

	if isVulkan then
		build:delete(source .. ".spv")
	end
end

embedShader("main.vert", "vert")
embedShader("main.frag", "frag")

-- Anything under assets becomes a module of the same name, for fonts and icons a
-- caller wants embedded.
for _, file in ipairs(build:scan("assets")) do
	local content = build:read(file)
	build:write((file:gsub("%.[^%.]+$", "")) .. ".lua", 'return "' .. toLuaLiteral(content) .. '"')
end
