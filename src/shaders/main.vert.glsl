#version 450

out gl_PerVertex {
    vec4 gl_Position;
};

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec4 aColor;
layout(location = 2) in vec2 aTexCoord;
layout(location = 3) in float aTexIndex;
// A corner of a box that is cut round: where this corner is from the middle of the box, and where
// the arcs sit inside it. Both are in pixels across the window and down it, which is what makes a
// radius as long one way as the other on a window that is not square.
layout(location = 4) in vec4 aCorner;
layout(location = 5) in float aRadius;

layout(location = 0) out vec4 vertexColor;
layout(location = 1) out vec2 texCoord;
layout(location = 2) flat out int texIndex;
layout(location = 3) out vec2 corner;
layout(location = 4) out vec2 inner;
layout(location = 5) out float radius;

void main() {
    gl_Position = vec4(aPos, 1.0);
    vertexColor = aColor;
    texCoord = aTexCoord;
    texIndex = int(aTexIndex);
    corner = aCorner.xy;
    inner = aCorner.zw;
    radius = aRadius;
}
