#version 450

#ifdef VULKAN
#define BINDING(s, b) layout(set = s, binding = b)
#define BUFFER_BINDING(s, b) layout(set = s, binding = b, std430)
#else
#define BINDING(s, b) layout(binding = b)
#define BUFFER_BINDING(s, b) layout(binding = b, std430)
#endif

#ifdef VULKAN
// Must separate them for Vulkan (and other future targets), where a sampler and the texture it
// reads are two objects.
BINDING(0, 0)uniform texture2DArray uTexture;
BINDING(0, 1)uniform sampler uSampler;
#else
// Can't separate them for OpenGL..
BINDING(0, 0)uniform sampler2DArray uTexture;
#endif

// Where a picture's rows are, per picture: the layer its first band is in, how many layers a
// picture of its height spans, and the last of them. A picture is uploaded in bands -- rows of it
// stacked as layers -- because an upload reaches the gpu through a window of host visible memory
// rather than the whole card, so what one upload holds is bounded however large a picture is.
BUFFER_BINDING(0, 2)readonly buffer PictureBands {
    vec4 pictureBand[];
};

layout(location = 0) in vec4 vertexColor;
layout(location = 1) in vec2 texCoord;
layout(location = 2) flat in int texIndex;
layout(location = 3) in vec2 corner;
layout(location = 4) in vec2 inner;
layout(location = 5) in vec2 edge;
// Whether this quad's picture is a picture of its own colours rather than a shape the colour is
// drawn through: a glyph a font draws as a picture -- an emoji -- is the colours it comes in, and
// what the vertex colour is of it is how opaque the element holding it is.
layout(location = 6) flat in float own;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 band = pictureBand[texIndex];

    // How far down the picture this pixel is, in bands: the whole of a picture that is one band is
    // the layer it is in, and one that is more is the band the row falls in.
    float down = texCoord.y * band.y;

    #ifdef VULKAN
    vec4 texColor = texture(sampler2DArray(uTexture, uSampler),
        vec3(texCoord.x, fract(down), min(band.x + floor(down), band.z)));
    #else
    vec4 texColor = texture(uTexture, vec3(texCoord.x, fract(down), min(band.x + floor(down), band.z)));
    #endif

    if (own > 0.5) {
        fragColor = vec4(texColor.rgb, texColor.a * vertexColor.a);
    } else {
        fragColor = texColor * vertexColor;
    }

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
