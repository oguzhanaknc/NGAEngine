package engine

import "core:fmt"
import "core:math/linalg/glsl"

Entity :: distinct u32

Transform2dComponent :: struct {
	translation: glsl.vec2,
	mat2:        glsl.mat2, // Rotasyon ve Scale matrisi
	color:       glsl.vec3,
	scale:       glsl.vec2,
}

World :: struct {
	entities:   [dynamic]Entity,
	transforms: #soa[dynamic]Transform2dComponent,
}

g_world: World


create_entity :: proc(
	pos: glsl.vec2 = glsl.vec2{0, 0},
	color: glsl.vec3 = glsl.vec3{1.0, 0.0, 0.0},
	transform_mat: glsl.mat2 = glsl.mat2{1, 0, 0, 1},
	scale: glsl.vec2 = glsl.vec2{1.0, 1.0},
) -> Entity {

	id := Entity(len(g_world.entities))
	append(&g_world.entities, id)

	append_soa(
		&g_world.transforms,
		Transform2dComponent{translation = pos, mat2 = transform_mat, color = color},
	)
	return id
}
