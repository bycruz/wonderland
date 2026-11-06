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

// Everything a quad says once, and not once a corner of it, comes in flat: the quad is the thing
// that is drawn, and the rasteriser is handed four corners of one instance either way. What is
// interpolated is what a pixel of the quad has its own of -- which point of the picture it samples,
// and where it is from the middle of the box.
layout(location = 0) flat in vec4 vertexColor;
layout(location = 1) in vec2 texCoord;
layout(location = 2) flat in int texIndex;
layout(location = 3) in vec2 corner;
layout(location = 4) flat in vec2 inner;
layout(location = 5) flat in vec2 edge;
// How this quad's picture is drawn: 0 a shape the colour is drawn through, 1 a picture of its own
// colours -- an emoji, whose vertex colour is only how opaque the element holding it is -- and 2 the
// coverage of a glyph, which is drawn through the colour and corrected for gamma: see `TEXT_GAMMA`.
layout(location = 6) flat in float own;
// The part of the picture the box this quad is drawn for is, and how far what it draws is spread: a
// blur of nought for a quad that asked for none, which is nearly all of them.
layout(location = 7) flat in vec4 uvRect;
layout(location = 8) flat in float blur;
layout(location = 9) flat in float border;

// What a blurred quad is sampled with: the taps of it, as offsets from the pixel being drawn, in
// steps of the stride below, and what each of them is worth. The weights are a gaussian of the
// offsets -- e^-(r*r/2) at the deviation the stride is -- so that what the taps add up to is a
// spread of about the size that was asked for, and no more samples than these are taken.
const int TAPS = 12;
const vec2 TAP_AT[12] = vec2[12](
    vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
    vec2(1.0, 1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(-1.0, -1.0),
    vec2(2.0, 0.0), vec2(-2.0, 0.0), vec2(0.0, 2.0), vec2(0.0, -2.0));
const float TAP_WEIGHT[12] = float[12](
    0.105, 0.105, 0.105, 0.105,
    0.072, 0.072, 0.072, 0.072,
    0.035, 0.035, 0.035, 0.035);
const float TAP_CENTRE = 0.152;
// What the deviation of the offsets above and their weights comes to, as a share of the stride:
// the stride is the blur that was asked for divided by it.
const float TAP_STRIDE = 0.8;

// What the coverage of a glyph is corrected by. It is blended into a target that holds encoded
// colour, and half a pixel of white over black blended there is a value that shows less than half as
// bright as it should: light text on a dark screen loses the soft half of every edge and reads as
// jagged. Coverage is raised for light text and lowered for dark by this power, picked by how light
// the text is, which is the correction DirectWrite and Skia make to a gamma of their own. 1.8 rather
// than the 2.2 the display is, because full correction makes small text heavier than the platform's.
const float TEXT_GAMMA = 1.8;

layout(location = 0) out vec4 fragColor;

// One point of the picture: where in it a pixel is, looked up through the picture's own bands --
// the layer its first band is in and how many a picture of its height spans, since a picture tall
// enough is uploaded as rows stacked as layers.
vec4 fetch(vec2 uv, vec4 band) {
    float down = uv.y * band.y;

    #ifdef VULKAN
    return texture(sampler2DArray(uTexture, uSampler),
        vec3(uv.x, fract(down), min(band.x + floor(down), band.z)));
    #else
    return texture(uTexture, vec3(uv.x, fract(down), min(band.x + floor(down), band.z)));
    #endif
}

// And one point of it that is inside it: the space beside a picture is not the picture, and the cell
// beside a glyph in a sheet is another glyph, so a sample past the part of it this box is counts as
// nothing. It is what a blurred edge fades out by, and what keeps one glyph from smearing into the
// one packed beside it.
vec4 tap(vec2 uv, vec4 band) {
    if (uv.x < uvRect.x || uv.x > uvRect.z || uv.y < uvRect.y || uv.y > uvRect.w) {
        return vec4(0.0);
    }

    vec4 texel = fetch(uv, band);

    // Premultiplied, so that what the taps add up to is what is drawn where two of them meet rather
    // than the colour of a texel with nothing in it.
    return vec4(texel.rgb * texel.a, texel.a);
}

void main() {
    vec4 band = pictureBand[texIndex];
    vec4 texColor;

    if (blur > 0.0) {
        // How far one tap is from the next, in uv: the blur is in pixels and the picture covers the
        // box, which is the corners the vertex carried.
        vec2 span = vec2(uvRect.z - uvRect.x, uvRect.w - uvRect.y);
        vec2 box = 2.0 * (inner + vec2(edge.x));
        vec2 step = blur * TAP_STRIDE * span / max(box, vec2(1.0));

        vec4 sum = tap(texCoord, band) * TAP_CENTRE;

        for (int at = 0; at < TAPS; at++) {
            sum += tap(texCoord + TAP_AT[at] * step, band) * TAP_WEIGHT[at];
        }

        // Divided back out, because a colour is what was summed and the alpha is how much of it
        // there is: what is drawn is that colour through the vertex colour, or as it is for a
        // picture of its own.
        texColor = vec4(sum.rgb / max(sum.a, 0.004), sum.a);
    } else {
        texColor = fetch(texCoord, band);
    }

    if (own > 1.5) {
        float coverage = texColor.a;
        float light = pow(coverage, 1.0 / TEXT_GAMMA);
        float dark = 1.0 - pow(1.0 - coverage, 1.0 / TEXT_GAMMA);
        float luma = dot(vertexColor.rgb, vec3(0.2126, 0.7152, 0.0722));

        fragColor = vec4(vertexColor.rgb, vertexColor.a * mix(dark, light, luma));
    } else if (own > 0.5) {
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

        float outer = clamp(0.5 - outside * edge.y, 0.0, 1.0);

        if (border > 0.5) {
            // The inside edge of a ring is the same rounded box, moved in by the border's
            // thickness: between the two edges is the only part that keeps its colour.
            float innerEdge = clamp(0.5 + (outside + border) * edge.y, 0.0, 1.0);
            fragColor.a *= outer * innerEdge;
        } else {
            fragColor.a *= outer;
        }
    }
}
