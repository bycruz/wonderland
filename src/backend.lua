-- Which GPU backend the app runs on.
--
-- Vulkan is the default; OpenGL is there for machines without it, and both the
-- build and the runtime have to agree on the choice, hence the one place:
--
--   OPENGL=1 lde ./examples/app.lua
-- A build embeds the shader flavor it was made for, so what the build left behind is what the
-- run is: asking for the flavor the other backend needs is asking for a module that was never
-- written, and a build for OpenGL run without OPENGL=1 is exactly that. The environment chooses
-- only when the build has both flavors, which is what a build with no setting leaves.
local spirv = pcall(require, "wonderland.shaders.main.vert.spv")
local glsl = pcall(require, "wonderland.shaders.main.vert.glsl")

local name = os.getenv("OPENGL") and "opengl" or "vulkan"

if spirv and not glsl then
	name = "vulkan"
elseif glsl and not spirv then
	name = "opengl"
end

local isVulkan = name == "vulkan"

---@class wonderland.Backend
---@field name hood.InstanceBackend
---@field isVulkan boolean
---@field shaderType "spirv" | "glsl" # What the backend's pipelines take
---@field shaderExt "spv" | "glsl" # The embedded shader flavor that matches
local backend = {
	name = name,
	isVulkan = isVulkan,
	shaderType = isVulkan and "spirv" or "glsl",
	shaderExt = isVulkan and "spv" or "glsl",
}

return backend
