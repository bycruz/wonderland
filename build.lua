-- Build script for wonderland.
--
-- One thing happens here: the shaders are embedded as Lua strings so the runtime
-- needs no asset files. Nothing is compiled into the package and nothing is
-- fetched: what draws text is the machine's own libraries, through `texter`, and
-- what draws the window is `hood` and `winit`.
--
-- What used to be here was stb_truetype: a header fetched from a pinned revision
-- and compiled into a shared library of its own, shipped beside the package. It
-- read TrueType outlines and nothing else -- no CFF outlines, no collections, no
-- emoji -- which is a font of Japanese drawn as missing-glyph boxes on a machine
-- whose Japanese font is a CFF collection.
local build = require("lde-build")

local isWindows = jit.os == "Windows"
local isMsvc = build.target:find("msvc") ~= nil
local sep = string.sub(package.config, 1, 1)

-- hood's OpenGL backend compiles GLSL itself, so it takes the source text, while
-- vulkan takes SPIR-V, which has to be compiled here. The runtime picks the flavor off
-- the same variable, so a build has to agree with the run: vulkan unless OPENGL is set.
local isVulkan = os.getenv("OPENGL") == nil

--- Whether a tool is on PATH. lde runs a build's shell commands with cmd.exe on windows
--- and sh everywhere else, which is what the two spellings of "is it there" are for.
---@param tool string
---@return boolean
local function has(tool)
	local command = isWindows and ("where " .. tool) or ("command -v " .. tool)
	local quiet = isWindows and " >NUL 2>NUL" or " >/dev/null 2>&1"

	return os.execute(command .. quiet) == 0
end

--- The compilers that turn GLSL into the SPIR-V vulkan takes, in the order they are looked
--- for, and the command each of them is given: the stage, the source and the output, which
--- they name differently. glslc is shaderc's and glslangValidator is glslang's, under the
--- name glslang now that its validator is the same program as its compiler -- a windows
--- machine only ever has that one, since glslang's windows release ships no glslangValidator.
--- Neither package is on every machine, and most machines have one of the two. All three
--- define VULKAN while compiling for vulkan, which is the branch of the shaders that hood's
--- vulkan backend needs.
local SPIRV = {
	{ tool = "glslc", command = 'glslc -fshader-stage=%s "%s.glsl" -o "%s.spv"' },
	{ tool = "glslangValidator", command = 'glslangValidator -V -S %s "%s.glsl" -o "%s.spv"' },
	{ tool = "glslang", command = 'glslang -V -S %s "%s.glsl" -o "%s.spv"' },
}

---@type { tool: string, command: string }?
local spirv = nil

if isVulkan then
	for _, candidate in ipairs(SPIRV) do
		if has(candidate.tool) then
			spirv = candidate
			break
		end
	end

	if not spirv then
		error("the shaders are compiled to SPIR-V for the vulkan backend, with glslc, "
			.. "glslangValidator or glslang, and none of the three is on PATH: install shaderc "
			.. "or glslang (glslc on ubuntu, glslang-tools on ubuntu and debian, glslang in "
			.. "termux, msys2, fedora and homebrew, or glslang's release for windows), or set "
			.. "OPENGL=1 to build for the opengl backend, which compiles the shaders itself and "
			.. "needs none of them")
	end

	print("compiling the shaders with " .. spirv.tool)
end

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

	if spirv then
		build:sh(string.format(spirv.command, stage, source, source))
		flavors[#flavors + 1] = "spv"
	end

	for _, flavor in ipairs(flavors) do
		local content = build:read(source .. "." .. flavor)
		build:write(module .. sep .. flavor .. ".lua", 'return "' .. toLuaLiteral(content) .. '"')
	end

	if spirv then
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
