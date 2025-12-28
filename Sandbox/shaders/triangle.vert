#version 460
#extension GL_EXT_buffer_reference : require
// scalar yerine std430 kullanıyoruz, daha standarttır.
#extension GL_EXT_scalar_block_layout : enable

// Odin'deki struct: { pos: [2]f32, color: [3]f32, pad: f32 }
// GLSL std430 kuralı: vec2 (8 byte), vec3 (16 byte hizalama ister!)
// Bu yüzden hizalamayı elle yapıyoruz ki Odin ile %100 uyuşsun.

struct Vertex {
    vec2 pos; // Offset: 0,  Size: 8
    vec3 color; // Offset: 8,  Size: 12
    float pad; // Offset: 20, Size: 4
    // Toplam: 24 byte
};

// buffer_reference için de scalar layout kullanabiliriz ama hizalamaya dikkat.
layout(buffer_reference, scalar) buffer VertexBufferRef {
    Vertex vertices[];
};

layout(push_constant, scalar) uniform PushConstants {
    VertexBufferRef vertex_ptr;
    vec3 color;
    float _pad;
    vec2 offset;
    mat2 transform;
} pc;

layout(location = 0) out vec3 outColor;

void main() {
    Vertex v = pc.vertex_ptr.vertices[gl_VertexIndex];
    gl_Position = vec4(pc.transform * v.pos + pc.offset, 0.0, 1.0);
}
