#version 450

out gl_PerVertex {
    vec4 gl_Position;
};

// The unit square every quad is drawn as: where this corner of it is, nought to one, and how many
// pixels one of the quad's own coordinates is worth, which is half the window it is drawn into.
layout(location = 0) in vec2 aUnit;
layout(location = 1) in vec2 aScale;

// One quad, as an instance: where its four corners are, the box they are cut against, what part of
// a picture it samples, and what is left of it. Everything here is one a quad rather than one a
// corner of it, so it is read as it is rather than worked out again for each corner.
layout(location = 2) in vec4 aCorner01;   // its top left and top right corners
layout(location = 3) in vec4 aCorner23;   // and its bottom right and bottom left ones
layout(location = 4) in vec4 aBox;        // the middle of the box a corner is measured from, and
                                          // where the arcs of a round one sit inside it, in pixels
layout(location = 5) in vec4 aPicture;    // where its top left samples the picture, and across it
layout(location = 6) in vec4 aPart;       // the part of the picture the box is, of one
layout(location = 7) in vec3 aCut;        // how round its corners are, how sharp that edge is, and
                                          // how far what it draws is spread: pixels, as halves
layout(location = 8) in vec4 aColour;     // the colour it is drawn in
layout(location = 9) in float aTexture;   // which picture it samples
layout(location = 10) in float aDepth;    // and how deep it is
layout(location = 11) in float aOwn;      // whether the picture is drawn as it is, of one

layout(location = 0) flat out vec4 vertexColor;
layout(location = 1) out vec2 texCoord;
layout(location = 2) flat out int texIndex;
layout(location = 3) out vec2 corner;
layout(location = 4) flat out vec2 inner;
layout(location = 5) flat out vec2 edge;
layout(location = 6) flat out float own;
layout(location = 7) flat out vec4 uvRect;
layout(location = 8) flat out float blur;

void main() {
    // Where this corner of the quad is. The four corners are what the instance names; which of them
    // this is, is where the corner of the unit square is. Across and down are two mixes rather than
    // one, because a quad is not a parallelogram in general -- a shape of a canvas is four points
    // that need not be one.
    vec2 across = mix(aCorner01.xy, aCorner01.zw, aUnit.x);
    vec2 below = mix(aCorner23.zw, aCorner23.xy, aUnit.x);
    vec2 where = mix(across, below, aUnit.y);

    gl_Position = vec4(where, aDepth, 1.0);

    // Where this corner is from the middle of the box, in pixels: what the cut of a box is measured
    // from, spread across the quad by the rasteriser so that every pixel of it has its own. Both
    // directions are in pixels rather than one, so that a rounded corner is round on a window that
    // is not square.
    corner = (where - aBox.xy) * aScale;

    // Which point of the picture this corner samples: where the quad's own top left samples it, and
    // how far across and down the whole of the quad goes.
    texCoord = aPicture.xy + aPicture.zw * aUnit;

    vertexColor = aColour;
    texIndex = int(aTexture);
    inner = aBox.zw;
    edge = aCut.xy;
    blur = aCut.z;
    uvRect = aPart;
    own = aOwn;
}
