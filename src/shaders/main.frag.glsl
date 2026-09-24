#version 450

#ifdef VULKAN
#define BINDING(s, b) layout(set = s, binding = b)
#define BUFFER_BINDING(s, b) layout(set = s, binding = b, std430)
#else
#define BINDING(s, b) layout(binding = b)
#define BUFFER_BINDING(s, b) layout(binding = b, std430)
#endif

#ifdef VULKAN
// Must separate them for Vulkan (and other future targets)
BINDING(0, 0)uniform texture2DArray uTextureArray;
BINDING(0, 1)uniform sampler uSampler;
#else
// Can't separate them for OpenGL..
BINDING(0, 0)uniform sampler2DArray uTextureArray;
#endif

BUFFER_BINDING(0, 2)readonly buffer TextureUVs {
    vec2 textureUVScale[];
};

layout(location = 0) in vec4 vertexColor;
layout(location = 1) in vec2 texCoord;
layout(location = 2) flat in int texIndex;
layout(location = 3) in vec2 corner;
layout(location = 4) in vec2 inner;
layout(location = 5) in float radius;

layout(location = 0) out vec4 fragColor;

void main() {
    #ifdef VULKAN
    vec4 texColor = texture(sampler2DArray(uTextureArray, uSampler), vec3(texCoord * textureUVScale[texIndex], texIndex));
    #else
    vec4 texColor = texture(uTextureArray, vec3(texCoord * textureUVScale[texIndex], texIndex));
    #endif

    fragColor = texColor * vertexColor;

    // A box with round corners is drawn as the box it is and cut here instead, so that it costs one
    // quad and no more geometry than a square one. How far this pixel is from the rounded box is
    // the distance to the arcs' box, less the radius: inside it is negative, and outside it is
    // positive by how far out it is. The pixels on the edge are the only ones that are neither
    // wholly in nor wholly out, and they are drawn as far in as the edge crosses them -- which is
    // what a corner that is not on a whole pixel needs to not be jagged.
    if (radius > 0.0) {
        float outside = length(max(abs(corner) - inner, vec2(0.0))) - radius;

        fragColor.a *= clamp(0.5 - outside, 0.0, 1.0);
    }
}
