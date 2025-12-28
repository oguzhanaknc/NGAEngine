#version 450
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : enable

layout(location = 0) in vec3 inColor;
layout(location = 0) out vec4 outFragColor;

layout(push_constant, scalar) uniform PushConstants {
    uvec2 _ptr_padding;
    vec3 color; // 8..20 byte
    float _pad; // 20..24 byte
    vec2 offset; // 24..32 byte
    mat2 transform;
} pc;

void main() {
    outFragColor = vec4(pc.color, 1.0);
}
