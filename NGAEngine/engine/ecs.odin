package engine

import "core:math"
import "core:math/linalg/glsl"
Entity :: distinct u32


Transform2dComponent :: struct {
	translation: glsl.vec2,
	mat2:        glsl.mat2, // Rotasyon ve Scale matrisi
	color:       glsl.vec3,
	scale:       glsl.vec2,
	rotation:    f32,
}


World :: struct {
	entities:   [dynamic]Entity,
	transforms: #soa[dynamic]Transform2dComponent,
}

g_world: World


create_entity :: proc(
    pos: glsl.vec2 = glsl.vec2{0, 0},
    color: glsl.vec3 = glsl.vec3{1.0, 0.0, 0.0},
    scale: glsl.vec2 = glsl.vec2{1.0, 1.0},
    rotation: f32 = 0.0, // Varsayılan rotasyon 0
) -> Entity {

    id := Entity(len(g_world.entities))
    append(&g_world.entities, id)

    // Component'i oluştur
    transform := Transform2dComponent {
        scale = scale,
        translation = pos,
        rotation = rotation,
        color = color,
        // mat2'yi aşağıda hesaplayacağız
    }

    // Matrisi başlangıç değerlerine göre ayarla
    c := math.cos(rotation)
    s := math.sin(rotation)
    transform.mat2 = glsl.mat2{
        scale.x * c,  scale.x * s,
       -scale.y * s,  scale.y * c,
    }

    append_soa(&g_world.transforms, transform)
    return id
}

@(private)
recalc_mat2 :: proc(t: ^Transform2dComponent) {
    c := math.cos(t.rotation)
    s := math.sin(t.rotation)

    // Odin/GLSL matris yapıcıları sütun-önceliklidir (Column-Major).
    // Col 1: X ekseni vektörü
    // Col 2: Y ekseni vektörü

    // [ sx * cos,  -sy * sin ]
    // [ sx * sin,   sy * cos ]

    t.mat2 = glsl.mat2{
        t.scale.x * c,  t.scale.x * s, // 1. Sütun
       -t.scale.y * s,  t.scale.y * c, // 2. Sütun
    }
}

set_scale :: proc(e: Entity, new_scale: glsl.vec2) {
    // 1. SOA Pointer'ı al (Bu özel bir tiptir: #soa ^...)
    t_soa_ptr := &g_world.transforms[e]

    // 2. Veriyi normal bir struct kopyasına çek (De-serialize)
    // SOA pointer'ın sonuna '^' koyarak veriyi okuyoruz.
    t_copy := t_soa_ptr^

    // 3. Kopyayı güncelle
    t_copy.scale = new_scale
    recalc_mat2(&t_copy) // Artık normal bir struct pointer gönderebilirsin!

    // 4. Güncellenmiş veriyi geri SOA dizisine yaz (Serialize)
    t_soa_ptr^ = t_copy
}

set_rotation :: proc(e: Entity, angle_radians: f32) {
    t_soa_ptr := &g_world.transforms[e]

    // Kopyala -> Değiştir -> Geri Yaz
    t_copy := t_soa_ptr^
    t_copy.rotation = angle_radians
    recalc_mat2(&t_copy)

    t_soa_ptr^ = t_copy
}

// Yardımcı: Derece cinsinden kullanım için
set_rotation_deg :: proc(e: Entity, angle_degrees: f32) {
    set_rotation(e, math.to_radians(angle_degrees))
}
