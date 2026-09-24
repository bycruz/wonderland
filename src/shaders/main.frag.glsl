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
layout(location = 5) in vec2 edge;

layout(location = 0) out vec4 fragColor;

void main() {
    #ifdef VULKAN
    vec4 texColor = texture(sampler2DArray(uTextureArray, uSampler), vec3(texCoord * textureUVScale[texIndex], texIndex));
    #else
    vec4 texColor = texture(uTextureArray, vec3(texCoord * textureUVScale[texIndex], texIndex));
    #endif

    fragColor = texColor * vertexColor;

    // A box that is cut is drawn as the box it is and cut here instead, so that it costs one quad
    // and no more geometry than a square one. How far this pixel is from the box is the distance
    // to the arcs' box outside it, and how deep it is inside it when it is, less the radius: the
    // second half is what a shadow's middle is solid by, since the distance to a box falls to
    // nought rather than to its middle. The band says how far the edge is spread over -- one pixel
    // either side for a box with round corners, more for a shadow -- and the pixels within it are
    // drawn as far in as the edge crosses them, which is what keeps a cut from being jagged.
    if (edge.y > 0.0) {
        vec2 q = abs(corner) - inner;
        float outside = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - edge.x;

        fragColor.a *= clamp(0.5 - outside * edge.y, 0.0, 1.0);
    }
}
